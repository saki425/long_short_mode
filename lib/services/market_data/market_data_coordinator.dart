import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';
import '../../repositories/basic_repositories.dart';
import 'binance_futures_market_stream.dart';
import 'binance_spot_market_stream.dart';
import 'futures_mark_price.dart';
import 'futures_ws_diagnostics.dart';
import 'market_data_health_monitor.dart';
import 'market_data_service.dart';
import 'market_data_status.dart';
import 'market_tick.dart';
import 'spot_book_ticker.dart';

class MarketDataCoordinator implements MarketDataService {
  MarketDataCoordinator({
    required this.db,
    BinanceSpotMarketStream? spotStream,
    BinanceFuturesMarketStream? futuresStream,
    LogRepository? logRepository,
    MarketDataHealthMonitor healthMonitor = const MarketDataHealthMonitor(),
  })  : _spotStream = spotStream ?? BinanceSpotMarketStream(),
        _futuresStream = futuresStream ??
            BinanceFuturesMarketStream(logRepository: logRepository),
        _healthMonitor = healthMonitor;

  final AppDatabase db;
  final BinanceSpotMarketStream _spotStream;
  final BinanceFuturesMarketStream _futuresStream;
  final MarketDataHealthMonitor _healthMonitor;
  final Uuid _uuid = const Uuid();

  final StreamController<SpotBookTicker> _spotController =
      StreamController.broadcast();
  final StreamController<FuturesMarkPrice> _futuresController =
      StreamController.broadcast();
  final StreamController<MarketDataStatus> _statusController =
      StreamController.broadcast();
  final StreamController<MarketTick> _uiController =
      StreamController.broadcast();
  final StreamController<Map<String, MarketTick>> _allTicksController =
      StreamController.broadcast();
  final StreamController<FuturesWsDiagnostics> _futuresDiagnosticsController =
      StreamController.broadcast();

  StreamSubscription<MarketStreamEvent<SpotBookTicker>>? _spotSubscription;
  StreamSubscription<MarketStreamEvent<FuturesMarkPrice>>? _futuresSubscription;
  StreamSubscription<FuturesWsDiagnostics>? _futuresDiagnosticsSubscription;
  final Map<String, BinanceSpotMarketStream> _spotStreams = {};
  final Map<String, BinanceFuturesMarketStream> _futuresStreams = {};
  final Map<String, StreamSubscription<MarketStreamEvent<SpotBookTicker>>>
      _spotSubscriptionsBySymbol = {};
  final Map<String, StreamSubscription<MarketStreamEvent<FuturesMarkPrice>>>
      _futuresSubscriptionsBySymbol = {};
  final Map<String, StreamSubscription<FuturesWsDiagnostics>>
      _futuresDiagnosticsSubscriptionsBySymbol = {};
  Timer? _healthTimer;
  Timer? _uiThrottleTimer;
  Timer? _snapshotTimer;
  bool _uiPending = false;
  bool _lifecycleBusy = false;

  MarketDataStatus _status = MarketDataStatus.initial;
  SpotBookTicker? _latestSpot;
  FuturesMarkPrice? _latestFutures;
  final Map<String, SpotBookTicker> _latestSpotBySymbol = {};
  final Map<String, FuturesMarkPrice> _latestFuturesBySymbol = {};
  final Set<String> _workspaceSymbols = {};
  String? _activeSymbol;
  FuturesWsDiagnostics? _latestFuturesDiagnostics;

  @override
  Stream<SpotBookTicker> get spotBookTickerStream => _spotController.stream;

  @override
  Stream<FuturesMarkPrice> get futuresMarkPriceStream =>
      _futuresController.stream;

  @override
  Stream<MarketDataStatus> get statusStream => _statusController.stream;

  @override
  Stream<MarketTick> get uiMarketStream => _uiController.stream;

  Stream<Map<String, MarketTick>> get allMarketTicksStream =>
      _allTicksController.stream;

  Stream<FuturesWsDiagnostics> get futuresDiagnosticsStream =>
      _futuresDiagnosticsController.stream;

  MarketTick get currentMarketTick {
    _setActiveLatest();
    return MarketTick(
      symbol: _activeSymbol ?? _latestSpot?.symbol ?? '',
      spot: _latestSpot,
      futures: _latestFutures,
    );
  }

  Map<String, MarketTick> get currentMarketTicks => {
        for (final symbol in _workspaceSymbols)
          symbol: MarketTick(
            symbol: symbol,
            spot: _latestSpotBySymbol[symbol],
            futures: _latestFuturesBySymbol[symbol],
          ),
      };

  @override
  SpotBookTicker? get latestSpotTicker => _latestSpot;

  @override
  FuturesMarkPrice? get latestFuturesMarkPrice => _latestFutures;

  String? get activeSymbol => _activeSymbol;

  Map<String, SpotBookTicker> get latestSpotTickers =>
      Map.unmodifiable(_latestSpotBySymbol);

  SpotBookTicker? latestSpotTickerFor(String symbol) {
    return _latestSpotBySymbol[symbol.toUpperCase()];
  }

  FuturesMarkPrice? latestFuturesMarkPriceFor(String symbol) {
    return _latestFuturesBySymbol[symbol.toUpperCase()];
  }

  @override
  MarketDataStatus get status => _status;

  FuturesWsDiagnostics get futuresDiagnostics =>
      _latestFuturesDiagnostics ?? _futuresStream.diagnostics;

  Future<void> setWorkspaceSymbols(
    Iterable<String> symbols, {
    String? activeSymbol,
  }) async {
    final normalized = symbols.map((symbol) => symbol.toUpperCase()).toSet();
    _workspaceSymbols
      ..clear()
      ..addAll(normalized);
    _activeSymbol = activeSymbol?.toUpperCase() ?? _activeSymbol;
    if (_activeSymbol != null && !_workspaceSymbols.contains(_activeSymbol)) {
      _activeSymbol =
          _workspaceSymbols.isEmpty ? null : _workspaceSymbols.first;
    }
    if (_status.mode == MarketDataMode.binanceLive) {
      await _syncSymbolConnections();
    }
    _setActiveLatest();
    _scheduleUiTick();
  }

  void setActiveSymbol(String? symbol) {
    _activeSymbol = symbol?.toUpperCase();
    _setActiveLatest();
    _emitUiTickNow();
    _scheduleUiTick();
  }

  @override
  Future<void> setMode(MarketDataMode mode) async {
    if (_status.mode == mode) {
      return;
    }
    await disconnect();
    _setStatus(
      _status.copyWith(
        mode: mode,
        overallStatus: MarketConnectionStatus.disconnected,
      ),
    );
    if (mode == MarketDataMode.binanceLive) {
      await connect();
    }
  }

  @override
  Future<void> connect() async {
    await _runExclusive(() async {
      if (_status.mode != MarketDataMode.binanceLive) {
        _setStatus(
          _status.copyWith(overallStatus: MarketConnectionStatus.ready),
        );
        return;
      }
      _setStatus(
        _status.copyWith(
          overallStatus: MarketConnectionStatus.connecting,
          spotConnectionStatus: MarketConnectionStatus.connecting,
          futuresConnectionStatus: MarketConnectionStatus.connecting,
          lastConnectedAt: DateTime.now().toUtc(),
        ),
      );
      if (_workspaceSymbols.isEmpty) {
        _setStatus(
          _status.copyWith(
            overallStatus: MarketConnectionStatus.stopped,
            spotConnectionStatus: MarketConnectionStatus.stopped,
            futuresConnectionStatus: MarketConnectionStatus.stopped,
          ),
        );
        return;
      }
      await _syncSymbolConnections();
      _emitUiTickNow();
      _healthTimer ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) => checkHealth(),
      );
      _snapshotTimer ??= Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(writeMarketSnapshot()),
      );
    });
  }

  @override
  Future<void> disconnect() async {
    await _runExclusive(() async {
      final disconnects = <Future<void>>[
        for (final stream in _spotStreams.values) stream.disconnect(),
        for (final stream in _futuresStreams.values) stream.disconnect(),
      ];
      await Future.wait(disconnects);
      await _spotSubscription?.cancel();
      await _futuresSubscription?.cancel();
      await _futuresDiagnosticsSubscription?.cancel();
      for (final subscription in _spotSubscriptionsBySymbol.values) {
        await subscription.cancel();
      }
      for (final subscription in _futuresSubscriptionsBySymbol.values) {
        await subscription.cancel();
      }
      for (final subscription
          in _futuresDiagnosticsSubscriptionsBySymbol.values) {
        await subscription.cancel();
      }
      _spotSubscription = null;
      _futuresSubscription = null;
      _futuresDiagnosticsSubscription = null;
      _spotSubscriptionsBySymbol.clear();
      _futuresSubscriptionsBySymbol.clear();
      _futuresDiagnosticsSubscriptionsBySymbol.clear();
      _healthTimer?.cancel();
      _uiThrottleTimer?.cancel();
      _snapshotTimer?.cancel();
      _healthTimer = null;
      _uiThrottleTimer = null;
      _uiPending = false;
      _snapshotTimer = null;
      _setStatus(
        _status.copyWith(
          overallStatus: MarketConnectionStatus.stopped,
          spotConnectionStatus: MarketConnectionStatus.stopped,
          futuresConnectionStatus: MarketConnectionStatus.stopped,
        ),
      );
    });
  }

  @override
  Future<void> reconnect() async {
    await _runExclusive(() async {
      _setStatus(
        _status.copyWith(overallStatus: MarketConnectionStatus.reconnecting),
      );
      await Future.wait([
        for (final stream in _spotStreams.values) stream.reconnect(),
        for (final stream in _futuresStreams.values) stream.reconnect(),
      ]);
    });
  }

  Future<void> reconnectFuturesOnly() async {
    if (_activeSymbol != null && _futuresStreams[_activeSymbol] != null) {
      await _futuresStreams[_activeSymbol]!.reconnect();
      return;
    }
    await Future.wait([
      for (final stream in _futuresStreams.values) stream.reconnect(),
    ]);
  }

  /// Ensures the futures market WebSocket for [symbol] has received data and
  /// is still connected. Returns `true` when the socket is healthy after the
  /// check. A failed socket gets exactly one immediate reconnect attempt; its
  /// own retry policy remains responsible for any later attempts.
  Future<bool> ensureFuturesSocketConnected(String symbol) async {
    final normalized = symbol.trim().toUpperCase();
    if (_status.mode != MarketDataMode.binanceLive ||
        normalized.isEmpty ||
        !_workspaceSymbols.contains(normalized)) {
      return false;
    }
    final stream = _futuresStreams[normalized];
    if (stream == null) {
      await _syncSymbolConnections();
      final connected = _futuresStreams[normalized];
      return connected?.isConnected == true &&
          connected?.status == MarketConnectionStatus.ready;
    }
    if (stream.isConnected && stream.status == MarketConnectionStatus.ready) {
      return true;
    }
    await stream.reconnect();
    return stream.isConnected && stream.status == MarketConnectionStatus.ready;
  }

  Future<FuturesWsProbeResult> testFuturesWebSocket() {
    return _futuresStream.probeConnection();
  }

  void onAppResumed() {
    _setStatus(
      _status.copyWith(
        overallStatus: MarketConnectionStatus.reconnecting,
        spotConnectionStatus: MarketConnectionStatus.reconnecting,
        futuresConnectionStatus: MarketConnectionStatus.reconnecting,
      ),
    );
    unawaited(reconnect());
  }

  void checkHealth({DateTime? now}) {
    final checkedAt = now ?? DateTime.now().toUtc();
    final spotStatus = _healthMonitor.evaluate(
      _status.lastSpotReceivedAt,
      checkedAt,
      _status.spotConnectionStatus,
    );
    final futuresStatus = _healthMonitor.evaluate(
      _status.lastFuturesReceivedAt,
      checkedAt,
      _status.futuresConnectionStatus,
    );
    if (spotStatus == MarketConnectionStatus.stale ||
        futuresStatus == MarketConnectionStatus.stale) {
      _setStatus(
        _status.copyWith(
          overallStatus: MarketConnectionStatus.stale,
          spotConnectionStatus: spotStatus,
          futuresConnectionStatus: futuresStatus,
        ),
      );
    }
  }

  Future<void> writeMarketSnapshot() async {
    final symbols = {
      ..._latestSpotBySymbol.keys,
      ..._latestFuturesBySymbol.keys,
    };
    if (symbols.isEmpty) {
      return;
    }
    for (final symbol in symbols) {
      final spot = _latestSpotBySymbol[symbol];
      final futures = _latestFuturesBySymbol[symbol];
      final mid = spot?.midPrice;
      final mark = futures?.markPrice;
      final basis = mid != null && mark != null ? mark - mid : null;
      final basisPercent = basis != null && mid != null && mid != Decimal.zero
          ? (basis / mid).toDecimal(scaleOnInfinitePrecision: 12) *
              Decimal.fromInt(100)
          : null;
      await db.into(db.marketSnapshots).insert(
            MarketSnapshotsCompanion.insert(
              id: _uuid.v4(),
              source: _status.mode.name,
              symbol: symbol,
              spotBid: Value(spot?.bidPrice.toString()),
              spotAsk: Value(spot?.askPrice.toString()),
              spotMid: Value(mid?.toString()),
              futuresMarkPrice: Value(mark?.toString()),
              indexPrice: Value(futures?.indexPrice.toString()),
              fundingRate: Value(futures?.fundingRate.toString()),
              basis: Value(basis?.toString()),
              basisPercent: Value(basisPercent?.toString()),
              recordedAt: DateTime.now().toUtc(),
            ),
          );
    }
  }

  void _handleSpotEvent(MarketStreamEvent<SpotBookTicker> event) {
    if (event.data != null) {
      final symbol = event.data!.symbol.toUpperCase();
      _latestSpotBySymbol[symbol] = event.data!;
      if (_activeSymbol == null || _activeSymbol == symbol) {
        _latestSpot = event.data;
      }
      _spotController.add(event.data!);
      _setStatus(
        _status.copyWith(
          spotConnectionStatus: MarketConnectionStatus.ready,
          lastSpotReceivedAt: event.data!.receivedAt,
          overallStatus: _overallStatus(spot: MarketConnectionStatus.ready),
          reconnectCount:
              event.reconnectDelay == null ? 0 : _status.reconnectCount,
        ),
      );
      _scheduleUiTick();
      return;
    }
    if (event.status != null) {
      _setStatus(
        _status.copyWith(
          spotConnectionStatus: event.status,
          overallStatus: _overallStatus(spot: event.status),
          lastError: event.error,
          reconnectDelay: event.reconnectDelay,
        ),
      );
    }
  }

  void _handleFuturesEvent(MarketStreamEvent<FuturesMarkPrice> event) {
    if (event.data != null) {
      final symbol = event.data!.symbol.toUpperCase();
      _latestFuturesBySymbol[symbol] = event.data!;
      if (_activeSymbol == null || _activeSymbol == symbol) {
        _latestFutures = event.data;
      }
      _futuresController.add(event.data!);
      _setStatus(
        _status.copyWith(
          futuresConnectionStatus: MarketConnectionStatus.ready,
          lastFuturesReceivedAt: event.data!.receivedAt,
          overallStatus: _overallStatus(futures: MarketConnectionStatus.ready),
          reconnectCount:
              event.reconnectDelay == null ? 0 : _status.reconnectCount,
        ),
      );
      _setActiveLatest();
      _emitUiTickNow();
      return;
    }
    if (event.status != null) {
      _setStatus(
        _status.copyWith(
          futuresConnectionStatus: event.status,
          overallStatus: _overallStatus(futures: event.status),
          lastError: event.error,
          reconnectDelay: event.reconnectDelay,
        ),
      );
    }
  }

  void _handleFuturesDiagnostics(FuturesWsDiagnostics diagnostics) {
    _latestFuturesDiagnostics = diagnostics;
    if (!_futuresDiagnosticsController.isClosed) {
      _futuresDiagnosticsController.add(diagnostics);
    }
  }

  MarketConnectionStatus _overallStatus({
    MarketConnectionStatus? spot,
    MarketConnectionStatus? futures,
  }) {
    final spotStatus = spot ?? _status.spotConnectionStatus;
    final futuresStatus = futures ?? _status.futuresConnectionStatus;
    if (spotStatus == MarketConnectionStatus.ready &&
        futuresStatus == MarketConnectionStatus.ready) {
      return MarketConnectionStatus.ready;
    }
    if (spotStatus == MarketConnectionStatus.stale ||
        futuresStatus == MarketConnectionStatus.stale) {
      return MarketConnectionStatus.stale;
    }
    if (spotStatus == MarketConnectionStatus.error ||
        futuresStatus == MarketConnectionStatus.error) {
      return MarketConnectionStatus.error;
    }
    if (spotStatus == MarketConnectionStatus.reconnecting ||
        futuresStatus == MarketConnectionStatus.reconnecting) {
      return MarketConnectionStatus.reconnecting;
    }
    if (spotStatus == MarketConnectionStatus.waitingFirstData ||
        futuresStatus == MarketConnectionStatus.waitingFirstData) {
      return MarketConnectionStatus.waitingFirstData;
    }
    return MarketConnectionStatus.connecting;
  }

  void _setStatus(MarketDataStatus status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  void _scheduleUiTick() {
    if (_uiPending && (_uiThrottleTimer?.isActive ?? false)) {
      return;
    }
    _uiThrottleTimer?.cancel();
    _uiPending = true;
    _uiThrottleTimer = Timer(const Duration(milliseconds: 150), () {
      _uiPending = false;
      _setActiveLatest();
      _emitUiTickNow();
    });
  }

  void _emitUiTickNow() {
    if (!_uiController.isClosed) {
      _uiController.add(currentMarketTick);
    }
    if (!_allTicksController.isClosed) {
      _allTicksController.add(currentMarketTicks);
    }
  }

  Future<void> _syncSymbolConnections() async {
    final toRemove = _spotStreams.keys
        .where((symbol) => !_workspaceSymbols.contains(symbol))
        .toList();
    for (final symbol in toRemove) {
      await _spotSubscriptionsBySymbol.remove(symbol)?.cancel();
      await _futuresSubscriptionsBySymbol.remove(symbol)?.cancel();
      await _futuresDiagnosticsSubscriptionsBySymbol.remove(symbol)?.cancel();
      await _spotStreams.remove(symbol)?.disconnect();
      await _futuresStreams.remove(symbol)?.disconnect();
      _latestSpotBySymbol.remove(symbol);
      _latestFuturesBySymbol.remove(symbol);
    }
    final connectTasks = <Future<void>>[];
    for (final symbol in _workspaceSymbols) {
      final spotStream = _spotStreams.putIfAbsent(
        symbol,
        () => symbol == _spotStream.symbol
            ? _spotStream
            : BinanceSpotMarketStream(symbol: symbol),
      );
      final futuresStream = _futuresStreams.putIfAbsent(
        symbol,
        () => symbol == _futuresStream.symbol
            ? _futuresStream
            : BinanceFuturesMarketStream(symbol: symbol),
      );
      _spotSubscriptionsBySymbol[symbol] ??= spotStream.events.listen(
        _handleSpotEvent,
      );
      _futuresSubscriptionsBySymbol[symbol] ??= futuresStream.events.listen(
        _handleFuturesEvent,
      );
      _futuresDiagnosticsSubscriptionsBySymbol[symbol] ??=
          futuresStream.diagnosticsStream.listen(_handleFuturesDiagnostics);
      connectTasks.add(spotStream.connect());
      connectTasks.add(futuresStream.connect());
    }
    await Future.wait(connectTasks);
    _emitUiTickNow();
  }

  void _setActiveLatest() {
    final symbol = _activeSymbol;
    if (symbol != null) {
      _latestSpot = _latestSpotBySymbol[symbol];
      _latestFutures = _latestFuturesBySymbol[symbol];
      return;
    }
    if (_workspaceSymbols.isNotEmpty) {
      final first = _workspaceSymbols.first;
      _latestSpot = _latestSpotBySymbol[first];
      _latestFutures = _latestFuturesBySymbol[first];
    }
  }

  Future<void> _runExclusive(Future<void> Function() action) async {
    if (_lifecycleBusy) {
      return;
    }
    _lifecycleBusy = true;
    try {
      await action();
    } finally {
      _lifecycleBusy = false;
    }
  }
}
