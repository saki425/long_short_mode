import 'package:decimal/decimal.dart';

class PaperStrategyConfig {
  const PaperStrategyConfig({
    required this.name,
    required this.symbol,
    required this.centerPrice,
    required this.lowerPrice,
    required this.upperPrice,
    required this.gridCount,
    required this.gridSpacingPercent,
    required this.gridMode,
    required this.spotCapital,
    required this.futuresCapital,
    required this.reserveCapital,
    required this.hedgeRatio,
    required this.maxLossUsdt,
    required this.maxExposureUsdt,
    required this.feeRate,
    required this.fundingRatePerTick,
    required this.minHedgeQuantity,
  });

  final String name;
  final String symbol;
  final Decimal centerPrice;
  final Decimal lowerPrice;
  final Decimal upperPrice;
  final int gridCount;
  final Decimal gridSpacingPercent;
  final String gridMode;
  final Decimal spotCapital;
  final Decimal futuresCapital;
  final Decimal reserveCapital;
  final Decimal hedgeRatio;
  final Decimal maxLossUsdt;
  final Decimal maxExposureUsdt;
  final Decimal feeRate;
  final Decimal fundingRatePerTick;
  final Decimal minHedgeQuantity;

  static PaperStrategyConfig defaults({Decimal? centerPrice}) {
    final center = centerPrice ?? Decimal.fromInt(60000);
    return PaperStrategyConfig(
      name: 'BTCUSDT Paper Grid Hedge',
      symbol: 'BTCUSDT',
      centerPrice: center,
      lowerPrice: center * Decimal.parse('0.94'),
      upperPrice: center * Decimal.parse('1.06'),
      gridCount: 12,
      gridSpacingPercent: Decimal.fromInt(1),
      gridMode: 'geometric',
      spotCapital: Decimal.fromInt(700),
      futuresCapital: Decimal.fromInt(250),
      reserveCapital: Decimal.fromInt(50),
      hedgeRatio: Decimal.fromInt(1),
      maxLossUsdt: Decimal.fromInt(50),
      maxExposureUsdt: Decimal.fromInt(100),
      feeRate: Decimal.parse('0.001'),
      fundingRatePerTick: Decimal.parse('0.000001'),
      minHedgeQuantity: Decimal.parse('0.0015'),
    );
  }
}

class GeneratedGridLevel {
  const GeneratedGridLevel({
    required this.index,
    required this.price,
    required this.nextLowerPrice,
    required this.nextUpperPrice,
    required this.side,
    required this.quantity,
    required this.quoteAmount,
  });

  final int index;
  final Decimal price;
  final Decimal? nextLowerPrice;
  final Decimal? nextUpperPrice;
  final String side;
  final Decimal quantity;
  final Decimal quoteAmount;
}
