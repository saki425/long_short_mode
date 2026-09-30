import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';

class CompletedGridCycleRebuildReport {
  const CompletedGridCycleRebuildReport({
    required this.filledBuyCount,
    required this.filledSellCount,
    required this.matchedCycles,
    required this.insertedCycles,
    required this.skippedDuplicates,
    required this.missingFills,
    required this.unmatchedOrders,
    required this.realizedPnl,
  });

  final int filledBuyCount;
  final int filledSellCount;
  final int matchedCycles;
  final int insertedCycles;
  final int skippedDuplicates;
  final int missingFills;
  final int unmatchedOrders;
  final Decimal realizedPnl;

  String toDisplayText() {
    return [
      '找到 FILLED BUY 数量: $filledBuyCount',
      '找到 FILLED SELL 数量: $filledSellCount',
      '成功匹配循环数量: $matchedCycles',
      '新增 completed cycles 数量: $insertedCycles',
      '跳过重复数量: $skippedDuplicates',
      '缺少 fills 数量: $missingFills',
      '无法匹配数量: $unmatchedOrders',
      '重新计算 realizedPnl: $realizedPnl USDT',
    ].join('\n');
  }
}

class CompletedGridCycleService {
  CompletedGridCycleService(this.db);

  final AppDatabase db;
  final _uuid = const Uuid();

  Stream<List<CompletedGridCycle>> watchCycles(String strategyId) {
    return (db.select(db.completedGridCycles)
          ..where((tbl) => tbl.strategyId.equals(strategyId))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.completedAt)]))
        .watch();
  }

  Future<CompletedGridCycleRebuildReport> rebuildForStrategy(
    String strategyId,
  ) async {
    final strategy = await (db.select(db.strategies)
          ..where((tbl) => tbl.id.equals(strategyId)))
        .getSingleOrNull();
    final isFuturesLongGrid = strategy?.environment == 'LIVE_FUTURES_GRID';
    final orderSource =
        isFuturesLongGrid ? 'autoFuturesLongGrid' : 'autoSpotGrid';
    final buyPurpose = isFuturesLongGrid ? 'futuresLongGridBuy' : 'gridBuy';
    final sellPurpose = isFuturesLongGrid ? 'futuresLongGridSell' : 'gridSell';
    final orders = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.source.equals(orderSource),
          ))
        .get();
    final fills = await (db.select(db.fills)
          ..where((tbl) => tbl.strategyId.equals(strategyId)))
        .get();
    final existing = await (db.select(db.completedGridCycles)
          ..where((tbl) => tbl.strategyId.equals(strategyId)))
        .get();

    final fillsByOrder = <String, List<Fill>>{};
    for (final fill in fills) {
      fillsByOrder.putIfAbsent(fill.orderId, () => <Fill>[]).add(fill);
    }

    final filledBuys = orders
        .where(
          (order) =>
              order.side == 'BUY' &&
              order.purpose == buyPurpose &&
              order.status == 'filled' &&
              order.gridLevelId != null,
        )
        .toList()
      ..sort(
        (a, b) => a.completedAtOrUpdated.compareTo(b.completedAtOrUpdated),
      );
    final filledSells = orders
        .where(
          (order) =>
              order.side == 'SELL' &&
              order.purpose == sellPurpose &&
              order.status == 'filled' &&
              order.gridLevelId != null,
        )
        .toList()
      ..sort(
        (a, b) => a.completedAtOrUpdated.compareTo(b.completedAtOrUpdated),
      );

    final existingPairs = {
      for (final cycle in existing) '${cycle.buyOrderId}:${cycle.sellOrderId}',
    };
    final existingGridCycles = {
      for (final cycle in existing)
        '${cycle.strategyId}:${cycle.gridId}:${cycle.cycleNumber}',
    };
    final usedSellIds = <String>{};
    final nextCycleByGrid = <String, int>{};
    for (final cycle in existing) {
      final current = nextCycleByGrid[cycle.gridId] ?? 0;
      if (cycle.cycleNumber >= current) {
        nextCycleByGrid[cycle.gridId] = cycle.cycleNumber + 1;
      }
    }

    var matchedCycles = 0;
    var insertedCycles = 0;
    var skippedDuplicates = 0;
    var missingFills = 0;
    var realizedPnl = Decimal.zero;

    for (final buy in filledBuys) {
      final buyFills = fillsByOrder[buy.id] ?? const <Fill>[];
      if (buyFills.isEmpty) {
        missingFills += 1;
      }
      final sell = _findMatchingSell(
        buy: buy,
        candidates: filledSells,
        usedSellIds: usedSellIds,
      );
      if (sell == null) {
        continue;
      }
      final sellFills = fillsByOrder[sell.id] ?? const <Fill>[];
      if (sellFills.isEmpty) {
        missingFills += 1;
      }
      usedSellIds.add(sell.id);
      matchedCycles += 1;

      final pairKey = '${buy.id}:${sell.id}';
      if (existingPairs.contains(pairKey)) {
        skippedDuplicates += 1;
        continue;
      }

      final gridId = buy.gridLevelId!;
      var cycleNumber = nextCycleByGrid[gridId] ?? 0;
      while (existingGridCycles.contains('$strategyId:$gridId:$cycleNumber')) {
        cycleNumber += 1;
      }

      final cycle = _buildCycle(
        strategyId: strategyId,
        gridId: gridId,
        cycleNumber: cycleNumber,
        buy: buy,
        sell: sell,
        buyFills: buyFills,
        sellFills: sellFills,
      );
      final rows = await db
          .into(db.completedGridCycles)
          .insert(cycle, mode: InsertMode.insertOrIgnore);
      if (rows > 0) {
        insertedCycles += 1;
        realizedPnl += _d(cycle.netPnl.value);
        nextCycleByGrid[gridId] = cycleNumber + 1;
        existingGridCycles.add('$strategyId:$gridId:$cycleNumber');
        existingPairs.add(pairKey);
      } else {
        skippedDuplicates += 1;
      }
    }

    await _refreshGridCycleCounters(strategyId);

    return CompletedGridCycleRebuildReport(
      filledBuyCount: filledBuys.length,
      filledSellCount: filledSells.length,
      matchedCycles: matchedCycles,
      insertedCycles: insertedCycles,
      skippedDuplicates: skippedDuplicates,
      missingFills: missingFills,
      unmatchedOrders: filledBuys.length - matchedCycles,
      realizedPnl: realizedPnl,
    );
  }

  Order? _findMatchingSell({
    required Order buy,
    required List<Order> candidates,
    required Set<String> usedSellIds,
  }) {
    for (final sell in candidates) {
      if (usedSellIds.contains(sell.id)) continue;
      if (sell.parentOrderId == buy.id) return sell;
    }
    for (final sell in candidates) {
      if (usedSellIds.contains(sell.id)) continue;
      if (sell.gridLevelId != buy.gridLevelId) continue;
      if (sell.createdAt.isBefore(buy.createdAt)) continue;
      return sell;
    }
    return null;
  }

  CompletedGridCyclesCompanion _buildCycle({
    required String strategyId,
    required String gridId,
    required int cycleNumber,
    required Order buy,
    required Order sell,
    required List<Fill> buyFills,
    required List<Fill> sellFills,
  }) {
    final buyQty = _quantityFromFillsOrOrder(buy, buyFills);
    final sellQty = _quantityFromFillsOrOrder(sell, sellFills);
    final baseQty = buyQty < sellQty ? buyQty : sellQty;
    final buyQuote = _quoteFromFillsOrOrder(buy, buyFills, baseQty);
    final sellQuote = _quoteFromFillsOrOrder(sell, sellFills, baseQty);
    final buyAvg = _safeDivide(buyQuote, baseQty);
    final sellAvg = _safeDivide(sellQuote, baseQty);
    final buyFee = _feeInUsdt(buyFills, buyAvg);
    final sellFee = _feeInUsdt(sellFills, sellAvg);
    final grossPnl = sellQuote - buyQuote;
    final netPnl = grossPnl - buyFee - sellFee;
    final pnlPct = _safeDivide(netPnl, buyQuote);
    final completedAt = sell.completedAt ?? sell.updatedAt;
    return CompletedGridCyclesCompanion.insert(
      id: _uuid.v4(),
      strategyId: strategyId,
      gridId: gridId,
      cycleNumber: cycleNumber,
      buyOrderId: buy.id,
      sellOrderId: sell.id,
      buyExchangeOrderId: Value(buy.exchangeOrderId),
      sellExchangeOrderId: Value(sell.exchangeOrderId),
      buyClientOrderId: buy.clientOrderId,
      sellClientOrderId: sell.clientOrderId,
      buyAvgPrice: buyAvg.toString(),
      sellAvgPrice: sellAvg.toString(),
      baseQty: baseQty.toString(),
      buyQuoteAmount: buyQuote.toString(),
      sellQuoteAmount: sellQuote.toString(),
      buyFeeUsdt: buyFee.toString(),
      sellFeeUsdt: sellFee.toString(),
      grossPnl: grossPnl.toString(),
      netPnl: netPnl.toString(),
      pnlPct: pnlPct.toString(),
      startedAt: buy.createdAt,
      completedAt: completedAt,
      createdAt: DateTime.now().toUtc(),
    );
  }

  Future<void> _refreshGridCycleCounters(String strategyId) async {
    final cycles = await (db.select(db.completedGridCycles)
          ..where((tbl) => tbl.strategyId.equals(strategyId)))
        .get();
    final byGrid = <String, List<CompletedGridCycle>>{};
    for (final cycle in cycles) {
      byGrid.putIfAbsent(cycle.gridId, () => <CompletedGridCycle>[]).add(cycle);
    }
    for (final entry in byGrid.entries) {
      final rows = entry.value
        ..sort((a, b) => a.completedAt.compareTo(b.completedAt));
      final last = rows.last;
      await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(entry.key)))
          .write(
        GridLevelsCompanion(
          cycleNumber: Value(rows.length),
          lastCompletedOrderId: Value(last.sellOrderId),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
    }
  }

  Decimal _quantityFromFillsOrOrder(Order order, List<Fill> fills) {
    final fillQty = fills.fold<Decimal>(
      Decimal.zero,
      (sum, fill) => sum + _d(fill.quantity),
    );
    return fillQty > Decimal.zero ? fillQty : _d(order.executedQuantity);
  }

  Decimal _quoteFromFillsOrOrder(
    Order order,
    List<Fill> fills,
    Decimal baseQty,
  ) {
    final fillQty = _quantityFromFillsOrOrder(order, fills);
    final fillQuote = fills.fold<Decimal>(
      Decimal.zero,
      (sum, fill) => sum + _d(fill.quoteQuantity),
    );
    if (fillQuote > Decimal.zero && fillQty > Decimal.zero) {
      return _safeDivide(fillQuote, fillQty) * baseQty;
    }
    final quote = _d(order.quoteQuantity);
    final orderQty = _d(order.executedQuantity);
    if (quote > Decimal.zero && orderQty > Decimal.zero) {
      return _safeDivide(quote, orderQty) * baseQty;
    }
    final avg = _d(order.averagePrice ?? order.price);
    return avg * baseQty;
  }

  Decimal _feeInUsdt(List<Fill> fills, Decimal referencePrice) {
    return fills.fold<Decimal>(Decimal.zero, (sum, fill) {
      final commission = _d(fill.commission);
      final asset = fill.commissionAsset.toUpperCase();
      if (asset == 'USDT') return sum + commission;
      if (asset == 'BTC') return sum + commission * referencePrice;
      return sum;
    });
  }

  Decimal _safeDivide(Decimal numerator, Decimal denominator) {
    if (denominator == Decimal.zero) return Decimal.zero;
    return (numerator / denominator).toDecimal(scaleOnInfinitePrecision: 12);
  }

  Decimal _d(String? value) => Decimal.tryParse(value ?? '') ?? Decimal.zero;
}

extension on Order {
  DateTime get completedAtOrUpdated => completedAt ?? updatedAt;
}
