import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/services/execution/live_trading_gate_service.dart';

void main() {
  test('live trading gate resets to disabled on app start', () {
    final gate = LiveTradingGateService();

    expect(gate.liveTradingEnabled.value, isFalse);

    gate.setEnabled(true);
    expect(gate.liveTradingEnabled.value, isTrue);

    gate.resetForAppStart();
    expect(gate.liveTradingEnabled.value, isFalse);
    expect(gate.warningConfirmed.value, isFalse);
  });

  test('activity does not disable live trading during the same app run', () {
    final gate = LiveTradingGateService();

    gate.setEnabled(true);
    gate.markActivity();
    gate.markActivity();

    expect(gate.liveTradingEnabled.value, isTrue);
    expect(gate.warningConfirmed.value, isTrue);
    expect(gate.disableReason.value, isEmpty);
  });
}
