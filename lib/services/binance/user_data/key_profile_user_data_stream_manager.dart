import 'dart:async';

class KeyProfileUserDataEvent {
  const KeyProfileUserDataEvent({
    required this.keyProfileId,
    required this.symbol,
    required this.accountType,
    required this.payload,
  });

  final String keyProfileId;
  final String symbol;
  final String accountType;
  final Object payload;
}

class KeyProfileUserDataSession {
  const KeyProfileUserDataSession({
    required this.keyProfileId,
    required this.accountType,
    required this.boundSymbols,
    required this.createdAt,
  });

  final String keyProfileId;
  final String accountType;
  final Set<String> boundSymbols;
  final DateTime createdAt;

  KeyProfileUserDataSession copyWith({Set<String>? boundSymbols}) {
    return KeyProfileUserDataSession(
      keyProfileId: keyProfileId,
      accountType: accountType,
      boundSymbols: boundSymbols ?? this.boundSymbols,
      createdAt: createdAt,
    );
  }
}

class KeyProfileUserDataStreamManager {
  final Map<String, KeyProfileUserDataSession> _spotSessions = {};
  final Map<String, KeyProfileUserDataSession> _futuresSessions = {};
  final StreamController<KeyProfileUserDataEvent> _controller =
      StreamController.broadcast();

  Stream<KeyProfileUserDataEvent> get events => _controller.stream;

  int get spotSessionCount => _spotSessions.length;
  int get futuresSessionCount => _futuresSessions.length;

  Map<String, KeyProfileUserDataSession> get spotSessions =>
      Map.unmodifiable(_spotSessions);

  Map<String, KeyProfileUserDataSession> get futuresSessions =>
      Map.unmodifiable(_futuresSessions);

  KeyProfileUserDataSession ensureSpotProfile({
    required String keyProfileId,
    required Iterable<String> symbols,
  }) {
    return _ensureProfile(
      sessions: _spotSessions,
      keyProfileId: keyProfileId,
      accountType: 'spot',
      symbols: symbols,
    );
  }

  KeyProfileUserDataSession ensureFuturesProfile({
    required String keyProfileId,
    required Iterable<String> symbols,
  }) {
    return _ensureProfile(
      sessions: _futuresSessions,
      keyProfileId: keyProfileId,
      accountType: 'futures',
      symbols: symbols,
    );
  }

  void removeSpotProfile(String keyProfileId) {
    _spotSessions.remove(keyProfileId);
  }

  void removeFuturesProfile(String keyProfileId) {
    _futuresSessions.remove(keyProfileId);
  }

  void dispatchSpotEvent({
    required String keyProfileId,
    required String symbol,
    required Object payload,
  }) {
    _dispatch(
      sessions: _spotSessions,
      keyProfileId: keyProfileId,
      symbol: symbol,
      accountType: 'spot',
      payload: payload,
    );
  }

  void dispatchFuturesEvent({
    required String keyProfileId,
    required String symbol,
    required Object payload,
  }) {
    _dispatch(
      sessions: _futuresSessions,
      keyProfileId: keyProfileId,
      symbol: symbol,
      accountType: 'futures',
      payload: payload,
    );
  }

  Future<void> dispose() async {
    _spotSessions.clear();
    _futuresSessions.clear();
    await _controller.close();
  }

  KeyProfileUserDataSession _ensureProfile({
    required Map<String, KeyProfileUserDataSession> sessions,
    required String keyProfileId,
    required String accountType,
    required Iterable<String> symbols,
  }) {
    final normalizedSymbols =
        symbols.map((symbol) => symbol.toUpperCase()).toSet();
    final existing = sessions[keyProfileId];
    if (existing == null) {
      final session = KeyProfileUserDataSession(
        keyProfileId: keyProfileId,
        accountType: accountType,
        boundSymbols: normalizedSymbols,
        createdAt: DateTime.now().toUtc(),
      );
      sessions[keyProfileId] = session;
      return session;
    }
    final merged = existing.copyWith(
      boundSymbols: {...existing.boundSymbols, ...normalizedSymbols},
    );
    sessions[keyProfileId] = merged;
    return merged;
  }

  void _dispatch({
    required Map<String, KeyProfileUserDataSession> sessions,
    required String keyProfileId,
    required String symbol,
    required String accountType,
    required Object payload,
  }) {
    final normalizedSymbol = symbol.toUpperCase();
    final session = sessions[keyProfileId];
    if (session == null || !session.boundSymbols.contains(normalizedSymbol)) {
      return;
    }
    if (!_controller.isClosed) {
      _controller.add(
        KeyProfileUserDataEvent(
          keyProfileId: keyProfileId,
          symbol: normalizedSymbol,
          accountType: accountType,
          payload: payload,
        ),
      );
    }
  }
}
