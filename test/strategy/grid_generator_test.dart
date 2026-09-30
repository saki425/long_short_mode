import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/models/paper_strategy_config.dart';
import 'package:grid_hedge_trader/strategy/grid/grid_generator.dart';

void main() {
  test('generates geometric grid around center', () {
    final config = PaperStrategyConfig.defaults(centerPrice: Decimal.fromInt(60000));
    final levels = const GridGenerator().generate(config);

    expect(levels, hasLength(13));
    expect(levels.where((level) => level.side == 'BUY'), isNotEmpty);
    expect(levels.where((level) => level.side == 'SELL'), isNotEmpty);
    expect(levels.every((level) => level.quantity > Decimal.zero), isTrue);
  });

  test('generates arithmetic grid with stable boundaries', () {
    final config = PaperStrategyConfig.defaults(centerPrice: Decimal.fromInt(60000));
    final arithmetic = PaperStrategyConfig(
      name: config.name,
      symbol: config.symbol,
      centerPrice: config.centerPrice,
      lowerPrice: config.lowerPrice,
      upperPrice: config.upperPrice,
      gridCount: config.gridCount,
      gridSpacingPercent: config.gridSpacingPercent,
      gridMode: 'arithmetic',
      spotCapital: config.spotCapital,
      futuresCapital: config.futuresCapital,
      reserveCapital: config.reserveCapital,
      hedgeRatio: config.hedgeRatio,
      maxLossUsdt: config.maxLossUsdt,
      maxExposureUsdt: config.maxExposureUsdt,
      feeRate: config.feeRate,
      fundingRatePerTick: config.fundingRatePerTick,
      minHedgeQuantity: config.minHedgeQuantity,
    );

    final levels = const GridGenerator().generate(arithmetic);

    expect(levels.first.price, Decimal.fromInt(56400));
    expect(levels.last.price, Decimal.fromInt(63600));
  });
}
