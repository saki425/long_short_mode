import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/database/app_database.dart';
import 'package:grid_hedge_trader/models/paper_strategy_config.dart';
import 'package:grid_hedge_trader/strategy/paper/paper_trading_service.dart';
import 'package:grid_hedge_trader/services/market_data/spot_book_ticker.dart';
import 'package:grid_hedge_trader/services/market_data/futures_mark_price.dart';

void main() {
  late AppDatabase db;
  late PaperTradingService paper;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    paper = PaperTradingService(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('creates strategy grid and planned orders', () async {
    final strategyId = await paper.createStrategy(PaperStrategyConfig.defaults(centerPrice: Decimal.fromInt(60000)));

    final strategy = await _strategy(db, strategyId);
    final levels = await (db.select(db.gridLevels)..where((tbl) => tbl.strategyId.equals(strategyId))).get();
    final orders = await (db.select(db.orders)..where((tbl) => tbl.strategyId.equals(strategyId))).get();

    expect(strategy?.status, 'idle');
    expect(levels, hasLength(13));
    expect(orders, hasLength(13));
    expect(orders.every((order) => order.status == 'planned'), isTrue);
  });

  test('starts paper and only submits buy orders without spot inventory', () async {
    final strategyId = await paper.createStrategy(PaperStrategyConfig.defaults(centerPrice: Decimal.fromInt(60000)));
    await paper.start(strategyId);

    final orders = await (db.select(db.orders)..where((tbl) => tbl.strategyId.equals(strategyId))).get();
    final newSells = orders.where((order) => order.side == 'SELL' && order.status == 'new');
    final newBuys = orders.where((order) => order.side == 'BUY' && order.status == 'new');

    expect(newBuys, isNotEmpty);
    expect(newSells, isEmpty);
  });

  test('price touch fills buy creates reverse sell and updates strategy spot btc', () async {
    final strategyId = await paper.createStrategy(PaperStrategyConfig.defaults(centerPrice: Decimal.fromInt(60000)));
    await paper.start(strategyId);
    final buy = await _firstNewBuy(db, strategyId);

    await paper.setManualPrice(strategyId, Decimal.parse(buy.price!));

    final filled = await (db.select(db.orders)..where((tbl) => tbl.id.equals(buy.id))).getSingle();
    final strategy = await _strategy(db, strategyId);
    final reverse = await (db.select(db.orders)
          ..where((tbl) => tbl.parentOrderId.equals(buy.id) & tbl.side.equals('SELL')))
        .getSingleOrNull();
    final fills = await (db.select(db.fills)..where((tbl) => tbl.orderId.equals(buy.id))).get();

    expect(filled.status, 'filled');
    expect(strategy?.strategySpotBtc, isNot('0'));
    expect(reverse?.status, 'planned');
    expect(fills, hasLength(1));
  });

  test('two filled buys trigger simulated hedge adjustment', () async {
    final strategyId = await paper.createStrategy(PaperStrategyConfig.defaults(centerPrice: Decimal.fromInt(60000)));
    await paper.start(strategyId);
    final lowestBuy = await (db.select(db.orders)
          ..where((tbl) => tbl.strategyId.equals(strategyId) & tbl.side.equals('BUY') & tbl.status.equals('new'))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.price)])
          ..limit(1))
        .getSingle();

    await paper.setManualPrice(strategyId, Decimal.parse(lowestBuy.price!));

    final hedges = await (db.select(db.hedgeAdjustments)..where((tbl) => tbl.strategyId.equals(strategyId))).get();
    final futuresOrders = await (db.select(db.orders)
          ..where((tbl) => tbl.strategyId.equals(strategyId) & tbl.marketType.equals('usdtFutures')))
        .get();

    expect(hedges, isNotEmpty);
    expect(hedges.last.action, 'increaseShort');
    expect(futuresOrders.where((order) => order.status == 'filled'), isNotEmpty);
  });

  test('out of range price creates risk event and pauses strategy', () async {
    final strategyId = await paper.createStrategy(PaperStrategyConfig.defaults(centerPrice: Decimal.fromInt(60000)));
    await paper.start(strategyId);

    await paper.setManualPrice(strategyId, Decimal.fromInt(50000));

    final strategy = await _strategy(db, strategyId);
    final riskEvents = await (db.select(db.riskEvents)..where((tbl) => tbl.strategyId.equals(strategyId) & tbl.type.equals('outOfRange'))).get();

    expect(strategy?.status, 'paused');
    expect(riskEvents, isNotEmpty);
  });

  test('spot bookTicker buy trigger uses ask price', () async {
    final strategyId = await paper.createStrategy(PaperStrategyConfig.defaults(centerPrice: Decimal.fromInt(60000)));
    await paper.start(strategyId);
    final buy = await _firstNewBuy(db, strategyId);

    await paper.onSpotBookTicker(
      strategyId,
      SpotBookTicker(
        symbol: 'BTCUSDT',
        bidPrice: Decimal.parse(buy.price!) - Decimal.fromInt(100),
        bidQuantity: Decimal.fromInt(1),
        askPrice: Decimal.parse(buy.price!) + Decimal.fromInt(1),
        askQuantity: Decimal.fromInt(1),
        receivedAt: DateTime.now().toUtc(),
      ),
    );
    final stillNew = await (db.select(db.orders)..where((tbl) => tbl.id.equals(buy.id))).getSingle();
    expect(stillNew.status, 'new');

    await paper.onSpotBookTicker(
      strategyId,
      SpotBookTicker(
        symbol: 'BTCUSDT',
        bidPrice: Decimal.parse(buy.price!) - Decimal.fromInt(1),
        bidQuantity: Decimal.fromInt(1),
        askPrice: Decimal.parse(buy.price!),
        askQuantity: Decimal.fromInt(1),
        receivedAt: DateTime.now().toUtc(),
      ),
    );
    final filled = await (db.select(db.orders)..where((tbl) => tbl.id.equals(buy.id))).getSingle();
    expect(filled.status, 'filled');
  });

  test('futures mark price updates pnl without filling spot orders', () async {
    final strategyId = await paper.createStrategy(PaperStrategyConfig.defaults(centerPrice: Decimal.fromInt(60000)));
    await paper.start(strategyId);
    final openBefore = await (db.select(db.orders)..where((tbl) => tbl.strategyId.equals(strategyId) & tbl.status.equals('new'))).get();

    await paper.onFuturesMarkPrice(
      strategyId,
      FuturesMarkPrice(
        symbol: 'BTCUSDT',
        markPrice: Decimal.fromInt(61000),
        indexPrice: Decimal.fromInt(60990),
        estimatedSettlePrice: Decimal.fromInt(60990),
        fundingRate: Decimal.parse('0.0001'),
        nextFundingTime: DateTime.now().toUtc().add(const Duration(hours: 1)),
        eventTime: DateTime.now().toUtc(),
        receivedAt: DateTime.now().toUtc(),
      ),
    );
    final openAfter = await (db.select(db.orders)..where((tbl) => tbl.strategyId.equals(strategyId) & tbl.status.equals('new'))).get();
    final pnl = await (db.select(db.pnlSnapshots)..where((tbl) => tbl.strategyId.equals(strategyId))).get();

    expect(openAfter.length, openBefore.length);
    expect(pnl, isNotEmpty);
  });

  test('funding settlement is idempotent for same nextFundingTime', () async {
    final strategyId = await paper.createStrategy(PaperStrategyConfig.defaults(centerPrice: Decimal.fromInt(60000)));
    await paper.start(strategyId);
    final fundingTime = DateTime.now().toUtc().subtract(const Duration(seconds: 1));
    final mark = FuturesMarkPrice(
      symbol: 'BTCUSDT',
      markPrice: Decimal.fromInt(61000),
      indexPrice: Decimal.fromInt(60990),
      estimatedSettlePrice: Decimal.fromInt(60990),
      fundingRate: Decimal.parse('0.0001'),
      nextFundingTime: fundingTime,
      eventTime: DateTime.now().toUtc(),
      receivedAt: DateTime.now().toUtc(),
    );

    await paper.onFuturesMarkPrice(strategyId, mark);
    await paper.onFuturesMarkPrice(strategyId, mark);

    final rows = await (db.select(db.appSettings)
          ..where((tbl) => tbl.key.like('paper.$strategyId.fundingSettled.%')))
        .get();
    expect(rows, hasLength(1));
  });
}

Future<Strategy?> _strategy(AppDatabase db, String strategyId) {
  return (db.select(db.strategies)..where((tbl) => tbl.id.equals(strategyId))).getSingleOrNull();
}

Future<Order> _firstNewBuy(AppDatabase db, String strategyId) {
  return (db.select(db.orders)
        ..where((tbl) => tbl.strategyId.equals(strategyId) & tbl.side.equals('BUY') & tbl.status.equals('new'))
        ..orderBy([(tbl) => OrderingTerm.desc(tbl.price)])
        ..limit(1))
      .getSingle();
}
