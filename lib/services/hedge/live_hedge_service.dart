import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';
import '../../repositories/basic_repositories.dart';
import '../../services/execution/live_exchange_execution_service.dart';
import '../../services/market_data/market_data_coordinator.dart';
import '../../strategy/hedge/hedge_engine.dart';

class LiveHedgeSnapshot {
  const LiveHedgeSnapshot({
    required this.strategy,
    required this.state,
    required this.result,
    required this.futuresPosition,
    required this.futuresAccountSnapshot,
    required this.externalFuturesPosition,
    required this.gridExposures,
  });

  final Strategy strategy;
  final HedgeState state;
  final HedgeCalculationResult result;
  final FuturesPosition? futuresPosition;
  final FuturesAccountSnapshot? futuresAccountSnapshot;
  final bool externalFuturesPosition;
  final List<HedgeGridExposure> gridExposures;
}

class LiveHedgeService {
  LiveHedgeService({
    required this.db,
    required this.liveExecution,
    required this.marketData,
    required this.logRepository,
    HedgeEngine hedgeEngine = const HedgeEngine(),
  }) : _hedgeEngine = hedgeEngine;

  final AppDatabase db;
  final LiveExchangeExecutionService liveExecution;
  final MarketDataCoordinator marketData;
  final LogRepository logRepository;
  final HedgeEngine _hedgeEngine;
  final Uuid _uuid = const Uuid();
  final Map<String, Timer> _autoExecutionTimers = {};
  final StreamController<Set<String>> _autoExecutionController =
      StreamController<Set<String>>.broadcast();

  Stream<HedgeState?> watchState(String strategyId) {
    return (db.select(db.hedgeStates)
          ..where((tbl) => tbl.strategyId.equals(strategyId))
          ..limit(1))
        .watchSingleOrNull();
  }

  Stream<List<HedgeAction>> watchActions(String strategyId) {
    return (db.select(db.hedgeActions)
          ..where((tbl) => tbl.strategyId.equals(strategyId))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)])
          ..limit(100))
        .watch();
  }

  Stream<Set<String>> watchAutoExecutionStrategies() {
    return _autoExecutionController.stream;
  }

  bool isAutoExecutionRunning(String strategyId) {
    return _autoExecutionTimers[strategyId]?.isActive == true;
  }

  Stream<List<FuturesPosition>> watchFuturesPositions() {
    return (db.select(db.futuresPositions)
      ..where((tbl) => tbl.symbol.equals('BTCUSDT'))).watch();
  }

  Stream<FuturesAccountSnapshot?> watchLatestFuturesAccountSnapshot() {
    return (db.select(db.futuresAccountSnapshots)
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.recordedAt)])
          ..limit(1))
        .watchSingleOrNull();
  }

  Future<HedgeState> ensureState(String strategyId) async {
    final existing =
        await (db.select(
          db.hedgeStates,
        )..where((tbl) => tbl.strategyId.equals(strategyId))).getSingleOrNull();
    if (existing != null) {
      return existing;
    }
    final now = DateTime.now().toUtc();
    final id = 'hedge_state_$strategyId';
    await db
        .into(db.hedgeStates)
        .insert(
          HedgeStatesCompanion.insert(
            id: id,
            strategyId: strategyId,
            symbol: 'BTCUSDT',
            updatedAt: now,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    return (db.select(db.hedgeStates)
      ..where((tbl) => tbl.id.equals(id))).getSingle();
  }

  Future<void> updateSettings({
    required String strategyId,
    required bool hedgeEnabled,
    required bool hedgeDryRun,
    required Decimal hedgeRatio,
    required Decimal maxHedgeQty,
    required Decimal minAdjustQty,
    required Decimal minAdjustNotional,
    required int checkIntervalSeconds,
    required bool allowAutoOpenShort,
    required bool allowAutoCloseShort,
  }) async {
    final state = await ensureState(strategyId);
    await (db.update(db.hedgeStates)
      ..where((tbl) => tbl.id.equals(state.id))).write(
      HedgeStatesCompanion(
        hedgeEnabled: Value(hedgeEnabled),
        hedgeDryRun: Value(hedgeDryRun),
        hedgeRatio: Value(hedgeRatio.toString()),
        maxHedgeQty: Value(maxHedgeQty.toString()),
        minAdjustQty: Value(minAdjustQty.toString()),
        minAdjustNotional: Value(minAdjustNotional.toString()),
        checkIntervalSeconds: Value(checkIntervalSeconds),
        allowAutoOpenShort: Value(allowAutoOpenShort),
        allowAutoCloseShort: Value(allowAutoCloseShort),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<LiveHedgeSnapshot> calculate(String strategyId) async {
    final strategy =
        await (db.select(db.strategies)
          ..where((tbl) => tbl.id.equals(strategyId))).getSingle();
    final state = await ensureState(strategyId);
    final exposures = await _gridExposures(strategyId);
    final position = await _currentBtcPosition();
    final accountSnapshot = await _latestFuturesAccountSnapshot();
    final currentShort = _currentShortQty(position);
    final hasExternal = await _hasExternalFuturesPosition(
      strategyId: strategyId,
      currentShort: currentShort,
    );
    final mark =
        marketData.latestFuturesMarkPrice?.markPrice ??
        _d(position?.markPrice) ??
        Decimal.zero;
    final currentPrice = marketData.latestSpotTicker?.midPrice ?? mark;
    final result = _hedgeEngine.calculate(
      HedgeCalculationInput(
        hedgeEnabled: state.hedgeEnabled,
        hedgeDryRun: state.hedgeDryRun,
        hedgeRatio: _d(state.hedgeRatio) ?? Decimal.parse('0.5'),
        currentPrice: currentPrice,
        lowerPrice: _d(strategy.lowerPrice) ?? Decimal.zero,
        upperPrice: _d(strategy.upperPrice) ?? Decimal.zero,
        currentShortQty: currentShort,
        markPrice: mark,
        minAdjustQty: _d(state.minAdjustQty) ?? Decimal.parse('0.00001'),
        minAdjustNotional: _d(state.minAdjustNotional) ?? Decimal.fromInt(5),
        maxHedgeQty: _d(state.maxHedgeQty) ?? Decimal.parse('0.01'),
        futuresRules: liveExecution.futuresRules,
        gridExposures: exposures,
        hedgePower: 2,
        maxHedgeRatio: _d(state.hedgeRatio) ?? Decimal.parse('0.8'),
        emergencyHedgeRatio: Decimal.fromInt(1),
        hedgeReleaseBufferPct: Decimal.parse('0.005'),
        blockReason:
            hasExternal
                ? 'external futures position detected; manual confirmation required'
                : _spotRiskBlockReason(strategyId),
      ),
    );
    await _writeState(state.id, result);
    await logRepository.append(
      level: 'info',
      module: 'HEDGE',
      message: 'HEDGE_CALCULATED',
      strategyId: strategyId,
      extraJson:
          '{"exposed":"${result.exposedSpotQty}","target":"${result.targetShortQty}","current":"${result.currentShortQty}","action":"${result.actionType.name}"}',
    );
    await logRepository.append(
      level: 'debug',
      module: 'HEDGE',
      message: 'HEDGE_CALC_DEBUG',
      strategyId: strategyId,
      extraJson: result.debug.toJsonText(),
    );
    final updated =
        await (db.select(db.hedgeStates)
          ..where((tbl) => tbl.id.equals(state.id))).getSingle();
    return LiveHedgeSnapshot(
      strategy: strategy,
      state: updated,
      result: result,
      futuresPosition: position,
      futuresAccountSnapshot: accountSnapshot,
      externalFuturesPosition: hasExternal,
      gridExposures: exposures,
    );
  }

  Future<LiveHedgeSnapshot> syncFuturesPositionAndCalculate(
    String strategyId,
  ) async {
    await liveExecution.refreshFuturesSnapshot();
    final snapshot = await calculate(strategyId);
    await logRepository.append(
      level: 'info',
      module: 'HEDGE',
      message: 'HEDGE_POSITION_SYNCED',
      strategyId: strategyId,
      extraJson:
          '{"currentShortQty":"${snapshot.result.currentShortQty}","targetShortQty":"${snapshot.result.targetShortQty}","diffQty":"${snapshot.result.diffQty}"}',
    );
    return snapshot;
  }

  Future<String> createDryRunAction(String strategyId) async {
    final snapshot = await calculate(strategyId);
    return _insertAction(
      strategyId: strategyId,
      result: snapshot.result,
      dryRun: true,
      status: 'calculated',
      reason: snapshot.result.reason,
    );
  }

  Future<String> executeSuggestedAction(String strategyId) async {
    final snapshot = await calculate(strategyId);
    final result = snapshot.result;
    if (!result.canSubmit) {
      return _insertAction(
        strategyId: strategyId,
        result: result,
        dryRun: true,
        status: 'skipped',
        reason: result.reason,
      );
    }
    if (snapshot.state.hedgeDryRun) {
      return _insertAction(
        strategyId: strategyId,
        result: result,
        dryRun: true,
        status: 'dryRun',
        reason: 'hedgeDryRun enabled; no futures order sent',
      );
    }
    final actionId = await _insertAction(
      strategyId: strategyId,
      result: result,
      dryRun: false,
      status: 'submitting',
      reason: result.reason,
    );
    try {
      final orderId = await liveExecution.placeHedgeFuturesMarketOrder(
        strategyId: strategyId,
        side: result.side,
        quantity: result.actionQty,
        reduceOnly: result.reduceOnly,
      );
      final order =
          await (db.select(db.orders)
            ..where((tbl) => tbl.id.equals(orderId))).getSingleOrNull();
      await (db.update(db.hedgeActions)
        ..where((tbl) => tbl.id.equals(actionId))).write(
        HedgeActionsCompanion(
          status: const Value('submitted'),
          futuresOrderId: Value(orderId),
          clientOrderId: Value(order?.clientOrderId),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      await logRepository.append(
        level: 'info',
        module: 'HEDGE',
        message: 'HEDGE_ORDER_SUBMITTED',
        strategyId: strategyId,
        extraJson: '{"actionId":"$actionId","orderId":"$orderId"}',
      );
      return actionId;
    } catch (error) {
      await (db.update(db.hedgeActions)
        ..where((tbl) => tbl.id.equals(actionId))).write(
        HedgeActionsCompanion(
          status: const Value('failed'),
          errorMessage: Value(error.toString()),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      await logRepository.append(
        level: 'error',
        module: 'HEDGE',
        message: 'HEDGE_ORDER_FAILED',
        strategyId: strategyId,
        extraJson: '{"actionId":"$actionId"}',
      );
      rethrow;
    }
  }

  Future<void> startAutoExecution(String strategyId) async {
    final state = await ensureState(strategyId);
    if (!state.hedgeEnabled) {
      throw StateError('Hedge is disabled');
    }
    if (state.hedgeDryRun) {
      throw StateError(
        'Dry Run is enabled; automatic futures execution is blocked',
      );
    }
    if (!state.allowAutoOpenShort && !state.allowAutoCloseShort) {
      throw StateError('Auto hedge open/close permissions are disabled');
    }
    await _runAutoExecutionOnce(strategyId);
    final interval = Duration(
      seconds:
          state.checkIntervalSeconds <= 0 ? 30 : state.checkIntervalSeconds,
    );
    _autoExecutionTimers[strategyId]?.cancel();
    _autoExecutionTimers[strategyId] = Timer.periodic(interval, (_) {
      unawaited(_runAutoExecutionOnce(strategyId));
    });
    _emitAutoExecutionState();
    await logRepository.append(
      level: 'warning',
      module: 'HEDGE',
      message: 'HEDGE_AUTO_EXECUTION_STARTED',
      strategyId: strategyId,
      extraJson: '{"intervalSeconds":${interval.inSeconds}}',
    );
  }

  Future<void> stopAutoExecution(String strategyId) async {
    _autoExecutionTimers.remove(strategyId)?.cancel();
    _emitAutoExecutionState();
    await logRepository.append(
      level: 'info',
      module: 'HEDGE',
      message: 'HEDGE_AUTO_EXECUTION_STOPPED',
      strategyId: strategyId,
    );
  }

  Future<void> stopAllAutoExecution() async {
    final strategyIds = _autoExecutionTimers.keys.toList();
    for (final strategyId in strategyIds) {
      _autoExecutionTimers.remove(strategyId)?.cancel();
    }
    _emitAutoExecutionState();
  }

  Future<void> _runAutoExecutionOnce(String strategyId) async {
    if (!isAutoExecutionRunning(strategyId) &&
        _autoExecutionTimers.containsKey(strategyId)) {
      return;
    }
    try {
      final snapshot = await calculate(strategyId);
      final result = snapshot.result;
      final state = snapshot.state;
      if (!state.hedgeEnabled || state.hedgeDryRun || !result.canSubmit) {
        return;
      }
      if (result.actionType == HedgeActionType.increaseShort &&
          !state.allowAutoOpenShort) {
        await _insertAction(
          strategyId: strategyId,
          result: result,
          dryRun: false,
          status: 'skipped',
          reason: 'auto open short disabled',
        );
        return;
      }
      if (result.actionType == HedgeActionType.reduceShort &&
          !state.allowAutoCloseShort) {
        await _insertAction(
          strategyId: strategyId,
          result: result,
          dryRun: false,
          status: 'skipped',
          reason: 'auto close short disabled',
        );
        return;
      }
      await executeSuggestedAction(strategyId);
    } catch (error) {
      await logRepository.append(
        level: 'error',
        module: 'HEDGE',
        message: 'HEDGE_AUTO_EXECUTION_FAILED',
        strategyId: strategyId,
        extraJson: '{"error":"${_jsonSafe(error.toString())}"}',
      );
    }
  }

  Future<List<HedgeGridExposure>> _gridExposures(String strategyId) async {
    final levels =
        await (db.select(db.gridLevels)
          ..where((tbl) => tbl.strategyId.equals(strategyId))).get();
    final orders =
        await (db.select(db.orders)..where(
          (tbl) =>
              tbl.strategyId.equals(strategyId) &
              tbl.source.equals('autoSpotGrid') &
              tbl.marketType.equals('spot'),
        )).get();
    final ordersByGrid = <String, List<Order>>{};
    for (final order in orders) {
      final gridId = order.gridLevelId;
      if (gridId != null) {
        ordersByGrid.putIfAbsent(gridId, () => []).add(order);
      }
    }
    return [
      for (final level in levels)
        HedgeGridExposure(
          gridId: level.id,
          cycleNumber: level.cycleNumber,
          phase: level.lifecycleStatus ?? level.status,
          buyFilledQty: _executedBySide(ordersByGrid[level.id], 'BUY'),
          sellFilledQty: _executedBySide(ordersByGrid[level.id], 'SELL'),
        ),
    ];
  }

  Decimal _executedBySide(List<Order>? orders, String side) {
    if (orders == null) {
      return Decimal.zero;
    }
    return orders
        .where((order) => order.side == side)
        .fold(
          Decimal.zero,
          (sum, order) => sum + (_d(order.executedQuantity) ?? Decimal.zero),
        );
  }

  Future<FuturesPosition?> _currentBtcPosition() async {
    final positions =
        await (db.select(db.futuresPositions)
              ..where((tbl) => tbl.symbol.equals('BTCUSDT'))
              ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)]))
            .get();
    final short =
        positions.where((position) {
          final amount = _d(position.positionAmount) ?? Decimal.zero;
          return position.positionSide == 'SHORT' ||
              (position.positionSide == 'BOTH' && amount < Decimal.zero);
        }).toList();
    final nonZeroShort =
        short.where((position) {
          final amount = _d(position.positionAmount) ?? Decimal.zero;
          return amount.abs() > Decimal.zero;
        }).firstOrNull;
    if (nonZeroShort != null) {
      return nonZeroShort;
    }
    if (short.isNotEmpty) {
      return short.first;
    }
    return positions.where((p) => p.positionSide == 'BOTH').firstOrNull;
  }

  Future<FuturesAccountSnapshot?> _latestFuturesAccountSnapshot() {
    return (db.select(db.futuresAccountSnapshots)
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.recordedAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  Decimal _currentShortQty(FuturesPosition? position) {
    if (position == null) {
      return Decimal.zero;
    }
    final amount = _d(position.positionAmount) ?? Decimal.zero;
    if (position.positionSide == 'SHORT') {
      return amount.abs();
    }
    if (position.positionSide == 'BOTH' && amount < Decimal.zero) {
      return amount.abs();
    }
    return Decimal.zero;
  }

  Future<bool> _hasExternalFuturesPosition({
    required String strategyId,
    required Decimal currentShort,
  }) async {
    if (currentShort <= Decimal.zero) {
      return false;
    }
    final localActions =
        await (db.select(db.hedgeActions)..where(
          (tbl) =>
              tbl.strategyId.equals(strategyId) &
              tbl.status.isIn(['submitted', 'filled']),
        )).get();
    return localActions.isEmpty;
  }

  String? _spotRiskBlockReason(String strategyId) {
    return null;
  }

  Future<void> _writeState(
    String stateId,
    HedgeCalculationResult result,
  ) async {
    final now = DateTime.now().toUtc();
    await (db.update(db.hedgeStates)
      ..where((tbl) => tbl.id.equals(stateId))).write(
      HedgeStatesCompanion(
        exposedSpotQty: Value(result.exposedSpotQty.toString()),
        targetShortQty: Value(result.targetShortQty.toString()),
        currentShortQty: Value(result.currentShortQty.toString()),
        diffQty: Value(result.diffQty.toString()),
        lastAction: Value(result.actionType.name),
        lastActionQty: Value(result.actionQty.toString()),
        lastActionStatus: Value(result.dryRun ? 'dryRun' : 'calculated'),
        lastError: Value(result.reason),
        lastCalculatedAt: Value(now),
        lastSyncedAt: Value(now),
        updatedAt: Value(now),
      ),
    );
  }

  Future<String> _insertAction({
    required String strategyId,
    required HedgeCalculationResult result,
    required bool dryRun,
    required String status,
    required String reason,
  }) async {
    final now = DateTime.now().toUtc();
    final id = 'hedge_action_${_uuid.v4()}';
    await db
        .into(db.hedgeActions)
        .insert(
          HedgeActionsCompanion.insert(
            id: id,
            strategyId: strategyId,
            actionType: result.actionType.name,
            symbol: 'BTCUSDT',
            side: result.side,
            quantity: result.actionQty.toString(),
            price: Value(
              marketData.latestFuturesMarkPrice?.markPrice.toString(),
            ),
            reduceOnly: Value(result.reduceOnly),
            dryRun: Value(dryRun),
            status: status,
            reason: Value(reason),
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  void _emitAutoExecutionState() {
    if (!_autoExecutionController.isClosed) {
      _autoExecutionController.add(_autoExecutionTimers.keys.toSet());
    }
  }

  String _jsonSafe(String value) {
    return value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  }

  Decimal? _d(String? value) => value == null ? null : Decimal.tryParse(value);
}
