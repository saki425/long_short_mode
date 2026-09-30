import 'package:decimal/decimal.dart';

import '../binance/trading/binance_symbol_rules.dart';

abstract class ExchangeExecutionService {
  Future<void> connect();
  Future<void> disconnect();

  Future<void> refreshSpotSnapshot();
  Future<void> refreshFuturesSnapshot();

  Future<String> placeSpotLimitOrder({
    required String side,
    required Decimal quantity,
    required Decimal price,
  });

  Future<String> placeSpotMarketOrder({
    required String side,
    Decimal? quantity,
    Decimal? quoteOrderQty,
  });

  Future<void> cancelSpotOrder(String clientOrderId);

  Future<String> placeFuturesLimitOrder({
    required String side,
    required Decimal quantity,
    required Decimal price,
    required bool reduceOnly,
    String symbol = 'BTCUSDT',
    String? positionSide,
    String? gridLevelId,
    int leverage = 1,
    String purpose = 'liveTradingVerification',
    String source = 'manualTest',
    String? strategyId,
  });

  Future<String> placeFuturesMarketOrder({
    required String side,
    required Decimal quantity,
    required bool reduceOnly,
    String symbol = 'BTCUSDT',
    String? positionSide,
    String? gridLevelId,
    int leverage = 1,
    String purpose = 'liveTradingVerification',
    String source = 'manualTest',
    String? strategyId,
  });

  Future<void> cancelFuturesOrder(String clientOrderId,
      {String symbol = 'BTCUSDT'});

  Future<void> emergencyExit({required bool sellSpot});

  BinanceSymbolRules? get spotRules;
  BinanceSymbolRules? get futuresRules;
}
