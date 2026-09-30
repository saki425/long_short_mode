import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/database/app_database.dart';
import 'package:grid_hedge_trader/services/reconciliation/account_reconciliation_service.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('creates read-only account and reconciliation tables', () async {
    final tables = await db.customSelect("select name from sqlite_master where type = 'table'").get();
    final names = tables.map((row) => row.data['name'] as String).toSet();

    expect(names, containsAll([
      'api_account_profiles',
      'account_assets',
      'spot_account_snapshots',
      'futures_account_snapshots',
      'exchange_open_orders',
      'exchange_historical_orders',
      'exchange_trades',
      'futures_positions',
      'funding_fee_records',
      'reconciliation_runs',
      'reconciliation_differences',
      'external_account_events',
    ]));
  });

  test('records unknown spot BTC as external account event', () async {
    await db.into(db.accountAssets).insert(
          AccountAssetsCompanion.insert(
            id: 'spotSubAccount-BTC',
            accountType: 'spotSubAccount',
            asset: 'BTC',
            free: '0.01',
            locked: '0',
            total: '0.01',
            updatedAt: DateTime.utc(2026, 7, 6),
          ),
        );

    final result = await AccountReconciliationService(db).runReadOnlyReconciliation();
    final externalEvents = await db.select(db.externalAccountEvents).get();

    expect(result.differences.map((item) => item.type), contains('unknownSpotBalanceChange'));
    expect(externalEvents, hasLength(1));
  });

  test('detects unexpected futures long and short positions without fixing them', () async {
    await db.into(db.futuresPositions).insert(
          FuturesPositionsCompanion.insert(
            id: 'BTCUSDT-LONG',
            symbol: 'BTCUSDT',
            positionSide: 'LONG',
            positionAmount: '0.01',
            entryPrice: '60000',
            unrealizedPnl: '0',
            updatedAt: DateTime.utc(2026, 7, 6),
          ),
        );
    await db.into(db.futuresPositions).insert(
          FuturesPositionsCompanion.insert(
            id: 'BTCUSDT-SHORT',
            symbol: 'BTCUSDT',
            positionSide: 'SHORT',
            positionAmount: '-0.02',
            entryPrice: '60000',
            unrealizedPnl: '0',
            updatedAt: DateTime.utc(2026, 7, 6),
          ),
        );

    final result = await AccountReconciliationService(db).runReadOnlyReconciliation();
    final types = result.differences.map((item) => item.type).toSet();

    expect(types, contains('unexpectedLongPosition'));
    expect(types, contains('unexpectedShortPosition'));
  });

  test('deduplicates exchange trades by account market and trade id', () async {
    final trade = ExchangeTradesCompanion.insert(
      id: 'spot-1',
      accountType: 'spotSubAccount',
      marketType: 'spot',
      environment: 'live',
      symbol: 'BTCUSDT',
      exchangeTradeId: '1',
      side: 'BUY',
      price: '60000',
      quantity: '0.001',
      quoteQuantity: '60',
      commission: '0.01',
      commissionAsset: 'USDT',
      tradeTime: DateTime.utc(2026, 7, 6),
      syncedAt: DateTime.utc(2026, 7, 6),
    );
    await db.into(db.exchangeTrades).insert(trade);
    await db.into(db.exchangeTrades).insert(trade.copyWith(id: const Value('spot-duplicate')), mode: InsertMode.insertOrIgnore);

    final rows = await db.select(db.exchangeTrades).get();
    expect(rows, hasLength(1));
  });
}
