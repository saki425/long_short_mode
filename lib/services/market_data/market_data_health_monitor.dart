import 'market_data_status.dart';

class MarketDataHealthMonitor {
  const MarketDataHealthMonitor({
    this.warningTimeout = const Duration(seconds: 5),
    this.staleTimeout = const Duration(seconds: 15),
  });

  final Duration warningTimeout;
  final Duration staleTimeout;

  MarketConnectionStatus evaluate(DateTime? lastReceivedAt, DateTime now, MarketConnectionStatus current) {
    if (lastReceivedAt == null) {
      return current;
    }
    final age = now.difference(lastReceivedAt);
    if (age >= staleTimeout) {
      return MarketConnectionStatus.stale;
    }
    return current;
  }

  bool isStale(DateTime? lastReceivedAt, DateTime now) => evaluate(lastReceivedAt, now, MarketConnectionStatus.ready) == MarketConnectionStatus.stale;
}
