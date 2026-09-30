import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/services/execution/order_state_transition_validator.dart';

void main() {
  const validator = OrderStateTransitionValidator();

  test('allows normal live spot order transitions', () {
    expect(validator.canTransition('created', 'submitting'), isTrue);
    expect(validator.canTransition('submitting', 'new'), isTrue);
    expect(validator.canTransition('new', 'partiallyFilled'), isTrue);
    expect(validator.canTransition('partiallyFilled', 'filled'), isTrue);
    expect(validator.canTransition('new', 'cancelled'), isTrue);
  });

  test('blocks terminal state rollback', () {
    expect(validator.canTransition('filled', 'new'), isFalse);
    expect(validator.canTransition('cancelled', 'new'), isFalse);
    expect(validator.canTransition('rejected', 'submitting'), isFalse);
    expect(validator.canTransition('expired', 'new'), isFalse);
  });

  test('blocks unsafe direct transitions', () {
    expect(validator.canTransition('submitting', 'cancelled'), isFalse);
    expect(validator.canTransition('created', 'cancelled'), isFalse);
    expect(validator.canTransition('planned', 'filled'), isFalse);
  });

  test('allows idempotent same-state event replay', () {
    expect(validator.canTransition('new', 'new'), isTrue);
    expect(
      validator.canTransition('partiallyFilled', 'partiallyFilled'),
      isTrue,
    );
    expect(validator.canTransition('filled', 'filled'), isTrue);
  });
}
