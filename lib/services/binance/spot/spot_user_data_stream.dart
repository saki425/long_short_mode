import 'dart:convert';

import 'package:decimal/decimal.dart';

import 'spot_account_models.dart';

class SpotUserDataEvent {
  const SpotUserDataEvent({
    required this.eventType,
    required this.eventTime,
    required this.dedupeKey,
  });

  final String eventType;
  final DateTime eventTime;
  final String dedupeKey;
}

class SpotBalanceUpdateEvent extends SpotUserDataEvent {
  const SpotBalanceUpdateEvent({
    required super.eventType,
    required super.eventTime,
    required super.dedupeKey,
    required this.balances,
  });

  final List<SpotAssetBalance> balances;
}

class SpotExecutionReportEvent extends SpotUserDataEvent {
  const SpotExecutionReportEvent({
    required super.eventType,
    required super.eventTime,
    required super.dedupeKey,
    required this.symbol,
    required this.clientOrderId,
    required this.side,
    required this.orderType,
    required this.orderStatus,
    required this.executionType,
    required this.orderId,
    required this.lastExecutedQuantity,
    required this.cumulativeFilledQuantity,
    required this.lastExecutedPrice,
    required this.commission,
    required this.commissionAsset,
    required this.tradeId,
  });

  final String symbol;
  final String clientOrderId;
  final String side;
  final String orderType;
  final String orderStatus;
  final String executionType;
  final String orderId;
  final Decimal lastExecutedQuantity;
  final Decimal cumulativeFilledQuantity;
  final Decimal lastExecutedPrice;
  final Decimal commission;
  final String commissionAsset;
  final String tradeId;
}

class SpotUserDataStreamParser {
  final Set<String> _seen = <String>{};

  SpotUserDataEvent? parse(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! Map) return null;
    final json = Map<String, dynamic>.from(decoded);
    final eventType = json['e']?.toString() ?? '';
    if (eventType == 'outboundAccountPosition') {
      final event = SpotBalanceUpdateEvent(
        eventType: eventType,
        eventTime: timeFromMs(json['E']),
        dedupeKey: '$eventType-${json['E']}',
        balances: (json['B'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => SpotAssetBalance(
                  asset: item['a']?.toString() ?? '',
                  free: decimalFromJson(item['f']),
                  locked: decimalFromJson(item['l']),
                ))
            .toList(),
      );
      return _dedupe(event);
    }
    if (eventType == 'executionReport') {
      final tradeId = json['t']?.toString() ?? '';
      final orderId = json['i']?.toString() ?? '';
      final event = SpotExecutionReportEvent(
        eventType: eventType,
        eventTime: timeFromMs(json['E']),
        dedupeKey: '$eventType-$orderId-${json['X']}-$tradeId-${json['E']}',
        symbol: json['s']?.toString() ?? '',
        clientOrderId: json['c']?.toString() ?? '',
        side: json['S']?.toString() ?? '',
        orderType: json['o']?.toString() ?? '',
        orderStatus: json['X']?.toString() ?? '',
        executionType: json['x']?.toString() ?? '',
        orderId: orderId,
        lastExecutedQuantity: decimalFromJson(json['l']),
        cumulativeFilledQuantity: decimalFromJson(json['z']),
        lastExecutedPrice: decimalFromJson(json['L']),
        commission: decimalFromJson(json['n']),
        commissionAsset: json['N']?.toString() ?? '',
        tradeId: tradeId,
      );
      return _dedupe(event);
    }
    return null;
  }

  T? _dedupe<T extends SpotUserDataEvent>(T event) {
    if (!_seen.add(event.dedupeKey)) return null;
    return event;
  }
}
