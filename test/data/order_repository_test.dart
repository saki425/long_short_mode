import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/database/app_database.dart';
import 'package:grid_hedge_trader/models/order_filters.dart';
import 'package:grid_hedge_trader/repositories/order_repository.dart';
import 'package:grid_hedge_trader/services/export/csv_export_service.dart';

void main() {
  late AppDatabase db;
  late OrderRepository repository;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repository = OrderRepository(db);
    await _insertStrategy(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('creates all required tables', () async {
    final tables =
        await db
            .customSelect("select name from sqlite_master where type = 'table'")
            .get();
    final names = tables.map((row) => row.data['name'] as String).toSet();
    expect(
      names,
      containsAll([
        'strategies',
        'grid_levels',
        'orders',
        'fills',
        'hedge_adjustments',
        'account_snapshots',
        'pnl_snapshots',
        'risk_events',
        'app_logs',
      ]),
    );
  });

  test('writes planned order and watches waiting orders', () async {
    final createdAt = DateTime.utc(2026, 7, 6, 10);
    await _insertOrder(
      db,
      id: 'planned_1',
      status: 'planned',
      createdAt: createdAt,
    );

    final orders =
        await repository
            .watchPlannedOrders(
              start: DateTime.utc(2026, 7, 6),
              end: DateTime.utc(2026, 7, 7),
            )
            .first;

    expect(orders, hasLength(1));
    expect(orders.single.id, 'planned_1');
  });

  test('watches open orders', () async {
    await _insertOrder(
      db,
      id: 'new_1',
      status: 'new',
      createdAt: DateTime.utc(2026, 7, 6, 11),
    );
    await _insertOrder(
      db,
      id: 'filled_1',
      status: 'filled',
      createdAt: DateTime.utc(2026, 7, 6, 12),
    );

    final orders =
        await repository
            .watchOpenOrders(
              start: DateTime.utc(2026, 7, 6),
              end: DateTime.utc(2026, 7, 7),
            )
            .first;

    expect(orders.map((order) => order.id), ['new_1']);
  });

  test('watches unfinished orders without final states', () async {
    final statuses = {
      'planned': true,
      'created': true,
      'submitting': true,
      'new': true,
      'partiallyFilled': true,
      'cancelling': true,
      'unknown': true,
      'pendingRecovery': true,
      'pendingReplacement': true,
      'reconciling': true,
      'filled': false,
      'cancelled': false,
      'rejected': false,
      'expired': false,
      'completed': false,
      'archived': false,
    };
    var minute = 0;
    for (final entry in statuses.entries) {
      await _insertOrder(
        db,
        id: 'unfinished_${entry.key}',
        status: entry.key,
        createdAt: DateTime.utc(2026, 7, 6, 9, minute++),
      );
    }

    final orders =
        await repository
            .watchUnfinishedOrders(
              start: DateTime.utc(2026, 7, 6),
              end: DateTime.utc(2026, 7, 7),
              filter: UnfinishedOrderFilter.all,
            )
            .first;

    expect(orders, hasLength(statuses.values.where((value) => value).length));
    expect(
      orders.map((order) => order.status).toSet(),
      isNot(containsAll(['filled', 'cancelled', 'rejected', 'expired'])),
    );
  });

  test(
    'unfinished order statistics separates unknown and pending replacement',
    () async {
      await _insertOrder(
        db,
        id: 'unfinished_plan',
        status: 'planned',
        createdAt: DateTime.utc(2026, 7, 6, 10),
      );
      await _insertOrder(
        db,
        id: 'unfinished_unknown',
        status: 'unknown',
        createdAt: DateTime.utc(2026, 7, 6, 11),
      );
      await _insertOrder(
        db,
        id: 'unfinished_replacement',
        status: 'pendingReplacement',
        createdAt: DateTime.utc(2026, 7, 6, 12),
      );

      final stats = await repository.getUnfinishedOrderStatistics(
        start: DateTime.utc(2026, 7, 6),
        end: DateTime.utc(2026, 7, 7),
      );

      expect(stats.localPlanCount, 1);
      expect(stats.unknownCount, 1);
      expect(stats.pendingReplacementCount, 1);
      expect(stats.strategyCount, 1);
    },
  );

  test('completed order date query includes the full end date', () async {
    await _insertOrder(
      db,
      id: 'completed_end_day',
      status: 'filled',
      createdAt: DateTime.utc(2026, 7, 5, 23),
      completedAt: DateTime.utc(2026, 7, 6, 19, 59, 59),
    );
    await _insertOrder(
      db,
      id: 'completed_next_day',
      status: 'filled',
      createdAt: DateTime.utc(2026, 7, 6, 23),
      completedAt: DateTime.utc(2026, 7, 7),
    );

    final range =
        LocalDateRange(
          label: 'custom',
          startLocal: DateTime(2026, 7, 6),
          endLocalInclusive: DateTime(2026, 7, 6),
        ).toUtcHalfOpenRange();
    final orders = await repository.getCompletedOrders(
      start: range.startInclusiveUtc,
      end: range.endExclusiveUtc,
    );

    expect(orders.map((order) => order.id), ['completed_end_day']);
  });

  test('completed order pagination returns 50 rows per page', () async {
    for (var i = 0; i < 55; i++) {
      await _insertOrder(
        db,
        id: 'filled_$i',
        status: 'filled',
        createdAt: DateTime.utc(2026, 7, 6, 1),
        completedAt: DateTime.utc(2026, 7, 6, 2, i),
      );
    }

    final firstPage = await repository.getCompletedOrders(
      start: DateTime.utc(2026, 7, 6),
      end: DateTime.utc(2026, 7, 7),
      limit: 50,
    );
    final secondPage = await repository.getCompletedOrders(
      start: DateTime.utc(2026, 7, 6),
      end: DateTime.utc(2026, 7, 7),
      limit: 50,
      offset: 50,
    );

    expect(firstPage, hasLength(50));
    expect(secondPage, hasLength(5));
  });

  test('updates order status', () async {
    await _insertOrder(
      db,
      id: 'order_status',
      status: 'planned',
      createdAt: DateTime.utc(2026, 7, 6),
    );

    await repository.updateOrderStatus(
      orderId: 'order_status',
      status: 'filled',
      completedAt: DateTime.utc(2026, 7, 6, 12),
    );
    final details = await repository.getOrderDetails('order_status');

    expect(details?.order.status, 'filled');
    expect(details?.order.completedAt?.toUtc(), DateTime.utc(2026, 7, 6, 12));
  });

  test('finds order details by clientOrderId', () async {
    await _insertOrder(
      db,
      id: 'order_by_client',
      status: 'new',
      createdAt: DateTime.utc(2026, 7, 6),
    );

    final details = await repository.getOrderDetailsByClientOrderId(
      'DHG_spot_strategy_gridBuy_order_by_client',
    );

    expect(details == null, isFalse);
    expect(details?.order.id, 'order_by_client');
  });

  test('deduplicates fills by exchangeTradeId', () async {
    await _insertOrder(
      db,
      id: 'order_fill',
      status: 'filled',
      createdAt: DateTime.utc(2026, 7, 6),
    );

    final fill = FillsCompanion.insert(
      id: 'fill_1',
      strategyId: 'strategy_1',
      orderId: 'order_fill',
      exchangeTradeId: 'trade_unique',
      symbol: 'BTCUSDT',
      side: 'BUY',
      price: '60000',
      quantity: '0.001',
      quoteQuantity: '60',
      commission: '0.01',
      commissionAsset: 'USDT',
      realizedPnl: const Value('1.25'),
      tradeTime: DateTime.utc(2026, 7, 6, 12),
      createdAt: DateTime.utc(2026, 7, 6, 12),
    );
    await repository.insertFill(fill);
    await repository.insertFill(fill.copyWith(id: const Value('fill_2')));

    final fills = await repository.getOrderFills('order_fill');
    expect(fills, hasLength(1));
    expect(fills.single.exchangeTradeId, 'trade_unique');
  });

  test('exports orders to CSV without API key fields', () async {
    await _insertOrder(
      db,
      id: 'csv_order',
      status: 'filled',
      createdAt: DateTime.utc(2026, 7, 6),
    );
    final orders = await repository.getCompletedOrders(
      start: DateTime.utc(2026, 7, 6),
      end: DateTime.utc(2026, 7, 7),
      dateField: OrderDateField.createdAt,
    );

    final csv = CsvExportService().ordersToCsv(orders);

    expect(csv, contains('csv_order'));
    expect(csv, isNot(contains('apiKey')));
    expect(csv, isNot(contains('secret')));
  });
}

Future<void> _insertStrategy(AppDatabase db) {
  return db
      .into(db.strategies)
      .insert(
        StrategiesCompanion.insert(
          id: 'strategy_1',
          name: 'Test Strategy',
          symbol: 'BTCUSDT',
          environment: 'PAPER',
          status: 'idle',
          createdAt: DateTime.utc(2026, 7, 6),
          lowerPrice: '56000',
          upperPrice: '64000',
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
          updatedAt: DateTime.utc(2026, 7, 6),
        ),
      );
}

Future<void> _insertOrder(
  AppDatabase db, {
  required String id,
  required String status,
  required DateTime createdAt,
  DateTime? completedAt,
}) {
  return db
      .into(db.orders)
      .insert(
        OrdersCompanion.insert(
          id: id,
          strategyId: 'strategy_1',
          accountType: 'spotSubAccount',
          marketType: 'spot',
          symbol: 'BTCUSDT',
          clientOrderId: 'DHG_spot_strategy_gridBuy_$id',
          side: 'BUY',
          orderType: 'LIMIT',
          timeInForce: const Value('GTC'),
          price: const Value('60000'),
          originalQuantity: '0.001',
          executedQuantity: Value(status == 'filled' ? '0.001' : '0'),
          averagePrice:
              status == 'filled' ? const Value('60000') : const Value.absent(),
          quoteQuantity:
              status == 'filled' ? const Value('60') : const Value.absent(),
          status: status,
          purpose: 'gridBuy',
          createdAt: createdAt,
          updatedAt: createdAt,
          completedAt: Value(completedAt),
        ),
      );
}
