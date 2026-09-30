import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import '../../services/app_ui_settings.dart';
import '../../services/market_data/market_data_coordinator.dart';
import '../../services/market_data/market_tick.dart';
import 'auto_spot_grid_execution_service.dart';
import 'live_exchange_execution_service.dart';

class RecoveryShortEngine {
  RecoveryShortEngine({
    required this.db,
    required this.liveExecution,
    required this.gridExecution,
    required this.marketData,
  });

  static const source = 'recoveryShort';
  static const entryPurpose = 'recoveryShortEntry';
  static const exitPurpose = 'recoveryShortExit';

  static const statusReadyToEnter = 'READY_TO_ENTER';
  static const statusEnterSubmitting = 'ENTER_SUBMITTING';
  static const statusOpen = 'OPEN';
  static const statusArmedExit = 'ARMED_EXIT';
  static const statusExitSubmitting = 'EXIT_SUBMITTING';
  static const statusClosedWaitingRearm = 'CLOSED_WAITING_REARM';
  static const statusFailed = 'FAILED';

  static final Decimal mainGridPercent = Decimal.fromInt(1);
  static final Decimal lowerBoundPercent = Decimal.fromInt(-7);
  static final Decimal recoveryStartPercent = Decimal.parse('-2.5');
  static final Decimal recoveryMicroStepPercent = Decimal.parse('0.1');
  static final Decimal recoveryAvgPercent = Decimal.parse('-2.95');
  static const int recoveryParts = 10;

  final AppDatabase db;
  final LiveExchangeExecutionService liveExecution;
  final AutoSpotGridExecutionService gridExecution;
  final MarketDataCoordinator marketData;

  final Map<String, Decimal> _previousPrices = {};
  final Set<String> _processingStrategies = {};
  StreamSubscription<Map<String, MarketTick>>? _tickSubscription;
  bool _startupRecoveryStarted = false;

  void start() {
    _tickSubscription ??= marketData.allMarketTicksStream.listen((ticks) {
      unawaited(_onTicks(ticks));
    });
    if (!_startupRecoveryStarted) {
      _startupRecoveryStarted = true;
      unawaited(recoverRunningStrategies());
    }
  }

  Future<void> dispose() async {
    await _tickSubscription?.cancel();
  }

  Stream<List<RecoveryShortLevel>> watchLevels(String strategyId) {
    final query = db.select(db.recoveryShortLevels)
      ..where((tbl) => tbl.strategyId.equals(strategyId))
      ..orderBy([(tbl) => OrderingTerm.asc(tbl.partIndex)]);
    return query.watch();
  }

  Future<RecoveryShortStats> loadStats(String strategyId) async {
    final rows = await (db.select(db.recoveryShortLevels)
          ..where((tbl) => tbl.strategyId.equals(strategyId)))
        .get();
    Decimal totalShort = Decimal.zero;
    for (final row in rows) {
      if (_isOpenStatus(row.status)) {
        totalShort += _parseDecimal(row.remainingQuantity);
      }
    }
    return RecoveryShortStats(
      total: rows.length,
      ready: rows.where((row) => row.status == statusReadyToEnter).length,
      open: rows.where((row) => row.status == statusOpen).length,
      armedExit: rows.where((row) => row.status == statusArmedExit).length,
      submitting: rows
          .where(
            (row) =>
                row.status == statusEnterSubmitting ||
                row.status == statusExitSubmitting,
          )
          .length,
      closedWaitingRearm:
          rows.where((row) => row.status == statusClosedWaitingRearm).length,
      failed: rows.where((row) => row.status == statusFailed).length,
      totalShortQty: totalShort,
    );
  }

  Future<RecoveryShortRiskSnapshot?> loadRiskSnapshot(String strategyId) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      return null;
    }
    final center = Decimal.tryParse(strategy.centerPrice);
    if (center == null || center <= Decimal.zero) {
      return null;
    }
    final markPrice =
        marketData.latestFuturesMarkPriceFor(strategy.symbol)?.markPrice;
    final longExposure = await _longExposure(strategyId, center);
    final shortExposure = await _shortExposure(strategyId);
    final longPnl = markPrice == null
        ? Decimal.zero
        : (markPrice - longExposure.longAvgPrice) * longExposure.totalLongQty;
    final shortPnl = markPrice == null
        ? Decimal.zero
        : (shortExposure.shortAvgPrice - markPrice) *
            shortExposure.totalShortQty;
    final combinedPnl = longPnl + shortPnl;
    final netQuantity = longExposure.totalLongQty - shortExposure.totalShortQty;
    final longLoss = longPnl < Decimal.zero ? -longPnl : Decimal.zero;
    final offsetAmount = longLoss > Decimal.zero && shortPnl > Decimal.zero
        ? (shortPnl < longLoss ? shortPnl : longLoss)
        : Decimal.zero;
    final offsetRatio = longLoss > Decimal.zero
        ? (offsetAmount / longLoss).toDecimal(
              scaleOnInfinitePrecision: 12,
            ) *
            Decimal.fromInt(100)
        : Decimal.zero;
    final currentPercent =
        markPrice == null ? null : _percentFromPrice(markPrice, center);
    final protectionStatus = _protectionStatus(
      shortQty: shortExposure.totalShortQty,
      shortPnl: shortPnl,
      longQty: longExposure.totalLongQty,
      currentPercent: currentPercent,
    );
    return RecoveryShortRiskSnapshot(
      symbol: strategy.symbol,
      currentMarkPrice: markPrice,
      longQuantity: longExposure.totalLongQty,
      longAvgPrice: longExposure.longAvgPrice,
      longUnrealizedPnl: longPnl,
      shortQuantity: shortExposure.totalShortQty,
      shortAvgPrice: shortExposure.shortAvgPrice,
      shortUnrealizedPnl: shortPnl,
      combinedUnrealizedPnl: combinedPnl,
      netQuantity: netQuantity,
      offsetAmount: offsetAmount,
      offsetRatio: offsetRatio,
      protectionStatus: protectionStatus,
    );
  }

  Future<void> ensureForStrategy(String strategyId) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      return;
    }
    final center = Decimal.tryParse(strategy.centerPrice);
    if (center == null || center <= Decimal.zero) {
      return;
    }
    final now = DateTime.now().toUtc();
    for (var i = 0; i < recoveryParts; i += 1) {
      final id = _levelId(strategyId, i);
      final entryPercent =
          recoveryStartPercent - recoveryMicroStepPercent * Decimal.fromInt(i);
      final entryPrice = _priceFromPercent(center, entryPercent);
      final existing = await (db.select(db.recoveryShortLevels)
            ..where((tbl) => tbl.id.equals(id)))
          .getSingleOrNull();
      if (existing == null) {
        await db.into(db.recoveryShortLevels).insert(
              RecoveryShortLevelsCompanion.insert(
                id: id,
                strategyId: strategyId,
                symbol: strategy.symbol,
                partIndex: i,
                entryPercent: entryPercent.toString(),
                entryPrice: entryPrice.toString(),
                status: statusReadyToEnter,
                createdAt: now,
                updatedAt: now,
              ),
            );
        _debugTrace(
          'RECOVERY_SHORT',
          'init level strategy=$strategyId symbol=${strategy.symbol} '
              'part=$i entryPercent=$entryPercent entryPrice=$entryPrice',
        );
        continue;
      }
      await (db.update(db.recoveryShortLevels)
            ..where((tbl) => tbl.id.equals(id)))
          .write(
        RecoveryShortLevelsCompanion(
          symbol: Value(strategy.symbol),
          entryPercent: Value(entryPercent.toString()),
          entryPrice: Value(entryPrice.toString()),
          updatedAt: Value(now),
        ),
      );
    }
  }

  Future<RecoveryShortReconcileReport> recoverRunningStrategies() async {
    final strategies = await (db.select(db.strategies)
          ..where(
            (tbl) =>
                tbl.environment.equals(
                  AutoSpotGridExecutionService.futuresGridEnvironment,
                ) &
                tbl.status.equals('running'),
          ))
        .get();
    var report = RecoveryShortReconcileReport.empty();
    for (final strategy in strategies) {
      final enabled = await AppUiSettings.shortRecoverEnabledForSymbol(
        db,
        symbol: strategy.symbol,
      );
      if (!enabled) {
        continue;
      }
      final next = await reconcileStrategy(strategy.id);
      report = report.merge(next);
    }
    if (report.scanned > 0) {
      _debugTrace(
        'RECOVERY_SHORT',
        'startup lightweight reconcile ${report.summary}',
      );
    }
    return report;
  }

  Future<RecoveryShortReconcileReport> reconcileStrategy(
    String strategyId,
  ) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      return RecoveryShortReconcileReport.empty();
    }
    await ensureForStrategy(strategyId);
    await liveExecution.connectFuturesForSymbol(strategy.symbol);
    final rows = await (db.select(db.recoveryShortLevels)
          ..where((tbl) => tbl.strategyId.equals(strategyId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.partIndex)]))
        .get();
    var scanned = 0;
    var synced = 0;
    var recovered = 0;
    var pending = 0;
    var failed = 0;
    var missingOrders = 0;
    final messages = <String>[];
    for (final row in rows) {
      final shouldCheck = row.status == statusEnterSubmitting ||
          row.status == statusExitSubmitting ||
          row.status == statusFailed;
      if (!shouldCheck) {
        continue;
      }
      scanned += 1;
      final isExit = row.status == statusExitSubmitting ||
          (row.status == statusFailed &&
              (row.exitOrderId != null ||
                  (row.entryOrderId != null &&
                      _parseDecimal(row.remainingQuantity) > Decimal.zero)));
      final orderId = isExit ? row.exitOrderId : row.entryOrderId;
      if (orderId == null || orderId.trim().isEmpty) {
        if (row.status == statusFailed) {
          await (db.update(db.recoveryShortLevels)
                ..where((tbl) => tbl.id.equals(row.id)))
              .write(
            RecoveryShortLevelsCompanion(
              status: Value(isExit ? statusArmedExit : statusReadyToEnter),
              armedForEntry: Value(!isExit),
              armedForExit: Value(isExit),
              lastError: const Value(null),
              updatedAt: Value(DateTime.now().toUtc()),
            ),
          );
          recovered += 1;
          messages.add(
            'part=${row.partIndex} ${isExit ? 'exit' : 'entry'} 提交前失败，已恢复',
          );
        } else {
          missingOrders += 1;
          messages.add(
            'part=${row.partIndex} ${isExit ? 'exit' : 'entry'} 无订单号',
          );
        }
        continue;
      }
      final localOrder = await _orderById(orderId);
      if (localOrder == null) {
        missingOrders += 1;
        messages.add('part=${row.partIndex} 本地订单不存在 order=$orderId');
        continue;
      }
      Order order = localOrder;
      try {
        final remoteSynced = await liveExecution.syncFuturesOrderFromBinance(
          localOrder,
        );
        if (remoteSynced) {
          synced += 1;
          order = await _orderById(orderId) ?? localOrder;
        }
      } catch (error) {
        failed += 1;
        messages.add('part=${row.partIndex} 单笔同步失败: $error');
        _debugTrace(
          'RECOVERY_SHORT',
          'light reconcile sync failed strategy=$strategyId '
              'symbol=${strategy.symbol} part=${row.partIndex} '
              'order=$orderId error=$error',
        );
        continue;
      }
      final next = await _applyReconciledOrder(
        row: row,
        order: order,
        isExit: isExit,
      );
      switch (next) {
        case _RecoveryReconcileOutcome.recovered:
          recovered += 1;
          break;
        case _RecoveryReconcileOutcome.pending:
          pending += 1;
          break;
        case _RecoveryReconcileOutcome.failed:
          failed += 1;
          break;
      }
    }
    final report = RecoveryShortReconcileReport(
      scanned: scanned,
      synced: synced,
      recovered: recovered,
      pending: pending,
      failed: failed,
      missingOrders: missingOrders,
      messages: messages,
    );
    _debugTrace(
      'RECOVERY_SHORT',
      'light reconcile strategy=$strategyId symbol=${strategy.symbol} '
          '${report.summary}',
    );
    return report;
  }

  Future<void> _onTicks(Map<String, MarketTick> ticks) async {
    for (final entry in ticks.entries) {
      final symbol = entry.key.toUpperCase();
      final tick = entry.value;
      final current = tick.futuresMarkPrice;
      if (current == null || current <= Decimal.zero) {
        continue;
      }
      final previous = _previousPrices[symbol];
      _previousPrices[symbol] = current;
      if (previous == null || previous == current) {
        continue;
      }
      final strategies = await (db.select(db.strategies)
            ..where(
              (tbl) =>
                  tbl.symbol.equals(symbol) &
                  tbl.environment.equals(
                    AutoSpotGridExecutionService.futuresGridEnvironment,
                  ) &
                  tbl.status.equals('running'),
            ))
          .get();
      for (final strategy in strategies) {
        if (!_processingStrategies.add(strategy.id)) {
          continue;
        }
        unawaited(
          _processStrategy(strategy, previous, current).whenComplete(() {
            _processingStrategies.remove(strategy.id);
          }),
        );
      }
    }
  }

  Future<void> _processStrategy(
    Strategy strategy,
    Decimal previousPrice,
    Decimal currentPrice,
  ) async {
    final enabled = await AppUiSettings.shortRecoverEnabledForSymbol(
      db,
      symbol: strategy.symbol,
    );
    if (!enabled) {
      return;
    }
    await ensureForStrategy(strategy.id);
    final center = Decimal.tryParse(strategy.centerPrice);
    if (center == null || center <= Decimal.zero) {
      return;
    }
    final config = await gridExecution.loadEditableConfig(strategy.id);
    final tolerance = config?.longEntryTriggerDistanceUsdt ??
        AutoSpotGridExecutionService.defaultLongEntryTriggerDistanceUsdt;
    final leverage = config?.futuresLeverage ?? 1;
    final exposure = await _longExposure(strategy.id, center);
    final partQty = _partQuantity(exposure);
    final previousPercent = _percentFromPrice(previousPrice, center);
    final currentPercent = _percentFromPrice(currentPrice, center);
    if (previousPercent > recoveryStartPercent &&
        currentPercent <= recoveryStartPercent) {
      _debugTrace(
        'RECOVERY_SHORT',
        'zone enter strategy=${strategy.id} symbol=${strategy.symbol} '
            'prevPrice=$previousPrice currentPrice=$currentPrice '
            'prevPercent=$previousPercent currentPercent=$currentPercent '
            'longQty=${exposure.totalLongQty} '
            'longAvgPrice=${exposure.longAvgPrice} '
            'longAvgPercent=${exposure.longAvgPercent} '
            'targetPartQty=$partQty tolerance=$tolerance leverage=$leverage',
      );
    }
    final rows = await (db.select(db.recoveryShortLevels)
          ..where((tbl) => tbl.strategyId.equals(strategy.id))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.partIndex)]))
        .get();
    for (final row in rows) {
      await _processLevel(
        strategy: strategy,
        row: row,
        previousPrice: previousPrice,
        currentPrice: currentPrice,
        previousPercent: previousPercent,
        currentPercent: currentPercent,
        targetPartQuantity: partQty,
        tolerance: tolerance,
        leverage: leverage,
      );
    }
    if (currentPercent <= lowerBoundPercent) {
      await _trimExcessShort(
        strategy: strategy,
        totalLongQty: exposure.totalLongQty,
        leverage: leverage,
      );
    }
  }

  Future<void> _processLevel({
    required Strategy strategy,
    required RecoveryShortLevel row,
    required Decimal previousPrice,
    required Decimal currentPrice,
    required Decimal previousPercent,
    required Decimal currentPercent,
    required Decimal targetPartQuantity,
    required Decimal tolerance,
    required int leverage,
  }) async {
    final entryPrice = _parseDecimal(row.entryPrice);
    final entryPercent = _parseDecimal(row.entryPercent);
    final upperTriggerPrice = entryPrice + tolerance;
    final lowerTriggerPrice = entryPrice - tolerance;
    final now = DateTime.now().toUtc();

    if (row.status == statusReadyToEnter &&
        row.armedForEntry &&
        targetPartQuantity > Decimal.zero &&
        previousPrice > upperTriggerPrice &&
        currentPrice <= upperTriggerPrice &&
        currentPrice >= lowerTriggerPrice) {
      _debugTrace(
        'RECOVERY_SHORT',
        'entry trigger strategy=${strategy.id} symbol=${strategy.symbol} '
            'part=${row.partIndex} prevPrice=$previousPrice '
            'currentPrice=$currentPrice entryPrice=$entryPrice '
            'lowerTrigger=$lowerTriggerPrice '
            'upperTrigger=$upperTriggerPrice '
            'prevPercent=$previousPercent currentPercent=$currentPercent '
            'qty=$targetPartQuantity',
      );
      await _enterShort(strategy, row, targetPartQuantity, leverage);
      return;
    }

    if (row.status == statusOpen || row.status == statusArmedExit) {
      final lowest = _minNullable(
        Decimal.tryParse(row.lowestPercentSinceOpen ?? ''),
        currentPercent,
      );
      if (row.status == statusOpen &&
          currentPercent <= entryPercent - recoveryMicroStepPercent) {
        _debugTrace(
          'RECOVERY_SHORT',
          'armed exit strategy=${strategy.id} symbol=${strategy.symbol} '
              'part=${row.partIndex} currentPercent=$currentPercent '
              'entryPercent=$entryPercent lowest=$lowest',
        );
        await (db.update(db.recoveryShortLevels)
              ..where((tbl) => tbl.id.equals(row.id)))
            .write(
          RecoveryShortLevelsCompanion(
            status: const Value(statusArmedExit),
            armedForExit: const Value(true),
            lowestPercentSinceOpen: Value(lowest.toString()),
            updatedAt: Value(now),
          ),
        );
        return;
      }
      if (row.status == statusArmedExit &&
          previousPrice < lowerTriggerPrice &&
          currentPrice >= lowerTriggerPrice &&
          currentPrice <= upperTriggerPrice) {
        _debugTrace(
          'RECOVERY_SHORT',
          'exit trigger strategy=${strategy.id} symbol=${strategy.symbol} '
              'part=${row.partIndex} prevPrice=$previousPrice '
              'currentPrice=$currentPrice entryPrice=$entryPrice '
              'lowerTrigger=$lowerTriggerPrice '
              'upperTrigger=$upperTriggerPrice '
              'qty=${row.remainingQuantity}',
        );
        await _exitShort(
          strategy,
          row,
          _parseDecimal(row.remainingQuantity),
          leverage,
        );
        return;
      }
      await (db.update(db.recoveryShortLevels)
            ..where((tbl) => tbl.id.equals(row.id)))
          .write(
        RecoveryShortLevelsCompanion(
          lowestPercentSinceOpen: Value(lowest.toString()),
          updatedAt: Value(now),
        ),
      );
      return;
    }

    if (row.status == statusClosedWaitingRearm) {
      final highest = _maxNullable(
        Decimal.tryParse(row.highestPercentSinceClose ?? ''),
        currentPercent,
      );
      final updates = RecoveryShortLevelsCompanion(
        highestPercentSinceClose: Value(highest.toString()),
        updatedAt: Value(now),
      );
      await (db.update(db.recoveryShortLevels)
            ..where((tbl) => tbl.id.equals(row.id)))
          .write(updates);
      if (currentPercent >= entryPercent + recoveryMicroStepPercent) {
        _debugTrace(
          'RECOVERY_SHORT',
          'rearmed entry strategy=${strategy.id} symbol=${strategy.symbol} '
              'part=${row.partIndex} currentPercent=$currentPercent '
              'entryPercent=$entryPercent highest=$highest',
        );
        await (db.update(db.recoveryShortLevels)
              ..where((tbl) => tbl.id.equals(row.id)))
            .write(
          RecoveryShortLevelsCompanion(
            status: const Value(statusReadyToEnter),
            armedForEntry: const Value(true),
            lastError: const Value(null),
            updatedAt: Value(DateTime.now().toUtc()),
          ),
        );
      }
    }
  }

  Future<void> _enterShort(
    Strategy strategy,
    RecoveryShortLevel row,
    Decimal quantity,
    int leverage,
  ) async {
    final now = DateTime.now().toUtc();
    final existingOrder = await _activeOrderForLevel(strategy.id, row);
    if (existingOrder != null) {
      await _bindExistingActiveOrder(row, existingOrder);
      _debugTrace(
        'RECOVERY_SHORT',
        'skip duplicate entry order strategy=${strategy.id} '
            'symbol=${strategy.symbol} part=${row.partIndex} '
            'existingOrder=${existingOrder.id} status=${existingOrder.status}',
      );
      return;
    }
    await (db.update(db.recoveryShortLevels)
          ..where((tbl) => tbl.id.equals(row.id)))
        .write(
      RecoveryShortLevelsCompanion(
        status: const Value(statusEnterSubmitting),
        quantity: Value(quantity.toString()),
        updatedAt: Value(now),
      ),
    );
    try {
      _debugTrace(
        'RECOVERY_SHORT',
        'submit entry SELL strategy=${strategy.id} symbol=${strategy.symbol} '
            'part=${row.partIndex} qty=$quantity leverage=$leverage',
      );
      await liveExecution.connectFuturesForSymbol(strategy.symbol);
      final orderId = await liveExecution.placeHedgeFuturesMarketOrder(
        strategyId: strategy.id,
        symbol: strategy.symbol,
        side: 'SELL',
        quantity: quantity,
        reduceOnly: false,
        leverage: leverage.clamp(1, 125),
        source: source,
        purpose: entryPurpose,
      );
      await (db.update(db.recoveryShortLevels)
            ..where((tbl) => tbl.id.equals(row.id)))
          .write(
        RecoveryShortLevelsCompanion(
          status: const Value(statusOpen),
          quantity: Value(quantity.toString()),
          remainingQuantity: Value(quantity.toString()),
          armedForExit: const Value(false),
          armedForEntry: const Value(false),
          lowestPercentSinceOpen: Value(row.entryPercent),
          entryOrderId: Value(orderId),
          lastError: const Value(null),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      _debugTrace(
        'RECOVERY_SHORT',
        'entry submitted strategy=${strategy.id} symbol=${strategy.symbol} '
            'part=${row.partIndex} orderId=$orderId qty=$quantity',
      );
    } catch (error) {
      await (db.update(db.recoveryShortLevels)
            ..where((tbl) => tbl.id.equals(row.id)))
          .write(
        RecoveryShortLevelsCompanion(
          status: const Value(statusFailed),
          lastError: Value(error.toString()),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      _debugTrace(
        'RECOVERY_SHORT',
        'entry failed strategy=${strategy.id} symbol=${strategy.symbol} '
            'part=${row.partIndex} qty=$quantity error=$error',
      );
    }
  }

  Future<void> _exitShort(
    Strategy strategy,
    RecoveryShortLevel row,
    Decimal quantity,
    int leverage,
  ) async {
    if (quantity <= Decimal.zero) {
      return;
    }
    final existingOrder = await _activeOrderForLevel(strategy.id, row);
    if (existingOrder != null) {
      await _bindExistingActiveOrder(row, existingOrder);
      _debugTrace(
        'RECOVERY_SHORT',
        'skip duplicate exit order strategy=${strategy.id} '
            'symbol=${strategy.symbol} part=${row.partIndex} '
            'existingOrder=${existingOrder.id} status=${existingOrder.status}',
      );
      return;
    }
    await (db.update(db.recoveryShortLevels)
          ..where((tbl) => tbl.id.equals(row.id)))
        .write(
      RecoveryShortLevelsCompanion(
        status: const Value(statusExitSubmitting),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    try {
      _debugTrace(
        'RECOVERY_SHORT',
        'submit exit BUY reduceOnly strategy=${strategy.id} '
            'symbol=${strategy.symbol} part=${row.partIndex} qty=$quantity '
            'leverage=$leverage',
      );
      await liveExecution.connectFuturesForSymbol(strategy.symbol);
      final orderId = await liveExecution.placeHedgeFuturesMarketOrder(
        strategyId: strategy.id,
        symbol: strategy.symbol,
        side: 'BUY',
        quantity: quantity,
        reduceOnly: true,
        leverage: leverage.clamp(1, 125),
        source: source,
        purpose: exitPurpose,
      );
      await (db.update(db.recoveryShortLevels)
            ..where((tbl) => tbl.id.equals(row.id)))
          .write(
        RecoveryShortLevelsCompanion(
          status: const Value(statusClosedWaitingRearm),
          remainingQuantity: const Value('0'),
          armedForExit: const Value(false),
          armedForEntry: const Value(false),
          highestPercentSinceClose: Value(row.entryPercent),
          exitOrderId: Value(orderId),
          roundId: Value(row.roundId + 1),
          lastError: const Value(null),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      _debugTrace(
        'RECOVERY_SHORT',
        'exit submitted strategy=${strategy.id} symbol=${strategy.symbol} '
            'part=${row.partIndex} orderId=$orderId qty=$quantity '
            'nextRound=${row.roundId + 1}',
      );
    } catch (error) {
      await (db.update(db.recoveryShortLevels)
            ..where((tbl) => tbl.id.equals(row.id)))
          .write(
        RecoveryShortLevelsCompanion(
          status: const Value(statusFailed),
          lastError: Value(error.toString()),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      _debugTrace(
        'RECOVERY_SHORT',
        'exit failed strategy=${strategy.id} symbol=${strategy.symbol} '
            'part=${row.partIndex} qty=$quantity error=$error',
      );
    }
  }

  Future<void> _trimExcessShort({
    required Strategy strategy,
    required Decimal totalLongQty,
    required int leverage,
  }) async {
    final rows = await (db.select(db.recoveryShortLevels)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategy.id) &
                tbl.status.isIn([statusOpen, statusArmedExit]),
          )
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.partIndex)]))
        .get();
    var totalShort = Decimal.zero;
    for (final row in rows) {
      totalShort += _parseDecimal(row.remainingQuantity);
    }
    var excess = totalShort - totalLongQty;
    if (excess <= Decimal.zero) {
      return;
    }
    _debugTrace(
      'RECOVERY_SHORT',
      'lower-bound trim start strategy=${strategy.id} '
          'symbol=${strategy.symbol} totalShort=$totalShort '
          'totalLong=$totalLongQty excess=$excess',
    );
    for (final row in rows) {
      if (excess <= Decimal.zero) {
        return;
      }
      final remaining = _parseDecimal(row.remainingQuantity);
      if (remaining <= Decimal.zero) {
        continue;
      }
      final closeQty = remaining < excess ? remaining : excess;
      _debugTrace(
        'RECOVERY_SHORT',
        'lower-bound trim submit strategy=${strategy.id} '
            'symbol=${strategy.symbol} part=${row.partIndex} '
            'remaining=$remaining closeQty=$closeQty excessBefore=$excess',
      );
      await liveExecution.connectFuturesForSymbol(strategy.symbol);
      await liveExecution.placeHedgeFuturesMarketOrder(
        strategyId: strategy.id,
        symbol: strategy.symbol,
        side: 'BUY',
        quantity: closeQty,
        reduceOnly: true,
        leverage: leverage.clamp(1, 125),
        source: source,
        purpose: 'recoveryShortLowerBoundTrim',
      );
      final nextRemaining = remaining - closeQty;
      await (db.update(db.recoveryShortLevels)
            ..where((tbl) => tbl.id.equals(row.id)))
          .write(
        RecoveryShortLevelsCompanion(
          remainingQuantity: Value(nextRemaining.toString()),
          status: Value(
            nextRemaining > Decimal.zero
                ? row.status
                : statusClosedWaitingRearm,
          ),
          armedForEntry: Value(
            nextRemaining <= Decimal.zero ? false : row.armedForEntry,
          ),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
      excess -= closeQty;
      _debugTrace(
        'RECOVERY_SHORT',
        'lower-bound trim done strategy=${strategy.id} '
            'symbol=${strategy.symbol} part=${row.partIndex} '
            'nextRemaining=$nextRemaining excessAfter=$excess',
      );
    }
  }

  Future<_LongExposure> _longExposure(
    String strategyId,
    Decimal centerPrice,
  ) async {
    final levels = await (db.select(db.gridLevels)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.lifecycleStatus.isIn([
                  'buyFilled',
                  'sellSubmitting',
                  'sellOpen',
                  'sellPartiallyFilled',
                ]),
          ))
        .get();
    Decimal totalQty = Decimal.zero;
    Decimal totalCost = Decimal.zero;
    for (final level in levels) {
      final orderId = level.lastBuyOrderId;
      if (orderId == null || orderId.trim().isEmpty) {
        continue;
      }
      final order = await (db.select(db.orders)
            ..where(
              (tbl) =>
                  tbl.id.equals(orderId) &
                  tbl.source.equals(
                    AutoSpotGridExecutionService.futuresLongSource,
                  ),
            ))
          .getSingleOrNull();
      if (order == null) {
        continue;
      }
      final qty = _parseDecimal(order.executedQuantity);
      if (qty <= Decimal.zero) {
        continue;
      }
      final price = _parseDecimal(order.averagePrice ?? order.price ?? '0');
      if (price <= Decimal.zero) {
        continue;
      }
      totalQty += qty;
      totalCost += price * qty;
    }
    if (totalQty <= Decimal.zero) {
      return _LongExposure.zero();
    }
    final avgPrice = (totalCost / totalQty).toDecimal(
      scaleOnInfinitePrecision: 18,
    );
    return _LongExposure(
      totalLongQty: totalQty,
      longAvgPrice: avgPrice,
      longAvgPercent: _percentFromPrice(avgPrice, centerPrice),
    );
  }

  Future<_ShortExposure> _shortExposure(String strategyId) async {
    final rows = await (db.select(db.recoveryShortLevels)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.status.isIn([
                  statusOpen,
                  statusArmedExit,
                  statusExitSubmitting,
                ]),
          ))
        .get();
    Decimal totalQty = Decimal.zero;
    Decimal totalCost = Decimal.zero;
    for (final row in rows) {
      final qty = _parseDecimal(row.remainingQuantity);
      final price = _parseDecimal(row.entryPrice);
      if (qty <= Decimal.zero || price <= Decimal.zero) {
        continue;
      }
      totalQty += qty;
      totalCost += price * qty;
    }
    if (totalQty <= Decimal.zero) {
      return _ShortExposure.zero();
    }
    return _ShortExposure(
      totalShortQty: totalQty,
      shortAvgPrice: (totalCost / totalQty).toDecimal(
        scaleOnInfinitePrecision: 18,
      ),
    );
  }

  Future<_RecoveryReconcileOutcome> _applyReconciledOrder({
    required RecoveryShortLevel row,
    required Order order,
    required bool isExit,
  }) async {
    final status = order.status.toLowerCase();
    final executed = _parseDecimal(order.executedQuantity);
    final now = DateTime.now().toUtc();
    if (status == 'filled' || executed > Decimal.zero) {
      if (isExit) {
        final remaining = _parseDecimal(row.remainingQuantity);
        final nextRemaining =
            remaining > executed ? remaining - executed : Decimal.zero;
        await (db.update(db.recoveryShortLevels)
              ..where((tbl) => tbl.id.equals(row.id)))
            .write(
          RecoveryShortLevelsCompanion(
            status: Value(
              nextRemaining > Decimal.zero
                  ? statusArmedExit
                  : statusClosedWaitingRearm,
            ),
            remainingQuantity: Value(nextRemaining.toString()),
            armedForExit: Value(nextRemaining > Decimal.zero),
            armedForEntry: const Value(false),
            highestPercentSinceClose: Value(
              nextRemaining > Decimal.zero
                  ? row.highestPercentSinceClose
                  : row.entryPercent,
            ),
            exitOrderId: Value(order.id),
            roundId: Value(
              nextRemaining > Decimal.zero ? row.roundId : row.roundId + 1,
            ),
            lastError: const Value(null),
            updatedAt: Value(now),
          ),
        );
        _debugTrace(
          'RECOVERY_SHORT',
          'light reconcile exit filled level=${row.id} order=${order.id} '
              'executed=$executed nextRemaining=$nextRemaining',
        );
        return _RecoveryReconcileOutcome.recovered;
      }
      final nextQty =
          executed > Decimal.zero ? executed : _parseDecimal(row.quantity);
      await (db.update(db.recoveryShortLevels)
            ..where((tbl) => tbl.id.equals(row.id)))
          .write(
        RecoveryShortLevelsCompanion(
          status: const Value(statusOpen),
          quantity: Value(nextQty.toString()),
          remainingQuantity: Value(nextQty.toString()),
          armedForExit: const Value(false),
          armedForEntry: const Value(false),
          lowestPercentSinceOpen: Value(row.entryPercent),
          entryOrderId: Value(order.id),
          lastError: const Value(null),
          updatedAt: Value(now),
        ),
      );
      _debugTrace(
        'RECOVERY_SHORT',
        'light reconcile entry filled level=${row.id} order=${order.id} '
            'executed=$executed qty=$nextQty',
      );
      return _RecoveryReconcileOutcome.recovered;
    }
    if (_isTerminalOrderStatus(status)) {
      await (db.update(db.recoveryShortLevels)
            ..where((tbl) => tbl.id.equals(row.id)))
          .write(
        RecoveryShortLevelsCompanion(
          status: Value(isExit ? statusArmedExit : statusFailed),
          armedForExit: Value(isExit),
          lastError: Value(
            'Recovery ${isExit ? 'exit' : 'entry'} order $status',
          ),
          updatedAt: Value(now),
        ),
      );
      _debugTrace(
        'RECOVERY_SHORT',
        'light reconcile terminal level=${row.id} order=${order.id} '
            'status=$status isExit=$isExit',
      );
      return _RecoveryReconcileOutcome.failed;
    }
    return _RecoveryReconcileOutcome.pending;
  }

  Future<Order?> _orderById(String orderId) {
    return (db.select(db.orders)..where((tbl) => tbl.id.equals(orderId)))
        .getSingleOrNull();
  }

  Future<Order?> _activeOrderForLevel(
    String strategyId,
    RecoveryShortLevel row,
  ) async {
    final orders = await (db.select(db.orders)
          ..where(
            (tbl) =>
                tbl.strategyId.equals(strategyId) & tbl.source.equals(source),
          ))
        .get();
    for (final order in orders) {
      final belongsToLevel =
          order.id == row.entryOrderId || order.id == row.exitOrderId;
      if (belongsToLevel && _isActiveOrderStatus(order.status)) {
        return order;
      }
    }
    return null;
  }

  Future<void> _bindExistingActiveOrder(
    RecoveryShortLevel row,
    Order order,
  ) async {
    final isExit = order.purpose == exitPurpose || order.reduceOnly;
    await (db.update(db.recoveryShortLevels)
          ..where((tbl) => tbl.id.equals(row.id)))
        .write(
      RecoveryShortLevelsCompanion(
        status: Value(isExit ? statusExitSubmitting : statusEnterSubmitting),
        entryOrderId: isExit ? const Value.absent() : Value(order.id),
        exitOrderId: isExit ? Value(order.id) : const Value.absent(),
        lastError: Value('当前层已有活动订单，禁止重复提交: ${order.clientOrderId}'),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  bool _isTerminalOrderStatus(String status) {
    return status == 'canceled' ||
        status == 'cancelled' ||
        status == 'expired' ||
        status == 'rejected' ||
        status == 'failed' ||
        status == 'error';
  }

  bool _isActiveOrderStatus(String status) {
    final normalized = status.toLowerCase();
    return normalized == 'created' ||
        normalized == 'submitting' ||
        normalized == 'pending' ||
        normalized == 'new' ||
        normalized == 'open' ||
        normalized == 'accepted' ||
        normalized == 'partiallyfilled' ||
        normalized == 'partially_filled' ||
        normalized == 'cancelling';
  }

  Decimal _partQuantity(_LongExposure exposure) {
    if (exposure.totalLongQty <= Decimal.zero) {
      return Decimal.zero;
    }
    final numerator = exposure.longAvgPercent - lowerBoundPercent;
    final denominator = recoveryAvgPercent - lowerBoundPercent;
    if (denominator <= Decimal.zero || numerator <= Decimal.zero) {
      return Decimal.zero;
    }
    final totalShort = exposure.totalLongQty *
        (numerator / denominator).toDecimal(scaleOnInfinitePrecision: 18);
    return (totalShort / Decimal.fromInt(recoveryParts)).toDecimal(
      scaleOnInfinitePrecision: 18,
    );
  }

  Future<Strategy?> _strategy(String strategyId) {
    return (db.select(db.strategies)..where((tbl) => tbl.id.equals(strategyId)))
        .getSingleOrNull();
  }

  String _levelId(String strategyId, int partIndex) =>
      '${strategyId}_recovery_short_$partIndex';

  Decimal _priceFromPercent(Decimal center, Decimal percent) {
    return center *
        (Decimal.fromInt(1) +
            (percent / Decimal.fromInt(100)).toDecimal(
              scaleOnInfinitePrecision: 18,
            ));
  }

  Decimal _percentFromPrice(Decimal price, Decimal center) {
    return ((price / center).toDecimal(scaleOnInfinitePrecision: 18) -
            Decimal.fromInt(1)) *
        Decimal.fromInt(100);
  }

  Decimal _parseDecimal(String raw) => Decimal.tryParse(raw) ?? Decimal.zero;

  Decimal _minNullable(Decimal? current, Decimal value) {
    if (current == null) {
      return value;
    }
    return current < value ? current : value;
  }

  Decimal _maxNullable(Decimal? current, Decimal value) {
    if (current == null) {
      return value;
    }
    return current > value ? current : value;
  }

  bool _isOpenStatus(String status) {
    return status == statusOpen ||
        status == statusArmedExit ||
        status == statusExitSubmitting;
  }

  String _protectionStatus({
    required Decimal shortQty,
    required Decimal shortPnl,
    required Decimal longQty,
    required Decimal? currentPercent,
  }) {
    if (shortQty <= Decimal.zero) {
      if (longQty > Decimal.zero &&
          currentPercent != null &&
          currentPercent <= recoveryStartPercent) {
        return '未生效';
      }
      return '未触发';
    }
    if (shortPnl <= Decimal.zero) {
      return '保护中';
    }
    return '有效抵消';
  }

  void _debugTrace(String tag, String message) {
    assert(() {
      // ignore: avoid_print
      print('[GH_DIAG][$tag] $message');
      return true;
    }());
  }
}

enum _RecoveryReconcileOutcome { recovered, pending, failed }

class RecoveryShortStats {
  const RecoveryShortStats({
    required this.total,
    required this.ready,
    required this.open,
    required this.armedExit,
    required this.submitting,
    required this.closedWaitingRearm,
    required this.failed,
    required this.totalShortQty,
  });

  final int total;
  final int ready;
  final int open;
  final int armedExit;
  final int submitting;
  final int closedWaitingRearm;
  final int failed;
  final Decimal totalShortQty;
}

class RecoveryShortReconcileReport {
  const RecoveryShortReconcileReport({
    required this.scanned,
    required this.synced,
    required this.recovered,
    required this.pending,
    required this.failed,
    required this.missingOrders,
    required this.messages,
  });

  factory RecoveryShortReconcileReport.empty() {
    return const RecoveryShortReconcileReport(
      scanned: 0,
      synced: 0,
      recovered: 0,
      pending: 0,
      failed: 0,
      missingOrders: 0,
      messages: [],
    );
  }

  final int scanned;
  final int synced;
  final int recovered;
  final int pending;
  final int failed;
  final int missingOrders;
  final List<String> messages;

  String get summary => '扫描 $scanned，单笔同步 $synced，恢复 $recovered，'
      '仍提交中 $pending，失败 $failed，缺订单 $missingOrders';

  RecoveryShortReconcileReport merge(RecoveryShortReconcileReport other) {
    return RecoveryShortReconcileReport(
      scanned: scanned + other.scanned,
      synced: synced + other.synced,
      recovered: recovered + other.recovered,
      pending: pending + other.pending,
      failed: failed + other.failed,
      missingOrders: missingOrders + other.missingOrders,
      messages: [...messages, ...other.messages],
    );
  }
}

class RecoveryShortRiskSnapshot {
  const RecoveryShortRiskSnapshot({
    required this.symbol,
    required this.currentMarkPrice,
    required this.longQuantity,
    required this.longAvgPrice,
    required this.longUnrealizedPnl,
    required this.shortQuantity,
    required this.shortAvgPrice,
    required this.shortUnrealizedPnl,
    required this.combinedUnrealizedPnl,
    required this.netQuantity,
    required this.offsetAmount,
    required this.offsetRatio,
    required this.protectionStatus,
  });

  final String symbol;
  final Decimal? currentMarkPrice;
  final Decimal longQuantity;
  final Decimal longAvgPrice;
  final Decimal longUnrealizedPnl;
  final Decimal shortQuantity;
  final Decimal shortAvgPrice;
  final Decimal shortUnrealizedPnl;
  final Decimal combinedUnrealizedPnl;
  final Decimal netQuantity;
  final Decimal offsetAmount;
  final Decimal offsetRatio;
  final String protectionStatus;
}

class _LongExposure {
  const _LongExposure({
    required this.totalLongQty,
    required this.longAvgPrice,
    required this.longAvgPercent,
  });

  _LongExposure.zero()
      : totalLongQty = Decimal.zero,
        longAvgPrice = Decimal.zero,
        longAvgPercent = Decimal.zero;

  final Decimal totalLongQty;
  final Decimal longAvgPrice;
  final Decimal longAvgPercent;
}

class _ShortExposure {
  const _ShortExposure({
    required this.totalShortQty,
    required this.shortAvgPrice,
  });

  _ShortExposure.zero()
      : totalShortQty = Decimal.zero,
        shortAvgPrice = Decimal.zero;

  final Decimal totalShortQty;
  final Decimal shortAvgPrice;
}
