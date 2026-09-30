import 'dart:convert';

import '../spot/spot_account_models.dart';

class FuturesUserDataEvent {
  const FuturesUserDataEvent({
    required this.eventType,
    required this.eventTime,
    required this.dedupeKey,
  });

  final String eventType;
  final DateTime eventTime;
  final String dedupeKey;
}

class FuturesAccountUpdateEvent extends FuturesUserDataEvent {
  const FuturesAccountUpdateEvent({
    required super.eventType,
    required super.eventTime,
    required super.dedupeKey,
    required this.reason,
    required this.balances,
    required this.positions,
  });

  final String reason;
  final List<Map<String, String>> balances;
  final List<Map<String, String>> positions;
}

class FuturesOrderTradeUpdateEvent extends FuturesUserDataEvent {
  const FuturesOrderTradeUpdateEvent({
    required super.eventType,
    required super.eventTime,
    required super.dedupeKey,
    required this.symbol,
    required this.clientOrderId,
    required this.side,
    required this.positionSide,
    required this.orderType,
    required this.status,
    required this.executionType,
    required this.orderId,
    required this.tradeId,
  });

  final String symbol;
  final String clientOrderId;
  final String side;
  final String positionSide;
  final String orderType;
  final String status;
  final String executionType;
  final String orderId;
  final String tradeId;
}

class FuturesUserDataStreamParser {
  final Set<String> _seen = <String>{};

  FuturesUserDataEvent? parse(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! Map) return null;
    final json = Map<String, dynamic>.from(decoded);
    final eventType = json['e']?.toString() ?? '';
    if (eventType == 'ACCOUNT_UPDATE') {
      final account = Map<String, dynamic>.from(json['a'] as Map? ?? const {});
      final event = FuturesAccountUpdateEvent(
        eventType: eventType,
        eventTime: timeFromMs(json['E']),
        dedupeKey: '$eventType-${json['E']}-${account['m']}',
        reason: account['m']?.toString() ?? '',
        balances: (account['B'] as List? ?? const []).whereType<Map>().map((item) => item.map((key, value) => MapEntry(key.toString(), value.toString()))).toList(),
        positions: (account['P'] as List? ?? const []).whereType<Map>().map((item) => item.map((key, value) => MapEntry(key.toString(), value.toString()))).toList(),
      );
      return _dedupe(event);
    }
    if (eventType == 'ORDER_TRADE_UPDATE') {
      final order = Map<String, dynamic>.from(json['o'] as Map? ?? const {});
      final tradeId = order['t']?.toString() ?? '';
      final orderId = order['i']?.toString() ?? '';
      final event = FuturesOrderTradeUpdateEvent(
        eventType: eventType,
        eventTime: timeFromMs(json['E']),
        dedupeKey: '$eventType-$orderId-${order['X']}-$tradeId-${json['E']}',
        symbol: order['s']?.toString() ?? '',
        clientOrderId: order['c']?.toString() ?? '',
        side: order['S']?.toString() ?? '',
        positionSide: order['ps']?.toString() ?? 'BOTH',
        orderType: order['o']?.toString() ?? '',
        status: order['X']?.toString() ?? '',
        executionType: order['x']?.toString() ?? '',
        orderId: orderId,
        tradeId: tradeId,
      );
      return _dedupe(event);
    }
    return null;
  }

  T? _dedupe<T extends FuturesUserDataEvent>(T event) {
    if (!_seen.add(event.dedupeKey)) return null;
    return event;
  }
}
