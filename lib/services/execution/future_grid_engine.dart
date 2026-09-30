import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide Column;

import '../../database/app_database.dart';
import 'live_exchange_execution_service.dart';

class FutureGridEngine {
  FutureGridEngine({required this.db, required this.liveExecution});

  static const source = 'autoFutureShortGrid';
  static const openPurpose = 'futuresShortGridOpen';
  static const closePurpose = 'futuresShortGridClose';

  final AppDatabase db;
  final LiveExchangeExecutionService liveExecution;

  Stream<List<FutureGridOrder>> watchFutureGridOrders(String strategyId) {
    return (db.select(db.futureGridOrders)
          ..where((tbl) => tbl.strategyId.equals(strategyId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.gridLevel)]))
        .watch();
  }

  Future<List<FutureGridOrder>> futureGridOrders(String strategyId) {
    return (db.select(db.futureGridOrders)
          ..where((tbl) => tbl.strategyId.equals(strategyId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.gridLevel)]))
        .get();
  }

  Future<void> ensureForStrategy(String strategyId, {int offset = 1}) async {
    final strategy =
        await (db.select(db.strategies)
          ..where((tbl) => tbl.id.equals(strategyId))).getSingleOrNull();
    if (strategy == null) {
      throw StateError('策略不存在: $strategyId');
    }
    final levels =
        await (db.select(db.gridLevels)
              ..where((tbl) => tbl.strategyId.equals(strategyId))
              ..orderBy([(tbl) => OrderingTerm.asc(tbl.gridIndex)]))
            .get();
    if (levels.isEmpty) {
      return;
    }
    final hedgeConfig = await _loadShortHedgeConfig(strategyId);
    final hedgeLayerIds = _bottomHedgeLayerIds(
      levels,
      hedgeConfig.spreadLevels,
    );
    final now = DateTime.now().toUtc();
    await (db.delete(db.futureGridOrders)..where(
      (tbl) =>
          tbl.strategyId.equals(strategyId) &
          tbl.status.isIn(['WAIT_OPEN', 'WAIT_TRIGGER']),
    )).go();
    for (final level in levels) {
      final layerPrice = _gridBuyPrice(level);
      if (layerPrice == null || !hedgeLayerIds.contains(level.id)) {
        continue;
      }
      final existing =
          await (db.select(db.futureGridOrders)..where(
            (tbl) => tbl.spotGridOrderId.equals(level.id),
          )).getSingleOrNull();
      if (existing?.status == 'OPEN') {
        continue;
      }
      final id = '${level.id}_future_short';
      await db
          .into(db.futureGridOrders)
          .insertOnConflictUpdate(
            FutureGridOrdersCompanion.insert(
              id: id,
              strategyId: strategyId,
              symbol: strategy.symbol,
              gridLevel: level.gridIndex,
              side: 'SHORT',
              price: layerPrice.toString(),
              quantity: '0',
              status: 'WAIT_TRIGGER',
              spotGridOrderId: level.id,
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
  }

  Future<void> onSpotBuyFilled(Order order) async {
    if (order.gridLevelId == null || order.side != 'BUY') {
      return;
    }
    final strategy =
        await (db.select(db.strategies)
          ..where((tbl) => tbl.id.equals(order.strategyId))).getSingleOrNull();
    if (strategy == null) {
      return;
    }
    final grid =
        await (db.select(
          db.gridLevels,
        )..where((tbl) => tbl.id.equals(order.gridLevelId!))).getSingleOrNull();
    if (grid == null) {
      return;
    }
    final layerPrice = _gridBuyPrice(grid);
    final hedgeConfig = await _loadShortHedgeConfig(order.strategyId);
    final levels =
        await (db.select(db.gridLevels)
          ..where((tbl) => tbl.strategyId.equals(order.strategyId))).get();
    final hedgeLayerIds = _bottomHedgeLayerIds(
      levels,
      hedgeConfig.spreadLevels,
    );
    if (layerPrice == null || !hedgeLayerIds.contains(grid.id)) {
      return;
    }
    final leverage = await _loadFuturesLeverage(order.strategyId);
    final longQty = await _openLongQuantity(order.strategyId);
    final spreadTargetTotal = longQty * hedgeConfig.multiplier;
    final spreadLevels = await _effectiveSpreadLevels(
      strategyId: order.strategyId,
      configuredLevels: hedgeConfig.spreadLevels,
    );
    final layerSpreadTarget = (spreadTargetTotal /
            Decimal.fromInt(spreadLevels))
        .toDecimal(scaleOnInfinitePrecision: 12);
    final layerLongQty = await _openLongQuantityForGrid(
      strategyId: order.strategyId,
      gridId: grid.id,
    );
    final layerTarget =
        layerSpreadTarget + (layerLongQty * hedgeConfig.multiplier);
    final ownLayerTargetTotal =
        await _openLongQuantityForHedgeLayers(
          strategyId: order.strategyId,
          configuredLevels: hedgeConfig.spreadLevels,
        ) *
        hedgeConfig.multiplier;
    final targetTotal = spreadTargetTotal + ownLayerTargetTotal;
    final shortQty = await _openLayerShortQuantity(order.strategyId);
    final totalRemaining = targetTotal - shortQty;
    if (totalRemaining <= Decimal.zero) {
      return;
    }
    final existing =
        await (db.select(db.futureGridOrders)..where(
          (tbl) => tbl.spotGridOrderId.equals(grid.id),
        )).getSingleOrNull();
    final existingQty =
        existing == null || existing.status != 'OPEN'
            ? Decimal.zero
            : _d(existing.quantity);
    final layerRemaining = layerTarget - existingQty;
    if (layerRemaining <= Decimal.zero) {
      return;
    }
    final quantityToOpen =
        layerRemaining < totalRemaining ? layerRemaining : totalRemaining;
    if (quantityToOpen <= Decimal.zero) {
      return;
    }
    if (existing != null && existing.status == 'OPEN') {
      final existingQty = _d(existing.quantity);
      if (existingQty >= layerTarget) {
        return;
      }
    }
    try {
      await liveExecution.connectFuturesForSymbol(strategy.symbol);
      final futuresOrderId = await liveExecution.placeHedgeFuturesMarketOrder(
        strategyId: order.strategyId,
        symbol: strategy.symbol,
        side: 'SELL',
        quantity: quantityToOpen,
        reduceOnly: false,
        leverage: leverage,
        source: source,
        purpose: openPurpose,
        gridLevelId: grid.id,
      );
      final now = DateTime.now().toUtc();
      final quantity =
          existing == null || existing.status != 'OPEN'
              ? quantityToOpen
              : _d(existing.quantity) + quantityToOpen;
      final futuresOrder = await _orderById(futuresOrderId);
      final status = _shortStatusForOrder(
        futuresOrder,
        fallbackStatus: 'OPEN',
        currentQuantity: quantity,
      );
      await db
          .into(db.futureGridOrders)
          .insertOnConflictUpdate(
            FutureGridOrdersCompanion.insert(
              id: existing?.id ?? '${grid.id}_future_short',
              strategyId: order.strategyId,
              symbol: strategy.symbol,
              gridLevel: grid.gridIndex,
              side: 'SHORT',
              price: layerPrice.toString(),
              quantity: quantity.toString(),
              status: status,
              spotGridOrderId: grid.id,
              futuresOrderId: Value(futuresOrderId),
              lastError: const Value(null),
              createdAt: existing?.createdAt ?? now,
              updatedAt: now,
            ),
          );
    } catch (error) {
      await _markLayerFailed(
        strategyId: order.strategyId,
        symbol: strategy.symbol,
        grid: grid,
        layerPrice: layerPrice,
        quantity: quantityToOpen,
        error: error,
      );
      rethrow;
    }
  }

  Future<void> onSpotSellFilled(Order order) async {
    if (order.gridLevelId == null || order.side != 'SELL') {
      return;
    }
    final strategy =
        await (db.select(db.strategies)
          ..where((tbl) => tbl.id.equals(order.strategyId))).getSingleOrNull();
    if (strategy == null) {
      return;
    }
    final sellPrice = _orderExecutionPrice(order);
    if (sellPrice == null || sellPrice <= Decimal.zero) {
      return;
    }
    final releaseRows = await _openLayersForRelease(
      strategyId: order.strategyId,
      sellPrice: sellPrice,
    );
    if (releaseRows.isEmpty) {
      return;
    }
    final leverage = await _loadFuturesLeverage(order.strategyId);
    for (final row in releaseRows) {
      try {
        await liveExecution.connectFuturesForSymbol(row.symbol);
        final futuresOrderId = await liveExecution.placeHedgeFuturesMarketOrder(
          strategyId: row.strategyId,
          symbol: row.symbol,
          side: 'BUY',
          quantity: _d(row.quantity),
          reduceOnly: true,
          leverage: leverage,
          source: source,
          purpose: closePurpose,
          gridLevelId: row.spotGridOrderId,
        );
        final futuresOrder = await _orderById(futuresOrderId);
        final update = _shortRowUpdateForOrder(row, futuresOrder);
        await (db.update(db.futureGridOrders)
          ..where((tbl) => tbl.id.equals(row.id))).write(
          FutureGridOrdersCompanion(
            status: Value(update.status),
            quantity: Value(update.quantity),
            futuresOrderId: Value(futuresOrderId),
            lastError: const Value(null),
            updatedAt: Value(DateTime.now().toUtc()),
          ),
        );
      } catch (error) {
        await (db.update(db.futureGridOrders)
          ..where((tbl) => tbl.id.equals(row.id))).write(
          FutureGridOrdersCompanion(
            status: const Value('FAILED'),
            lastError: Value(error.toString()),
            updatedAt: Value(DateTime.now().toUtc()),
          ),
        );
        rethrow;
      }
    }
  }

  Future<String> submitShort(String futureGridOrderId) async {
    final row =
        await (db.select(db.futureGridOrders)
          ..where((tbl) => tbl.id.equals(futureGridOrderId))).getSingle();
    if (row.status == 'CLOSED') {
      throw StateError('Future Short Grid 已关闭，不能重新挂单。');
    }
    final duplicate =
        await (db.select(db.futureGridOrders)..where(
          (tbl) =>
              tbl.strategyId.equals(row.strategyId) &
              tbl.price.equals(row.price) &
              tbl.side.equals(row.side) &
              tbl.status.isIn(['WAIT_OPEN', 'OPEN']) &
              tbl.id.equals(row.id).not(),
        )).get();
    if (duplicate.isNotEmpty) {
      throw StateError('存在相同价格的 Future Short Grid，禁止重复挂单。');
    }
    try {
      await liveExecution.connectFuturesForSymbol(row.symbol);
      final leverage = await _loadFuturesLeverage(row.strategyId);
      final orderId = await liveExecution.placeFuturesLimitOrder(
        symbol: row.symbol,
        positionSide: 'SHORT',
        side: 'SELL',
        quantity: _d(row.quantity),
        price: _d(row.price),
        reduceOnly: false,
        leverage: leverage,
        source: source,
        strategyId: row.strategyId,
        purpose: openPurpose,
        gridLevelId: row.spotGridOrderId,
      );
      final futuresOrder = await _orderById(orderId);
      final status = _shortStatusForOrder(
        futuresOrder,
        fallbackStatus: 'WAIT_OPEN',
        currentQuantity: _d(row.quantity),
      );
      await (db.update(db.futureGridOrders)
        ..where((tbl) => tbl.id.equals(row.id))).write(
        FutureGridOrdersCompanion(
          status: Value(status),
          futuresOrderId: Value(orderId),
          lastError: const Value(null),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      return orderId;
    } catch (error) {
      await (db.update(db.futureGridOrders)
        ..where((tbl) => tbl.id.equals(row.id))).write(
        FutureGridOrdersCompanion(
          status: const Value('FAILED'),
          lastError: Value(error.toString()),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      rethrow;
    }
  }

  Future<void> submitAllWaiting(String strategyId) async {
    return;
  }

  Future<FutureGridReconcileReport> reconcileStrategy(
    String strategyId, {
    bool refreshFirst = true,
    bool includeHistory = true,
  }) async {
    final strategy =
        await (db.select(db.strategies)
          ..where((tbl) => tbl.id.equals(strategyId))).getSingleOrNull();
    if (strategy == null) {
      throw StateError('策略不存在: $strategyId');
    }
    if (refreshFirst) {
      await liveExecution.refreshFuturesSnapshotForSymbol(
        strategy.symbol,
        includeHistory: includeHistory,
      );
    }
    final rows = await futureGridOrders(strategyId);
    var synced = 0;
    var open = 0;
    var closing = 0;
    var closed = 0;
    var failed = 0;
    for (final row in rows) {
      final orderId = row.futuresOrderId;
      if (orderId == null || orderId.isEmpty) {
        if (row.status == 'OPEN') open += 1;
        if ({'CLOSING', 'CLOSE_SUBMITTED'}.contains(row.status)) closing += 1;
        if (row.status == 'CLOSED') closed += 1;
        if (row.status == 'FAILED') failed += 1;
        continue;
      }
      final local = await _orderById(orderId);
      if (local == null) {
        if (row.status == 'OPEN') open += 1;
        if ({'CLOSING', 'CLOSE_SUBMITTED'}.contains(row.status)) closing += 1;
        if (row.status == 'CLOSED') closed += 1;
        if (row.status == 'FAILED') failed += 1;
        continue;
      }
      final updated = await _syncOrderFromHistorical(local) ?? local;
      final rowUpdate = _shortRowUpdateForOrder(row, updated);
      await (db.update(db.futureGridOrders)
        ..where((tbl) => tbl.id.equals(row.id))).write(
        FutureGridOrdersCompanion(
          status: Value(rowUpdate.status),
          quantity: Value(rowUpdate.quantity),
          lastError:
              rowUpdate.error == null
                  ? const Value(null)
                  : Value(rowUpdate.error),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      synced += 1;
      if (rowUpdate.status == 'OPEN') open += 1;
      if ({'CLOSING', 'CLOSE_SUBMITTED'}.contains(rowUpdate.status)) {
        closing += 1;
      }
      if (rowUpdate.status == 'CLOSED') closed += 1;
      if (rowUpdate.status == 'FAILED') failed += 1;
    }
    return FutureGridReconcileReport(
      strategyId: strategyId,
      symbol: strategy.symbol,
      syncedRows: synced,
      openRows: open,
      closingRows: closing,
      closedRows: closed,
      failedRows: failed,
    );
  }

  Future<void> closeForSpotGrid(String spotGridOrderId) async {
    final row =
        await (db.select(db.futureGridOrders)..where(
          (tbl) =>
              tbl.spotGridOrderId.equals(spotGridOrderId) &
              tbl.status.isIn(['WAIT_OPEN', 'OPEN']),
        )).getSingleOrNull();
    if (row == null) {
      return;
    }
    try {
      await liveExecution.connectFuturesForSymbol(row.symbol);
      final leverage = await _loadFuturesLeverage(row.strategyId);
      final orderId = await liveExecution.placeFuturesMarketOrder(
        symbol: row.symbol,
        positionSide: 'SHORT',
        side: 'BUY',
        quantity: _d(row.quantity),
        reduceOnly: true,
        leverage: leverage,
        source: source,
        strategyId: row.strategyId,
        purpose: closePurpose,
        gridLevelId: row.spotGridOrderId,
      );
      final futuresOrder = await _orderById(orderId);
      final update = _shortRowUpdateForOrder(row, futuresOrder);
      await (db.update(db.futureGridOrders)
        ..where((tbl) => tbl.id.equals(row.id))).write(
        FutureGridOrdersCompanion(
          status: Value(update.status),
          quantity: Value(update.quantity),
          futuresOrderId: Value(orderId),
          lastError: const Value(null),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
    } catch (error) {
      await (db.update(db.futureGridOrders)
        ..where((tbl) => tbl.id.equals(row.id))).write(
        FutureGridOrdersCompanion(
          status: const Value('FAILED'),
          lastError: Value(error.toString()),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      rethrow;
    }
  }

  Future<FutureGridOrder> closeTailShort(String strategyId) async {
    final rows =
        await (db.select(db.futureGridOrders)..where(
          (tbl) =>
              tbl.strategyId.equals(strategyId) &
              tbl.side.equals('SHORT') &
              tbl.status.equals('OPEN'),
        )).get();
    final openRows =
        rows.where((row) => _d(row.quantity) > Decimal.zero).toList();
    if (openRows.isEmpty) {
      throw StateError('当前没有 OPEN 状态的 SHORT 尾单。');
    }
    final sorted = [...openRows]
      ..sort((a, b) => _d(a.price).compareTo(_d(b.price)));
    final tail = sorted.first;
    try {
      await liveExecution.connectFuturesForSymbol(tail.symbol);
      final leverage = await _loadFuturesLeverage(tail.strategyId);
      final orderId = await liveExecution.placeHedgeFuturesMarketOrder(
        strategyId: tail.strategyId,
        symbol: tail.symbol,
        side: 'BUY',
        quantity: _d(tail.quantity),
        reduceOnly: true,
        leverage: leverage,
        source: source,
        purpose: closePurpose,
        gridLevelId: tail.spotGridOrderId,
      );
      final futuresOrder = await _orderById(orderId);
      final update = _shortRowUpdateForOrder(tail, futuresOrder);
      await (db.update(db.futureGridOrders)
        ..where((tbl) => tbl.id.equals(tail.id))).write(
        FutureGridOrdersCompanion(
          status: Value(update.status),
          quantity: Value(update.quantity),
          futuresOrderId: Value(orderId),
          lastError: const Value(null),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      return tail;
    } catch (error) {
      await (db.update(db.futureGridOrders)
        ..where((tbl) => tbl.id.equals(tail.id))).write(
        FutureGridOrdersCompanion(
          status: const Value('FAILED'),
          lastError: Value(error.toString()),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      rethrow;
    }
  }

  Future<FutureGridStage> stageForStrategy(String strategyId) async {
    final levels =
        await (db.select(db.gridLevels)
              ..where((tbl) => tbl.strategyId.equals(strategyId))
              ..orderBy([(tbl) => OrderingTerm.asc(tbl.gridIndex)]))
            .get();
    final futureRows = await futureGridOrders(strategyId);
    if (levels.isEmpty) {
      return const FutureGridStage(
        title: '等待现货网格',
        reason: '当前策略还没有 Spot Grid 行。',
      );
    }
    final activeSpot =
        levels.where((level) {
          final status = level.lifecycleStatus ?? level.status;
          return [
            'buyFilled',
            'sellSubmitting',
            'sellOpen',
            'sellPartiallyFilled',
          ].contains(status);
        }).length;
    final openLayers = futureRows.where((row) => row.status == 'OPEN').length;
    if (activeSpot == 0) {
      return const FutureGridStage(
        title: '等待现货买入',
        reason: '空单只会在最低分摊层的 Spot BUY 成交后按价格层市价开仓。',
      );
    }
    return FutureGridStage(
      title: '成交触发价格层对冲',
      reason: '当前有 $activeSpot 个 Spot Grid 已买入待卖出，$openLayers 个价格层空单仍处于 OPEN。',
    );
  }

  Future<_ShortHedgeConfig> _loadShortHedgeConfig(String strategyId) async {
    final row =
        await (db.select(db.appSettings)..where(
          (tbl) => tbl.key.equals('live_spot_grid_config_$strategyId'),
        )).getSingleOrNull();
    if (row == null) {
      return const _ShortHedgeConfig(multiplierText: '1.2', spreadLevels: 4);
    }
    try {
      final decoded = Map<String, dynamic>.from(jsonDecode(row.value) as Map);
      final multiplierText = '${decoded['shortHedgeMultiplier'] ?? '1.2'}';
      final spreadLevels =
          int.tryParse('${decoded['shortHedgeSpreadLevels'] ?? '4'}') ?? 4;
      return _ShortHedgeConfig(
        multiplierText: multiplierText,
        spreadLevels: spreadLevels,
      );
    } catch (_) {
      return const _ShortHedgeConfig(multiplierText: '1.2', spreadLevels: 4);
    }
  }

  Future<int> _loadFuturesLeverage(String strategyId) async {
    final row =
        await (db.select(db.appSettings)..where(
          (tbl) => tbl.key.equals('live_spot_grid_config_$strategyId'),
        )).getSingleOrNull();
    if (row == null) {
      return 1;
    }
    try {
      final decoded = Map<String, dynamic>.from(jsonDecode(row.value) as Map);
      return (int.tryParse('${decoded['futuresLeverage'] ?? '1'}') ?? 1).clamp(
        1,
        125,
      );
    } catch (_) {
      return 1;
    }
  }

  Future<int> _effectiveSpreadLevels({
    required String strategyId,
    required int configuredLevels,
  }) async {
    final levels =
        await (db.select(db.gridLevels)
          ..where((tbl) => tbl.strategyId.equals(strategyId))).get();
    final requested = configuredLevels <= 0 ? 1 : configuredLevels;
    final available =
        levels.where((level) => _gridBuyPrice(level) != null).length;
    if (available <= 0) return requested;
    return available < requested ? available : requested;
  }

  Future<Decimal> _openLongQuantity(String strategyId) async {
    final orders =
        await (db.select(db.orders)..where(
          (tbl) =>
              tbl.strategyId.equals(strategyId) &
              tbl.source.isIn(['autoSpotGrid', 'autoFuturesLongGrid']) &
              tbl.purpose.isIn([
                'gridBuy',
                'gridSell',
                'futuresLongGridBuy',
                'futuresLongGridSell',
              ]) &
              tbl.status.isIn(['filled', 'cancelled']),
        )).get();
    var quantity = Decimal.zero;
    for (final order in orders) {
      final executed = _d(order.executedQuantity);
      quantity += order.side == 'BUY' ? executed : -executed;
    }
    return quantity > Decimal.zero ? quantity : Decimal.zero;
  }

  Future<Decimal> _openLongQuantityForGrid({
    required String strategyId,
    required String gridId,
  }) async {
    final orders =
        await (db.select(db.orders)..where(
          (tbl) =>
              tbl.strategyId.equals(strategyId) &
              tbl.gridLevelId.equals(gridId) &
              tbl.source.isIn(['autoSpotGrid', 'autoFuturesLongGrid']) &
              tbl.purpose.isIn([
                'gridBuy',
                'gridSell',
                'futuresLongGridBuy',
                'futuresLongGridSell',
              ]) &
              tbl.status.isIn(['filled', 'cancelled']),
        )).get();
    return _netLongQuantity(orders);
  }

  Future<Decimal> _openLongQuantityForHedgeLayers({
    required String strategyId,
    required int configuredLevels,
  }) async {
    final levels =
        await (db.select(db.gridLevels)
          ..where((tbl) => tbl.strategyId.equals(strategyId))).get();
    final hedgeGridIds = _bottomHedgeLayerIds(
      levels,
      configuredLevels,
    ).toList(growable: false);
    if (hedgeGridIds.isEmpty) {
      return Decimal.zero;
    }
    final orders =
        await (db.select(db.orders)..where(
          (tbl) =>
              tbl.strategyId.equals(strategyId) &
              tbl.gridLevelId.isIn(hedgeGridIds) &
              tbl.source.isIn(['autoSpotGrid', 'autoFuturesLongGrid']) &
              tbl.purpose.isIn([
                'gridBuy',
                'gridSell',
                'futuresLongGridBuy',
                'futuresLongGridSell',
              ]) &
              tbl.status.isIn(['filled', 'cancelled']),
        )).get();
    return _netLongQuantity(orders);
  }

  Decimal _netLongQuantity(List<Order> orders) {
    var quantity = Decimal.zero;
    for (final order in orders) {
      final executed = _d(order.executedQuantity);
      quantity += order.side == 'BUY' ? executed : -executed;
    }
    return quantity > Decimal.zero ? quantity : Decimal.zero;
  }

  Set<String> _bottomHedgeLayerIds(
    List<GridLevel> levels,
    int configuredLevels,
  ) {
    final requested = configuredLevels <= 0 ? 1 : configuredLevels;
    final sorted = levels
        .where((level) => _gridBuyPrice(level) != null)
        .toList(growable: false)
      ..sort((a, b) => _gridBuyPrice(a)!.compareTo(_gridBuyPrice(b)!));
    return sorted.take(requested).map((level) => level.id).toSet();
  }

  Future<Decimal> _openLayerShortQuantity(String strategyId) async {
    final rows =
        await (db.select(db.futureGridOrders)..where(
          (tbl) =>
              tbl.strategyId.equals(strategyId) & tbl.status.equals('OPEN'),
        )).get();
    var quantity = Decimal.zero;
    for (final row in rows) {
      quantity += _d(row.quantity);
    }
    return quantity;
  }

  Future<List<FutureGridOrder>> _openLayersForRelease({
    required String strategyId,
    required Decimal sellPrice,
  }) async {
    final rows =
        await (db.select(db.futureGridOrders)..where(
          (tbl) =>
              tbl.strategyId.equals(strategyId) & tbl.status.equals('OPEN'),
        )).get();
    if (rows.isEmpty) {
      return const [];
    }
    final levels =
        await (db.select(db.gridLevels)
              ..where((tbl) => tbl.strategyId.equals(strategyId))
              ..orderBy([(tbl) => OrderingTerm.asc(tbl.gridIndex)]))
            .get();
    if (levels.isEmpty) {
      return rows.where((row) => _d(row.price) == sellPrice).toList();
    }
    final minBuyPrice = levels
        .map(_gridBuyPrice)
        .whereType<Decimal>()
        .fold<Decimal?>(null, (min, price) {
          if (min == null || price < min) return price;
          return min;
        });
    final bottomReleasePrices = <Decimal>{};
    if (minBuyPrice != null) {
      for (final level in levels) {
        final buyPrice = _gridBuyPrice(level);
        final sell = _gridSellPrice(level);
        if (buyPrice == minBuyPrice && sell != null) {
          bottomReleasePrices.add(sell);
        }
      }
    }
    return rows
        .where((row) {
          final layerPrice = _d(row.price);
          if (layerPrice == sellPrice) {
            return true;
          }
          return layerPrice == minBuyPrice &&
              bottomReleasePrices.contains(sellPrice);
        })
        .toList(growable: false);
  }

  Future<void> _markLayerFailed({
    required String strategyId,
    required String symbol,
    required GridLevel grid,
    required Decimal layerPrice,
    required Decimal quantity,
    required Object error,
  }) async {
    final now = DateTime.now().toUtc();
    await db
        .into(db.futureGridOrders)
        .insertOnConflictUpdate(
          FutureGridOrdersCompanion.insert(
            id: '${grid.id}_future_short',
            strategyId: strategyId,
            symbol: symbol,
            gridLevel: grid.gridIndex,
            side: 'SHORT',
            price: layerPrice.toString(),
            quantity: quantity.toString(),
            status: 'FAILED',
            spotGridOrderId: grid.id,
            lastError: Value(error.toString()),
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  Decimal? _gridBuyPrice(GridLevel level) {
    final raw = level.buyPrice ?? level.price;
    final price = _d(raw);
    return price <= Decimal.zero ? null : price;
  }

  Decimal? _gridSellPrice(GridLevel level) {
    final raw = level.sellPrice ?? level.nextUpperPrice;
    if (raw == null) {
      return null;
    }
    final price = _d(raw);
    return price <= Decimal.zero ? null : price;
  }

  Decimal? _orderExecutionPrice(Order order) {
    final average = order.averagePrice;
    final price =
        average != null && _d(average) > Decimal.zero
            ? _d(average)
            : _d(order.price ?? '0');
    return price <= Decimal.zero ? null : price;
  }

  Decimal _d(String value) => Decimal.tryParse(value) ?? Decimal.zero;

  Future<Order?> _orderById(String orderId) {
    return (db.select(db.orders)
      ..where((tbl) => tbl.id.equals(orderId))).getSingleOrNull();
  }

  Future<Order?> _syncOrderFromHistorical(Order order) async {
    final historical =
        await (db.select(db.exchangeHistoricalOrders)
              ..where(
                (tbl) =>
                    tbl.symbol.equals(order.symbol) &
                    tbl.clientOrderId.equals(order.clientOrderId),
              )
              ..limit(1))
            .getSingleOrNull();
    if (historical == null) {
      return null;
    }
    final status = _normalizeExchangeStatus(historical.status);
    await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id))).write(
      OrdersCompanion(
        exchangeOrderId: Value(historical.exchangeOrderId),
        status: Value(status),
        executedQuantity: Value(historical.executedQuantity),
        quoteQuantity: Value(historical.quoteQuantity),
        averagePrice: Value(historical.averagePrice ?? historical.price),
        updatedAt: Value(DateTime.now().toUtc()),
        completedAt: Value(status == 'filled' ? historical.updatedAt : null),
        cancelledAt: Value(status == 'cancelled' ? historical.updatedAt : null),
      ),
    );
    return _orderById(order.id);
  }

  _FutureShortRowUpdate _shortRowUpdateForOrder(
    FutureGridOrder row,
    Order? order,
  ) {
    if (order == null) {
      return _FutureShortRowUpdate(status: row.status, quantity: row.quantity);
    }
    final status = _shortStatusForOrder(
      order,
      fallbackStatus: row.status,
      currentQuantity: _d(row.quantity),
    );
    if (order.side == 'BUY') {
      final remaining = _d(row.quantity) - _d(order.executedQuantity);
      return _FutureShortRowUpdate(
        status: status,
        quantity:
            status == 'CLOSED'
                ? '0'
                : remaining > Decimal.zero
                ? remaining.toString()
                : row.quantity,
        error: _shortOrderError(order),
      );
    }
    final executed = _d(order.executedQuantity);
    return _FutureShortRowUpdate(
      status: status,
      quantity:
          executed > Decimal.zero
              ? executed.toString()
              : _d(row.quantity) > Decimal.zero
              ? row.quantity
              : order.originalQuantity,
      error: _shortOrderError(order),
    );
  }

  String _shortStatusForOrder(
    Order? order, {
    required String fallbackStatus,
    required Decimal currentQuantity,
  }) {
    if (order == null) {
      return fallbackStatus;
    }
    final status = order.status;
    final executed = _d(order.executedQuantity);
    if (order.side == 'SELL') {
      if (status == 'filled') return 'OPEN';
      if (status == 'partiallyFilled' && executed > Decimal.zero) return 'OPEN';
      if ({
        'created',
        'submitting',
        'new',
        'partiallyFilled',
      }.contains(status)) {
        return 'WAIT_OPEN';
      }
      if (status == 'cancelled' && executed > Decimal.zero) return 'OPEN';
      if (status == 'cancelled') return 'WAIT_TRIGGER';
      return 'FAILED';
    }
    if (status == 'filled') return 'CLOSED';
    if (status == 'partiallyFilled') {
      return currentQuantity - executed > Decimal.zero ? 'CLOSING' : 'CLOSED';
    }
    if ({'created', 'submitting', 'new'}.contains(status)) {
      return 'CLOSING';
    }
    if (status == 'cancelled') {
      return currentQuantity - executed > Decimal.zero ? 'OPEN' : 'CLOSED';
    }
    return 'FAILED';
  }

  String? _shortOrderError(Order order) {
    if (!{'failed', 'unknown', 'rejected', 'expired'}.contains(order.status)) {
      return null;
    }
    final message = order.errorMessage;
    return message == null || message.isEmpty
        ? '订单状态: ${order.status}'
        : message;
  }

  String _normalizeExchangeStatus(String raw) {
    return switch (raw.toUpperCase()) {
      'NEW' => 'new',
      'PARTIALLY_FILLED' => 'partiallyFilled',
      'FILLED' => 'filled',
      'CANCELED' || 'CANCELLED' => 'cancelled',
      'REJECTED' => 'rejected',
      'EXPIRED' => 'expired',
      _ => raw.toLowerCase(),
    };
  }
}

class FutureGridStage {
  const FutureGridStage({required this.title, required this.reason});

  final String title;
  final String reason;
}

class FutureGridReconcileReport {
  const FutureGridReconcileReport({
    required this.strategyId,
    required this.symbol,
    required this.syncedRows,
    required this.openRows,
    required this.closingRows,
    required this.closedRows,
    required this.failedRows,
  });

  final String strategyId;
  final String symbol;
  final int syncedRows;
  final int openRows;
  final int closingRows;
  final int closedRows;
  final int failedRows;

  String toDisplayText() {
    return [
      'SHORT Futures Binance 对账完成',
      'symbol=$symbol',
      '同步价格层=$syncedRows',
      'OPEN=$openRows',
      'CLOSING=$closingRows',
      'CLOSED=$closedRows',
      'FAILED=$failedRows',
    ].join('，');
  }
}

class _FutureShortRowUpdate {
  const _FutureShortRowUpdate({
    required this.status,
    required this.quantity,
    this.error,
  });

  final String status;
  final String quantity;
  final String? error;
}

class _ShortHedgeConfig {
  const _ShortHedgeConfig({
    required this.multiplierText,
    required this.spreadLevels,
  });

  final String multiplierText;
  final int spreadLevels;

  Decimal get multiplier {
    final value = Decimal.tryParse(multiplierText) ?? Decimal.parse('1.2');
    return value <= Decimal.zero ? Decimal.parse('1.2') : value;
  }
}
