import 'package:decimal/decimal.dart';

class BinanceSymbolRules {
  const BinanceSymbolRules({
    required this.symbol,
    required this.marketType,
    required this.tickSize,
    required this.stepSize,
    required this.minQty,
    required this.maxQty,
    required this.minNotional,
    required this.pricePrecision,
    required this.quantityPrecision,
  });

  final String symbol;
  final String marketType;
  final Decimal tickSize;
  final Decimal stepSize;
  final Decimal minQty;
  final Decimal maxQty;
  final Decimal minNotional;
  final int pricePrecision;
  final int quantityPrecision;

  Decimal quantizePrice(Decimal price) => _floorToStep(price, tickSize);

  Decimal quantizeQuantity(Decimal quantity) =>
      _floorToStep(quantity, stepSize);

  Decimal notional(Decimal price, Decimal quantity) => price * quantity;

  bool isQuantityAcceptable(Decimal quantity) {
    final q = quantizeQuantity(quantity);
    return q >= minQty && q <= maxQty;
  }

  bool isNotionalAcceptable(Decimal price, Decimal quantity) {
    return notional(price, quantity) >= minNotional;
  }

  bool isAcceptableOrder({required Decimal price, required Decimal quantity}) {
    return isQuantityAcceptable(quantity) &&
        isNotionalAcceptable(price, quantity);
  }

  static Decimal _floorToStep(Decimal value, Decimal step) {
    if (step == Decimal.zero) {
      return value;
    }
    final ratio = (value / step).toDecimal(scaleOnInfinitePrecision: 18);
    return ratio.floor() * step;
  }
}
