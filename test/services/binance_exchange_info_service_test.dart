import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/services/binance/trading/binance_exchange_info_service.dart';

void main() {
  test('futures BTCUSDT rules prefer MARKET_LOT_SIZE for market quantity', () {
    final rules = BinanceExchangeInfoService.parseFuturesSymbolRules({
      'symbols': [
        {
          'symbol': 'BTCUSDT',
          'pricePrecision': 2,
          'quantityPrecision': 6,
          'filters': [
            {'filterType': 'PRICE_FILTER', 'tickSize': '0.10'},
            {
              'filterType': 'LOT_SIZE',
              'minQty': '0.001',
              'maxQty': '1000',
              'stepSize': '0.001',
            },
            {
              'filterType': 'MARKET_LOT_SIZE',
              'minQty': '0.000001',
              'maxQty': '1000',
              'stepSize': '0.000001',
            },
            {'filterType': 'MIN_NOTIONAL', 'notional': '5'},
          ],
        },
      ],
    }, symbol: 'BTCUSDT');

    expect(rules.stepSize, Decimal.parse('0.000001'));
    expect(rules.minQty, Decimal.parse('0.000001'));
    expect(rules.minNotional, Decimal.fromInt(5));
    expect(
      rules.quantizeQuantity(Decimal.parse('0.00033')),
      Decimal.parse('0.00033'),
    );
  });
}
