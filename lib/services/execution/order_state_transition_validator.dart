class OrderStateTransitionValidator {
  const OrderStateTransitionValidator();

  static const Set<String> terminalStates = {
    'filled',
    'cancelled',
    'rejected',
    'expired',
  };

  static const Map<String, Set<String>> _allowed = {
    'planned': {'created', 'submitting', 'cancelled', 'unknown'},
    'created': {'submitting', 'new', 'partiallyFilled', 'filled', 'unknown'},
    'submitting': {
      'new',
      'partiallyFilled',
      'filled',
      'rejected',
      'expired',
      'unknown',
    },
    'new': {
      'partiallyFilled',
      'filled',
      'cancelling',
      'cancelled',
      'rejected',
      'expired',
      'unknown',
    },
    'partiallyFilled': {'filled', 'cancelling', 'cancelled', 'unknown'},
    'cancelling': {'cancelled', 'filled', 'partiallyFilled', 'unknown'},
    'unknown': {
      'new',
      'partiallyFilled',
      'filled',
      'cancelled',
      'rejected',
      'expired',
    },
  };

  bool canTransition(String from, String to) {
    if (from == to) {
      return true;
    }
    if (terminalStates.contains(from)) {
      return false;
    }
    return _allowed[from]?.contains(to) ?? false;
  }
}
