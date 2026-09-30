import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/database/app_database.dart';
import 'package:grid_hedge_trader/repositories/basic_repositories.dart';
import 'package:grid_hedge_trader/repositories/order_repository.dart';
import 'package:grid_hedge_trader/services/binance/auth/binance_request_exception.dart';
import 'package:grid_hedge_trader/services/execution/auto_spot_grid_execution_service.dart';
import 'package:grid_hedge_trader/services/execution/future_grid_engine.dart';
import 'package:grid_hedge_trader/services/execution/live_exchange_execution_service.dart';
import 'package:grid_hedge_trader/services/execution/live_trading_gate_service.dart';
import 'package:grid_hedge_trader/services/market_data/market_data_coordinator.dart';
import 'package:grid_hedge_trader/services/pnl/completed_grid_cycle_service.dart';
import 'package:grid_hedge_trader/services/pnl/strategy_performance_service.dart';
import 'package:grid_hedge_trader/services/security/secure_key_storage.dart';

void main() {
  late AppDatabase db;
  late AutoSpotGridExecutionService service;
  late MarketDataCoordinator marketData;
  late LiveTradingGateService gate;
  late _TestLiveExchangeExecutionService liveExecution;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    final logRepository = LogRepository(db);
    marketData = MarketDataCoordinator(db: db, logRepository: logRepository);
    gate = LiveTradingGateService()..resetForAppStart();
    final credentialsVault = CredentialsVault(
      store: MemorySecretStore(),
      cache: CredentialsSessionCache(),
      logRepository: logRepository,
    );
    liveExecution = _TestLiveExchangeExecutionService(
      db: db,
      orderRepository: OrderRepository(db),
      logRepository: logRepository,
      credentialsVault: credentialsVault,
      marketDataCoordinator: marketData,
      liveTradingGateService: gate,
    );
    service = AutoSpotGridExecutionService(
      db: db,
      liveExecution: liveExecution,
      liveTradingGate: gate,
      marketData: marketData,
      logRepository: logRepository,
    );
  });

  tearDown(() async {
    await marketData.disconnect();
    await db.close();
  });

  test(
    'creates LIVE_SPOT_GRID strategy and grid levels without paper orders',
    () async {
      final strategyId = await service.createDefaultStrategy();

      final strategy =
          await (db.select(db.strategies)
            ..where((tbl) => tbl.id.equals(strategyId))).getSingle();
      final levels = await service.watchGridLevels(strategyId).first;
      final orders = await db.select(db.orders).get();

      expect(strategy.environment, AutoSpotGridExecutionService.environment);
      expect(strategy.spotCapital, '50');
      expect(strategy.status, 'idle');
      expect(levels, isNotEmpty);
      expect(orders, isEmpty);
    },
  );

  test(
    'default LIVE grid separates interval count from price level count',
    () async {
      final strategyId = await service.createDefaultStrategy();

      final strategy =
          await (db.select(db.strategies)
            ..where((tbl) => tbl.id.equals(strategyId))).getSingle();
      final levels = await service.watchGridLevels(strategyId).first;

      expect(strategy.gridCount, 6);
      expect(levels, hasLength(6));
      expect(AutoSpotGridExecutionService.maxOpenOrders, 4);
      expect(AutoSpotGridExecutionService.initialBuyOrderCount, 2);
      expect(AutoSpotGridExecutionService.initialSellOrderCount, 0);
      expect(
        levels.every((level) => level.lifecycleStatus == 'waitingBuy'),
        isTrue,
      );
      expect(levels.every((level) => level.buyPrice != null), isTrue);
      expect(levels.every((level) => level.sellPrice != null), isTrue);
      expect(levels.every((level) => level.plannedSide == 'BUY'), isTrue);
      final pairs =
          levels.map((level) => '${level.buyPrice}:${level.sellPrice}').toSet();
      expect(pairs, hasLength(levels.length));
    },
  );

  test('enabled future hedge grid maps configured bottom rows', () async {
    final strategyId = await service.createDefaultStrategy();
    final config = await service.loadEditableConfig(strategyId);
    expect(config == null, isFalse);

    await service.updateEditableConfig(
      strategyId,
      LiveSpotGridEditableConfig(
        name: config!.name,
        symbol: config.symbol,
        executionMode: config.executionMode,
        centerPrice: config.centerPrice,
        lowerPrice: config.lowerPrice,
        upperPrice: config.upperPrice,
        gridMode: config.gridMode,
        gridIntervalCount: config.gridIntervalCount,
        initialBuyOrderCount: config.initialBuyOrderCount,
        initialSellOrderCount: config.initialSellOrderCount,
        maxOpenOrders: config.maxOpenOrders,
        spotCapital: config.spotCapital,
        initialBtcRatio: config.initialBtcRatio,
        singleGridAmount: config.singleGridAmount,
        maxLossUsdt: config.maxLossUsdt,
        dailyMaxLossUsdt: config.dailyMaxLossUsdt,
        outOfRangeAction: config.outOfRangeAction,
        enableFutureHedgeGrid: true,
        futureGridOffset: 1,
        futuresLeverage: config.futuresLeverage,
        futuresPriceSource: config.futuresPriceSource,
        longEntryTriggerDistanceUsdt: config.longEntryTriggerDistanceUsdt,
        shortHedgeMultiplier: config.shortHedgeMultiplier,
        shortHedgeSpreadLevels: config.shortHedgeSpreadLevels,
      ),
    );

    final spotLevels = await service.watchGridLevels(strategyId).first;
    final futureRows = await service.futureGridEngine.futureGridOrders(
      strategyId,
    );

    final hedgedSpotLevels = spotLevels.take(config.shortHedgeSpreadLevels);
    expect(futureRows, hasLength(config.shortHedgeSpreadLevels));
    for (final row in futureRows) {
      final spot = hedgedSpotLevels.firstWhere(
        (level) => level.id == row.spotGridOrderId,
      );
      expect(row.side, 'SHORT');
      expect(row.status, 'WAIT_TRIGGER');
      expect(row.price, spot.buyPrice);
      expect(row.quantity, '0');
      expect(row.symbol, 'BTCUSDT');
    }
  });

  test(
    'short futures reconcile advances open and close rows from Binance history',
    () async {
      final strategyId = await service.createDefaultStrategy(
        executionMode: LiveSpotGridEditableConfig.futuresGridHedge,
      );
      final level = (await service.watchGridLevels(strategyId).first).first;
      final existingRow =
          await (db.select(db.futureGridOrders)
            ..where((tbl) => tbl.spotGridOrderId.equals(level.id))).getSingle();
      final now = DateTime.utc(2026, 8, 16, 14);
      await (db.update(db.futureGridOrders)
        ..where((tbl) => tbl.id.equals(existingRow.id))).write(
        FutureGridOrdersCompanion(
          quantity: const Value('0.02'),
          status: const Value('WAIT_OPEN'),
          futuresOrderId: const Value('short_open_1'),
          updatedAt: Value(now),
        ),
      );
      await _insertGridOrder(
        db,
        id: 'short_open_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'SELL',
        status: 'new',
        clientOrderId: 'GH_SHORT_open_1',
        createdAt: now,
        source: FutureGridEngine.source,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: FutureGridEngine.openPurpose,
        positionSide: 'SHORT',
      );
      await _insertExchangeHistoricalOrder(
        db,
        id: 'hist_short_open_1',
        symbol: 'BTCUSDT',
        exchangeOrderId: '3001',
        clientOrderId: 'GH_SHORT_open_1',
        side: 'SELL',
        positionSide: 'SHORT',
        status: 'FILLED',
        price: level.buyPrice ?? level.price,
        originalQuantity: '0.02',
        executedQuantity: '0.02',
        averagePrice: level.buyPrice ?? level.price,
        createdAt: now,
        updatedAt: now.add(const Duration(seconds: 1)),
      );

      await service.futureGridEngine.reconcileStrategy(
        strategyId,
        refreshFirst: false,
      );

      var row =
          await (db.select(db.futureGridOrders)
            ..where((tbl) => tbl.id.equals(existingRow.id))).getSingle();
      expect(row.status, 'OPEN');
      expect(row.quantity, '0.02');

      await _insertGridOrder(
        db,
        id: 'short_close_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'new',
        clientOrderId: 'GH_SHORT_close_1',
        createdAt: now.add(const Duration(seconds: 2)),
        source: FutureGridEngine.source,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: FutureGridEngine.closePurpose,
        positionSide: 'SHORT',
        reduceOnly: true,
      );
      await _insertExchangeHistoricalOrder(
        db,
        id: 'hist_short_close_1',
        symbol: 'BTCUSDT',
        exchangeOrderId: '3002',
        clientOrderId: 'GH_SHORT_close_1',
        side: 'BUY',
        positionSide: 'SHORT',
        status: 'FILLED',
        price: level.buyPrice ?? level.price,
        originalQuantity: '0.02',
        executedQuantity: '0.02',
        averagePrice: level.buyPrice ?? level.price,
        reduceOnly: true,
        createdAt: now.add(const Duration(seconds: 2)),
        updatedAt: now.add(const Duration(seconds: 3)),
      );
      await (db.update(db.futureGridOrders)
        ..where((tbl) => tbl.id.equals(existingRow.id))).write(
        FutureGridOrdersCompanion(
          status: const Value('CLOSING'),
          futuresOrderId: const Value('short_close_1'),
          updatedAt: Value(now.add(const Duration(seconds: 2))),
        ),
      );

      await service.futureGridEngine.reconcileStrategy(
        strategyId,
        refreshFirst: false,
      );

      row =
          await (db.select(db.futureGridOrders)
            ..where((tbl) => tbl.id.equals(existingRow.id))).getSingle();
      expect(row.status, 'CLOSED');
      expect(row.quantity, '0');
    },
  );

  test(
    'preflight blocks when live writes and market data are not ready',
    () async {
      final strategyId = await service.createDefaultStrategy();

      final result = await service.preflight(strategyId);

      expect(result.ok, isFalse);
      expect(result.failures, contains('真实写操作未开启'));
      expect(result.failures, contains('公共行情未就绪'));
    },
  );

  test(
    'refreshGridLifecycle moves fixed row from filled BUY to open SELL',
    () async {
      final strategyId = await service.createDefaultStrategy();
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 7, 10, 10);
      await _insertGridOrder(
        db,
        id: 'buy_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'filled',
        clientOrderId: 'GH_LIVE_GRID_SPOT_buy_1',
        createdAt: now,
        completedAt: now.add(const Duration(seconds: 2)),
        executedQuantity: '0.00014',
        averagePrice: level.buyPrice ?? level.price,
      );
      await _insertGridOrder(
        db,
        id: 'sell_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'SELL',
        status: 'new',
        clientOrderId: 'GH_LIVE_GRID_SPOT_sell_1',
        parentOrderId: 'buy_1',
        createdAt: now.add(const Duration(seconds: 3)),
        price: level.sellPrice,
      );

      await service.refreshGridLifecycle(strategyId);

      final refreshed =
          await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(level.id))).getSingle();
      expect(refreshed.lifecycleStatus, 'sellOpen');
      expect(refreshed.activeOrderId, 'sell_1');
      expect(refreshed.lastBuyOrderId, 'buy_1');
      expect(refreshed.lastSellOrderId, 'sell_1');
    },
  );

  test(
    'refreshGridLifecycle moves fixed row from filled SELL to next open BUY',
    () async {
      final strategyId = await service.createDefaultStrategy();
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 7, 10, 11);
      await _insertGridOrder(
        db,
        id: 'buy_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'filled',
        clientOrderId: 'GH_LIVE_GRID_SPOT_buy_1',
        createdAt: now,
        completedAt: now.add(const Duration(seconds: 2)),
        executedQuantity: '0.00014',
        averagePrice: level.buyPrice ?? level.price,
      );
      await _insertGridOrder(
        db,
        id: 'sell_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'SELL',
        status: 'filled',
        clientOrderId: 'GH_LIVE_GRID_SPOT_sell_1',
        parentOrderId: 'buy_1',
        createdAt: now.add(const Duration(seconds: 3)),
        completedAt: now.add(const Duration(seconds: 5)),
        executedQuantity: '0.00014',
        averagePrice: level.sellPrice ?? level.nextUpperPrice ?? level.price,
        price: level.sellPrice,
      );
      await _insertGridOrder(
        db,
        id: 'buy_2',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'new',
        clientOrderId: 'GH_LIVE_GRID_SPOT_buy_2',
        parentOrderId: 'sell_1',
        createdAt: now.add(const Duration(seconds: 6)),
      );

      await service.refreshGridLifecycle(strategyId);

      final refreshed =
          await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(level.id))).getSingle();
      expect(refreshed.lifecycleStatus, 'buyOpen');
      expect(refreshed.activeOrderId, 'buy_2');
      expect(refreshed.lastCompletedOrderId, 'sell_1');
      expect(refreshed.lastSellOrderId, equals(null));
      expect(refreshed.cycleNumber, 1);
    },
  );

  test(
    'futures long reconcile keeps next BUY as current row after old SELL history sync',
    () async {
      final strategyId = await service.createDefaultStrategy(
        executionMode: LiveSpotGridEditableConfig.futuresGridHedge,
      );
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 8, 16, 10);
      await _insertGridOrder(
        db,
        id: 'futures_buy_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'filled',
        clientOrderId: 'GH_FUTURES_LONG_buy_1',
        createdAt: now,
        completedAt: now.add(const Duration(seconds: 2)),
        executedQuantity: '0.02',
        averagePrice: level.buyPrice ?? level.price,
        source: AutoSpotGridExecutionService.futuresLongSource,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: 'futuresLongGridBuy',
        positionSide: 'LONG',
      );
      await _insertGridOrder(
        db,
        id: 'futures_buy_2',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'new',
        clientOrderId: 'GH_FUTURES_LONG_buy_2',
        parentOrderId: 'futures_sell_1',
        createdAt: now.add(const Duration(seconds: 6)),
        source: AutoSpotGridExecutionService.futuresLongSource,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: 'futuresLongGridBuy',
        positionSide: 'LONG',
      );
      await _insertGridOrder(
        db,
        id: 'futures_sell_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'SELL',
        status: 'filled',
        clientOrderId: 'GH_FUTURES_LONG_sell_1',
        parentOrderId: 'futures_buy_1',
        createdAt: now.add(const Duration(seconds: 3)),
        completedAt: now.add(const Duration(seconds: 5)),
        executedQuantity: '0.02',
        averagePrice: level.sellPrice ?? level.nextUpperPrice ?? level.price,
        price: level.sellPrice,
        source: AutoSpotGridExecutionService.futuresLongSource,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: 'futuresLongGridSell',
        positionSide: 'LONG',
        reduceOnly: true,
      );
      await _insertExchangeHistoricalOrder(
        db,
        id: 'hist_futures_sell_1',
        symbol: 'BTCUSDT',
        exchangeOrderId: '2001',
        clientOrderId: 'GH_FUTURES_LONG_sell_1',
        side: 'SELL',
        positionSide: 'LONG',
        status: 'FILLED',
        price: level.sellPrice ?? level.price,
        originalQuantity: '0.02',
        executedQuantity: '0.02',
        averagePrice: level.sellPrice ?? level.price,
        reduceOnly: true,
        createdAt: now.add(const Duration(seconds: 3)),
        updatedAt: now.add(const Duration(seconds: 5)),
      );
      await _insertExchangeHistoricalOrder(
        db,
        id: 'hist_futures_buy_2',
        symbol: 'BTCUSDT',
        exchangeOrderId: '2002',
        clientOrderId: 'GH_FUTURES_LONG_buy_2',
        side: 'BUY',
        positionSide: 'LONG',
        status: 'NEW',
        price: level.buyPrice ?? level.price,
        originalQuantity: '0.02',
        executedQuantity: '0',
        averagePrice: '0',
        createdAt: now.add(const Duration(seconds: 6)),
        updatedAt: now.add(const Duration(seconds: 6)),
      );

      await service.reconcileFuturesLongGrid(
        strategyId,
        refreshFirst: false,
        validateMissingOpenOrders: false,
      );

      final refreshed =
          await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(level.id))).getSingle();
      expect(refreshed.lifecycleStatus, 'buyOpen');
      expect(refreshed.activeOrderId, 'futures_buy_2');
      expect(refreshed.linkedOrderId, 'futures_buy_2');
      expect(refreshed.lastBuyOrderId, 'futures_buy_2');
      expect(refreshed.lastSellOrderId, equals(null));
      expect(refreshed.lastCompletedOrderId, 'futures_sell_1');
      expect(refreshed.cycleNumber, 1);
    },
  );

  test(
    'futures long reconcile releases filled sell back to waiting buy',
    () async {
      final strategyId = await service.createDefaultStrategy(
        executionMode: LiveSpotGridEditableConfig.futuresGridHedge,
      );
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 8, 24, 12);
      await _insertGridOrder(
        db,
        id: 'futures_buy_done',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'filled',
        clientOrderId: 'GH_FUTURES_LONG_done_buy',
        createdAt: now,
        completedAt: now.add(const Duration(seconds: 1)),
        executedQuantity: '0.02',
        averagePrice: level.buyPrice ?? level.price,
        source: AutoSpotGridExecutionService.futuresLongSource,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: 'futuresLongGridBuy',
        positionSide: 'LONG',
      );
      await _insertGridOrder(
        db,
        id: 'futures_sell_done',
        strategyId: strategyId,
        gridId: level.id,
        side: 'SELL',
        status: 'filled',
        clientOrderId: 'GH_FUTURES_LONG_done_sell',
        parentOrderId: 'futures_buy_done',
        createdAt: now.add(const Duration(seconds: 2)),
        completedAt: now.add(const Duration(seconds: 3)),
        executedQuantity: '0.02',
        averagePrice: level.sellPrice ?? level.price,
        price: level.sellPrice,
        source: AutoSpotGridExecutionService.futuresLongSource,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: 'futuresLongGridSell',
        positionSide: 'LONG',
        reduceOnly: true,
      );

      await service.reconcileFuturesLongGrid(
        strategyId,
        refreshFirst: false,
        validateMissingOpenOrders: false,
      );

      final refreshed =
          await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(level.id))).getSingle();
      expect(refreshed.lifecycleStatus, 'waitingBuy');
      expect(refreshed.status, 'waitingBuy');
      expect(refreshed.linkedOrderId, equals(null));
      expect(refreshed.activeOrderId, equals(null));
      expect(refreshed.lastBuyOrderId, equals(null));
      expect(refreshed.lastSellOrderId, equals(null));
      expect(refreshed.lastCompletedOrderId, 'futures_sell_done');
      expect(refreshed.cycleNumber, 1);
    },
  );

  test(
    'futures long reconcile ignores released historical errors in summary',
    () async {
      final strategyId = await service.createDefaultStrategy(
        executionMode: LiveSpotGridEditableConfig.futuresGridHedge,
      );
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 8, 16, 15);
      await _insertGridOrder(
        db,
        id: 'released_sell_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'SELL',
        status: 'expired',
        clientOrderId: 'GH_LONG_GRID_FUTURES_released_sell_1',
        createdAt: now,
        source: AutoSpotGridExecutionService.futuresLongSource,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: 'futuresLongGridSell',
        positionSide: 'LONG',
        reduceOnly: true,
      );
      await (db.update(db.orders)
        ..where((tbl) => tbl.id.equals('released_sell_1'))).write(
        const OrdersCompanion(
          errorMessage: Value('Binance 当前挂单和历史订单均无有效活动状态，已释放本地网格。'),
        ),
      );

      final report = await service.reconcileFuturesLongGrid(
        strategyId,
        refreshFirst: false,
        validateMissingOpenOrders: false,
      );

      expect(report.errorOrders, 0);
      expect(report.errorDetails, isEmpty);
      final refreshed =
          await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(level.id))).getSingle();
      expect(refreshed.lifecycleStatus, 'waitingBuy');
      expect(refreshed.activeOrderId, equals(null));
      expect(refreshed.lastSellOrderId, equals(null));
    },
  );

  test(
    'futures long reconcile ignores zero fill terminal close failures',
    () async {
      final strategyId = await service.createDefaultStrategy(
        executionMode: LiveSpotGridEditableConfig.futuresGridHedge,
      );
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 8, 24, 15);
      await _insertGridOrder(
        db,
        id: 'filled_long_buy_before_failed_close',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'filled',
        clientOrderId: 'GH_LONG_GRID_FUTURES_filled_buy_before_failed_close',
        createdAt: now,
        completedAt: now.add(const Duration(seconds: 1)),
        executedQuantity: '0.02',
        averagePrice: level.buyPrice ?? level.price,
        price: level.buyPrice,
        source: AutoSpotGridExecutionService.futuresLongSource,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: 'futuresLongGridBuy',
        positionSide: 'LONG',
      );
      await _insertGridOrder(
        db,
        id: 'failed_zero_fill_long_close',
        strategyId: strategyId,
        gridId: level.id,
        side: 'SELL',
        status: 'failed',
        clientOrderId: 'GH_LONG_GRID_FUTURES_failed_zero_fill_close',
        createdAt: now.add(const Duration(seconds: 2)),
        price: level.sellPrice,
        source: AutoSpotGridExecutionService.futuresLongSource,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: 'futuresLongGridSell',
        positionSide: 'LONG',
        reduceOnly: true,
      );
      await (db.update(db.orders)
        ..where((tbl) => tbl.id.equals('failed_zero_fill_long_close'))).write(
        const OrdersCompanion(
          errorMessage: Value(
            'BinanceRequestException(statusCode: 400, code: -2022, message: ReduceOnly Order is rejected.)',
          ),
        ),
      );
      await (db.update(db.gridLevels)
        ..where((tbl) => tbl.id.equals(level.id))).write(
        GridLevelsCompanion(
          status: const Value('error'),
          lifecycleStatus: const Value('error'),
          linkedOrderId: const Value('failed_zero_fill_long_close'),
          activeOrderId: const Value(null),
          lastBuyOrderId: const Value('filled_long_buy_before_failed_close'),
          lastSellOrderId: const Value('failed_zero_fill_long_close'),
          updatedAt: Value(now),
        ),
      );

      final report = await service.reconcileFuturesLongGrid(
        strategyId,
        refreshFirst: false,
        validateMissingOpenOrders: false,
      );

      final refreshed =
          await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(level.id))).getSingle();
      expect(report.errorOrders, 0);
      expect(report.errorDetails, isEmpty);
      expect(refreshed.lifecycleStatus, 'buyFilled');
      expect(refreshed.status, 'buyFilled');
      expect(refreshed.linkedOrderId, 'filled_long_buy_before_failed_close');
      expect(refreshed.lastBuyOrderId, 'filled_long_buy_before_failed_close');
      expect(refreshed.lastSellOrderId, equals(null));
    },
  );

  test(
    'futures long close repairs level when reduce only orders occupy quantity',
    () async {
      final strategyId = await service.createDefaultStrategy(
        executionMode: LiveSpotGridEditableConfig.futuresGridHedge,
      );
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 8, 24, 22);
      liveExecution.currentLongQuantity = Decimal.parse('0.02');
      await _insertGridOrder(
        db,
        id: 'filled_long_buy_before_occupied_close',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'filled',
        clientOrderId: 'GH_LONG_GRID_FUTURES_filled_buy_before_occupied_close',
        createdAt: now,
        completedAt: now.add(const Duration(seconds: 1)),
        executedQuantity: '0.02',
        averagePrice: level.buyPrice ?? level.price,
        price: level.buyPrice,
        source: AutoSpotGridExecutionService.futuresLongSource,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: 'futuresLongGridBuy',
        positionSide: 'LONG',
      );
      await _insertGridOrder(
        db,
        id: 'failed_occupied_long_close',
        strategyId: strategyId,
        gridId: level.id,
        side: 'SELL',
        status: 'failed',
        clientOrderId: 'GH_LONG_GRID_FUTURES_failed_occupied_close',
        createdAt: now.add(const Duration(seconds: 2)),
        price: level.sellPrice,
        source: AutoSpotGridExecutionService.futuresLongSource,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: 'futuresLongGridSell',
        positionSide: 'LONG',
        reduceOnly: true,
      );
      await db
          .into(db.exchangeOpenOrders)
          .insert(
            ExchangeOpenOrdersCompanion.insert(
              id: 'occupied_reduce_only_sell',
              accountType: 'futuresSubAccount',
              marketType: 'usdtFutures',
              environment: 'live',
              symbol: 'BTCUSDT',
              exchangeOrderId: '2801',
              clientOrderId: 'existing_reduce_only_sell',
              side: 'SELL',
              positionSide: const Value('LONG'),
              orderType: 'LIMIT',
              price: level.sellPrice ?? level.price,
              originalQuantity: '0.02',
              executedQuantity: '0',
              status: 'new',
              reduceOnly: const Value(true),
              createdAt: now,
              updatedAt: now,
              syncedAt: now,
            ),
          );
      await (db.update(db.gridLevels)
        ..where((tbl) => tbl.id.equals(level.id))).write(
        GridLevelsCompanion(
          status: const Value('error'),
          lifecycleStatus: const Value('error'),
          linkedOrderId: const Value('failed_occupied_long_close'),
          activeOrderId: const Value(null),
          lastBuyOrderId: const Value('filled_long_buy_before_occupied_close'),
          lastSellOrderId: const Value('failed_occupied_long_close'),
          updatedAt: Value(now),
        ),
      );

      await expectLater(
        service.submitFuturesLongCloseGridLevel(level.id),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('未继续提交新的平多单'),
          ),
        ),
      );

      final refreshed =
          await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(level.id))).getSingle();
      expect(liveExecution.futuresLimitOrderAttempts, 0);
      expect(refreshed.lifecycleStatus, 'buyFilled');
      expect(refreshed.status, 'buyFilled');
      expect(refreshed.linkedOrderId, 'filled_long_buy_before_occupied_close');
      expect(refreshed.lastBuyOrderId, 'filled_long_buy_before_occupied_close');
      expect(refreshed.lastSellOrderId, equals(null));
    },
  );

  test(
    'futures long reconcile restores filled buy with stale released error',
    () async {
      final strategyId = await service.createDefaultStrategy(
        executionMode: LiveSpotGridEditableConfig.futuresGridHedge,
      );
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 8, 24, 11);
      await _insertGridOrder(
        db,
        id: 'stale_released_buy_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'expired',
        clientOrderId: 'GH_LONG_GRID_FUTURES_stale_buy_1',
        createdAt: now,
        source: AutoSpotGridExecutionService.futuresLongSource,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: 'futuresLongGridBuy',
        positionSide: 'LONG',
      );
      await (db.update(db.orders)
        ..where((tbl) => tbl.id.equals('stale_released_buy_1'))).write(
        const OrdersCompanion(
          errorMessage: Value('Binance 当前挂单和历史订单均无有效活动状态，已释放本地网格。'),
        ),
      );
      await (db.update(db.gridLevels)
        ..where((tbl) => tbl.id.equals(level.id))).write(
        GridLevelsCompanion(
          status: const Value('error'),
          lifecycleStatus: const Value('error'),
          linkedOrderId: const Value('stale_released_buy_1'),
          activeOrderId: const Value('stale_released_buy_1'),
          updatedAt: Value(now),
        ),
      );
      await _insertExchangeHistoricalOrder(
        db,
        id: 'hist_stale_released_buy_1',
        symbol: 'BTCUSDT',
        exchangeOrderId: '2401',
        clientOrderId: 'GH_LONG_GRID_FUTURES_stale_buy_1',
        side: 'BUY',
        positionSide: 'LONG',
        status: 'FILLED',
        price: level.buyPrice ?? level.price,
        originalQuantity: '0.02',
        executedQuantity: '0.02',
        averagePrice: level.buyPrice ?? level.price,
        createdAt: now,
        updatedAt: now.add(const Duration(seconds: 1)),
      );
      liveExecution.currentLongQuantity = Decimal.parse('0.02');

      await service.reconcileFuturesLongGrid(
        strategyId,
        refreshFirst: false,
        validateMissingOpenOrders: false,
      );

      final refreshed =
          await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(level.id))).getSingle();
      final order =
          await (db.select(
            db.orders,
          )..where((tbl) => tbl.id.equals('stale_released_buy_1'))).getSingle();
      expect(order.status, 'filled');
      expect(order.errorMessage, equals(null));
      expect(refreshed.lifecycleStatus, 'buyFilled');
      expect(refreshed.status, 'buyFilled');
      expect(refreshed.linkedOrderId, 'stale_released_buy_1');
      expect(refreshed.lastBuyOrderId, 'stale_released_buy_1');
    },
  );

  test(
    'repair futures long grid level releases filled buy when Binance has no long position',
    () async {
      final strategyId = await service.createDefaultStrategy(
        executionMode: LiveSpotGridEditableConfig.futuresGridHedge,
      );
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 8, 25, 10);
      await _insertGridOrder(
        db,
        id: 'filled_buy_without_position',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'failed',
        clientOrderId: 'GH_LONG_GRID_FUTURES_no_position_buy',
        createdAt: now,
        source: AutoSpotGridExecutionService.futuresLongSource,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: 'futuresLongGridBuy',
        positionSide: 'LONG',
      );
      await (db.update(db.gridLevels)
        ..where((tbl) => tbl.id.equals(level.id))).write(
        GridLevelsCompanion(
          status: const Value('error'),
          lifecycleStatus: const Value('error'),
          linkedOrderId: const Value('filled_buy_without_position'),
          activeOrderId: const Value('filled_buy_without_position'),
          updatedAt: Value(now),
        ),
      );
      await _insertExchangeHistoricalOrder(
        db,
        id: 'hist_filled_buy_without_position',
        symbol: 'BTCUSDT',
        exchangeOrderId: '2501',
        clientOrderId: 'GH_LONG_GRID_FUTURES_no_position_buy',
        side: 'BUY',
        positionSide: 'LONG',
        status: 'FILLED',
        price: level.buyPrice ?? level.price,
        originalQuantity: '0.02',
        executedQuantity: '0.02',
        averagePrice: level.buyPrice ?? level.price,
        createdAt: now,
        updatedAt: now.add(const Duration(seconds: 1)),
      );
      liveExecution.currentLongQuantity = Decimal.zero;

      final repaired = await service.repairFuturesLongGridLevel(level.id);
      await service.reconcileFuturesLongGrid(
        strategyId,
        refreshFirst: false,
        validateMissingOpenOrders: false,
      );

      final refreshed =
          await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(level.id))).getSingle();
      final order =
          await (db.select(db.orders)..where(
            (tbl) => tbl.id.equals('filled_buy_without_position'),
          )).getSingle();
      expect(repaired, isTrue);
      expect(order.status, 'filled');
      expect(
        order.errorMessage,
        AutoSpotGridExecutionService.noPositionReleasedFuturesLongBuyMessage,
      );
      expect(refreshed.lifecycleStatus, 'waitingBuy');
      expect(refreshed.status, 'waitingBuy');
      expect(refreshed.linkedOrderId, equals(null));
      expect(refreshed.activeOrderId, equals(null));
      expect(refreshed.lastBuyOrderId, equals(null));
    },
  );

  test('renew futures long grid level releases old filled buy', () async {
    final strategyId = await service.createDefaultStrategy(
      executionMode: LiveSpotGridEditableConfig.futuresGridHedge,
    );
    final level = (await service.watchGridLevels(strategyId).first).first;
    final now = DateTime.utc(2026, 8, 25, 11);
    await _insertGridOrder(
      db,
      id: 'renew_old_buy_1',
      strategyId: strategyId,
      gridId: level.id,
      side: 'BUY',
      status: 'filled',
      clientOrderId: 'GH_LONG_GRID_FUTURES_renew_old_buy_1',
      createdAt: now,
      completedAt: now,
      executedQuantity: '0.02',
      averagePrice: level.buyPrice ?? level.price,
      source: AutoSpotGridExecutionService.futuresLongSource,
      accountType: 'futuresSubAccount',
      marketType: 'usdtFutures',
      purpose: 'futuresLongGridBuy',
      positionSide: 'LONG',
    );
    await (db.update(db.gridLevels)
      ..where((tbl) => tbl.id.equals(level.id))).write(
      GridLevelsCompanion(
        status: const Value('buyFilled'),
        lifecycleStatus: const Value('buyFilled'),
        linkedOrderId: const Value('renew_old_buy_1'),
        lastBuyOrderId: const Value('renew_old_buy_1'),
        updatedAt: Value(now),
      ),
    );

    await service.renewFuturesLongGridLevel(level.id);
    await service.reconcileFuturesLongGrid(
      strategyId,
      refreshFirst: false,
      validateMissingOpenOrders: false,
    );

    final refreshed =
        await (db.select(db.gridLevels)
          ..where((tbl) => tbl.id.equals(level.id))).getSingle();
    final order =
        await (db.select(db.orders)
          ..where((tbl) => tbl.id.equals('renew_old_buy_1'))).getSingle();
    expect(order.status, 'filled');
    expect(
      order.errorMessage,
      AutoSpotGridExecutionService.noPositionReleasedFuturesLongBuyMessage,
    );
    expect(refreshed.lifecycleStatus, 'waitingBuy');
    expect(refreshed.status, 'waitingBuy');
    expect(refreshed.lastBuyOrderId, equals(null));
  });

  test(
    'cancel futures long grid level releases local order when Binance returns unknown order',
    () async {
      final strategyId = await service.createDefaultStrategy(
        executionMode: LiveSpotGridEditableConfig.futuresGridHedge,
      );
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 8, 25, 12);
      await _insertGridOrder(
        db,
        id: 'cancel_unknown_order_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'new',
        clientOrderId: 'GH_LONG_GRID_FUTURES_cancel_unknown_1',
        createdAt: now,
        source: AutoSpotGridExecutionService.futuresLongSource,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: 'futuresLongGridBuy',
        positionSide: 'LONG',
      );
      await (db.update(db.gridLevels)
        ..where((tbl) => tbl.id.equals(level.id))).write(
        GridLevelsCompanion(
          status: const Value('buyOpen'),
          lifecycleStatus: const Value('buyOpen'),
          linkedOrderId: const Value('cancel_unknown_order_1'),
          activeOrderId: const Value('cancel_unknown_order_1'),
          updatedAt: Value(now),
        ),
      );
      liveExecution.cancelFuturesOrderError = const BinanceRequestException(
        type: BinanceRequestExceptionType.unknown,
        statusCode: 400,
        binanceCode: -2011,
        message: 'Unknown order sent.',
      );

      final cancelled = await service.cancelFuturesLongGridLevelOpenOrders(
        level.id,
      );

      final refreshed =
          await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(level.id))).getSingle();
      final order =
          await (db.select(db.orders)..where(
            (tbl) => tbl.id.equals('cancel_unknown_order_1'),
          )).getSingle();
      expect(cancelled, 1);
      expect(order.status, 'cancelled');
      expect(refreshed.lifecycleStatus, 'waitingBuy');
      expect(refreshed.activeOrderId, equals(null));
    },
  );

  test(
    'renew futures long grid level releases zero fill active local residue',
    () async {
      final strategyId = await service.createDefaultStrategy(
        executionMode: LiveSpotGridEditableConfig.futuresGridHedge,
      );
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 8, 25, 12, 30);
      await _insertGridOrder(
        db,
        id: 'renew_active_residue_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'new',
        clientOrderId: 'GH_LONG_GRID_FUTURES_renew_active_residue_1',
        createdAt: now,
        source: AutoSpotGridExecutionService.futuresLongSource,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: 'futuresLongGridBuy',
        positionSide: 'LONG',
      );
      await (db.update(db.gridLevels)
        ..where((tbl) => tbl.id.equals(level.id))).write(
        GridLevelsCompanion(
          status: const Value('buyOpen'),
          lifecycleStatus: const Value('buyOpen'),
          linkedOrderId: const Value('renew_active_residue_1'),
          activeOrderId: const Value('renew_active_residue_1'),
          updatedAt: Value(now),
        ),
      );

      await service.renewFuturesLongGridLevel(level.id);

      final refreshed =
          await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(level.id))).getSingle();
      final order =
          await (db.select(db.orders)..where(
            (tbl) => tbl.id.equals('renew_active_residue_1'),
          )).getSingle();
      expect(order.status, 'cancelled');
      expect(refreshed.lifecycleStatus, 'waitingBuy');
      expect(refreshed.activeOrderId, equals(null));
    },
  );

  test(
    'repair futures long grid level syncs local error from Binance history',
    () async {
      final strategyId = await service.createDefaultStrategy(
        executionMode: LiveSpotGridEditableConfig.futuresGridHedge,
      );
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 8, 24, 13);
      await _insertGridOrder(
        db,
        id: 'error_buy_history_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'failed',
        clientOrderId: 'GH_LONG_GRID_FUTURES_history_buy_1',
        createdAt: now,
        source: AutoSpotGridExecutionService.futuresLongSource,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: 'futuresLongGridBuy',
        positionSide: 'LONG',
      );
      await (db.update(db.orders)..where(
        (tbl) => tbl.id.equals('error_buy_history_1'),
      )).write(const OrdersCompanion(errorMessage: Value('本地下单失败')));
      await (db.update(db.gridLevels)
        ..where((tbl) => tbl.id.equals(level.id))).write(
        GridLevelsCompanion(
          status: const Value('error'),
          lifecycleStatus: const Value('error'),
          linkedOrderId: const Value('error_buy_history_1'),
          activeOrderId: const Value('error_buy_history_1'),
          updatedAt: Value(now),
        ),
      );
      await _insertExchangeHistoricalOrder(
        db,
        id: 'hist_error_buy_history_1',
        symbol: 'BTCUSDT',
        exchangeOrderId: '2402',
        clientOrderId: 'GH_LONG_GRID_FUTURES_history_buy_1',
        side: 'BUY',
        positionSide: 'LONG',
        status: 'FILLED',
        price: level.buyPrice ?? level.price,
        originalQuantity: '0.02',
        executedQuantity: '0.02',
        averagePrice: level.buyPrice ?? level.price,
        createdAt: now,
        updatedAt: now.add(const Duration(seconds: 1)),
      );
      liveExecution.currentLongQuantity = Decimal.parse('0.02');

      final repaired = await service.repairFuturesLongGridLevel(level.id);

      final refreshed =
          await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(level.id))).getSingle();
      final order =
          await (db.select(db.orders)
            ..where((tbl) => tbl.id.equals('error_buy_history_1'))).getSingle();
      expect(repaired, isTrue);
      expect(order.status, 'filled');
      expect(order.errorMessage, equals(null));
      expect(refreshed.lifecycleStatus, 'buyFilled');
      expect(refreshed.status, 'buyFilled');
      expect(refreshed.linkedOrderId, 'error_buy_history_1');
      expect(refreshed.lastBuyOrderId, 'error_buy_history_1');
    },
  );

  test(
    'recover futures long grid clears stale strategy error after clean reconcile',
    () async {
      final strategyId = await service.createDefaultStrategy(
        executionMode: LiveSpotGridEditableConfig.futuresGridHedge,
      );
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 8, 16, 16);
      await (db.update(db.strategies)
        ..where((tbl) => tbl.id.equals(strategyId))).write(
        const StrategiesCompanion(
          status: Value('error'),
          lastError: Value('old startup error'),
        ),
      );
      await _insertGridOrder(
        db,
        id: 'released_sell_for_recover',
        strategyId: strategyId,
        gridId: level.id,
        side: 'SELL',
        status: 'expired',
        clientOrderId: 'GH_LONG_GRID_FUTURES_released_sell_recover',
        createdAt: now,
        source: AutoSpotGridExecutionService.futuresLongSource,
        accountType: 'futuresSubAccount',
        marketType: 'usdtFutures',
        purpose: 'futuresLongGridSell',
        positionSide: 'LONG',
        reduceOnly: true,
      );
      await (db.update(db.orders)
        ..where((tbl) => tbl.id.equals('released_sell_for_recover'))).write(
        const OrdersCompanion(
          errorMessage: Value('Binance 当前挂单和历史订单均无有效活动状态，已释放本地网格。'),
        ),
      );

      final report = await service.recoverAndReconcileFuturesLongGrid(
        strategyId,
        refreshFirst: false,
      );

      final strategy =
          await (db.select(db.strategies)
            ..where((tbl) => tbl.id.equals(strategyId))).getSingle();
      expect(report.restored, isTrue);
      expect(strategy.status, 'running');
      expect(strategy.lastError, equals(null));
    },
  );

  test(
    'refreshGridLifecycle ignores failed local submissions with no exchange order',
    () async {
      final strategyId = await service.createDefaultStrategy();
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 7, 10, 11, 30);
      await _insertGridOrder(
        db,
        id: 'failed_buy_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'failed',
        clientOrderId: 'GH_LIVE_GRID_SPOT_failed_buy_1',
        createdAt: now,
        executedQuantity: '0',
        price: level.buyPrice ?? level.price,
      );
      await (db.update(db.gridLevels)
        ..where((tbl) => tbl.id.equals(level.id))).write(
        GridLevelsCompanion(
          status: const Value('error'),
          lifecycleStatus: const Value('error'),
          linkedOrderId: const Value('failed_buy_1'),
          activeOrderId: const Value('failed_buy_1'),
          updatedAt: Value(now),
        ),
      );

      await service.refreshGridLifecycle(strategyId);

      final refreshed =
          await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(level.id))).getSingle();
      final failedOrder =
          await (db.select(db.orders)
            ..where((tbl) => tbl.id.equals('failed_buy_1'))).getSingle();
      expect(refreshed.lifecycleStatus, 'waitingBuy');
      expect(refreshed.status, 'waitingBuy');
      expect(refreshed.activeOrderId, equals(null));
      expect(refreshed.linkedOrderId, equals(null));
      expect(failedOrder.status, 'failed');
    },
  );

  test(
    'refreshGridLifecycle returns failed replacement sell to buyFilled',
    () async {
      final strategyId = await service.createDefaultStrategy();
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 7, 10, 11, 45);
      await _insertGridOrder(
        db,
        id: 'buy_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'filled',
        clientOrderId: 'GH_LIVE_GRID_SPOT_buy_1',
        createdAt: now,
        completedAt: now.add(const Duration(seconds: 1)),
        executedQuantity: '0.0158',
        averagePrice: level.buyPrice ?? level.price,
      );
      await _insertGridOrder(
        db,
        id: 'failed_sell_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'SELL',
        status: 'failed',
        clientOrderId: 'GH_LIVE_GRID_SPOT_failed_sell_1',
        parentOrderId: 'buy_1',
        createdAt: now.add(const Duration(seconds: 2)),
        executedQuantity: '0',
        price: level.sellPrice ?? level.nextUpperPrice ?? level.price,
      );
      await (db.update(db.gridLevels)
        ..where((tbl) => tbl.id.equals(level.id))).write(
        GridLevelsCompanion(
          status: const Value('error'),
          lifecycleStatus: const Value('error'),
          linkedOrderId: const Value('failed_sell_1'),
          activeOrderId: const Value('failed_sell_1'),
          lastBuyOrderId: const Value('buy_1'),
          lastSellOrderId: const Value('failed_sell_1'),
          updatedAt: Value(now),
        ),
      );

      await service.refreshGridLifecycle(strategyId);

      final refreshed =
          await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(level.id))).getSingle();
      final failedOrder =
          await (db.select(db.orders)
            ..where((tbl) => tbl.id.equals('failed_sell_1'))).getSingle();
      expect(refreshed.lifecycleStatus, 'buyFilled');
      expect(refreshed.status, 'buyFilled');
      expect(refreshed.activeOrderId, equals(null));
      expect(refreshed.linkedOrderId, 'buy_1');
      expect(refreshed.lastBuyOrderId, 'buy_1');
      expect(refreshed.lastSellOrderId, equals(null));
      expect(failedOrder.status, 'failed');
    },
  );

  test(
    'refreshGridLifecycle repairs unknown local rejected replacement sell',
    () async {
      final strategyId = await service.createDefaultStrategy();
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 7, 16, 12, 10);
      await _insertGridOrder(
        db,
        id: 'buy_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'filled',
        clientOrderId: 'GH_LIVE_GRID_SPOT_buy_1',
        createdAt: now,
        completedAt: now.add(const Duration(seconds: 1)),
        executedQuantity: '0.0158',
        averagePrice: level.buyPrice ?? level.price,
      );
      await _insertGridOrder(
        db,
        id: 'unknown_rejected_sell_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'SELL',
        status: 'unknown',
        clientOrderId: 'GH_LIVE_GRID_SPOT_unknown_rejected_sell_1',
        parentOrderId: 'buy_1',
        createdAt: now.add(const Duration(seconds: 2)),
        executedQuantity: '0',
        price: level.sellPrice ?? level.nextUpperPrice ?? level.price,
      );
      await (db.update(db.orders)
        ..where((tbl) => tbl.id.equals('unknown_rejected_sell_1'))).write(
        const OrdersCompanion(
          errorCode: Value('-2010'),
          errorMessage: Value(
            'Account has insufficient balance for requested action.',
          ),
        ),
      );
      await (db.update(db.gridLevels)
        ..where((tbl) => tbl.id.equals(level.id))).write(
        GridLevelsCompanion(
          status: const Value('error'),
          lifecycleStatus: const Value('error'),
          linkedOrderId: const Value('unknown_rejected_sell_1'),
          activeOrderId: const Value('unknown_rejected_sell_1'),
          lastBuyOrderId: const Value('buy_1'),
          lastSellOrderId: const Value('unknown_rejected_sell_1'),
          updatedAt: Value(now),
        ),
      );

      await service.refreshGridLifecycle(strategyId);

      final refreshed =
          await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(level.id))).getSingle();
      final repairedOrder =
          await (db.select(db.orders)..where(
            (tbl) => tbl.id.equals('unknown_rejected_sell_1'),
          )).getSingle();
      expect(repairedOrder.status, 'failed');
      expect(refreshed.lifecycleStatus, 'buyFilled');
      expect(refreshed.status, 'buyFilled');
      expect(refreshed.activeOrderId, equals(null));
      expect(refreshed.linkedOrderId, 'buy_1');
      expect(refreshed.lastBuyOrderId, 'buy_1');
      expect(refreshed.lastSellOrderId, equals(null));
    },
  );

  test(
    'refreshGridLifecycle repairs unknown local order missing on exchange',
    () async {
      final strategyId = await service.createDefaultStrategy();
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 7, 17, 10);
      await _insertGridOrder(
        db,
        id: 'missing_buy_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'unknown',
        clientOrderId: 'GH_LIVE_GRID_SPOT_missing_buy_1',
        createdAt: now,
        executedQuantity: '0',
        price: level.buyPrice ?? level.price,
      );
      await (db.update(db.orders)
        ..where((tbl) => tbl.id.equals('missing_buy_1'))).write(
        const OrdersCompanion(
          errorCode: Value('-2013'),
          errorMessage: Value('Order does not exist.'),
        ),
      );
      await (db.update(db.gridLevels)
        ..where((tbl) => tbl.id.equals(level.id))).write(
        GridLevelsCompanion(
          status: const Value('error'),
          lifecycleStatus: const Value('error'),
          linkedOrderId: const Value('missing_buy_1'),
          activeOrderId: const Value('missing_buy_1'),
          updatedAt: Value(now),
        ),
      );

      await service.refreshGridLifecycle(strategyId);

      final refreshed =
          await (db.select(db.gridLevels)
            ..where((tbl) => tbl.id.equals(level.id))).getSingle();
      final repairedOrder =
          await (db.select(db.orders)
            ..where((tbl) => tbl.id.equals('missing_buy_1'))).getSingle();
      expect(repairedOrder.status, 'failed');
      expect(refreshed.lifecycleStatus, 'waitingBuy');
      expect(refreshed.activeOrderId, equals(null));
      expect(refreshed.linkedOrderId, equals(null));
    },
  );

  test(
    'replacement sell quantity is capped by available base balance',
    () async {
      final strategyId = await service.createDefaultStrategy(symbol: 'ETHUSDT');
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 7, 21, 10);
      await _insertAccountAsset(
        db,
        asset: 'ETH',
        free: '0.0106859',
        locked: '0',
        updatedAt: now,
      );
      await _insertGridOrder(
        db,
        id: 'eth_buy_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'filled',
        clientOrderId: 'GH_LIVE_GRID_SPOT_eth_buy_1',
        createdAt: now,
        completedAt: now.add(const Duration(seconds: 1)),
        executedQuantity: '0.0107',
        averagePrice: level.buyPrice ?? level.price,
        symbol: 'ETHUSDT',
        price: level.buyPrice ?? level.price,
      );

      final preview = await service.previewReplacementOrder('eth_buy_1');

      expect(preview.replacementSide, 'SELL');
      expect(preview.replacementQuantity.toString(), '0.0106');
      expect(
        preview.notional,
        preview.replacementPrice * Decimal.parse('0.0106'),
      );
    },
  );

  test(
    'filled sell does not treat previous filled buy as next replacement buy',
    () async {
      final strategyId = await service.createDefaultStrategy(symbol: 'ETHUSDT');
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 7, 21, 11);
      await _insertGridOrder(
        db,
        id: 'eth_buy_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'filled',
        clientOrderId: 'GH_LIVE_GRID_SPOT_eth_buy_1',
        createdAt: now,
        completedAt: now.add(const Duration(seconds: 1)),
        executedQuantity: '0.0107',
        averagePrice: level.buyPrice ?? level.price,
        symbol: 'ETHUSDT',
        price: level.buyPrice ?? level.price,
      );
      await _insertGridOrder(
        db,
        id: 'eth_sell_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'SELL',
        status: 'filled',
        clientOrderId: 'GH_LIVE_GRID_SPOT_eth_sell_1',
        parentOrderId: 'eth_buy_1',
        createdAt: now.add(const Duration(seconds: 2)),
        completedAt: now.add(const Duration(seconds: 3)),
        executedQuantity: '0.0107',
        averagePrice: level.sellPrice ?? level.nextUpperPrice ?? level.price,
        symbol: 'ETHUSDT',
        price: level.sellPrice ?? level.nextUpperPrice ?? level.price,
      );

      final preview = await service.previewReplacementOrder('eth_sell_1');

      expect(preview.replacementSide, 'BUY');
      expect(preview.existingReplacementOrderId, equals(null));
      expect(preview.canSubmit, isTrue);
    },
  );

  test(
    'rebuilds completed grid cycles and PnL reads realized profit',
    () async {
      final strategyId = await service.createDefaultStrategy();
      final level = (await service.watchGridLevels(strategyId).first).first;
      final now = DateTime.utc(2026, 7, 10, 12);
      await _insertGridOrder(
        db,
        id: 'buy_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'BUY',
        status: 'filled',
        clientOrderId: 'GH_LIVE_GRID_SPOT_buy_1',
        createdAt: now,
        completedAt: now.add(const Duration(seconds: 1)),
        executedQuantity: '0.0001',
        averagePrice: '80000',
      );
      await _insertGridOrder(
        db,
        id: 'sell_1',
        strategyId: strategyId,
        gridId: level.id,
        side: 'SELL',
        status: 'filled',
        clientOrderId: 'GH_LIVE_GRID_SPOT_sell_1',
        parentOrderId: 'buy_1',
        createdAt: now.add(const Duration(seconds: 2)),
        completedAt: now.add(const Duration(seconds: 3)),
        executedQuantity: '0.0001',
        averagePrice: '82000',
      );
      await _insertFill(
        db,
        id: 'fill_buy_1',
        strategyId: strategyId,
        orderId: 'buy_1',
        side: 'BUY',
        price: '80000',
        quantity: '0.0001',
        quoteQuantity: '8',
        commission: '0.01',
        tradeTime: now.add(const Duration(seconds: 1)),
      );
      await _insertFill(
        db,
        id: 'fill_sell_1',
        strategyId: strategyId,
        orderId: 'sell_1',
        side: 'SELL',
        price: '82000',
        quantity: '0.0001',
        quoteQuantity: '8.2',
        commission: '0.01',
        tradeTime: now.add(const Duration(seconds: 3)),
      );

      final cycleService = CompletedGridCycleService(db);
      final report = await cycleService.rebuildForStrategy(strategyId);
      final secondReport = await cycleService.rebuildForStrategy(strategyId);
      final cycles = await db.select(db.completedGridCycles).get();
      final pnl = await StrategyPerformanceService(
        db,
        marketData,
      ).calculate(strategyId);

      expect(report.insertedCycles, 1);
      expect(secondReport.insertedCycles, 0);
      expect(cycles, hasLength(1));
      expect(cycles.single.netPnl, '0.18');
      expect(pnl.completedGridCycles, 1);
      expect(pnl.spotGridRealizedPnl.toString(), '0.18');
      expect(pnl.periods.last.pnl.toString(), '0.18');
    },
  );

  test('PnL uses the current symbol futures profile scope', () async {
    final now = DateTime.utc(2026, 7, 10, 12);
    await _insertStrategy(db, id: 'btc_strategy', symbol: 'BTCUSDT');
    await db
        .into(db.symbolAccountBindings)
        .insert(
          SymbolAccountBindingsCompanion.insert(
            id: 'btc_binding',
            symbol: 'BTCUSDT',
            environment: 'live',
            futuresKeyProfileId: const Value('btc_profile'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.hedgeActions)
        .insert(
          HedgeActionsCompanion.insert(
            id: 'btc_hedge',
            strategyId: 'btc_strategy',
            actionType: 'openShort',
            symbol: 'BTCUSDT',
            side: 'SELL',
            quantity: '0.001',
            dryRun: const Value(false),
            status: 'filled',
            keyProfileId: const Value('btc_profile'),
            accountBindingId: const Value('btc_binding'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    for (final trade in [
      ExchangeTradesCompanion.insert(
        id: 'btc_trade',
        accountType: 'futuresSubAccount',
        keyProfileId: const Value('btc_profile'),
        accountBindingId: const Value('btc_binding'),
        marketType: 'usdtFutures',
        environment: 'live',
        symbol: 'BTCUSDT',
        exchangeTradeId: 'btc_trade',
        side: 'SELL',
        price: '60000',
        quantity: '0.001',
        quoteQuantity: '60',
        commission: '0.1',
        commissionAsset: 'USDT',
        realizedPnl: const Value('5'),
        tradeTime: now,
        syncedAt: now,
      ),
      ExchangeTradesCompanion.insert(
        id: 'wrong_profile_trade',
        accountType: 'futuresSubAccount',
        keyProfileId: const Value('other_profile'),
        accountBindingId: const Value('other_binding'),
        marketType: 'usdtFutures',
        environment: 'live',
        symbol: 'BTCUSDT',
        exchangeTradeId: 'wrong_profile_trade',
        side: 'SELL',
        price: '60000',
        quantity: '0.001',
        quoteQuantity: '60',
        commission: '9',
        commissionAsset: 'USDT',
        realizedPnl: const Value('20'),
        tradeTime: now,
        syncedAt: now,
      ),
    ]) {
      await db.into(db.exchangeTrades).insert(trade);
    }
    for (final funding in [
      FundingFeeRecordsCompanion.insert(
        id: 'btc_funding',
        accountType: const Value('futuresSubAccount'),
        keyProfileId: const Value('btc_profile'),
        accountBindingId: const Value('btc_binding'),
        symbol: 'BTCUSDT',
        income: '0.5',
        asset: 'USDT',
        incomeTime: now,
        syncedAt: now,
      ),
      FundingFeeRecordsCompanion.insert(
        id: 'wrong_profile_funding',
        accountType: const Value('futuresSubAccount'),
        keyProfileId: const Value('other_profile'),
        accountBindingId: const Value('other_binding'),
        symbol: 'BTCUSDT',
        income: '10',
        asset: 'USDT',
        incomeTime: now.add(const Duration(seconds: 1)),
        syncedAt: now,
      ),
    ]) {
      await db.into(db.fundingFeeRecords).insert(funding);
    }
    for (final snapshot in [
      FuturesAccountSnapshotsCompanion.insert(
        id: 'btc_snapshot',
        keyProfileId: const Value('btc_profile'),
        accountBindingId: const Value('btc_binding'),
        walletBalance: '100',
        availableBalance: '80',
        totalUnrealizedPnl: '3',
        markPrice: const Value('60000'),
        recordedAt: now,
      ),
      FuturesAccountSnapshotsCompanion.insert(
        id: 'wrong_profile_snapshot',
        keyProfileId: const Value('other_profile'),
        accountBindingId: const Value('other_binding'),
        walletBalance: '999',
        availableBalance: '999',
        totalUnrealizedPnl: '999',
        markPrice: const Value('70000'),
        recordedAt: now.add(const Duration(seconds: 1)),
      ),
    ]) {
      await db.into(db.futuresAccountSnapshots).insert(snapshot);
    }

    final pnl = await StrategyPerformanceService(
      db,
      marketData,
    ).calculate('btc_strategy');

    expect(pnl.futuresRealizedPnl.toString(), '5');
    expect(pnl.futuresFees.toString(), '0.1');
    expect(pnl.fundingFee.toString(), '0.5');
    expect(pnl.futuresUnrealizedPnl.toString(), '3');
    expect(pnl.currentFuturesMargin.toString(), '100');
  });

  test('daily auto spot turnover is isolated by strategy and symbol', () async {
    final now = DateTime.now().toUtc();
    await _insertStrategy(db, id: 'btc_strategy', symbol: 'BTCUSDT');
    await _insertStrategy(db, id: 'eth_strategy', symbol: 'ETHUSDT');
    await _insertGridOrder(
      db,
      id: 'btc_filled_1',
      strategyId: 'btc_strategy',
      gridId: 'btc_grid_1',
      side: 'BUY',
      status: 'filled',
      clientOrderId: 'GH_LIVE_GRID_SPOT_btc_1',
      createdAt: now,
      completedAt: now,
      symbol: 'BTCUSDT',
      environment: 'live',
      quoteQuantity: '120',
    );
    await _insertGridOrder(
      db,
      id: 'eth_filled_1',
      strategyId: 'eth_strategy',
      gridId: 'eth_grid_1',
      side: 'BUY',
      status: 'filled',
      clientOrderId: 'GH_LIVE_GRID_SPOT_eth_1',
      createdAt: now,
      completedAt: now,
      symbol: 'ETHUSDT',
      environment: 'live',
      quoteQuantity: '40',
    );

    final btcTurnover = await liveExecution.dailyAutoSpotGridTurnover(
      strategyId: 'btc_strategy',
      symbol: 'BTCUSDT',
      now: now,
    );
    final ethTurnover = await liveExecution.dailyAutoSpotGridTurnover(
      strategyId: 'eth_strategy',
      symbol: 'ETHUSDT',
      now: now,
    );
    final ethFromBtcStrategy = await liveExecution.dailyAutoSpotGridTurnover(
      strategyId: 'btc_strategy',
      symbol: 'ETHUSDT',
      now: now,
    );

    expect(btcTurnover.toString(), '120');
    expect(ethTurnover.toString(), '40');
    expect(ethFromBtcStrategy, Decimal.zero);
  });

  test('daily auto spot turnover limit is configurable', () async {
    expect(
      (await liveExecution.autoSpotGridDailyTurnoverLimit()).toString(),
      '100',
    );

    await db
        .into(db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: LiveExchangeExecutionService.autoSpotGridDailyTurnoverLimitKey,
            value: '250',
            updatedAt: DateTime.now().toUtc(),
          ),
        );

    expect(
      (await liveExecution.autoSpotGridDailyTurnoverLimit()).toString(),
      '250',
    );
  });
}

Future<void> _insertStrategy(
  AppDatabase db, {
  required String id,
  required String symbol,
}) {
  final now = DateTime.now().toUtc();
  return db
      .into(db.strategies)
      .insert(
        StrategiesCompanion.insert(
          id: id,
          name: '$symbol strategy',
          symbol: symbol,
          environment: AutoSpotGridExecutionService.environment,
          status: 'running',
          createdAt: now,
          lowerPrice: '100',
          upperPrice: '200',
          centerPrice: '150',
          gridCount: 2,
          gridSpacingPercent: '1',
          gridMode: 'geometric',
          spotCapital: '50',
          futuresCapital: '0',
          reserveCapital: '0',
          hedgeRatio: '0',
          maxLossUsdt: '3',
          maxExposureUsdt: '50',
          updatedAt: now,
        ),
      );
}

class _TestLiveExchangeExecutionService extends LiveExchangeExecutionService {
  _TestLiveExchangeExecutionService({
    required super.db,
    required super.orderRepository,
    required super.logRepository,
    required super.credentialsVault,
    required super.marketDataCoordinator,
    required super.liveTradingGateService,
  });

  Decimal currentLongQuantity = Decimal.zero;
  int futuresLimitOrderAttempts = 0;
  Object? cancelFuturesOrderError;

  @override
  Future<void> refreshFuturesSnapshotForSymbol(
    String symbol, {
    bool includeHistory = true,
  }) async {}

  @override
  Future<Decimal> currentFuturesLongQuantity(String symbol) async {
    return currentLongQuantity;
  }

  @override
  Future<void> cancelFuturesOrder(
    String clientOrderId, {
    String symbol = 'BTCUSDT',
  }) async {
    final error = cancelFuturesOrderError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<String> placeFuturesLimitOrder({
    required String side,
    required Decimal quantity,
    required Decimal price,
    required bool reduceOnly,
    String symbol = 'BTCUSDT',
    String? positionSide,
    String? gridLevelId,
    int leverage = 1,
    String purpose = 'liveTradingVerification',
    String source = 'manualTest',
    String? strategyId,
  }) async {
    futuresLimitOrderAttempts += 1;
    throw StateError('Unexpected futures limit order attempt');
  }
}

Future<void> _insertGridOrder(
  AppDatabase db, {
  required String id,
  required String strategyId,
  required String gridId,
  required String side,
  required String status,
  required String clientOrderId,
  required DateTime createdAt,
  String? parentOrderId,
  DateTime? completedAt,
  String executedQuantity = '0',
  String? averagePrice,
  String? price,
  String symbol = 'BTCUSDT',
  String environment = 'live',
  String? quoteQuantity,
  String source = AutoSpotGridExecutionService.source,
  String accountType = 'spotSubAccount',
  String marketType = 'spot',
  String? purpose,
  String? positionSide,
  bool reduceOnly = false,
}) async {
  final existingGrid =
      await (db.select(db.gridLevels)
        ..where((tbl) => tbl.id.equals(gridId))).getSingleOrNull();
  if (existingGrid == null) {
    final existingLevels =
        await (db.select(db.gridLevels)
          ..where((tbl) => tbl.strategyId.equals(strategyId))).get();
    final gridPrice = price ?? (side == 'BUY' ? '60000' : '61000');
    await db
        .into(db.gridLevels)
        .insert(
          GridLevelsCompanion.insert(
            id: gridId,
            strategyId: strategyId,
            gridIndex: existingLevels.length,
            price: gridPrice,
            buyPrice: Value(side == 'BUY' ? gridPrice : '60000'),
            sellPrice: Value(side == 'SELL' ? gridPrice : '61000'),
            plannedSide: side,
            plannedQuantity: '0.00014',
            plannedQuoteAmount: quoteQuantity ?? '8.4',
            status: 'ready',
            lifecycleStatus: const Value('waitingBuy'),
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        );
  }

  await db
      .into(db.orders)
      .insert(
        OrdersCompanion.insert(
          id: id,
          strategyId: strategyId,
          environment: Value(environment),
          source: Value(source),
          accountType: accountType,
          marketType: marketType,
          symbol: symbol,
          clientOrderId: clientOrderId,
          side: side,
          positionSide:
              positionSide == null ? const Value.absent() : Value(positionSide),
          orderType: 'LIMIT',
          timeInForce: const Value('GTC'),
          price: Value(price ?? (side == 'BUY' ? '60000' : '61000')),
          originalQuantity: '0.00014',
          executedQuantity: Value(executedQuantity),
          averagePrice:
              averagePrice == null ? const Value.absent() : Value(averagePrice),
          quoteQuantity:
              status == 'filled'
                  ? Value(quoteQuantity ?? '8.4')
                  : const Value.absent(),
          status: status,
          purpose: purpose ?? (side == 'BUY' ? 'gridBuy' : 'gridSell'),
          gridLevelId: Value(gridId),
          parentOrderId:
              parentOrderId == null
                  ? const Value.absent()
                  : Value(parentOrderId),
          reduceOnly: Value(reduceOnly),
          createdAt: createdAt,
          updatedAt: createdAt,
          completedAt:
              completedAt == null ? const Value.absent() : Value(completedAt),
        ),
      );
}

Future<void> _insertExchangeHistoricalOrder(
  AppDatabase db, {
  required String id,
  required String symbol,
  required String exchangeOrderId,
  required String clientOrderId,
  required String side,
  required String status,
  required String price,
  required String originalQuantity,
  required String executedQuantity,
  required String averagePrice,
  required DateTime createdAt,
  required DateTime updatedAt,
  String accountType = 'futuresSubAccount',
  String marketType = 'usdtFutures',
  String environment = 'live',
  String? positionSide,
  bool? reduceOnly,
}) {
  return db
      .into(db.exchangeHistoricalOrders)
      .insert(
        ExchangeHistoricalOrdersCompanion.insert(
          id: id,
          accountType: accountType,
          marketType: marketType,
          environment: environment,
          symbol: symbol,
          exchangeOrderId: exchangeOrderId,
          clientOrderId: clientOrderId,
          side: side,
          positionSide:
              positionSide == null ? const Value.absent() : Value(positionSide),
          orderType: 'LIMIT',
          timeInForce: const Value('GTC'),
          price: price,
          originalQuantity: originalQuantity,
          executedQuantity: executedQuantity,
          averagePrice: Value(averagePrice),
          status: status,
          reduceOnly:
              reduceOnly == null ? const Value.absent() : Value(reduceOnly),
          createdAt: createdAt,
          updatedAt: updatedAt,
          syncedAt: updatedAt,
        ),
      );
}

Future<void> _insertAccountAsset(
  AppDatabase db, {
  required String asset,
  required String free,
  required String locked,
  required DateTime updatedAt,
}) {
  final freeDecimal = Decimal.parse(free);
  final lockedDecimal = Decimal.parse(locked);
  return db
      .into(db.accountAssets)
      .insertOnConflictUpdate(
        AccountAssetsCompanion.insert(
          id: 'spotSubAccount_${asset.toUpperCase()}',
          accountType: 'spotSubAccount',
          asset: asset.toUpperCase(),
          free: free,
          locked: locked,
          total: (freeDecimal + lockedDecimal).toString(),
          updatedAt: updatedAt,
        ),
      );
}

Future<void> _insertFill(
  AppDatabase db, {
  required String id,
  required String strategyId,
  required String orderId,
  required String side,
  required String price,
  required String quantity,
  required String quoteQuantity,
  required String commission,
  required DateTime tradeTime,
}) {
  return db
      .into(db.fills)
      .insert(
        FillsCompanion.insert(
          id: id,
          strategyId: strategyId,
          orderId: orderId,
          exchangeTradeId: id,
          symbol: 'BTCUSDT',
          side: side,
          price: price,
          quantity: quantity,
          quoteQuantity: quoteQuantity,
          commission: commission,
          commissionAsset: 'USDT',
          realizedPnl: const Value('0'),
          tradeTime: tradeTime,
          createdAt: tradeTime,
        ),
      );
}
