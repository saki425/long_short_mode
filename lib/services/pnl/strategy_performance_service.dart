import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import '../market_data/market_data_coordinator.dart';

class PeriodPerformance {
  const PeriodPerformance({
    required this.label,
    required this.pnl,
    required this.returnRate,
  });

  final String label;
  final Decimal pnl;
  final Decimal returnRate;
}

class StrategyPerformanceStats {
  const StrategyPerformanceStats({
    required this.strategy,
    required this.initialCapital,
    required this.currentSpotBalance,
    required this.currentFuturesMargin,
    required this.completedGridCycles,
    required this.spotGridRealizedPnl,
    required this.unrealizedSpotPnl,
    required this.futuresRealizedPnl,
    required this.futuresUnrealizedPnl,
    required this.fundingFee,
    required this.spotFees,
    required this.futuresFees,
    required this.currentNetWorth,
    required this.runningDays,
    required this.netPnl,
    required this.realizedOnlyNetPnl,
    required this.returnRate,
    required this.annualizedReturn,
    required this.realizedOnlyAnnualizedReturn,
    required this.maxFloatingLoss,
    required this.maxDrawdown,
    required this.periods,
    required this.sampleInsufficient,
  });

  final Strategy strategy;
  final Decimal initialCapital;
  final Decimal currentSpotBalance;
  final Decimal currentFuturesMargin;
  final int completedGridCycles;
  final Decimal spotGridRealizedPnl;
  final Decimal unrealizedSpotPnl;
  final Decimal futuresRealizedPnl;
  final Decimal futuresUnrealizedPnl;
  final Decimal fundingFee;
  final Decimal spotFees;
  final Decimal futuresFees;
  final Decimal currentNetWorth;
  final Decimal runningDays;
  final Decimal netPnl;
  final Decimal realizedOnlyNetPnl;
  final Decimal returnRate;
  final Decimal annualizedReturn;
  final Decimal realizedOnlyAnnualizedReturn;
  final Decimal maxFloatingLoss;
  final Decimal maxDrawdown;
  final List<PeriodPerformance> periods;
  final bool sampleInsufficient;
}

class StrategyPerformanceService {
  StrategyPerformanceService(this.db, this.marketData);

  final AppDatabase db;
  final MarketDataCoordinator marketData;

  Stream<Strategy?> watchCurrentStrategy({String? symbol}) {
    return (db.select(db.strategies)
          ..where(
            (tbl) =>
                (symbol == null
                    ? const Constant(true)
                    : tbl.symbol.equals(symbol)) &
                tbl.status.isNotIn(['archived', 'completed']),
          )
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)])
          ..limit(1))
        .watchSingleOrNull();
  }

  Stream<List<Strategy>> watchStrategies({String? symbol}) {
    return (db.select(db.strategies)
          ..where(
            (tbl) =>
                (symbol == null
                    ? const Constant(true)
                    : tbl.symbol.equals(symbol)) &
                tbl.status.isNotIn(['archived']),
          )
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)]))
        .watch();
  }

  Future<List<StrategyPerformanceStats>> calculateStrategies({
    String? symbol,
  }) async {
    final strategies =
        await (db.select(db.strategies)
              ..where(
                (tbl) =>
                    (symbol == null
                        ? const Constant(true)
                        : tbl.symbol.equals(symbol)) &
                    tbl.status.isNotIn(['archived']),
              )
              ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)]))
            .get();
    final stats = <StrategyPerformanceStats>[];
    for (final strategy in strategies) {
      stats.add(await calculate(strategy.id));
    }
    return stats;
  }

  Future<void> archiveStrategyRecord(String strategyId) async {
    await (db.update(db.strategies)
      ..where((tbl) => tbl.id.equals(strategyId))).write(
      StrategiesCompanion(
        status: const Value('archived'),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<StrategyPerformanceStats> calculate(String strategyId) async {
    final strategy =
        await (db.select(db.strategies)
          ..where((tbl) => tbl.id.equals(strategyId))).getSingle();
    final pnlRows =
        await (db.select(db.pnlSnapshots)
              ..where((tbl) => tbl.strategyId.equals(strategyId))
              ..orderBy([(tbl) => OrderingTerm.asc(tbl.recordedAt)]))
            .get();
    final orders =
        await (db.select(db.orders)
          ..where((tbl) => tbl.strategyId.equals(strategyId))).get();
    final futuresScope = await _futuresScopeFor(strategy, orders);
    final fills =
        await (db.select(db.fills)
          ..where((tbl) => tbl.strategyId.equals(strategyId))).get();
    final completedCycles =
        await (db.select(db.completedGridCycles)
              ..where((tbl) => tbl.strategyId.equals(strategyId))
              ..orderBy([(tbl) => OrderingTerm.asc(tbl.completedAt)]))
            .get();
    final hedgeActions =
        await (db.select(db.hedgeActions)
          ..where((tbl) => tbl.strategyId.equals(strategyId))).get();
    final futuresTrades =
        await (db.select(db.exchangeTrades)..where(
          (tbl) =>
              tbl.environment.equals('live') &
              tbl.marketType.equals('usdtFutures') &
              tbl.symbol.equals(strategy.symbol) &
              _optionalProfileFilter(
                tbl.keyProfileId,
                futuresScope.keyProfileId,
              ),
        )).get();
    final fundingRows =
        await (db.select(db.fundingFeeRecords)..where(
          (tbl) =>
              tbl.symbol.equals(strategy.symbol) &
              _optionalProfileFilter(
                tbl.keyProfileId,
                futuresScope.keyProfileId,
              ),
        )).get();
    final latestFutures =
        await (db.select(db.futuresAccountSnapshots)
              ..where(
                (tbl) => _optionalProfileFilter(
                  tbl.keyProfileId,
                  futuresScope.keyProfileId,
                ),
              )
              ..orderBy([(tbl) => OrderingTerm.desc(tbl.recordedAt)])
              ..limit(1))
            .getSingleOrNull();

    final initialCapital =
        _d(strategy.spotCapital) +
        _d(strategy.futuresCapital) +
        _d(strategy.reserveCapital);
    final markPrice =
        marketData.latestFuturesMarkPriceFor(strategy.symbol)?.markPrice ??
        marketData.latestSpotTickerFor(strategy.symbol)?.midPrice ??
        _d(latestFutures?.markPrice);
    final spotBreakdown = _calculateSpotBreakdown(
      orders: orders,
      fills: fills,
      markPrice: markPrice,
    );
    final spotGridRealizedPnl = _sum(completedCycles.map((row) => row.netPnl));
    final unrealizedSpotPnl = spotBreakdown.unrealizedSpotPnl;
    final spotFees = spotBreakdown.spotFees;
    final hasStrategyHedge = hedgeActions.any((row) => row.dryRun == false);
    final futuresRealizedPnl =
        hasStrategyHedge
            ? _sum(futuresTrades.map((row) => row.realizedPnl ?? '0'))
            : Decimal.zero;
    final futuresFees =
        hasStrategyHedge
            ? _sum(futuresTrades.map((row) => row.commission))
            : Decimal.zero;
    final futuresUnrealizedPnl =
        hasStrategyHedge ? _d(latestFutures?.totalUnrealizedPnl) : Decimal.zero;
    final fundingFee =
        hasStrategyHedge
            ? _sum(fundingRows.map((row) => row.income))
            : Decimal.zero;
    final netPnl =
        spotGridRealizedPnl +
        unrealizedSpotPnl +
        futuresRealizedPnl +
        futuresUnrealizedPnl +
        fundingFee -
        spotBreakdown.unrealizedSpotFees -
        futuresFees;
    final realizedOnlyNetPnl =
        spotGridRealizedPnl +
        futuresRealizedPnl +
        fundingFee -
        spotBreakdown.unrealizedSpotFees -
        futuresFees;
    final runningDays = _runningDays(strategy);
    final returnRate = _safeDivide(netPnl, initialCapital);
    final annualizedReturn =
        runningDays <= Decimal.zero
            ? Decimal.zero
            : _safeDivide(returnRate, runningDays) * Decimal.fromInt(365);
    final realizedOnlyAnnualizedReturn =
        runningDays <= Decimal.zero
            ? Decimal.zero
            : _safeDivide(
                  _safeDivide(realizedOnlyNetPnl, initialCapital),
                  runningDays,
                ) *
                Decimal.fromInt(365);
    final currentSpotBalance =
        initialCapital +
        spotGridRealizedPnl +
        unrealizedSpotPnl -
        spotBreakdown.unrealizedSpotFees;
    final currentFuturesMargin = _d(latestFutures?.walletBalance);
    final currentNetWorth = initialCapital + netPnl;
    final maxDrawdown = _maxDrawdown(pnlRows);
    final maxFloatingLoss = _maxFloatingLoss(pnlRows);

    return StrategyPerformanceStats(
      strategy: strategy,
      initialCapital: initialCapital,
      currentSpotBalance: currentSpotBalance,
      currentFuturesMargin: currentFuturesMargin,
      completedGridCycles: completedCycles.length,
      spotGridRealizedPnl: spotGridRealizedPnl,
      unrealizedSpotPnl: unrealizedSpotPnl,
      futuresRealizedPnl: futuresRealizedPnl,
      futuresUnrealizedPnl: futuresUnrealizedPnl,
      fundingFee: fundingFee,
      spotFees: spotFees,
      futuresFees: futuresFees,
      currentNetWorth: currentNetWorth,
      runningDays: runningDays,
      netPnl: netPnl,
      realizedOnlyNetPnl: realizedOnlyNetPnl,
      returnRate: returnRate,
      annualizedReturn: annualizedReturn,
      realizedOnlyAnnualizedReturn: realizedOnlyAnnualizedReturn,
      maxFloatingLoss: maxFloatingLoss,
      maxDrawdown: maxDrawdown,
      periods: _periods(completedCycles, initialCapital),
      sampleInsufficient: runningDays < Decimal.fromInt(7),
    );
  }

  Future<_FuturesPnlScope> _futuresScopeFor(
    Strategy strategy,
    List<Order> orders,
  ) async {
    final orderProfileId = orders
        .where((order) => order.marketType == 'usdtFutures')
        .map((order) => order.keyProfileId?.trim())
        .firstWhere(
          (value) => value != null && value.isNotEmpty,
          orElse: () => null,
        );
    if (orderProfileId != null && orderProfileId.isNotEmpty) {
      return _FuturesPnlScope(keyProfileId: orderProfileId);
    }

    final binding =
        await (db.select(db.symbolAccountBindings)
              ..where(
                (tbl) =>
                    tbl.symbol.equals(strategy.symbol) &
                    tbl.environment.equals('live'),
              )
              ..limit(1))
            .getSingleOrNull();
    final bindingProfileId = binding?.futuresKeyProfileId?.trim();
    return _FuturesPnlScope(
      keyProfileId:
          bindingProfileId == null || bindingProfileId.isEmpty
              ? null
              : bindingProfileId,
    );
  }

  Expression<bool> _optionalProfileFilter(
    Expression<String> column,
    String? keyProfileId,
  ) {
    if (keyProfileId == null || keyProfileId.isEmpty) {
      return const Constant(true);
    }
    return column.equals(keyProfileId);
  }

  List<PeriodPerformance> _periods(
    List<CompletedGridCycle> cycles,
    Decimal initialCapital,
  ) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day).toUtc();
    return [
      _period('今日收益', cycles, today, initialCapital),
      _period(
        '7日收益',
        cycles,
        now.subtract(const Duration(days: 7)).toUtc(),
        initialCapital,
      ),
      _period(
        '30日收益',
        cycles,
        now.subtract(const Duration(days: 30)).toUtc(),
        initialCapital,
      ),
      _period(
        '累计收益',
        cycles,
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        initialCapital,
      ),
    ];
  }

  PeriodPerformance _period(
    String label,
    List<CompletedGridCycle> cycles,
    DateTime start,
    Decimal initialCapital,
  ) {
    final pnl = cycles
        .where(
          (cycle) =>
              cycle.completedAt.toUtc().isAfter(start) ||
              cycle.completedAt.toUtc().isAtSameMomentAs(start),
        )
        .fold<Decimal>(Decimal.zero, (sum, cycle) => sum + _d(cycle.netPnl));
    return PeriodPerformance(
      label: label,
      pnl: pnl,
      returnRate: _safeDivide(pnl, initialCapital),
    );
  }

  Decimal _runningDays(Strategy strategy) {
    final start = strategy.startedAt ?? strategy.createdAt;
    final seconds = DateTime.now().toUtc().difference(start.toUtc()).inSeconds;
    if (seconds <= 0) {
      return Decimal.parse('0.000001');
    }
    return (Decimal.fromInt(seconds) / Decimal.fromInt(86400)).toDecimal(
      scaleOnInfinitePrecision: 12,
    );
  }

  Decimal _maxDrawdown(List<PnlSnapshot> rows) {
    var peak = Decimal.zero;
    var maxDrawdown = Decimal.zero;
    for (final row in rows) {
      final equity = _d(row.totalEquity);
      if (equity > peak) {
        peak = equity;
      }
      final drawdown = peak - equity;
      if (drawdown > maxDrawdown) {
        maxDrawdown = drawdown;
      }
    }
    return maxDrawdown;
  }

  Decimal _maxFloatingLoss(List<PnlSnapshot> rows) {
    var maxLoss = Decimal.zero;
    for (final row in rows) {
      final floating = _d(row.spotUnrealizedPnl) + _d(row.futuresUnrealizedPnl);
      if (floating < maxLoss) {
        maxLoss = floating;
      }
    }
    return maxLoss.abs();
  }

  Decimal _sum(Iterable<String?> values) {
    return values.fold(Decimal.zero, (sum, value) => sum + _d(value));
  }

  _SpotPnlBreakdown _calculateSpotBreakdown({
    required List<Order> orders,
    required List<Fill> fills,
    required Decimal markPrice,
  }) {
    final fillsByOrder = <String, List<Fill>>{};
    for (final fill in fills) {
      fillsByOrder.putIfAbsent(fill.orderId, () => <Fill>[]).add(fill);
    }
    Decimal realizedGridPnl = Decimal.zero;
    Decimal completedCycleFees = Decimal.zero;
    Decimal exposedBtc = Decimal.zero;
    Decimal exposedCost = Decimal.zero;
    int completedCycles = 0;

    final sellChildren = <String, List<Order>>{};
    for (final order in orders) {
      final parentId = order.parentOrderId;
      if (parentId != null && order.side == 'SELL') {
        sellChildren.putIfAbsent(parentId, () => <Order>[]).add(order);
      }
    }

    final buyOrders = orders.where(
      (order) =>
          order.side == 'BUY' &&
          order.purpose == 'gridBuy' &&
          _d(order.executedQuantity) > Decimal.zero,
    );
    for (final buy in buyOrders) {
      final buyQty = _d(buy.executedQuantity);
      if (buyQty <= Decimal.zero) {
        continue;
      }
      final buyQuote = _orderQuote(buy, fillsByOrder[buy.id]);
      final buyAvg = _safeDivide(buyQuote, buyQty);
      final sellOrders = sellChildren[buy.id] ?? const <Order>[];
      final filledSell = sellOrders.where((order) => order.status == 'filled');
      for (final sell in filledSell) {
        final sellQty = _d(sell.executedQuantity);
        final sellQuote = _orderQuote(sell, fillsByOrder[sell.id]);
        final buyCostForSell = buyAvg * sellQty;
        final buyFeeForSell =
            _feeInUsdt(fillsByOrder[buy.id] ?? const [], markPrice) *
            _safeDivide(sellQty, buyQty);
        final sellFee = _feeInUsdt(
          fillsByOrder[sell.id] ?? const [],
          markPrice,
        );
        realizedGridPnl += sellQuote - buyCostForSell - buyFeeForSell - sellFee;
        completedCycleFees += buyFeeForSell + sellFee;
        completedCycles += 1;
      }
      final allSellFilledQty = sellOrders.fold<Decimal>(
        Decimal.zero,
        (sum, sell) => sum + _d(sell.executedQuantity),
      );
      final remainingQty = buyQty - allSellFilledQty;
      if (remainingQty > Decimal.zero) {
        exposedBtc += remainingQty;
        exposedCost += buyAvg * remainingQty;
      }
    }

    final spotFees = _feeInUsdt(fills, markPrice);
    final unrealizedSpotPnl = exposedBtc * markPrice - exposedCost;
    final unrealizedSpotFees = spotFees - completedCycleFees;
    return _SpotPnlBreakdown(
      realizedGridPnl: realizedGridPnl,
      unrealizedSpotPnl: unrealizedSpotPnl,
      spotFees: spotFees,
      unrealizedSpotFees:
          unrealizedSpotFees < Decimal.zero ? Decimal.zero : unrealizedSpotFees,
      completedCycles: completedCycles,
    );
  }

  Decimal _orderQuote(Order order, List<Fill>? fills) {
    final fillQuote = (fills ?? const <Fill>[]).fold<Decimal>(
      Decimal.zero,
      (sum, fill) => sum + _d(fill.quoteQuantity),
    );
    if (fillQuote > Decimal.zero) {
      return fillQuote;
    }
    final quote = _d(order.quoteQuantity);
    if (quote > Decimal.zero) {
      return quote;
    }
    final avg = _d(order.averagePrice ?? order.price);
    return avg * _d(order.executedQuantity);
  }

  Decimal _feeInUsdt(List<Fill> fills, Decimal markPrice) {
    return fills.fold<Decimal>(Decimal.zero, (sum, fill) {
      final commission = _d(fill.commission);
      final asset = fill.commissionAsset.toUpperCase();
      if (asset == 'USDT') {
        return sum + commission;
      }
      if (asset == 'BTC') {
        return sum + commission * markPrice;
      }
      if (asset == 'BNB') {
        return sum + commission;
      }
      return sum + commission;
    });
  }

  Decimal _safeDivide(Decimal numerator, Decimal denominator) {
    if (denominator == Decimal.zero) {
      return Decimal.zero;
    }
    return (numerator / denominator).toDecimal(scaleOnInfinitePrecision: 12);
  }

  Decimal _d(String? value) => Decimal.tryParse(value ?? '') ?? Decimal.zero;
}

class _FuturesPnlScope {
  const _FuturesPnlScope({required this.keyProfileId});

  final String? keyProfileId;
}

class _SpotPnlBreakdown {
  const _SpotPnlBreakdown({
    required this.realizedGridPnl,
    required this.unrealizedSpotPnl,
    required this.spotFees,
    required this.unrealizedSpotFees,
    required this.completedCycles,
  });

  final Decimal realizedGridPnl;
  final Decimal unrealizedSpotPnl;
  final Decimal spotFees;
  final Decimal unrealizedSpotFees;
  final int completedCycles;
}
