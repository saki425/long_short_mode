import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/strategy/risk/risk_manager.dart';

void main() {
  test('reduceOnly futures close is not blocked by opening order cap', () {
    final manager = RiskManager(
      maxFuturesOrderNotional: Decimal.fromInt(5),
      maxFuturesShortNotional: Decimal.fromInt(10),
    );

    final decision = manager.validateFuturesOrder(
      notional: Decimal.fromInt(6),
      side: 'BUY',
      reduceOnly: true,
      currentShortNotional: Decimal.fromInt(6),
      currentLongNotional: Decimal.zero,
    );

    expect(decision.allowed, isTrue);
  });

  test('non reduceOnly futures order remains capped', () {
    final manager = RiskManager(
      maxFuturesOrderNotional: Decimal.fromInt(5),
      maxFuturesShortNotional: Decimal.fromInt(10),
    );

    final decision = manager.validateFuturesOrder(
      notional: Decimal.fromInt(6),
      side: 'SELL',
      reduceOnly: false,
      currentShortNotional: Decimal.zero,
      currentLongNotional: Decimal.zero,
    );

    expect(decision.allowed, isFalse);
  });

  test('hedge short may open while long exposure exists', () {
    final manager = RiskManager(
      maxFuturesOrderNotional: Decimal.fromInt(20),
      maxFuturesShortNotional: Decimal.fromInt(50),
    );

    final decision = manager.validateFuturesOrder(
      notional: Decimal.fromInt(10),
      side: 'SELL',
      reduceOnly: false,
      allowExistingLongExposure: true,
      currentShortNotional: Decimal.zero,
      currentLongNotional: Decimal.fromInt(25),
    );

    expect(decision.allowed, isTrue);
  });
}
