import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import '../../../database/app_database.dart';
import 'spot_account_models.dart' as spot;

class SpotAccountRepository {
  SpotAccountRepository(this.db);

  final AppDatabase db;

  Future<void> saveSnapshot(
    spot.SpotAccountSnapshot snapshot, {
    String accountType = 'spotSubAccount',
    String? keyProfileId,
    String? accountBindingId,
  }) async {
    final now = DateTime.now().toUtc();
    final btc = snapshot.balanceOf('BTC');
    final usdt = snapshot.balanceOf('USDT');
    final previous =
        await (db.select(db.spotAccountSnapshots)
              ..orderBy([(tbl) => OrderingTerm.desc(tbl.recordedAt)])
              ..limit(1))
            .getSingleOrNull();
    final totalBtc = btc.total;
    var strategyTrackedBtc =
        previous == null
            ? Decimal.zero
            : Decimal.tryParse(previous.strategyTrackedBtc) ?? Decimal.zero;
    var externalBtc =
        previous == null
            ? Decimal.zero
            : Decimal.tryParse(previous.externalBtc) ?? Decimal.zero;
    if (strategyTrackedBtc > totalBtc) {
      strategyTrackedBtc = totalBtc;
      externalBtc = Decimal.zero;
    } else if (strategyTrackedBtc + externalBtc > totalBtc) {
      externalBtc = totalBtc - strategyTrackedBtc;
    }
    final unclassifiedBtc = totalBtc - strategyTrackedBtc - externalBtc;
    await db.transaction(() async {
      for (final balance in snapshot.balances) {
        await db
            .into(db.accountAssets)
            .insertOnConflictUpdate(
              AccountAssetsCompanion.insert(
                id: _scopedId(accountType, keyProfileId, balance.asset),
                accountType: accountType,
                keyProfileId: Value(_profileScope(keyProfileId)),
                accountBindingId: Value(accountBindingId),
                asset: balance.asset,
                free: balance.free.toString(),
                locked: balance.locked.toString(),
                total: balance.total.toString(),
                updatedAt: now,
              ),
            );
      }
      await db
          .into(db.spotAccountSnapshots)
          .insert(
            SpotAccountSnapshotsCompanion.insert(
              id: _scopedId('spot', keyProfileId, now.toIso8601String()),
              keyProfileId: Value(_profileScope(keyProfileId)),
              accountBindingId: Value(accountBindingId),
              usdtFree: usdt.free.toString(),
              usdtLocked: usdt.locked.toString(),
              btcFree: btc.free.toString(),
              btcLocked: btc.locked.toString(),
              accountTotalBtc: btc.total.toString(),
              strategyTrackedBtc: Value(strategyTrackedBtc.toString()),
              externalBtc: Value(externalBtc.toString()),
              unclassifiedBtc: Value(unclassifiedBtc.toString()),
              canTrade: Value(snapshot.canTrade),
              canWithdraw: Value(snapshot.canWithdraw),
              permissionsJson: Value(jsonEncode(snapshot.permissions)),
              exchangeUpdateTime: Value(snapshot.updateTime),
              recordedAt: now,
            ),
          );
    });
  }

  Future<void> saveOpenOrders(
    List<spot.SpotOpenOrder> orders, {
    String environment = 'live',
    String? symbol,
    String? keyProfileId,
    String? accountBindingId,
  }) async {
    final now = DateTime.now().toUtc();
    final liveIds =
        orders
            .map((order) => _scopedId('spot', keyProfileId, order.orderId))
            .toSet();
    final symbols = <String>{
      if (symbol != null) symbol.toUpperCase(),
      ...orders.map((order) => order.symbol.toUpperCase()),
    };
    await db.transaction(() async {
      for (final symbol in symbols) {
        final stale =
            await (db.select(db.exchangeOpenOrders)..where(
              (tbl) =>
                  tbl.accountType.equals('spotSubAccount') &
                  tbl.keyProfileId.equals(_profileScope(keyProfileId)) &
                  tbl.marketType.equals('spot') &
                  tbl.environment.equals(environment) &
                  tbl.symbol.equals(symbol),
            )).get();
        for (final order in stale) {
          if (!liveIds.contains(order.id)) {
            await (db.delete(db.exchangeOpenOrders)
              ..where((tbl) => tbl.id.equals(order.id))).go();
          }
        }
      }
      for (final order in orders) {
        await db
            .into(db.exchangeOpenOrders)
            .insert(
              ExchangeOpenOrdersCompanion.insert(
                id: _scopedId('spot', keyProfileId, order.orderId),
                accountType: 'spotSubAccount',
                keyProfileId: Value(_profileScope(keyProfileId)),
                accountBindingId: Value(accountBindingId),
                marketType: 'spot',
                environment: environment,
                symbol: order.symbol,
                exchangeOrderId: order.orderId,
                clientOrderId: order.clientOrderId,
                side: order.side,
                orderType: order.type,
                timeInForce: Value(order.timeInForce),
                price: order.price.toString(),
                originalQuantity: order.originalQuantity.toString(),
                executedQuantity: order.executedQuantity.toString(),
                status: order.status,
                createdAt: order.createdAt,
                updatedAt: order.updatedAt,
                syncedAt: now,
              ),
              mode: InsertMode.insertOrReplace,
            );
      }
    });
  }

  Future<void> saveHistoricalOrders(
    List<spot.SpotHistoricalOrder> orders, {
    String environment = 'live',
    String? keyProfileId,
    String? accountBindingId,
  }) async {
    final now = DateTime.now().toUtc();
    await db.batch((batch) {
      for (final order in orders) {
        batch.insert(
          db.exchangeHistoricalOrders,
          ExchangeHistoricalOrdersCompanion.insert(
            id: _scopedId('spot', keyProfileId, order.orderId),
            accountType: 'spotSubAccount',
            keyProfileId: Value(_profileScope(keyProfileId)),
            accountBindingId: Value(accountBindingId),
            marketType: 'spot',
            environment: environment,
            symbol: order.symbol,
            exchangeOrderId: order.orderId,
            clientOrderId: order.clientOrderId,
            side: order.side,
            orderType: order.type,
            timeInForce: Value(order.timeInForce),
            price: order.price.toString(),
            originalQuantity: order.originalQuantity.toString(),
            executedQuantity: order.executedQuantity.toString(),
            quoteQuantity: Value(order.quoteQuantity.toString()),
            status: order.status,
            createdAt: order.createdAt,
            updatedAt: order.updatedAt,
            syncedAt: now,
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Future<void> saveTrades(
    List<spot.SpotTrade> trades, {
    String environment = 'live',
    String? keyProfileId,
    String? accountBindingId,
  }) async {
    final now = DateTime.now().toUtc();
    await db.batch((batch) {
      for (final trade in trades) {
        batch.insert(
          db.exchangeTrades,
          ExchangeTradesCompanion.insert(
            id: _scopedId('spot', keyProfileId, trade.id),
            accountType: 'spotSubAccount',
            keyProfileId: Value(_profileScope(keyProfileId)),
            accountBindingId: Value(accountBindingId),
            marketType: 'spot',
            environment: environment,
            symbol: trade.symbol,
            exchangeTradeId: trade.id,
            exchangeOrderId: Value(trade.orderId),
            side: trade.side,
            price: trade.price.toString(),
            quantity: trade.quantity.toString(),
            quoteQuantity: trade.quoteQuantity.toString(),
            commission: trade.commission.toString(),
            commissionAsset: trade.commissionAsset,
            isMaker: Value(trade.isMaker),
            tradeTime: trade.tradeTime,
            syncedAt: now,
          ),
          mode: InsertMode.insertOrIgnore,
        );
      }
    });
  }

  String _scopedId(String prefix, String? keyProfileId, String value) {
    return '$prefix-${_profileScope(keyProfileId)}-$value';
  }

  String _profileScope(String? keyProfileId) =>
      keyProfileId == null || keyProfileId.isEmpty ? 'legacy' : keyProfileId;
}
