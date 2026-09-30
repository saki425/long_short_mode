import 'package:csv/csv.dart';
import 'package:intl/intl.dart';

import '../../database/app_database.dart';

class CsvExportService {
  CsvExportService();

  final DateFormat _localFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

  String ordersToCsv(List<Order> orders) {
    final rows = <List<Object?>>[
      [
        'id',
        'strategyId',
        'marketType',
        'symbol',
        'side',
        'status',
        'purpose',
        'price',
        'originalQuantity',
        'executedQuantity',
        'averagePrice',
        'quoteQuantity',
        'createdAtLocal',
        'createdAtUtc',
        'completedAtLocal',
        'completedAtUtc',
      ],
      for (final order in orders)
        [
          order.id,
          order.strategyId,
          order.marketType,
          order.symbol,
          order.side,
          order.status,
          order.purpose,
          order.price,
          order.originalQuantity,
          order.executedQuantity,
          order.averagePrice,
          order.quoteQuantity,
          _formatLocal(order.createdAt),
          order.createdAt.toUtc().toIso8601String(),
          order.completedAt == null ? '' : _formatLocal(order.completedAt!),
          order.completedAt?.toUtc().toIso8601String() ?? '',
        ],
    ];
    return const ListToCsvConverter().convert(rows);
  }

  String fillsToCsv(List<Fill> fills) {
    final rows = <List<Object?>>[
      [
        'id',
        'strategyId',
        'orderId',
        'exchangeTradeId',
        'symbol',
        'side',
        'price',
        'quantity',
        'quoteQuantity',
        'commission',
        'commissionAsset',
        'realizedPnl',
        'tradeTimeLocal',
        'tradeTimeUtc',
      ],
      for (final fill in fills)
        [
          fill.id,
          fill.strategyId,
          fill.orderId,
          fill.exchangeTradeId,
          fill.symbol,
          fill.side,
          fill.price,
          fill.quantity,
          fill.quoteQuantity,
          fill.commission,
          fill.commissionAsset,
          fill.realizedPnl,
          _formatLocal(fill.tradeTime),
          fill.tradeTime.toUtc().toIso8601String(),
        ],
    ];
    return const ListToCsvConverter().convert(rows);
  }

  String _formatLocal(DateTime value) => _localFormat.format(value.toLocal());
}
