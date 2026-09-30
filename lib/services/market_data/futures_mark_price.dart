import 'package:decimal/decimal.dart';

class FuturesMarkPrice {
  const FuturesMarkPrice({
    required this.symbol,
    required this.markPrice,
    required this.indexPrice,
    required this.estimatedSettlePrice,
    required this.fundingRate,
    required this.nextFundingTime,
    required this.eventTime,
    required this.receivedAt,
  });

  final String symbol;
  final Decimal markPrice;
  final Decimal indexPrice;
  final Decimal? estimatedSettlePrice;
  final Decimal fundingRate;
  final DateTime nextFundingTime;
  final DateTime eventTime;
  final DateTime receivedAt;

  static FuturesMarkPrice fromJson(Map<String, dynamic> json, {DateTime? receivedAt}) {
    final symbol = json['s'] as String?;
    final markPrice = Decimal.tryParse('${json['p'] ?? ''}');
    final indexPrice = Decimal.tryParse('${json['i'] ?? ''}');
    final estimatedSettlePrice = Decimal.tryParse('${json['P'] ?? ''}');
    final fundingRate = Decimal.tryParse('${json['r'] ?? ''}');
    final eventTime = json['E'];
    final nextFundingTime = json['T'];
    if (symbol == null || markPrice == null || indexPrice == null || fundingRate == null || eventTime is! int || nextFundingTime is! int) {
      throw const FormatException('Invalid futures markPrice payload');
    }
    return FuturesMarkPrice(
      symbol: symbol,
      markPrice: markPrice,
      indexPrice: indexPrice,
      estimatedSettlePrice: estimatedSettlePrice,
      fundingRate: fundingRate,
      nextFundingTime: DateTime.fromMillisecondsSinceEpoch(nextFundingTime, isUtc: true),
      eventTime: DateTime.fromMillisecondsSinceEpoch(eventTime, isUtc: true),
      receivedAt: receivedAt ?? DateTime.now().toUtc(),
    );
  }
}
