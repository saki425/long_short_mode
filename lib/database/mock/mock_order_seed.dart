import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../app_database.dart';

class MockOrderSeed {
  MockOrderSeed(this.db);

  final AppDatabase db;
  final Uuid _uuid = const Uuid();

  Future<void> seedIfEmpty() async {
    final existing = await db.select(db.orders).get();
    if (existing.isNotEmpty) {
      return;
    }
    final now = DateTime.now().toUtc();
    const strategyId = 'strategy_mock_btcusdt';
    await db.into(db.strategies).insert(
          StrategiesCompanion.insert(
            id: strategyId,
            name: 'BTCUSDT Paper Grid Hedge',
            symbol: 'BTCUSDT',
            environment: 'PAPER',
            status: 'idle',
            createdAt: now.subtract(const Duration(days: 3)),
            lowerPrice: '56400',
            upperPrice: '63600',
            centerPrice: '60000',
            gridCount: 12,
            gridSpacingPercent: '1',
            gridMode: 'geometric',
            spotCapital: '700',
            futuresCapital: '250',
            reserveCapital: '50',
            hedgeRatio: '1',
            maxLossUsdt: '50',
            maxExposureUsdt: '100',
            updatedAt: now,
          ),
          mode: InsertMode.insertOrIgnore,
        );

    for (var i = 0; i < 6; i++) {
      final levelId = 'grid_$i';
      await db.into(db.gridLevels).insert(
            GridLevelsCompanion.insert(
              id: levelId,
              strategyId: strategyId,
              gridIndex: i,
              price: (58500 + i * 300).toString(),
              nextUpperPrice: Value((58800 + i * 300).toString()),
              nextLowerPrice: Value((58200 + i * 300).toString()),
              plannedSide: i.isEven ? 'BUY' : 'SELL',
              plannedQuantity: '0.001',
              plannedQuoteAmount: '60',
              status: i < 2 ? 'ready' : 'waiting',
              createdAt: now.subtract(Duration(hours: 12 - i)),
              updatedAt: now.subtract(Duration(hours: 10 - i)),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }

    await _insertOrder(
      strategyId: strategyId,
      gridLevelId: 'grid_0',
      marketType: 'spot',
      side: 'BUY',
      status: 'planned',
      purpose: 'gridBuy',
      createdAt: now.subtract(const Duration(hours: 5)),
      price: '59000',
      originalQuantity: '0.001',
    );
    await _insertOrder(
      strategyId: strategyId,
      gridLevelId: 'grid_1',
      marketType: 'spot',
      side: 'SELL',
      status: 'new',
      purpose: 'gridSell',
      createdAt: now.subtract(const Duration(hours: 4)),
      submittedAt: now.subtract(const Duration(hours: 4, minutes: -1)),
      price: '60400',
      originalQuantity: '0.001',
      executedQuantity: '0.0003',
    );
    final filledOrderId = await _insertOrder(
      strategyId: strategyId,
      gridLevelId: 'grid_2',
      marketType: 'spot',
      side: 'BUY',
      status: 'filled',
      purpose: 'gridBuy',
      createdAt: now.subtract(const Duration(days: 1, hours: 2)),
      submittedAt: now.subtract(const Duration(days: 1, hours: 2, minutes: -1)),
      completedAt: now.subtract(const Duration(days: 1, hours: 1)),
      price: '58800',
      originalQuantity: '0.001',
      executedQuantity: '0.001',
      averagePrice: '58810',
      quoteQuantity: '58.81',
    );
    await db.into(db.fills).insert(
          FillsCompanion.insert(
            id: _uuid.v4(),
            strategyId: strategyId,
            orderId: filledOrderId,
            exchangeTradeId: 'mock_trade_1',
            symbol: 'BTCUSDT',
            side: 'BUY',
            price: '58810',
            quantity: '0.001',
            quoteQuantity: '58.81',
            commission: '0.000001',
            commissionAsset: 'BTC',
            realizedPnl: const Value('0'),
            tradeTime: now.subtract(const Duration(days: 1, hours: 1)),
            createdAt: now.subtract(const Duration(days: 1, hours: 1)),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    await _insertOrder(
      strategyId: strategyId,
      gridLevelId: 'grid_3',
      marketType: 'usdtFutures',
      side: 'SELL',
      status: 'cancelled',
      purpose: 'increaseHedge',
      createdAt: now.subtract(const Duration(days: 2)),
      submittedAt: now.subtract(const Duration(days: 2, minutes: -1)),
      cancelledAt: now.subtract(const Duration(days: 2, minutes: -10)),
      price: '60100',
      originalQuantity: '0.001',
    );
    await _insertOrder(
      strategyId: strategyId,
      marketType: 'usdtFutures',
      side: 'BUY',
      status: 'rejected',
      purpose: 'reduceHedge',
      createdAt: now.subtract(const Duration(hours: 2)),
      price: '60200',
      originalQuantity: '0.001',
      errorCode: '-2010',
      errorMessage: 'Mock insufficient margin',
    );
  }

  Future<String> _insertOrder({
    required String strategyId,
    required String marketType,
    required String side,
    required String status,
    required String purpose,
    required DateTime createdAt,
    required String price,
    required String originalQuantity,
    String? gridLevelId,
    DateTime? submittedAt,
    DateTime? completedAt,
    DateTime? cancelledAt,
    String executedQuantity = '0',
    String? averagePrice,
    String? quoteQuantity,
    String? errorCode,
    String? errorMessage,
  }) async {
    final id = _uuid.v4();
    await db.into(db.orders).insert(
          OrdersCompanion.insert(
            id: id,
            strategyId: strategyId,
            accountType: marketType == 'spot' ? 'spotSubAccount' : 'futuresSubAccount',
            marketType: marketType,
            symbol: 'BTCUSDT',
            clientOrderId: 'DHG_${marketType}_strategy_${purpose}_${id.substring(0, 8)}',
            side: side,
            orderType: 'LIMIT',
            timeInForce: const Value('GTC'),
            price: Value(price),
            originalQuantity: originalQuantity,
            executedQuantity: Value(executedQuantity),
            averagePrice: Value(averagePrice),
            quoteQuantity: Value(quoteQuantity),
            reduceOnly: Value(purpose == 'reduceHedge'),
            status: status,
            purpose: purpose,
            gridLevelId: Value(gridLevelId),
            createdAt: createdAt.toUtc(),
            submittedAt: Value(submittedAt?.toUtc()),
            updatedAt: DateTime.now().toUtc(),
            completedAt: Value(completedAt?.toUtc()),
            cancelledAt: Value(cancelledAt?.toUtc()),
            errorCode: Value(errorCode),
            errorMessage: Value(errorMessage),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    return id;
  }
}
