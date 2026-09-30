import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import '../../models/order_filters.dart';
import '../database/app_database.dart';

class OrderDetails {
  const OrderDetails({required this.order, required this.fills});

  final Order order;
  final List<Fill> fills;
}

class OrderStatistics {
  const OrderStatistics({
    required this.plannedOrderCount,
    required this.submittedOrderCount,
    required this.openOrderCount,
    required this.completedOrderCount,
    required this.cancelledOrderCount,
    required this.failedOrderCount,
    required this.spotTurnover,
    required this.futuresTurnover,
    required this.spotFees,
    required this.futuresFees,
    required this.gridRealizedPnl,
    required this.futuresRealizedPnl,
    required this.fundingFees,
    required this.totalNetPnl,
  });

  final int plannedOrderCount;
  final int submittedOrderCount;
  final int openOrderCount;
  final int completedOrderCount;
  final int cancelledOrderCount;
  final int failedOrderCount;
  final Decimal spotTurnover;
  final Decimal futuresTurnover;
  final Decimal spotFees;
  final Decimal futuresFees;
  final Decimal gridRealizedPnl;
  final Decimal futuresRealizedPnl;
  final Decimal fundingFees;
  final Decimal totalNetPnl;
}

class UnfinishedOrderStatistics {
  const UnfinishedOrderStatistics({
    required this.localPlanCount,
    required this.submittingCount,
    required this.binanceOpenCount,
    required this.partiallyFilledCount,
    required this.unknownCount,
    required this.pendingRecoveryCount,
    required this.pendingReplacementCount,
    required this.strategyCount,
    required this.estimatedUsdtLocked,
    required this.lockedBtc,
    required this.lockedUsdt,
  });

  final int localPlanCount;
  final int submittingCount;
  final int binanceOpenCount;
  final int partiallyFilledCount;
  final int unknownCount;
  final int pendingRecoveryCount;
  final int pendingReplacementCount;
  final int strategyCount;
  final Decimal estimatedUsdtLocked;
  final Decimal lockedBtc;
  final Decimal lockedUsdt;
}

class UnfinishedOrderProcessReport {
  const UnfinishedOrderProcessReport({
    required this.generatedAt,
    required this.localUnfinishedCount,
    required this.binanceLikeOpenCount,
    required this.statusMismatchCount,
    required this.submittingTimeoutCount,
    required this.unknownCount,
    required this.pendingReplacementCount,
    required this.notes,
  });

  final DateTime generatedAt;
  final int localUnfinishedCount;
  final int binanceLikeOpenCount;
  final int statusMismatchCount;
  final int submittingTimeoutCount;
  final int unknownCount;
  final int pendingReplacementCount;
  final List<String> notes;
}

class OrderRepository {
  OrderRepository(this.db);

  final AppDatabase db;

  static const unfinishedStatuses = [
    'planned',
    'created',
    'submitting',
    'new',
    'partiallyFilled',
    'cancelling',
    'unknown',
    'pendingRecovery',
    'pendingReplacement',
    'reconciling',
  ];

  static const finalStatuses = [
    'filled',
    'cancelled',
    'rejected',
    'expired',
    'completed',
    'archived',
  ];

  Future<void> insertOrder(OrdersCompanion order) {
    return db.into(db.orders).insert(order, mode: InsertMode.insertOrIgnore);
  }

  Future<void> updateOrderStatus({
    required String orderId,
    required String status,
    DateTime? completedAt,
    DateTime? cancelledAt,
    String? errorCode,
    String? errorMessage,
  }) {
    final now = DateTime.now().toUtc();
    return (db.update(db.orders)..where((tbl) => tbl.id.equals(orderId))).write(
      OrdersCompanion(
        status: Value(status),
        updatedAt: Value(now),
        completedAt: Value(completedAt?.toUtc()),
        cancelledAt: Value(cancelledAt?.toUtc()),
        errorCode: Value(errorCode),
        errorMessage: Value(errorMessage),
      ),
    );
  }

  Stream<List<Order>> watchOpenOrders({
    required DateTime start,
    required DateTime end,
    String? symbol,
    MarketTypeFilter marketType = MarketTypeFilter.all,
    OrderEnvironmentFilter environment = OrderEnvironmentFilter.all,
  }) {
    final query = _baseDateQuery(
      start: start,
      end: end,
      dateField: OrderDateField.createdAt,
      marketType: marketType,
      environment: environment,
      symbol: symbol,
    )..where(
      (tbl) => tbl.status.isIn(['submitting', 'new', 'partiallyFilled']),
    );
    return (query..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]))
        .watch();
  }

  Stream<List<Order>> watchAllOrders({
    required DateTime start,
    required DateTime end,
    String? symbol,
    MarketTypeFilter marketType = MarketTypeFilter.all,
    OrderEnvironmentFilter environment = OrderEnvironmentFilter.all,
  }) {
    final query = _baseDateQuery(
      start: start,
      end: end,
      dateField: OrderDateField.createdAt,
      marketType: marketType,
      environment: environment,
      symbol: symbol,
    );
    return (query..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]))
        .watch();
  }

  Stream<List<Order>> watchUnfinishedOrders({
    required DateTime start,
    required DateTime end,
    required UnfinishedOrderFilter filter,
    String? symbol,
    MarketTypeFilter marketType = MarketTypeFilter.all,
    OrderEnvironmentFilter environment = OrderEnvironmentFilter.all,
  }) {
    final statuses = _unfinishedStatusesForFilter(filter);
    final query = _baseDateQuery(
      start: start,
      end: end,
      dateField: OrderDateField.updatedAt,
      marketType: marketType,
      environment: environment,
      symbol: symbol,
    )..where((tbl) => tbl.status.isIn(statuses));
    return (query..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)]))
        .watch();
  }

  Stream<List<Order>> watchPlannedOrders({
    required DateTime start,
    required DateTime end,
    String? symbol,
    MarketTypeFilter marketType = MarketTypeFilter.all,
    OrderEnvironmentFilter environment = OrderEnvironmentFilter.all,
  }) {
    final query = _baseDateQuery(
      start: start,
      end: end,
      dateField: OrderDateField.createdAt,
      marketType: marketType,
      environment: environment,
      symbol: symbol,
    )..where((tbl) => tbl.status.isIn(['planned', 'created']));
    return (query..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]))
        .watch();
  }

  Future<List<Order>> getCompletedOrders({
    required DateTime start,
    required DateTime end,
    String? symbol,
    MarketTypeFilter marketType = MarketTypeFilter.all,
    OrderEnvironmentFilter environment = OrderEnvironmentFilter.all,
    OrderDateField dateField = OrderDateField.completedAt,
    int limit = 50,
    int offset = 0,
  }) {
    return _pagedByStatus(
      statuses: ['filled'],
      start: start,
      end: end,
      marketType: marketType,
      environment: environment,
      symbol: symbol,
      dateField: dateField,
      limit: limit,
      offset: offset,
    );
  }

  Future<List<Order>> getCancelledOrders({
    required DateTime start,
    required DateTime end,
    String? symbol,
    MarketTypeFilter marketType = MarketTypeFilter.all,
    OrderEnvironmentFilter environment = OrderEnvironmentFilter.all,
    OrderDateField dateField = OrderDateField.updatedAt,
    int limit = 50,
    int offset = 0,
  }) {
    return _pagedByStatus(
      statuses: ['cancelled'],
      start: start,
      end: end,
      marketType: marketType,
      environment: environment,
      symbol: symbol,
      dateField: dateField,
      limit: limit,
      offset: offset,
    );
  }

  Future<List<Order>> getFailedOrders({
    required DateTime start,
    required DateTime end,
    String? symbol,
    MarketTypeFilter marketType = MarketTypeFilter.all,
    OrderEnvironmentFilter environment = OrderEnvironmentFilter.all,
    OrderDateField dateField = OrderDateField.updatedAt,
    int limit = 50,
    int offset = 0,
  }) {
    return _pagedByStatus(
      statuses: ['rejected', 'expired', 'unknown'],
      start: start,
      end: end,
      marketType: marketType,
      environment: environment,
      symbol: symbol,
      dateField: dateField,
      limit: limit,
      offset: offset,
    );
  }

  Future<List<Order>> getAllOrders({
    required DateTime start,
    required DateTime end,
    String? symbol,
    MarketTypeFilter marketType = MarketTypeFilter.all,
    OrderEnvironmentFilter environment = OrderEnvironmentFilter.all,
    OrderDateField dateField = OrderDateField.createdAt,
    int limit = 50,
    int offset = 0,
  }) {
    final query = _baseDateQuery(
      start: start,
      end: end,
      dateField: dateField,
      marketType: marketType,
      environment: environment,
      symbol: symbol,
    );
    return (query
          ..orderBy([(_dateColumnOrdering(dateField))])
          ..limit(limit, offset: offset))
        .get();
  }

  Future<OrderDetails?> getOrderDetails(String orderId) async {
    final order =
        await (db.select(db.orders)
          ..where((tbl) => tbl.id.equals(orderId))).getSingleOrNull();
    if (order == null) {
      return null;
    }
    return OrderDetails(order: order, fills: await getOrderFills(orderId));
  }

  Future<List<Order>> getOrdersByIds(Iterable<String> orderIds) {
    final ids = orderIds.toSet().toList();
    if (ids.isEmpty) {
      return Future.value(const []);
    }
    return (db.select(db.orders)..where((tbl) => tbl.id.isIn(ids))).get();
  }

  Future<OrderDetails?> getOrderDetailsByClientOrderId(
    String clientOrderId,
  ) async {
    final order =
        await (db.select(db.orders)..where(
          (tbl) => tbl.clientOrderId.equals(clientOrderId),
        )).getSingleOrNull();
    if (order == null) {
      return null;
    }
    return OrderDetails(order: order, fills: await getOrderFills(order.id));
  }

  Future<List<Fill>> getOrderFills(String orderId) {
    return (db.select(db.fills)
          ..where((tbl) => tbl.orderId.equals(orderId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.tradeTime)]))
        .get();
  }

  Future<void> insertFill(FillsCompanion fill) {
    return db.into(db.fills).insert(fill, mode: InsertMode.insertOrIgnore);
  }

  Future<OrderStatistics> getOrderStatistics({
    required DateTime start,
    required DateTime end,
    String? symbol,
    OrderEnvironmentFilter environment = OrderEnvironmentFilter.all,
  }) async {
    final orders =
        await (_baseDateQuery(
          start: start,
          end: end,
          dateField: OrderDateField.createdAt,
          marketType: MarketTypeFilter.all,
          environment: environment,
          symbol: symbol,
        )).get();
    final fills =
        await (db.select(db.fills)..where(
          (tbl) =>
              tbl.tradeTime.isBiggerOrEqualValue(start.toUtc()) &
              tbl.tradeTime.isSmallerThanValue(end.toUtc()) &
              (symbol == null || symbol.isEmpty
                  ? const Constant(true)
                  : tbl.symbol.equals(symbol)),
        )).get();

    final planned =
        orders
            .where((o) => o.status == 'planned' || o.status == 'created')
            .length;
    final submitted = orders.where((o) => o.submittedAt != null).length;
    final open =
        orders
            .where(
              (o) =>
                  ['submitting', 'new', 'partiallyFilled'].contains(o.status),
            )
            .length;
    final completed = orders.where((o) => o.status == 'filled').length;
    final cancelled = orders.where((o) => o.status == 'cancelled').length;
    final failed =
        orders
            .where((o) => ['rejected', 'expired', 'unknown'].contains(o.status))
            .length;
    final orderById = {for (final order in orders) order.id: order};

    Decimal spotTurnover = Decimal.zero;
    Decimal futuresTurnover = Decimal.zero;
    Decimal spotFees = Decimal.zero;
    Decimal futuresFees = Decimal.zero;
    Decimal gridPnl = Decimal.zero;
    Decimal futuresPnl = Decimal.zero;
    for (final fill in fills) {
      final order = orderById[fill.orderId];
      final quote = _decimal(fill.quoteQuantity);
      final fee = _decimal(fill.commission);
      final pnl = _decimal(fill.realizedPnl ?? '0');
      if (order?.marketType == 'spot') {
        spotTurnover += quote;
        spotFees += fee;
        gridPnl += pnl;
      } else if (order?.marketType == 'usdtFutures') {
        futuresTurnover += quote;
        futuresFees += fee;
        futuresPnl += pnl;
      }
    }

    return OrderStatistics(
      plannedOrderCount: planned,
      submittedOrderCount: submitted,
      openOrderCount: open,
      completedOrderCount: completed,
      cancelledOrderCount: cancelled,
      failedOrderCount: failed,
      spotTurnover: spotTurnover,
      futuresTurnover: futuresTurnover,
      spotFees: spotFees,
      futuresFees: futuresFees,
      gridRealizedPnl: gridPnl,
      futuresRealizedPnl: futuresPnl,
      fundingFees: Decimal.zero,
      totalNetPnl: gridPnl + futuresPnl - spotFees - futuresFees,
    );
  }

  Future<UnfinishedOrderStatistics> getUnfinishedOrderStatistics({
    required DateTime start,
    required DateTime end,
    String? symbol,
    MarketTypeFilter marketType = MarketTypeFilter.all,
    OrderEnvironmentFilter environment = OrderEnvironmentFilter.all,
  }) async {
    final orders =
        await (_baseDateQuery(
          start: start,
          end: end,
          dateField: OrderDateField.updatedAt,
          marketType: marketType,
          environment: environment,
          symbol: symbol,
        )..where((tbl) => tbl.status.isIn(unfinishedStatuses))).get();

    Decimal estimatedUsdtLocked = Decimal.zero;
    Decimal lockedBtc = Decimal.zero;
    Decimal lockedUsdt = Decimal.zero;
    for (final order in orders) {
      final qty = _decimal(order.originalQuantity);
      final executed = _decimal(order.executedQuantity);
      final remaining = qty - executed;
      final price = _decimal(order.price ?? order.averagePrice ?? '0');
      if (remaining <= Decimal.zero) {
        continue;
      }
      if (order.side == 'BUY') {
        final quote = price * remaining;
        lockedUsdt += quote;
        estimatedUsdtLocked += quote;
      } else if (order.side == 'SELL') {
        lockedBtc += remaining;
        estimatedUsdtLocked += price * remaining;
      }
    }

    return UnfinishedOrderStatistics(
      localPlanCount:
          orders.where((o) => ['planned', 'created'].contains(o.status)).length,
      submittingCount:
          orders
              .where((o) => ['submitting', 'cancelling'].contains(o.status))
              .length,
      binanceOpenCount: orders.where((o) => o.status == 'new').length,
      partiallyFilledCount:
          orders.where((o) => o.status == 'partiallyFilled').length,
      unknownCount: orders.where((o) => o.status == 'unknown').length,
      pendingRecoveryCount:
          orders.where((o) => o.status == 'pendingRecovery').length,
      pendingReplacementCount:
          orders.where((o) => o.status == 'pendingReplacement').length,
      strategyCount: orders.map((o) => o.strategyId).toSet().length,
      estimatedUsdtLocked: estimatedUsdtLocked,
      lockedBtc: lockedBtc,
      lockedUsdt: lockedUsdt,
    );
  }

  Future<UnfinishedOrderProcessReport> buildUnfinishedOrderReport({
    required DateTime start,
    required DateTime end,
    String? symbol,
    MarketTypeFilter marketType = MarketTypeFilter.all,
    OrderEnvironmentFilter environment = OrderEnvironmentFilter.all,
  }) async {
    final orders =
        await (_baseDateQuery(
          start: start,
          end: end,
          dateField: OrderDateField.updatedAt,
          marketType: marketType,
          environment: environment,
          symbol: symbol,
        )..where((tbl) => tbl.status.isIn(unfinishedStatuses))).get();
    final now = DateTime.now().toUtc();
    final submittingTimeout =
        orders
            .where(
              (order) =>
                  order.status == 'submitting' &&
                  now.difference(order.updatedAt) > const Duration(minutes: 2),
            )
            .length;
    final notes = <String>[
      '本报告当前只读取本地 SQLite 订单状态，不会发送撤单或下单请求。',
      '真实 Binance 对账仍需通过现有策略/账户对账服务执行。',
    ];
    if (orders.any((order) => order.status == 'unknown')) {
      notes.add('存在 unknown 订单，禁止直接重试下单或删除。');
    }
    if (orders.any((order) => order.status == 'pendingReplacement')) {
      notes.add('存在等待反向订单的成交，恢复前需要校验父订单和数量。');
    }
    return UnfinishedOrderProcessReport(
      generatedAt: now,
      localUnfinishedCount: orders.length,
      binanceLikeOpenCount:
          orders
              .where(
                (order) => [
                  'new',
                  'partiallyFilled',
                  'cancelling',
                ].contains(order.status),
              )
              .length,
      statusMismatchCount: 0,
      submittingTimeoutCount: submittingTimeout,
      unknownCount: orders.where((order) => order.status == 'unknown').length,
      pendingReplacementCount:
          orders.where((order) => order.status == 'pendingReplacement').length,
      notes: notes,
    );
  }

  Future<List<Order>> _pagedByStatus({
    required List<String> statuses,
    required DateTime start,
    required DateTime end,
    required String? symbol,
    required MarketTypeFilter marketType,
    required OrderEnvironmentFilter environment,
    required OrderDateField dateField,
    required int limit,
    required int offset,
  }) {
    final query = _baseDateQuery(
      start: start,
      end: end,
      dateField: dateField,
      marketType: marketType,
      environment: environment,
      symbol: symbol,
    )..where((tbl) => tbl.status.isIn(statuses));
    return (query
          ..orderBy([(_dateColumnOrdering(dateField))])
          ..limit(limit, offset: offset))
        .get();
  }

  SimpleSelectStatement<$OrdersTable, Order> _baseDateQuery({
    required DateTime start,
    required DateTime end,
    required OrderDateField dateField,
    required MarketTypeFilter marketType,
    required OrderEnvironmentFilter environment,
    String? symbol,
  }) {
    final query = db.select(db.orders);
    final startUtc = start.toUtc();
    final endUtc = end.toUtc();
    query.where((tbl) {
      final dateColumn = _dateColumn(tbl, dateField);
      Expression<bool> predicate =
          dateColumn.isBiggerOrEqualValue(startUtc) &
          dateColumn.isSmallerThanValue(endUtc);
      final dbMarketType = _marketTypeValue(marketType);
      if (dbMarketType != null) {
        predicate = predicate & tbl.marketType.equals(dbMarketType);
      }
      final dbEnvironment = _environmentValue(environment);
      if (dbEnvironment != null) {
        predicate = predicate & tbl.environment.equals(dbEnvironment);
      }
      if (symbol != null && symbol.isNotEmpty) {
        predicate = predicate & tbl.symbol.equals(symbol);
      }
      return predicate;
    });
    return query;
  }

  GeneratedColumn<DateTime> _dateColumn(
    $OrdersTable tbl,
    OrderDateField dateField,
  ) {
    switch (dateField) {
      case OrderDateField.createdAt:
        return tbl.createdAt;
      case OrderDateField.completedAt:
        return tbl.completedAt;
      case OrderDateField.updatedAt:
        return tbl.updatedAt;
    }
  }

  OrderingTerm Function($OrdersTable) _dateColumnOrdering(
    OrderDateField dateField,
  ) {
    return (tbl) => OrderingTerm.desc(_dateColumn(tbl, dateField));
  }

  String? _marketTypeValue(MarketTypeFilter marketType) {
    switch (marketType) {
      case MarketTypeFilter.all:
        return null;
      case MarketTypeFilter.spot:
        return 'spot';
      case MarketTypeFilter.usdtFutures:
        return 'usdtFutures';
    }
  }

  String? _environmentValue(OrderEnvironmentFilter environment) {
    switch (environment) {
      case OrderEnvironmentFilter.all:
        return null;
      case OrderEnvironmentFilter.paper:
        return 'paper';
      case OrderEnvironmentFilter.live:
        return 'live';
    }
  }

  List<String> _unfinishedStatusesForFilter(UnfinishedOrderFilter filter) {
    switch (filter) {
      case UnfinishedOrderFilter.all:
        return unfinishedStatuses;
      case UnfinishedOrderFilter.localPlan:
        return ['planned', 'created'];
      case UnfinishedOrderFilter.submitting:
        return ['submitting', 'cancelling'];
      case UnfinishedOrderFilter.open:
        return ['new'];
      case UnfinishedOrderFilter.partiallyFilled:
        return ['partiallyFilled'];
      case UnfinishedOrderFilter.unknown:
        return ['unknown'];
      case UnfinishedOrderFilter.pendingRecovery:
        return ['pendingRecovery', 'reconciling'];
      case UnfinishedOrderFilter.pendingReplacement:
        return ['pendingReplacement'];
    }
  }

  Decimal _decimal(String value) => Decimal.tryParse(value) ?? Decimal.zero;
}
