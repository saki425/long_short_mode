import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/database/app_database.dart';
import 'package:grid_hedge_trader/repositories/basic_repositories.dart';
import 'package:grid_hedge_trader/repositories/order_repository.dart';
import 'package:grid_hedge_trader/services/execution/auto_spot_grid_execution_service.dart';
import 'package:grid_hedge_trader/services/execution/live_exchange_execution_service.dart';
import 'package:grid_hedge_trader/services/execution/live_trading_gate_service.dart';
import 'package:grid_hedge_trader/services/execution/recovery_short_engine.dart';
import 'package:grid_hedge_trader/services/app_ui_settings.dart';
import 'package:grid_hedge_trader/services/market_data/binance_futures_market_stream.dart';
import 'package:grid_hedge_trader/services/market_data/binance_spot_market_stream.dart';
import 'package:grid_hedge_trader/services/market_data/market_data_coordinator.dart';
import 'package:grid_hedge_trader/services/market_data/market_data_status.dart';
import 'package:grid_hedge_trader/services/security/secure_key_storage.dart';

void main() {
  late AppDatabase db;
  late StreamController<dynamic> spotController;
  late StreamController<dynamic> futuresController;
  late MarketDataCoordinator marketData;
  late _RecoveryTestLiveExecution liveExecution;
  late AutoSpotGridExecutionService gridExecution;
  late RecoveryShortEngine engine;
  late String strategyId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    spotController = StreamController<dynamic>.broadcast();
    futuresController = StreamController<dynamic>.broadcast();
    final logRepository = LogRepository(db);
    marketData = MarketDataCoordinator(
      db: db,
      logRepository: logRepository,
      spotStream: BinanceSpotMarketStream(
        streamFactory: (_) => spotController.stream,
      ),
      futuresStream: BinanceFuturesMarketStream(
        streamFactory: (_) => futuresController.stream,
      ),
    );
    final gate = LiveTradingGateService()..resetForAppStart();
    liveExecution = _RecoveryTestLiveExecution(
      database: db,
      orderRepository: OrderRepository(db),
      logRepository: logRepository,
      credentialsVault: CredentialsVault(
        store: MemorySecretStore(),
        cache: CredentialsSessionCache(),
        logRepository: logRepository,
      ),
      marketDataCoordinator: marketData,
      liveTradingGateService: gate,
    );
    gridExecution = AutoSpotGridExecutionService(
      db: db,
      liveExecution: liveExecution,
      liveTradingGate: gate,
      marketData: marketData,
      logRepository: logRepository,
    );
    engine = RecoveryShortEngine(
      db: db,
      liveExecution: liveExecution,
      gridExecution: gridExecution,
      marketData: marketData,
    )..start();
    strategyId = await _insertRunningLongStrategyWithExposure(db);
    await AppUiSettings.setShortRecoverEnabledForSymbol(
      db,
      symbol: 'BTCUSDT',
      value: true,
    );
    await marketData.setWorkspaceSymbols(const [
      'BTCUSDT',
    ], activeSymbol: 'BTCUSDT');
    await marketData.setMode(MarketDataMode.binanceLive);
  });

  tearDown(() async {
    await engine.dispose();
    await marketData.disconnect();
    await spotController.close();
    await futuresController.close();
    await db.close();
  });

  test('opens short only on downward entry into trigger range', () async {
    await _emitMark(futuresController, '97');
    await _emitMark(futuresController, '96');
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(liveExecution.orders, isEmpty);

    await _emitMark(futuresController, '99');
    await _emitMark(futuresController, '95.5');
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(liveExecution.orders, isEmpty);

    await _emitMark(futuresController, '95.5');
    await _emitMark(futuresController, '96.8');
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(liveExecution.orders, isEmpty);

    await _emitMark(futuresController, '99');
    await _emitMark(futuresController, '98.45');

    await _waitFor(() => liveExecution.orders.length == 1);
    expect(liveExecution.orders.single.side, 'SELL');
    expect(liveExecution.orders.single.reduceOnly, isFalse);
    final level = await _level(db, strategyId, 0);
    expect(level.status, RecoveryShortEngine.statusOpen);
  });

  test('does not execute while short recovery is disabled', () async {
    await AppUiSettings.setShortRecoverEnabledForSymbol(
      db,
      symbol: 'BTCUSDT',
      value: false,
    );
    await engine.ensureForStrategy(strategyId);

    await _emitMark(futuresController, '99');
    await _emitMark(futuresController, '98.45');
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(liveExecution.orders, isEmpty);
    final level = await _level(db, strategyId, 0);
    expect(level.status, RecoveryShortEngine.statusReadyToEnter);
  });

  test('requires another 0.1 percent drop before exit is armed', () async {
    await _openFirstLevel(futuresController, liveExecution);

    await _emitMark(futuresController, '97.45');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(
      (await _level(db, strategyId, 0)).status,
      RecoveryShortEngine.statusOpen,
    );

    await _emitMark(futuresController, '97.39');
    await _waitFor(
      () async =>
          (await _level(db, strategyId, 0)).status ==
          RecoveryShortEngine.statusArmedExit,
    );
  });

  test(
    'closes short when price rebounds near entry after being armed',
    () async {
      await _openFirstLevel(futuresController, liveExecution);
      await _emitMark(futuresController, '97.3');
      await _waitFor(
        () async =>
            (await _level(db, strategyId, 0)).status ==
            RecoveryShortEngine.statusArmedExit,
      );

      await _emitMark(futuresController, '96.4');
      await _emitMark(futuresController, '96.6');

      await _waitFor(
        () async =>
            (await _level(db, strategyId, 0)).status ==
            RecoveryShortEngine.statusClosedWaitingRearm,
      );
      expect(liveExecution.orders.last.side, 'BUY');
      expect(liveExecution.orders.last.reduceOnly, isTrue);
      final level = await _level(db, strategyId, 0);
      expect(level.status, RecoveryShortEngine.statusClosedWaitingRearm);
      expect(level.remainingQuantity, '0');
    },
  );

  test(
    'requires a 0.1 percent rebound before re-entering is allowed',
    () async {
      await _openAndCloseFirstLevel(
        futuresController,
        liveExecution,
        db,
        strategyId,
      );

      await _emitMark(futuresController, '97.55');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      var level = await _level(db, strategyId, 0);
      expect(level.status, RecoveryShortEngine.statusClosedWaitingRearm);
      expect(level.armedForEntry, isFalse);

      await _emitMark(futuresController, '97.6');
      await _waitFor(
        () async =>
            (await _level(db, strategyId, 0)).status ==
            RecoveryShortEngine.statusReadyToEnter,
      );
      level = await _level(db, strategyId, 0);
      expect(level.armedForEntry, isTrue);
    },
  );

  test('failed level does not block lower recovery levels', () async {
    liveExecution.failNextSellCount = 1;

    await _emitMark(futuresController, '99');
    await _emitMark(futuresController, '98.35');

    await _waitFor(() async {
      final first = await _level(db, strategyId, 0);
      final second = await _level(db, strategyId, 1);
      return first.status == RecoveryShortEngine.statusFailed &&
          second.status == RecoveryShortEngine.statusOpen;
    });

    final first = await _level(db, strategyId, 0);
    final second = await _level(db, strategyId, 1);
    expect(first.lastError, contains('planned SELL failure'));
    expect(second.entryOrderId, isNotNull);
    expect(liveExecution.orders, hasLength(1));
    expect(liveExecution.orders.single.side, 'SELL');
  });

  test('light reconcile rearms entry that failed before submission', () async {
    await engine.ensureForStrategy(strategyId);
    final level = await _level(db, strategyId, 0);
    await (db.update(db.recoveryShortLevels)
          ..where((tbl) => tbl.id.equals(level.id)))
        .write(
      const RecoveryShortLevelsCompanion(
        status: Value(RecoveryShortEngine.statusFailed),
        armedForEntry: Value(true),
        lastError: Value(
          'Bad state: Long futures exposure is disabled for live futures',
        ),
      ),
    );

    final report = await engine.reconcileStrategy(strategyId);
    final updated = await _level(db, strategyId, 0);

    expect(report.scanned, 1);
    expect(report.recovered, 1);
    expect(updated.status, RecoveryShortEngine.statusReadyToEnter);
    expect(updated.armedForEntry, isTrue);
    expect(updated.lastError, isNull);
  });

  test('light reconcile recovers filled entry submission', () async {
    await engine.ensureForStrategy(strategyId);
    final now = DateTime.now().toUtc();
    const orderId = 'recovery_entry_stuck';
    await _insertRecoveryOrder(
      db: db,
      id: orderId,
      strategyId: strategyId,
      side: 'SELL',
      reduceOnly: false,
      quantity: '1.25',
      status: 'filled',
      now: now,
    );
    final level = await _level(db, strategyId, 0);
    await (db.update(db.recoveryShortLevels)
          ..where((tbl) => tbl.id.equals(level.id)))
        .write(
      const RecoveryShortLevelsCompanion(
        status: Value(RecoveryShortEngine.statusEnterSubmitting),
        quantity: Value('1.25'),
        entryOrderId: Value(orderId),
      ),
    );

    final report = await engine.reconcileStrategy(strategyId);
    final updated = await _level(db, strategyId, 0);

    expect(report.scanned, 1);
    expect(report.recovered, 1);
    expect(updated.status, RecoveryShortEngine.statusOpen);
    expect(updated.remainingQuantity, '1.25');
    expect(updated.entryOrderId, orderId);
  });

  test('light reconcile recovers filled exit submission', () async {
    await engine.ensureForStrategy(strategyId);
    final now = DateTime.now().toUtc();
    const orderId = 'recovery_exit_stuck';
    await _insertRecoveryOrder(
      db: db,
      id: orderId,
      strategyId: strategyId,
      side: 'BUY',
      reduceOnly: true,
      quantity: '1.25',
      status: 'filled',
      now: now,
    );
    final level = await _level(db, strategyId, 0);
    await (db.update(db.recoveryShortLevels)
          ..where((tbl) => tbl.id.equals(level.id)))
        .write(
      const RecoveryShortLevelsCompanion(
        status: Value(RecoveryShortEngine.statusExitSubmitting),
        quantity: Value('1.25'),
        remainingQuantity: Value('1.25'),
        armedForExit: Value(true),
        exitOrderId: Value(orderId),
      ),
    );

    final report = await engine.reconcileStrategy(strategyId);
    final updated = await _level(db, strategyId, 0);

    expect(report.scanned, 1);
    expect(report.recovered, 1);
    expect(updated.status, RecoveryShortEngine.statusClosedWaitingRearm);
    expect(updated.remainingQuantity, '0');
    expect(updated.roundId, 1);
    expect(updated.exitOrderId, orderId);
  });

  test('does not submit duplicate order for the same recovery level', () async {
    await engine.ensureForStrategy(strategyId);
    final level = await _level(db, strategyId, 0);
    const orderId = 'recovery_entry_active';
    await _insertRecoveryOrder(
      db: db,
      id: orderId,
      strategyId: strategyId,
      side: 'SELL',
      reduceOnly: false,
      quantity: '1.25',
      status: 'new',
      now: DateTime.now().toUtc(),
    );
    await (db.update(db.recoveryShortLevels)
          ..where(
            (tbl) => tbl.id.equals(level.id),
          ))
        .write(
            const RecoveryShortLevelsCompanion(entryOrderId: Value(orderId)));

    await _emitMark(futuresController, '99');
    await _emitMark(futuresController, '98.45');
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final updated = await _level(db, strategyId, 0);
    expect(liveExecution.orders, isEmpty);
    expect(updated.status, RecoveryShortEngine.statusEnterSubmitting);
    expect(updated.entryOrderId, orderId);
    expect(updated.lastError, contains('禁止重复提交'));
  });
}

Future<String> _insertRunningLongStrategyWithExposure(AppDatabase db) async {
  final now = DateTime.utc(2026, 9, 17);
  const strategyId = 'recovery_strategy_1';
  await db.into(db.strategies).insert(
        StrategiesCompanion.insert(
          id: strategyId,
          name: 'BTCUSDT LIVE Futures Long Grid',
          symbol: 'BTCUSDT',
          environment: AutoSpotGridExecutionService.futuresGridEnvironment,
          status: 'running',
          createdAt: now,
          startedAt: Value(now),
          lowerPrice: '93',
          upperPrice: '107',
          centerPrice: '100',
          gridCount: 14,
          gridSpacingPercent: '1',
          gridMode: 'arithmetic',
          spotCapital: '0',
          futuresCapital: '100',
          reserveCapital: '0',
          hedgeRatio: '0',
          maxLossUsdt: '0',
          maxExposureUsdt: '100',
          updatedAt: now,
        ),
      );
  await db.into(db.gridLevels).insert(
        GridLevelsCompanion.insert(
          id: 'long_level_1',
          strategyId: strategyId,
          gridIndex: 1,
          price: '101',
          buyPrice: const Value('101'),
          sellPrice: const Value('102'),
          plannedSide: 'BUY',
          plannedQuantity: '10',
          plannedQuoteAmount: '1010',
          status: 'buyFilled',
          lifecycleStatus: const Value('buyFilled'),
          lastBuyOrderId: const Value('long_buy_order_1'),
          createdAt: now,
          updatedAt: now,
        ),
      );
  await db.into(db.orders).insert(
        OrdersCompanion.insert(
          id: 'long_buy_order_1',
          strategyId: strategyId,
          environment: const Value('live'),
          source: const Value(AutoSpotGridExecutionService.futuresLongSource),
          accountType: 'futuresSubAccount',
          marketType: 'usdtFutures',
          symbol: 'BTCUSDT',
          clientOrderId: 'GH_LONG_BUY_1',
          side: 'BUY',
          positionSide: const Value('LONG'),
          orderType: 'LIMIT',
          timeInForce: const Value('GTC'),
          price: const Value('101'),
          originalQuantity: '10',
          executedQuantity: const Value('10'),
          averagePrice: const Value('101'),
          status: 'filled',
          purpose: 'gridBuy',
          gridLevelId: const Value('long_level_1'),
          createdAt: now,
          updatedAt: now,
          completedAt: Value(now),
        ),
      );
  return strategyId;
}

Future<void> _openFirstLevel(
  StreamController<dynamic> futuresController,
  _RecoveryTestLiveExecution liveExecution,
) async {
  await _emitMark(futuresController, '99');
  await _emitMark(futuresController, '98.45');
  await _waitFor(() => liveExecution.orders.length == 1);
}

Future<void> _openAndCloseFirstLevel(
  StreamController<dynamic> futuresController,
  _RecoveryTestLiveExecution liveExecution,
  AppDatabase db,
  String strategyId,
) async {
  await _openFirstLevel(futuresController, liveExecution);
  await _emitMark(futuresController, '97.3');
  await _waitFor(
    () async =>
        (await _level(db, strategyId, 0)).status ==
        RecoveryShortEngine.statusArmedExit,
  );
  await _emitMark(futuresController, '96.4');
  await _emitMark(futuresController, '96.6');
  await _waitFor(
    () async =>
        (await _level(db, strategyId, 0)).status ==
        RecoveryShortEngine.statusClosedWaitingRearm,
  );
}

Future<RecoveryShortLevel> _level(
  AppDatabase db,
  String strategyId,
  int partIndex,
) {
  final query = db.select(db.recoveryShortLevels)
    ..where((tbl) => tbl.strategyId.equals(strategyId))
    ..where((tbl) => tbl.partIndex.equals(partIndex));
  return query.getSingle();
}

Future<void> _insertRecoveryOrder({
  required AppDatabase db,
  required String id,
  required String strategyId,
  required String side,
  required bool reduceOnly,
  required String quantity,
  required String status,
  required DateTime now,
}) async {
  await db.into(db.orders).insert(
        OrdersCompanion.insert(
          id: id,
          strategyId: strategyId,
          environment: const Value('live'),
          source: const Value(RecoveryShortEngine.source),
          accountType: 'futuresSubAccount',
          marketType: 'usdtFutures',
          symbol: 'BTCUSDT',
          clientOrderId: 'GH_$id',
          side: side,
          positionSide: const Value('SHORT'),
          orderType: 'MARKET',
          price: const Value('0'),
          originalQuantity: quantity,
          executedQuantity: Value(quantity),
          averagePrice: const Value('97.5'),
          reduceOnly: Value(reduceOnly),
          status: status,
          purpose: side == 'SELL'
              ? RecoveryShortEngine.entryPurpose
              : RecoveryShortEngine.exitPurpose,
          createdAt: now,
          submittedAt: Value(now),
          updatedAt: now,
          completedAt: Value(now),
        ),
      );
}

Future<void> _emitMark(
  StreamController<dynamic> futuresController,
  String price,
) async {
  futuresController.add(
    '{"e":"markPriceUpdate","E":1562305380000,"s":"BTCUSDT","p":"$price","i":"$price","P":"$price","r":"0","T":1562306400000}',
  );
  await Future<void>.delayed(const Duration(milliseconds: 30));
}

Future<void> _waitFor(
  FutureOr<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Timed out waiting for condition');
}

class _RecoveryTestLiveExecution extends LiveExchangeExecutionService {
  _RecoveryTestLiveExecution({
    required AppDatabase database,
    required super.orderRepository,
    required super.logRepository,
    required super.credentialsVault,
    required super.marketDataCoordinator,
    required super.liveTradingGateService,
  })  : database = database,
        super(db: database);

  final AppDatabase database;
  final List<_PlacedRecoveryOrder> orders = [];
  int failNextSellCount = 0;

  @override
  Future<void> connectFuturesForSymbol(String symbol) async {}

  @override
  Future<bool> syncFuturesOrderFromBinance(Order order) async {
    return true;
  }

  @override
  Future<String> placeHedgeFuturesMarketOrder({
    required String strategyId,
    required String side,
    required Decimal quantity,
    required bool reduceOnly,
    String symbol = 'BTCUSDT',
    int leverage = 1,
    String source = 'autoHedge',
    String? purpose,
    String? gridLevelId,
  }) async {
    if (side == 'SELL' && failNextSellCount > 0) {
      failNextSellCount -= 1;
      throw StateError('planned SELL failure');
    }
    final id = 'recovery_order_${orders.length + 1}';
    final now = DateTime.now().toUtc();
    await database.into(database.orders).insert(
          OrdersCompanion.insert(
            id: id,
            strategyId: strategyId,
            environment: const Value('live'),
            source: Value(source),
            accountType: 'futuresSubAccount',
            marketType: 'usdtFutures',
            symbol: symbol,
            clientOrderId: 'GH_RECOVERY_${orders.length + 1}',
            side: side,
            positionSide: const Value('SHORT'),
            orderType: 'MARKET',
            price: const Value('0'),
            originalQuantity: quantity.toString(),
            executedQuantity: Value(quantity.toString()),
            averagePrice: const Value('0'),
            reduceOnly: Value(reduceOnly),
            status: 'filled',
            purpose: purpose ?? 'recoveryShort',
            createdAt: now,
            submittedAt: Value(now),
            updatedAt: now,
            completedAt: Value(now),
          ),
        );
    orders.add(
      _PlacedRecoveryOrder(
        id: id,
        side: side,
        quantity: quantity,
        reduceOnly: reduceOnly,
        source: source,
        purpose: purpose,
      ),
    );
    return id;
  }
}

class _PlacedRecoveryOrder {
  const _PlacedRecoveryOrder({
    required this.id,
    required this.side,
    required this.quantity,
    required this.reduceOnly,
    required this.source,
    required this.purpose,
  });

  final String id;
  final String side;
  final Decimal quantity;
  final bool reduceOnly;
  final String source;
  final String? purpose;
}
