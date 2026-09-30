import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/database/app_database.dart';
import 'package:grid_hedge_trader/services/binance/spot/spot_account_models.dart';
import 'package:grid_hedge_trader/services/binance/spot/spot_account_repository.dart';

void main() {
  late AppDatabase db;
  late SpotAccountRepository repository;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repository = SpotAccountRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'saveOpenOrders removes stale spot open orders after empty snapshot',
    () async {
      final now = DateTime.utc(2026, 7, 7, 12);
      await repository.saveOpenOrders([
        SpotOpenOrder(
          symbol: 'BTCUSDT',
          orderId: '1001',
          clientOrderId: 'GH_LIVE_GRID_SPOT_old',
          price: Decimal.parse('63000'),
          originalQuantity: Decimal.parse('0.0001'),
          executedQuantity: Decimal.zero,
          status: 'NEW',
          timeInForce: 'GTC',
          type: 'LIMIT',
          side: 'BUY',
          createdAt: now,
          updatedAt: now,
        ),
      ]);

      expect(await db.select(db.exchangeOpenOrders).get(), hasLength(1));

      await repository.saveOpenOrders(const [], symbol: 'BTCUSDT');

      expect(await db.select(db.exchangeOpenOrders).get(), isEmpty);
    },
  );

  test(
    'empty snapshot only removes stale orders for the specified symbol',
    () async {
      final now = DateTime.utc(2026, 7, 7, 12);
      await repository.saveOpenOrders([
        SpotOpenOrder(
          symbol: 'BTCUSDT',
          orderId: '1001',
          clientOrderId: 'GH_LIVE_GRID_SPOT_btc',
          price: Decimal.parse('63000'),
          originalQuantity: Decimal.parse('0.0001'),
          executedQuantity: Decimal.zero,
          status: 'NEW',
          timeInForce: 'GTC',
          type: 'LIMIT',
          side: 'BUY',
          createdAt: now,
          updatedAt: now,
        ),
        SpotOpenOrder(
          symbol: 'ETHUSDT',
          orderId: '2001',
          clientOrderId: 'GH_LIVE_GRID_SPOT_eth',
          price: Decimal.parse('1800'),
          originalQuantity: Decimal.parse('0.01'),
          executedQuantity: Decimal.zero,
          status: 'NEW',
          timeInForce: 'GTC',
          type: 'LIMIT',
          side: 'BUY',
          createdAt: now,
          updatedAt: now,
        ),
      ]);

      await repository.saveOpenOrders(const [], symbol: 'ETHUSDT');

      final remaining = await db.select(db.exchangeOpenOrders).get();
      expect(remaining, hasLength(1));
      expect(remaining.single.symbol, 'BTCUSDT');
    },
  );
}
