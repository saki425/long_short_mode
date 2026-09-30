import 'dart:math' as math;

import 'package:decimal/decimal.dart';

import '../../models/paper_strategy_config.dart';

class GridGenerator {
  const GridGenerator();

  List<GeneratedGridLevel> generate(PaperStrategyConfig config) {
    final prices = config.gridMode == 'arithmetic' ? _arithmeticPrices(config) : _geometricPrices(config);
    final plannedPrices = prices.where((price) => price != config.centerPrice).toList();
    final perGridQuote = (config.spotCapital / Decimal.fromInt(plannedPrices.length)).toDecimal(scaleOnInfinitePrecision: 8);
    final levels = <GeneratedGridLevel>[];
    for (var i = 0; i < prices.length; i++) {
      final price = prices[i];
      if (price == config.centerPrice) {
        continue;
      }
      final side = price < config.centerPrice ? 'BUY' : 'SELL';
      final quantity = (perGridQuote / price).toDecimal(scaleOnInfinitePrecision: 8);
      levels.add(
        GeneratedGridLevel(
          index: i,
          price: _scale(price, 2),
          nextLowerPrice: i == 0 ? null : _scale(prices[i - 1], 2),
          nextUpperPrice: i == prices.length - 1 ? null : _scale(prices[i + 1], 2),
          side: side,
          quantity: _scale(quantity, 8),
          quoteAmount: _scale(perGridQuote, 8),
        ),
      );
    }
    return levels;
  }

  List<Decimal> _geometricPrices(PaperStrategyConfig config) {
    final lower = config.lowerPrice.toDouble();
    final upper = config.upperPrice.toDouble();
    final ratio = math.pow(upper / lower, 1 / config.gridCount).toDouble();
    return [
      for (var i = 0; i <= config.gridCount; i++) Decimal.parse((lower * math.pow(ratio, i)).toStringAsFixed(8)),
    ];
  }

  List<Decimal> _arithmeticPrices(PaperStrategyConfig config) {
    final step = ((config.upperPrice - config.lowerPrice) / Decimal.fromInt(config.gridCount)).toDecimal(scaleOnInfinitePrecision: 8);
    return [
      for (var i = 0; i <= config.gridCount; i++) config.lowerPrice + step * Decimal.fromInt(i),
    ];
  }

  Decimal _scale(Decimal value, int scale) => Decimal.parse(value.toStringAsFixed(scale));
}
