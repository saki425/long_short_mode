import 'package:decimal/decimal.dart';

import 'futures_mark_price.dart';
import 'spot_book_ticker.dart';

class MarketTick {
  const MarketTick({
    required this.symbol,
    this.spot,
    this.futures,
  });

  final String symbol;
  final SpotBookTicker? spot;
  final FuturesMarkPrice? futures;

  Decimal? get spotMidPrice => spot?.midPrice;
  Decimal? get futuresMarkPrice => futures?.markPrice;
  Decimal? get basis {
    final spotMid = spotMidPrice;
    final mark = futuresMarkPrice;
    if (spotMid == null || mark == null) {
      return null;
    }
    return mark - spotMid;
  }

  Decimal? get basisPercent {
    final spotMid = spotMidPrice;
    final basisValue = basis;
    if (spotMid == null || basisValue == null || spotMid == Decimal.zero) {
      return null;
    }
    return (basisValue / spotMid).toDecimal(scaleOnInfinitePrecision: 12) * Decimal.fromInt(100);
  }
}
