enum MarketDataMode { mockManual, mockRandom, binanceLive }

enum MarketConnectionStatus {
  disconnected,
  connecting,
  connected,
  waitingFirstData,
  ready,
  reconnecting,
  stale,
  error,
  stopped,
  reconciling,
}

class MarketDataStatus {
  const MarketDataStatus({
    required this.mode,
    required this.overallStatus,
    required this.spotConnectionStatus,
    required this.futuresConnectionStatus,
    this.lastSpotReceivedAt,
    this.lastFuturesReceivedAt,
    this.lastConnectedAt,
    this.reconnectCount = 0,
    this.reconnectDelay,
    this.lastError,
  });

  final MarketDataMode mode;
  final MarketConnectionStatus overallStatus;
  final MarketConnectionStatus spotConnectionStatus;
  final MarketConnectionStatus futuresConnectionStatus;
  final DateTime? lastSpotReceivedAt;
  final DateTime? lastFuturesReceivedAt;
  final DateTime? lastConnectedAt;
  final int reconnectCount;
  final Duration? reconnectDelay;
  final String? lastError;

  bool get isReady => overallStatus == MarketConnectionStatus.ready;

  MarketDataStatus copyWith({
    MarketDataMode? mode,
    MarketConnectionStatus? overallStatus,
    MarketConnectionStatus? spotConnectionStatus,
    MarketConnectionStatus? futuresConnectionStatus,
    DateTime? lastSpotReceivedAt,
    DateTime? lastFuturesReceivedAt,
    DateTime? lastConnectedAt,
    int? reconnectCount,
    Duration? reconnectDelay,
    String? lastError,
  }) {
    return MarketDataStatus(
      mode: mode ?? this.mode,
      overallStatus: overallStatus ?? this.overallStatus,
      spotConnectionStatus: spotConnectionStatus ?? this.spotConnectionStatus,
      futuresConnectionStatus:
          futuresConnectionStatus ?? this.futuresConnectionStatus,
      lastSpotReceivedAt: lastSpotReceivedAt ?? this.lastSpotReceivedAt,
      lastFuturesReceivedAt:
          lastFuturesReceivedAt ?? this.lastFuturesReceivedAt,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      reconnectCount: reconnectCount ?? this.reconnectCount,
      reconnectDelay: reconnectDelay ?? this.reconnectDelay,
      lastError: lastError ?? this.lastError,
    );
  }

  static const initial = MarketDataStatus(
    mode: MarketDataMode.mockManual,
    overallStatus: MarketConnectionStatus.disconnected,
    spotConnectionStatus: MarketConnectionStatus.disconnected,
    futuresConnectionStatus: MarketConnectionStatus.disconnected,
  );
}
