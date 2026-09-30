import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import '../../../database/app_database.dart';
import 'futures_account_models.dart' as futures;

class FuturesAccountRepository {
  FuturesAccountRepository(this.db);

  final AppDatabase db;

  Future<void> saveSnapshot(
    futures.FuturesAccountSnapshot snapshot, {
    String? keyProfileId,
    String? accountBindingId,
  }) async {
    final now = DateTime.now().toUtc();
    final btcPositions =
        snapshot.positions
            .where((position) => position.symbol == 'BTCUSDT')
            .toList();
    final shortQty = btcPositions
        .where((p) => p.isShort)
        .fold(Decimal.zero, (sum, p) => sum + p.positionAmount.abs());
    final longQty = btcPositions
        .where((p) => p.isLong)
        .fold(Decimal.zero, (sum, p) => sum + p.positionAmount.abs());
    final shortEntry =
        btcPositions
            .where((p) => p.isShort)
            .map((p) => p.entryPrice.toString())
            .firstOrNull;
    final longEntry =
        btcPositions
            .where((p) => p.isLong)
            .map((p) => p.entryPrice.toString())
            .firstOrNull;
    final mark = btcPositions.map((p) => p.markPrice.toString()).firstOrNull;
    await db.transaction(() async {
      await db
          .into(db.futuresAccountSnapshots)
          .insert(
            FuturesAccountSnapshotsCompanion.insert(
              id: _scopedId('futures', keyProfileId, now.toIso8601String()),
              keyProfileId: Value(_profileScope(keyProfileId)),
              accountBindingId: Value(accountBindingId),
              walletBalance: snapshot.walletBalance.toString(),
              availableBalance: snapshot.availableBalance.toString(),
              totalUnrealizedPnl: snapshot.totalUnrealizedPnl.toString(),
              shortQuantity: Value(shortQty.toString()),
              longQuantity: Value(longQty.toString()),
              shortEntryPrice: Value(shortEntry),
              longEntryPrice: Value(longEntry),
              markPrice: Value(mark),
              positionMode: Value(snapshot.positionMode),
              recordedAt: now,
            ),
          );
      for (final position in snapshot.positions) {
        await db
            .into(db.futuresPositions)
            .insertOnConflictUpdate(
              FuturesPositionsCompanion.insert(
                id: _scopedId(
                  'futures-position',
                  keyProfileId,
                  '${position.symbol}-${position.positionSide}',
                ),
                keyProfileId: Value(_profileScope(keyProfileId)),
                accountBindingId: Value(accountBindingId),
                symbol: position.symbol,
                positionSide: position.positionSide,
                positionAmount: position.positionAmount.toString(),
                entryPrice: position.entryPrice.toString(),
                markPrice: Value(position.markPrice.toString()),
                unrealizedPnl: position.unrealizedPnl.toString(),
                leverage: Value(position.leverage),
                marginType: Value(position.marginType),
                liquidationPrice: Value(position.liquidationPrice?.toString()),
                updatedAt: now,
              ),
            );
      }
    });
  }

  Future<void> saveOpenOrders(
    List<futures.FuturesOpenOrder> orders, {
    String environment = 'live',
    String? symbol,
    String? keyProfileId,
    String? accountBindingId,
  }) async {
    final now = DateTime.now().toUtc();
    final liveIds =
        orders
            .map((order) => _scopedId('futures', keyProfileId, order.orderId))
            .toSet();
    final symbols = {
      if (symbol != null && symbol.isNotEmpty) symbol.toUpperCase(),
      ...orders.map((order) => order.symbol),
    };
    await db.transaction(() async {
      final stale =
          symbols.isEmpty
              ? <ExchangeOpenOrder>[]
              : await (db.select(db.exchangeOpenOrders)..where(
                (tbl) =>
                    tbl.accountType.equals('futuresSubAccount') &
                    tbl.keyProfileId.equals(_profileScope(keyProfileId)) &
                    tbl.marketType.equals('usdtFutures') &
                    tbl.environment.equals(environment) &
                    tbl.symbol.isIn(symbols),
              )).get();
      for (final order in stale) {
        if (!liveIds.contains(order.id)) {
          await (db.delete(db.exchangeOpenOrders)
            ..where((tbl) => tbl.id.equals(order.id))).go();
        }
      }
      for (final order in orders) {
        await db
            .into(db.exchangeOpenOrders)
            .insert(
              ExchangeOpenOrdersCompanion.insert(
                id: _scopedId('futures', keyProfileId, order.orderId),
                accountType: 'futuresSubAccount',
                keyProfileId: Value(_profileScope(keyProfileId)),
                accountBindingId: Value(accountBindingId),
                marketType: 'usdtFutures',
                environment: environment,
                symbol: order.symbol,
                exchangeOrderId: order.orderId,
                clientOrderId: order.clientOrderId,
                side: order.side,
                positionSide: Value(order.positionSide),
                orderType: order.type,
                timeInForce: Value(order.timeInForce),
                price: order.price.toString(),
                originalQuantity: order.originalQuantity.toString(),
                executedQuantity: order.executedQuantity.toString(),
                averagePrice: Value(order.averagePrice.toString()),
                status: order.status,
                reduceOnly: Value(order.reduceOnly),
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
    List<futures.FuturesHistoricalOrder> orders, {
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
            id: _scopedId('futures', keyProfileId, order.orderId),
            accountType: 'futuresSubAccount',
            keyProfileId: Value(_profileScope(keyProfileId)),
            accountBindingId: Value(accountBindingId),
            marketType: 'usdtFutures',
            environment: environment,
            symbol: order.symbol,
            exchangeOrderId: order.orderId,
            clientOrderId: order.clientOrderId,
            side: order.side,
            positionSide: Value(order.positionSide),
            orderType: order.type,
            timeInForce: Value(order.timeInForce),
            price: order.price.toString(),
            originalQuantity: order.originalQuantity.toString(),
            executedQuantity: order.executedQuantity.toString(),
            averagePrice: Value(order.averagePrice.toString()),
            status: order.status,
            reduceOnly: Value(order.reduceOnly),
            createdAt: order.createdAt,
            updatedAt: order.updatedAt,
            syncedAt: now,
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Future<void> saveHistoricalOrderFromLocalOrder(
    Order order, {
    String environment = 'live',
    String? keyProfileId,
    String? accountBindingId,
  }) async {
    final exchangeOrderId = order.exchangeOrderId;
    if (exchangeOrderId == null || exchangeOrderId.isEmpty) {
      return;
    }
    final now = DateTime.now().toUtc();
    await db
        .into(db.exchangeHistoricalOrders)
        .insert(
          ExchangeHistoricalOrdersCompanion.insert(
            id: _scopedId('futures', keyProfileId, exchangeOrderId),
            accountType: 'futuresSubAccount',
            keyProfileId: Value(_profileScope(keyProfileId)),
            accountBindingId: Value(accountBindingId),
            marketType: 'usdtFutures',
            environment: environment,
            symbol: order.symbol,
            exchangeOrderId: exchangeOrderId,
            clientOrderId: order.clientOrderId,
            side: order.side,
            positionSide: Value(order.positionSide),
            orderType: order.orderType,
            timeInForce: const Value(null),
            price: order.price ?? '0',
            originalQuantity: order.originalQuantity,
            executedQuantity: order.executedQuantity,
            averagePrice: Value(order.averagePrice),
            status: _exchangeStatusFromLocal(order.status),
            reduceOnly: Value(order.reduceOnly),
            createdAt: order.createdAt,
            updatedAt: order.updatedAt,
            syncedAt: now,
          ),
          mode: InsertMode.insertOrReplace,
        );
  }

  String _exchangeStatusFromLocal(String status) {
    switch (status) {
      case 'new':
        return 'NEW';
      case 'partiallyFilled':
        return 'PARTIALLY_FILLED';
      case 'filled':
        return 'FILLED';
      case 'cancelled':
        return 'CANCELED';
      case 'rejected':
        return 'REJECTED';
      case 'expired':
        return 'EXPIRED';
      default:
        return status.toUpperCase();
    }
  }

  Future<void> saveTrades(
    List<futures.FuturesTrade> trades, {
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
            id: _scopedId('futures', keyProfileId, trade.id),
            accountType: 'futuresSubAccount',
            keyProfileId: Value(_profileScope(keyProfileId)),
            accountBindingId: Value(accountBindingId),
            marketType: 'usdtFutures',
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
            realizedPnl: Value(trade.realizedPnl.toString()),
            isMaker: Value(trade.isMaker),
            tradeTime: trade.tradeTime,
            syncedAt: now,
          ),
          mode: InsertMode.insertOrIgnore,
        );
      }
    });
  }

  Future<void> saveFundingFees(
    List<futures.FundingFeeRecord> records, {
    String? keyProfileId,
    String? accountBindingId,
  }) async {
    final now = DateTime.now().toUtc();
    await db.batch((batch) {
      for (final record in records) {
        batch.insert(
          db.fundingFeeRecords,
          FundingFeeRecordsCompanion.insert(
            id: _scopedId(
              'funding',
              keyProfileId,
              '${record.transactionId}-${record.time.millisecondsSinceEpoch}',
            ),
            keyProfileId: Value(_profileScope(keyProfileId)),
            accountBindingId: Value(accountBindingId),
            symbol: record.symbol,
            income: record.income.toString(),
            asset: record.asset,
            info: Value(record.info),
            transactionId: Value(record.transactionId),
            incomeTime: record.time,
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
