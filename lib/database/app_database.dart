import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tables/trading_tables.dart';

part 'app_database.g.dart';

LazyDatabase openAppDatabase() {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final dbFolder = Directory(p.join(dir.path, 'grid_hedge_desktop'));
    if (!dbFolder.existsSync()) {
      dbFolder.createSync(recursive: true);
    }
    return NativeDatabase(File(p.join(dbFolder.path, 'grid_hedge.db')));
  });
}

@DriftDatabase(
  tables: [
    SymbolWorkspaces,
    Strategies,
    GridLevels,
    Orders,
    Fills,
    CompletedGridCycles,
    FutureGridOrders,
    RecoveryShortLevels,
    HedgeAdjustments,
    HedgeStates,
    HedgeActions,
    AccountSnapshots,
    PnlSnapshots,
    RiskEvents,
    MarketSnapshots,
    AppLogs,
    AppSettings,
    ApiAccountProfiles,
    ApiKeyProfiles,
    SymbolAccountBindings,
    AccountAssets,
    SpotAccountSnapshots,
    FuturesAccountSnapshots,
    ExchangeOpenOrders,
    ExchangeHistoricalOrders,
    ExchangeTrades,
    FuturesPositions,
    FundingFeeRecords,
    ReconciliationRuns,
    ReconciliationDifferences,
    ExternalAccountEvents,
    AssetClassificationEvents,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(QueryExecutor executor) : super(executor);

  factory AppDatabase.local() => AppDatabase(openAppDatabase());

  Future<int> clearAllApplicationData() async {
    var deletedRows = 0;
    await customStatement('PRAGMA foreign_keys = OFF');
    try {
      await transaction(() async {
        for (final table in allTables.toList().reversed) {
          deletedRows += await delete(table).go();
        }
      });
    } finally {
      await customStatement('PRAGMA foreign_keys = ON');
    }
    await customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    await customStatement('VACUUM');
    return deletedRows;
  }

  @override
  int get schemaVersion => 13;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (m) async => m.createAll(),
      onUpgrade: (m, from, to) async {
        if (from < 2) {
          await m.createTable(marketSnapshots);
        }
        if (from < 3) {
          await customStatement(
            "ALTER TABLE orders ADD COLUMN environment TEXT NOT NULL DEFAULT 'paper'",
          );
          await customStatement(
            "ALTER TABLE orders ADD COLUMN source TEXT NOT NULL DEFAULT 'localStrategy'",
          );
          await m.createTable(apiAccountProfiles);
          await m.createTable(accountAssets);
          await m.createTable(spotAccountSnapshots);
          await m.createTable(futuresAccountSnapshots);
          await m.createTable(exchangeOpenOrders);
          await m.createTable(exchangeHistoricalOrders);
          await m.createTable(exchangeTrades);
          await m.createTable(futuresPositions);
          await m.createTable(fundingFeeRecords);
          await m.createTable(reconciliationRuns);
          await m.createTable(reconciliationDifferences);
          await m.createTable(externalAccountEvents);
        }
        if (from < 4) {
          await m.createTable(assetClassificationEvents);
        }
        if (from < 5) {
          await customStatement(
            'ALTER TABLE grid_levels ADD COLUMN buy_price TEXT',
          );
          await customStatement(
            'ALTER TABLE grid_levels ADD COLUMN sell_price TEXT',
          );
          await customStatement(
            'ALTER TABLE grid_levels ADD COLUMN lifecycle_status TEXT',
          );
          await customStatement(
            'ALTER TABLE grid_levels ADD COLUMN active_order_id TEXT',
          );
          await customStatement(
            'ALTER TABLE grid_levels ADD COLUMN last_buy_order_id TEXT',
          );
          await customStatement(
            'ALTER TABLE grid_levels ADD COLUMN last_sell_order_id TEXT',
          );
          await customStatement(
            'ALTER TABLE grid_levels ADD COLUMN last_completed_order_id TEXT',
          );
          await customStatement(
            'ALTER TABLE grid_levels ADD COLUMN cycle_number INTEGER NOT NULL DEFAULT 0',
          );
          await customStatement("""
            UPDATE grid_levels
            SET
              buy_price = CASE
                WHEN planned_side = 'BUY' THEN price
                ELSE next_lower_price
              END,
              sell_price = CASE
                WHEN planned_side = 'BUY' THEN next_upper_price
                ELSE price
              END,
              lifecycle_status = CASE
                WHEN status IN ('submitting', 'buySubmitting') THEN 'buySubmitting'
                WHEN status IN ('open', 'buyOpen') THEN 'buyOpen'
                WHEN status IN ('filled', 'buyFilled') THEN 'buyFilled'
                WHEN status IN ('paused') THEN 'paused'
                WHEN status IN ('error') THEN 'error'
                ELSE 'waitingBuy'
              END,
              active_order_id = linked_order_id
          """);
        }
        if (from < 6) {
          await m.createTable(hedgeStates);
          await m.createTable(hedgeActions);
        }
        if (from < 7) {
          await m.createTable(completedGridCycles);
        }
        if (from < 8) {
          await m.createTable(symbolWorkspaces);
        }
        if (from < 9) {
          await m.createTable(apiKeyProfiles);
          await m.createTable(symbolAccountBindings);
          await customStatement(
            'ALTER TABLE orders ADD COLUMN key_profile_id TEXT',
          );
          await customStatement(
            'ALTER TABLE orders ADD COLUMN account_binding_id TEXT',
          );
          await customStatement(
            'ALTER TABLE hedge_actions ADD COLUMN key_profile_id TEXT',
          );
          await customStatement(
            'ALTER TABLE hedge_actions ADD COLUMN account_binding_id TEXT',
          );
        }
        if (from < 10) {
          await m.createTable(futureGridOrders);
        }
        if (from < 11) {
          for (final table in [
            'account_assets',
            'spot_account_snapshots',
            'futures_account_snapshots',
            'exchange_open_orders',
            'exchange_historical_orders',
            'exchange_trades',
            'futures_positions',
            'funding_fee_records',
          ]) {
            await customStatement(
              "ALTER TABLE $table ADD COLUMN key_profile_id TEXT NOT NULL DEFAULT 'legacy'",
            );
            await customStatement(
              'ALTER TABLE $table ADD COLUMN account_binding_id TEXT',
            );
          }
        }
        if (from < 12) {
          await _rebuildMultiAccountUniqueTables();
        }
        if (from < 13) {
          await m.createTable(recoveryShortLevels);
        }
      },
      beforeOpen: (details) async {
        await customStatement('PRAGMA foreign_keys = ON');
        await customStatement('PRAGMA journal_mode = WAL');
      },
    );
  }

  Future<void> _rebuildMultiAccountUniqueTables() async {
    await customStatement('''
      CREATE TABLE account_assets_v12 (
        id TEXT NOT NULL PRIMARY KEY,
        account_type TEXT NOT NULL,
        key_profile_id TEXT NOT NULL DEFAULT 'legacy',
        account_binding_id TEXT,
        asset TEXT NOT NULL,
        free TEXT NOT NULL,
        locked TEXT NOT NULL,
        total TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'binanceExchange',
        updated_at INTEGER NOT NULL,
        UNIQUE(account_type, key_profile_id, asset)
      )
    ''');
    await customStatement('''
      INSERT OR IGNORE INTO account_assets_v12
      SELECT id, account_type, key_profile_id, account_binding_id, asset, free,
        locked, total, source, updated_at
      FROM account_assets
      ORDER BY updated_at DESC
    ''');
    await customStatement('DROP TABLE account_assets');
    await customStatement(
      'ALTER TABLE account_assets_v12 RENAME TO account_assets',
    );

    await customStatement('''
      CREATE TABLE exchange_open_orders_v12 (
        id TEXT NOT NULL PRIMARY KEY,
        account_type TEXT NOT NULL,
        key_profile_id TEXT NOT NULL DEFAULT 'legacy',
        account_binding_id TEXT,
        market_type TEXT NOT NULL,
        environment TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'binanceExchange',
        symbol TEXT NOT NULL,
        exchange_order_id TEXT NOT NULL,
        client_order_id TEXT NOT NULL,
        side TEXT NOT NULL,
        position_side TEXT,
        order_type TEXT NOT NULL,
        time_in_force TEXT,
        price TEXT NOT NULL,
        original_quantity TEXT NOT NULL,
        executed_quantity TEXT NOT NULL,
        average_price TEXT,
        status TEXT NOT NULL,
        reduce_only INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        synced_at INTEGER NOT NULL,
        UNIQUE(account_type, key_profile_id, market_type, exchange_order_id)
      )
    ''');
    await customStatement('''
      INSERT OR IGNORE INTO exchange_open_orders_v12
      SELECT id, account_type, key_profile_id, account_binding_id, market_type,
        environment, source, symbol, exchange_order_id, client_order_id, side,
        position_side, order_type, time_in_force, price, original_quantity,
        executed_quantity, average_price, status, reduce_only, created_at,
        updated_at, synced_at
      FROM exchange_open_orders
      ORDER BY synced_at DESC
    ''');
    await customStatement('DROP TABLE exchange_open_orders');
    await customStatement(
      'ALTER TABLE exchange_open_orders_v12 RENAME TO exchange_open_orders',
    );

    await customStatement('''
      CREATE TABLE exchange_historical_orders_v12 (
        id TEXT NOT NULL PRIMARY KEY,
        account_type TEXT NOT NULL,
        key_profile_id TEXT NOT NULL DEFAULT 'legacy',
        account_binding_id TEXT,
        market_type TEXT NOT NULL,
        environment TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'binanceExchange',
        symbol TEXT NOT NULL,
        exchange_order_id TEXT NOT NULL,
        client_order_id TEXT NOT NULL,
        side TEXT NOT NULL,
        position_side TEXT,
        order_type TEXT NOT NULL,
        time_in_force TEXT,
        price TEXT NOT NULL,
        original_quantity TEXT NOT NULL,
        executed_quantity TEXT NOT NULL,
        average_price TEXT,
        quote_quantity TEXT,
        status TEXT NOT NULL,
        reduce_only INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        synced_at INTEGER NOT NULL,
        UNIQUE(account_type, key_profile_id, market_type, exchange_order_id)
      )
    ''');
    await customStatement('''
      INSERT OR IGNORE INTO exchange_historical_orders_v12
      SELECT id, account_type, key_profile_id, account_binding_id, market_type,
        environment, source, symbol, exchange_order_id, client_order_id, side,
        position_side, order_type, time_in_force, price, original_quantity,
        executed_quantity, average_price, quote_quantity, status, reduce_only,
        created_at, updated_at, synced_at
      FROM exchange_historical_orders
      ORDER BY synced_at DESC
    ''');
    await customStatement('DROP TABLE exchange_historical_orders');
    await customStatement(
      'ALTER TABLE exchange_historical_orders_v12 RENAME TO exchange_historical_orders',
    );

    await customStatement('''
      CREATE TABLE exchange_trades_v12 (
        id TEXT NOT NULL PRIMARY KEY,
        account_type TEXT NOT NULL,
        key_profile_id TEXT NOT NULL DEFAULT 'legacy',
        account_binding_id TEXT,
        market_type TEXT NOT NULL,
        environment TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'binanceExchange',
        symbol TEXT NOT NULL,
        exchange_trade_id TEXT NOT NULL,
        exchange_order_id TEXT,
        side TEXT NOT NULL,
        price TEXT NOT NULL,
        quantity TEXT NOT NULL,
        quote_quantity TEXT NOT NULL,
        commission TEXT NOT NULL,
        commission_asset TEXT NOT NULL,
        realized_pnl TEXT,
        is_maker INTEGER,
        trade_time INTEGER NOT NULL,
        synced_at INTEGER NOT NULL,
        UNIQUE(account_type, key_profile_id, market_type, exchange_trade_id)
      )
    ''');
    await customStatement('''
      INSERT OR IGNORE INTO exchange_trades_v12
      SELECT id, account_type, key_profile_id, account_binding_id, market_type,
        environment, source, symbol, exchange_trade_id, exchange_order_id, side,
        price, quantity, quote_quantity, commission, commission_asset,
        realized_pnl, is_maker, trade_time, synced_at
      FROM exchange_trades
      ORDER BY synced_at DESC
    ''');
    await customStatement('DROP TABLE exchange_trades');
    await customStatement(
      'ALTER TABLE exchange_trades_v12 RENAME TO exchange_trades',
    );

    await customStatement('''
      CREATE TABLE futures_positions_v12 (
        id TEXT NOT NULL PRIMARY KEY,
        account_type TEXT NOT NULL DEFAULT 'futuresSubAccount',
        key_profile_id TEXT NOT NULL DEFAULT 'legacy',
        account_binding_id TEXT,
        symbol TEXT NOT NULL,
        position_side TEXT NOT NULL,
        position_amount TEXT NOT NULL,
        entry_price TEXT NOT NULL,
        mark_price TEXT,
        unrealized_pnl TEXT NOT NULL,
        leverage TEXT,
        margin_type TEXT,
        liquidation_price TEXT,
        updated_at INTEGER NOT NULL,
        UNIQUE(key_profile_id, symbol, position_side)
      )
    ''');
    await customStatement('''
      INSERT OR IGNORE INTO futures_positions_v12
      SELECT id, account_type, key_profile_id, account_binding_id, symbol,
        position_side, position_amount, entry_price, mark_price,
        unrealized_pnl, leverage, margin_type, liquidation_price, updated_at
      FROM futures_positions
      ORDER BY updated_at DESC
    ''');
    await customStatement('DROP TABLE futures_positions');
    await customStatement(
      'ALTER TABLE futures_positions_v12 RENAME TO futures_positions',
    );

    await customStatement('''
      CREATE TABLE funding_fee_records_v12 (
        id TEXT NOT NULL PRIMARY KEY,
        account_type TEXT NOT NULL DEFAULT 'futuresSubAccount',
        key_profile_id TEXT NOT NULL DEFAULT 'legacy',
        account_binding_id TEXT,
        symbol TEXT NOT NULL,
        income TEXT NOT NULL,
        asset TEXT NOT NULL,
        info TEXT,
        transaction_id TEXT,
        income_time INTEGER NOT NULL,
        synced_at INTEGER NOT NULL,
        UNIQUE(account_type, key_profile_id, symbol, income_time, income)
      )
    ''');
    await customStatement('''
      INSERT OR IGNORE INTO funding_fee_records_v12
      SELECT id, account_type, key_profile_id, account_binding_id, symbol,
        income, asset, info, transaction_id, income_time, synced_at
      FROM funding_fee_records
      ORDER BY synced_at DESC
    ''');
    await customStatement('DROP TABLE funding_fee_records');
    await customStatement(
      'ALTER TABLE funding_fee_records_v12 RENAME TO funding_fee_records',
    );
  }
}
