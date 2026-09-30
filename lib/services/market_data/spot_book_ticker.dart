import 'package:decimal/decimal.dart';

class SpotBookTicker {
  const SpotBookTicker({
    required this.symbol,
    required this.bidPrice,
    required this.bidQuantity,
    required this.askPrice,
    required this.askQuantity,
    required this.receivedAt,
    this.exchangeEventTime,
  });

  final String symbol;
  final Decimal bidPrice;
  final Decimal bidQuantity;
  final Decimal askPrice;
  final Decimal askQuantity;
  final DateTime receivedAt;
  final DateTime? exchangeEventTime;

  Decimal get midPrice => ((bidPrice + askPrice) / Decimal.fromInt(2)).toDecimal(scaleOnInfinitePrecision: 12);
  Decimal get spread => askPrice - bidPrice;
  Decimal get spreadPercent => midPrice == Decimal.zero
      ? Decimal.zero
      : (spread / midPrice).toDecimal(scaleOnInfinitePrecision: 12) * Decimal.fromInt(100);

  static SpotBookTicker fromJson(Map<String, dynamic> json, {DateTime? receivedAt}) {
    final symbol = json['s'] as String?;
    final bidPrice = Decimal.tryParse('${json['b'] ?? ''}');
    final bidQuantity = Decimal.tryParse('${json['B'] ?? ''}');
    final askPrice = Decimal.tryParse('${json['a'] ?? ''}');
    final askQuantity = Decimal.tryParse('${json['A'] ?? ''}');
    if (symbol == null || bidPrice == null || bidQuantity == null || askPrice == null || askQuantity == null) {
      throw const FormatException('Invalid spot bookTicker payload');
    }
    final eventTime = json['E'];
    return SpotBookTicker(
      symbol: symbol,
      bidPrice: bidPrice,
      bidQuantity: bidQuantity,
      askPrice: askPrice,
      askQuantity: askQuantity,
      receivedAt: receivedAt ?? DateTime.now().toUtc(),
      exchangeEventTime: eventTime is int ? DateTime.fromMillisecondsSinceEpoch(eventTime, isUtc: true) : null,
    );
  }
}
