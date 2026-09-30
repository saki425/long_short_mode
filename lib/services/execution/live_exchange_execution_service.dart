import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';

import '../../database/app_database.dart' hide FuturesAccountSnapshot;
import '../../repositories/basic_repositories.dart';
import '../../repositories/order_repository.dart';
import '../../services/app_ui_settings.dart';
import '../../services/binance/auth/binance_credentials.dart';
import '../../services/binance/auth/binance_client_provider.dart';
import '../../services/binance/auth/binance_request_exception.dart';
import '../../services/binance/auth/binance_server_time_service.dart';
import '../../services/binance/futures/binance_futures_account_client.dart';
import '../../services/binance/futures/futures_account_models.dart';
import '../../services/binance/futures/futures_account_repository.dart';
import '../../services/binance/spot/binance_spot_account_client.dart';
import '../../services/binance/spot/spot_account_models.dart';
import '../../services/binance/spot/spot_account_repository.dart';
import '../../services/binance/trading/binance_account_stream_status.dart';
import '../../services/binance/trading/binance_exchange_info_service.dart';
import '../../services/binance/trading/binance_symbol_rules.dart';
import '../../services/market_data/market_data_coordinator.dart';
import '../security/secure_key_storage.dart';
import 'exchange_execution_service.dart';
import 'live_trading_gate_service.dart';

class LiveExecutionState {
  const LiveExecutionState({
    required this.spotRestStatus,
    required this.spotWsStatus,
    required this.futuresRestStatus,
    required this.futuresWsStatus,
    required this.writesBlocked,
    required this.liveTradingEnabled,
    required this.lastError,
    this.restCooldownUntil,
    this.restCooldownReason,
  });

  final String spotRestStatus;
  final String spotWsStatus;
  final String futuresRestStatus;
  final String futuresWsStatus;
  final bool writesBlocked;
  final bool liveTradingEnabled;
  final String? lastError;
  final DateTime? restCooldownUntil;
  final String? restCooldownReason;
}

class SpotExchangeRulesDiagnostics {
  const SpotExchangeRulesDiagnostics({
    required this.url,
    required this.loaded,
    this.httpStatus,
    this.binanceCode,
    this.binanceMessage,
    this.lastSuccessAt,
    this.lastAttemptAt,
    this.usingCache = false,
    this.lastError,
  });

  final String url;
  final bool loaded;
  final int? httpStatus;
  final int? binanceCode;
  final String? binanceMessage;
  final DateTime? lastSuccessAt;
  final DateTime? lastAttemptAt;
  final bool usingCache;
  final String? lastError;
}

class CancelAllSpotOpenOrdersReport {
  const CancelAllSpotOpenOrdersReport({
    required this.totalOpenOrders,
    required this.cancelledOrders,
    required this.failedOrders,
    required this.failures,
  });

  final int totalOpenOrders;
  final int cancelledOrders;
  final int failedOrders;
  final List<String> failures;

  String toDisplayText() {
    final buffer = StringBuffer()
      ..writeln('现货挂单批量撤销完成')
      ..writeln('发现挂单: $totalOpenOrders')
      ..writeln('撤销成功: $cancelledOrders')
      ..writeln('撤销失败: $failedOrders');
    if (failures.isNotEmpty) {
      buffer.writeln('失败明细:');
      for (final failure in failures) {
        buffer.writeln('- $failure');
      }
    }
    return buffer.toString();
  }
}

class FuturesUserOrderUpdate {
  const FuturesUserOrderUpdate({
    required this.symbol,
    required this.clientOrderId,
    required this.gridLevelId,
    required this.side,
    required this.status,
    required this.source,
    required this.strategyId,
    required this.isTerminal,
    required this.receivedAt,
  });

  final String symbol;
  final String clientOrderId;
  final String? gridLevelId;
  final String side;
  final String status;
  final String source;
  final String strategyId;
  final bool isTerminal;
  final DateTime receivedAt;
}

class _FuturesUserDataSession {
  _FuturesUserDataSession({
    required this.symbol,
    required this.keyProfileId,
    required this.accountBindingId,
    required this.client,
  });

  String symbol;
  String keyProfileId;
  String accountBindingId;
  BinanceFuturesAccountClient client;
  IOWebSocketChannel? channel;
  StreamSubscription<dynamic>? subscription;
  Timer? keepAliveTimer;
  Timer? reconnectTimer;
  String? listenKey;
  final Set<String> consumers = {};
  bool enabled = false;
  bool connecting = false;
  bool refreshing = false;
  DateTime? lastEventAt;
  BinanceAccountStreamStatus wsStatus = BinanceAccountStreamStatus.disconnected;
}

class LiveExchangeExecutionService implements ExchangeExecutionService {
  LiveExchangeExecutionService({
    required AppDatabase db,
    required OrderRepository orderRepository,
    required LogRepository logRepository,
    required CredentialsVault credentialsVault,
    BinanceClientProvider? clientProvider,
    required MarketDataCoordinator marketDataCoordinator,
    required LiveTradingGateService liveTradingGateService,
    BinanceExchangeInfoService? exchangeInfoService,
  })  : _db = db,
        _orderRepository = orderRepository,
        _logRepository = logRepository,
        _credentialsVault = credentialsVault,
        _clientProvider = clientProvider,
        _marketDataCoordinator = marketDataCoordinator,
        _liveTradingGateService = liveTradingGateService,
        _exchangeInfoService = exchangeInfoService ??
            BinanceExchangeInfoService(
              spotBaseUrl: 'https://api.binance.com',
              futuresBaseUrl: 'https://fapi.binance.com/fapi',
            );

  final AppDatabase _db;
  final OrderRepository _orderRepository;
  final LogRepository _logRepository;
  final CredentialsVault _credentialsVault;
  final BinanceClientProvider? _clientProvider;
  final MarketDataCoordinator _marketDataCoordinator;
  final LiveTradingGateService _liveTradingGateService;
  final BinanceExchangeInfoService _exchangeInfoService;
  final Uuid _uuid = const Uuid();
  final StreamController<LiveExecutionState> _stateController =
      StreamController.broadcast();
  final StreamController<FuturesUserOrderUpdate>
      _futuresUserOrderUpdateController = StreamController.broadcast();

  static const String manualSpotOrderLimitKey = 'manualSpotOrderLimitUsdt';
  static const String manualSpotDailyLimitKey = 'manualSpotDailyLimitUsdt';
  static const String manualFuturesOrderLimitKey =
      'manualFuturesOrderLimitUsdt';
  static const String manualFuturesShortLimitKey =
      'manualFuturesShortLimitUsdt';
  static const String autoSpotGridOrderLimitKey = 'autoSpotGridOrderLimitUsdt';
  static const String autoSpotGridDailyTurnoverLimitKey =
      'autoSpotGridDailyTurnoverLimitUsdt';

  BinanceServerTimeService? _timeService;
  BinanceSpotAccountClient? _spotClient;
  BinanceFuturesAccountClient? _futuresClient;
  SpotAccountRepository? _spotRepository;
  FuturesAccountRepository? _futuresRepository;
  BinanceSymbolRules? _spotRules;
  BinanceSymbolRules? _futuresRules;
  final Map<String, BinanceSymbolRules> _spotRulesBySymbol = {};
  final Map<String, DateTime> _spotRulesLoadedAtBySymbol = {};
  final Map<String, SpotExchangeRulesDiagnostics>
      _spotRulesDiagnosticsBySymbol = {};
  SpotExchangeRulesDiagnostics? _spotRulesDiagnostics;
  DateTime? _spotRulesLoadedAt;
  BinanceCredentials? _spotCredentials;
  BinanceCredentials? _futuresCredentials;
  String? _spotKeyProfileId;
  String? _spotAccountBindingId;
  String? _spotClientSymbol;
  String? _futuresKeyProfileId;
  String? _futuresAccountBindingId;
  String? _futuresClientSymbol;
  final Map<String, _FuturesUserDataSession> _futuresUserDataSessions = {};
  final Map<String, Future<FuturesAccountSnapshot>>
      _futuresAccountSnapshotInflight = {};
  final Map<String, FuturesAccountSnapshot> _futuresAccountSnapshotCache = {};
  final Map<String, DateTime> _futuresAccountSnapshotLoadedAt = {};

  Future<void> _binanceRestQueue = Future.value();
  Future<void> _futuresTradeQueue = Future.value();
  DateTime? _binanceRestNextAllowedAt;
  String? _binanceRestCooldownReason;
  DateTime _binanceRestLastRequestAt = DateTime.fromMillisecondsSinceEpoch(
    0,
    isUtc: true,
  );

  static const Duration _binanceRestMinInterval = Duration(milliseconds: 250);
  static const Duration _binanceRestRateLimitCooldown = Duration(minutes: 2);
  static const Duration _futuresAccountSnapshotCacheTtl = Duration(seconds: 20);

  bool _connected = false;
  bool _writesBlocked = false;
  int _consecutiveWriteFailures = 0;
  String? _lastError;
  BinanceAccountStreamStatus _spotRestStatus =
      BinanceAccountStreamStatus.disconnected;
  BinanceAccountStreamStatus _spotWsStatus =
      BinanceAccountStreamStatus.disconnected;
  BinanceAccountStreamStatus _futuresRestStatus =
      BinanceAccountStreamStatus.disconnected;
  BinanceAccountStreamStatus _futuresWsStatus =
      BinanceAccountStreamStatus.disconnected;

  Stream<LiveExecutionState> get stateStream => _stateController.stream;

  Stream<FuturesUserOrderUpdate> get futuresUserOrderUpdates =>
      _futuresUserOrderUpdateController.stream;

  @override
  BinanceSymbolRules? get spotRules => _spotRules;

  BinanceSymbolRules? spotRulesForSymbol(String symbol) =>
      _spotRulesBySymbol[symbol.toUpperCase()];

  SpotExchangeRulesDiagnostics get spotRulesDiagnostics =>
      _spotRulesDiagnostics ??
      const SpotExchangeRulesDiagnostics(
        url: 'https://api.binance.com/api/v3/exchangeInfo?symbol=BTCUSDT',
        loaded: false,
      );

  @override
  BinanceSymbolRules? get futuresRules => _futuresRules;

  Future<BinanceSymbolRules> ensureFuturesRules({
    String symbol = 'BTCUSDT',
  }) async {
    final normalized = symbol.toUpperCase();
    final rules = await _exchangeInfoService.loadFuturesRules(
      symbol: normalized,
    );
    _futuresRules = rules;
    return rules;
  }

  bool get connected => _connected;
  bool get writesBlocked =>
      _writesBlocked ||
      !_liveTradingGateService.isEnabledForScope(_currentWriteScope());
  int get consecutiveWriteFailures => _consecutiveWriteFailures;
  String? get lastError => _lastError;

  Future<Decimal> manualSpotOrderLimit({String? symbol}) => _decimalSetting(
        manualSpotOrderLimitKey,
        Decimal.fromInt(5),
        symbol: symbol ?? _spotClientSymbol,
        keyProfileId: _spotKeyProfileId,
      );

  Future<Decimal> manualSpotDailyLimit({String? symbol}) => _decimalSetting(
        manualSpotDailyLimitKey,
        Decimal.fromInt(20),
        symbol: symbol ?? _spotClientSymbol,
        keyProfileId: _spotKeyProfileId,
      );

  Future<Decimal> manualFuturesOrderLimit({String? symbol}) => _decimalSetting(
        manualFuturesOrderLimitKey,
        Decimal.fromInt(5),
        symbol: symbol ?? _futuresClientSymbol,
        keyProfileId: _futuresKeyProfileId,
      );

  Future<Decimal> manualFuturesShortLimit({String? symbol}) => _decimalSetting(
        manualFuturesShortLimitKey,
        Decimal.fromInt(10),
        symbol: symbol ?? _futuresClientSymbol,
        keyProfileId: _futuresKeyProfileId,
      );

  Future<Decimal> autoSpotGridOrderLimit({String? symbol}) => _decimalSetting(
        autoSpotGridOrderLimitKey,
        Decimal.fromInt(10),
        symbol: symbol ?? _spotClientSymbol,
        keyProfileId: _spotKeyProfileId,
      );

  Future<Decimal> autoSpotGridDailyTurnoverLimit({String? symbol}) =>
      _decimalSetting(
        autoSpotGridDailyTurnoverLimitKey,
        Decimal.fromInt(100),
        symbol: symbol ?? _spotClientSymbol,
        keyProfileId: _spotKeyProfileId,
      );

  Future<void> ensureLiveStrategy() async {
    final now = DateTime.now().toUtc();
    final existing = await (_db.select(_db.strategies)
          ..where((tbl) => tbl.id.equals(_strategyId())))
        .getSingleOrNull();
    if (existing != null) {
      return;
    }
    await _db.into(_db.strategies).insert(
          StrategiesCompanion.insert(
            id: _strategyId(),
            name: 'LIVE BTCUSDT Manual Lab',
            symbol: 'BTCUSDT',
            environment: 'LIVE',
            status: 'idle',
            createdAt: now,
            lowerPrice: '0',
            upperPrice: '0',
            centerPrice: '0',
            gridCount: 0,
            gridSpacingPercent: '0',
            gridMode: 'manual',
            spotCapital: '0',
            futuresCapital: '0',
            reserveCapital: '0',
            hedgeRatio: '0',
            maxLossUsdt: '0',
            maxExposureUsdt: '0',
            updatedAt: now,
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  @override
  Future<void> connect({String symbol = 'BTCUSDT'}) async {
    final normalizedSymbol = symbol.toUpperCase();
    await disconnect();
    await ensureLiveStrategy();
    await _logState('CONNECT');
    await _loadRules();
    _timeService = BinanceServerTimeService(
      spotBaseUrl: 'https://api.binance.com',
      futuresBaseUrl: 'https://fapi.binance.com/fapi',
    );
    await _timeService!.syncSpot();
    await _timeService!.syncFutures();

    final provider = _clientProvider;
    if (provider != null) {
      await connectSpotForSymbol(normalizedSymbol);
      final futures = await provider.getFuturesClientForSymbol(
        normalizedSymbol,
        'live',
      );
      _futuresClient = futures.client;
      _futuresKeyProfileId = futures.keyProfileId;
      _futuresAccountBindingId = futures.accountBindingId;
    } else {
      await _loadCredentials();
      _spotClient = BinanceSpotAccountClient(
        credentials: _spotCredentials!,
        timeService: _timeService!,
        baseUrl: 'https://api.binance.com',
      );
      _spotClientSymbol = normalizedSymbol;
      _futuresClient = BinanceFuturesAccountClient(
        credentials: _futuresCredentials!,
        timeService: _timeService!,
        baseUrl: 'https://fapi.binance.com/fapi',
      );
      _futuresClientSymbol = normalizedSymbol;
    }
    _spotRepository = SpotAccountRepository(_db);
    _futuresRepository = FuturesAccountRepository(_db);

    await refreshSpotSnapshotForSymbol(normalizedSymbol);
    await refreshFuturesSnapshotForSymbol(normalizedSymbol);
    _connected = true;
    _emitState();
  }

  Future<void> connectSpotForSymbol(String symbol) async {
    final normalized = symbol.toUpperCase();
    if (_spotClient != null && _spotClientSymbol == normalized) {
      return;
    }
    _timeService ??= BinanceServerTimeService(
      spotBaseUrl: 'https://api.binance.com',
      futuresBaseUrl: 'https://fapi.binance.com/fapi',
    );
    await _timeService!.syncSpot();
    final provider = _clientProvider;
    if (provider != null) {
      final spot = await provider.getSpotClientForSymbol(normalized, 'live');
      _spotClient = spot.client;
      _spotKeyProfileId = spot.keyProfileId;
      _spotAccountBindingId = spot.accountBindingId;
    } else {
      await _loadCredentials();
      _spotClient = BinanceSpotAccountClient(
        credentials: _spotCredentials!,
        timeService: _timeService!,
        baseUrl: 'https://api.binance.com',
      );
    }
    _spotClientSymbol = normalized;
    _spotRepository ??= SpotAccountRepository(_db);
  }

  @override
  Future<void> disconnect() async {
    await stopFuturesUserDataStream();
    _connected = false;
    _spotClient = null;
    _futuresClient = null;
    _spotRepository = null;
    _futuresRepository = null;
    _timeService = null;
    _spotKeyProfileId = null;
    _spotAccountBindingId = null;
    _spotClientSymbol = null;
    _futuresKeyProfileId = null;
    _futuresAccountBindingId = null;
    _futuresClientSymbol = null;
    _emitState();
  }

  Future<void> connectFuturesForSymbol(String symbol) async {
    final normalized = symbol.toUpperCase();
    if (_futuresClient != null && _futuresClientSymbol == normalized) {
      _syncCurrentFuturesWsStatus();
      return;
    }
    _timeService ??= BinanceServerTimeService(
      spotBaseUrl: 'https://api.binance.com',
      futuresBaseUrl: 'https://fapi.binance.com/fapi',
    );
    await _timeService!.syncFutures();
    final provider = _clientProvider;
    if (provider != null) {
      final futures = await provider.getFuturesClientForSymbol(
        normalized,
        'live',
      );
      _futuresClient = futures.client;
      _futuresKeyProfileId = futures.keyProfileId;
      _futuresAccountBindingId = futures.accountBindingId;
    } else {
      await _loadCredentials();
      _futuresClient = BinanceFuturesAccountClient(
        credentials: _futuresCredentials!,
        timeService: _timeService!,
        baseUrl: 'https://fapi.binance.com/fapi',
      );
    }
    _futuresClientSymbol = normalized;
    _futuresRepository ??= FuturesAccountRepository(_db);
    _syncCurrentFuturesWsStatus();
  }

  Future<T> _runFuturesTradeOperation<T>(
    String symbol,
    Future<T> Function() action,
  ) async {
    final previous = _futuresTradeQueue;
    final completer = Completer<void>();
    _futuresTradeQueue = completer.future;
    try {
      try {
        await previous;
      } catch (_) {
        // Keep the queue moving after a failed previous trade operation.
      }
      await connectFuturesForSymbol(symbol);
      return await action();
    } finally {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  Future<void> startFuturesUserDataStream({
    required String symbol,
    String consumerKey = 'default',
  }) async {
    final normalizedSymbol = symbol.toUpperCase();
    try {
      await connectFuturesForSymbol(normalizedSymbol);
    } catch (error) {
      _futuresWsStatus = BinanceAccountStreamStatus.error;
      _lastError = error.toString();
      _emitState();
      await _logRepository.append(
        level: 'warning',
        module: 'FUTURES_USER_STREAM',
        message: 'Futures user data stream skipped by account config error',
        extraJson: jsonEncode({
          'symbol': normalizedSymbol,
          'error': error.toString(),
        }),
      );
      rethrow;
    }
    final client = _futuresClient;
    if (client == null || _futuresClientSymbol != normalizedSymbol) {
      throw StateError('Futures live not connected for $normalizedSymbol');
    }
    final keyProfileId = _profileScope(_futuresKeyProfileId);
    final accountBindingId = _futuresAccountBindingId ?? '';
    final session = _futuresUserDataSessions.putIfAbsent(
      keyProfileId,
      () => _FuturesUserDataSession(
        symbol: normalizedSymbol,
        keyProfileId: keyProfileId,
        accountBindingId: accountBindingId,
        client: client,
      ),
    );
    session
      ..symbol = normalizedSymbol
      ..accountBindingId = accountBindingId
      ..client = client
      ..enabled = true;
    session.consumers.add(consumerKey);
    if (session.connecting || session.channel != null) {
      _syncCurrentFuturesWsStatus();
      return;
    }
    session.connecting = true;
    session.wsStatus = BinanceAccountStreamStatus.connecting;
    _syncCurrentFuturesWsStatus();
    _emitState();
    try {
      await _closeFuturesUserDataConnection(
        session: session,
        closeListenKey: true,
      );
      await _refreshFuturesSnapshotForClient(
        symbol: normalizedSymbol,
        client: client,
        keyProfileId: keyProfileId,
        accountBindingId: accountBindingId,
        includeHistory: false,
      );
      final listenKey = await client.createListenKey();
      final uri = Uri.parse('wss://fstream.binance.com/ws/$listenKey');
      final channel = IOWebSocketChannel.connect(uri);
      session.listenKey = listenKey;
      session.channel = channel;
      session.lastEventAt = null;
      session.wsStatus = BinanceAccountStreamStatus.ready;
      _syncCurrentFuturesWsStatus();
      _emitState();
      session.subscription = channel.stream.listen(
        (message) => unawaited(
          _handleFuturesUserDataMessage(
            message,
            symbol: normalizedSymbol,
            keyProfileId: keyProfileId,
          ),
        ),
        onError: (Object error, StackTrace stackTrace) {
          unawaited(
            _handleFuturesUserDataDisconnect(
              symbol: normalizedSymbol,
              keyProfileId: keyProfileId,
              error: error,
              stackTrace: stackTrace,
            ),
          );
        },
        onDone: () {
          unawaited(
            _handleFuturesUserDataDisconnect(
              symbol: normalizedSymbol,
              keyProfileId: keyProfileId,
            ),
          );
        },
        cancelOnError: false,
      );
      session.keepAliveTimer?.cancel();
      session.keepAliveTimer = Timer.periodic(
        const Duration(minutes: 25),
        (_) => unawaited(_keepAliveFuturesUserDataListenKey(keyProfileId)),
      );
      await _logRepository.append(
        level: 'info',
        module: 'FUTURES_USER_STREAM',
        message: 'Futures user data stream connected',
        extraJson: jsonEncode({
          'symbol': normalizedSymbol,
          'keyProfileId': keyProfileId,
        }),
      );
    } catch (error) {
      session.wsStatus = BinanceAccountStreamStatus.error;
      _lastError = error.toString();
      _syncCurrentFuturesWsStatus();
      _emitState();
      await _logRepository.append(
        level: 'error',
        module: 'FUTURES_USER_STREAM',
        message: 'Futures user data stream connect failed',
        extraJson: jsonEncode({
          'symbol': normalizedSymbol,
          'keyProfileId': keyProfileId,
          'error': error.toString(),
        }),
      );
      if (_isRetryableFuturesUserDataError(error)) {
        _scheduleFuturesUserDataReconnect(keyProfileId);
      }
    } finally {
      session.connecting = false;
    }
  }

  Future<void> stopFuturesUserDataStream({String? consumerKey}) async {
    final sessions = _futuresUserDataSessions.values.toList();
    for (final session in sessions) {
      if (consumerKey == null) {
        session.consumers.clear();
      } else {
        session.consumers.remove(consumerKey);
      }
      if (session.consumers.isNotEmpty) {
        continue;
      }
      session.enabled = false;
      session.reconnectTimer?.cancel();
      session.reconnectTimer = null;
      await _closeFuturesUserDataConnection(
        session: session,
        closeListenKey: true,
      );
      session.wsStatus = BinanceAccountStreamStatus.disconnected;
    }
    _futuresUserDataSessions.removeWhere(
      (_, session) => !session.enabled && session.consumers.isEmpty,
    );
    _syncCurrentFuturesWsStatus();
    _emitState();
  }

  bool get futuresUserDataStreamActive =>
      _currentFuturesUserDataSession()?.channel != null &&
      _currentFuturesUserDataSession()?.wsStatus ==
          BinanceAccountStreamStatus.ready;

  DateTime? get futuresUserDataLastEventAt =>
      _currentFuturesUserDataSession()?.lastEventAt;

  Future<String> futuresUserDataStatusForSymbol(String? symbol) async {
    final normalizedSymbol = symbol?.trim().toUpperCase();
    if (normalizedSymbol == null || normalizedSymbol.isEmpty) {
      return BinanceAccountStreamStatus.disconnected.name;
    }
    final provider = _clientProvider;
    if (provider == null) {
      return _currentFuturesUserDataSession()?.wsStatus.name ??
          BinanceAccountStreamStatus.disconnected.name;
    }
    final binding = await provider.profileService.getBinding(
      symbol: normalizedSymbol,
      environment: 'live',
    );
    final profileId = binding?.futuresKeyProfileId;
    if (profileId == null || profileId.trim().isEmpty) {
      return BinanceAccountStreamStatus.disconnected.name;
    }
    return _futuresUserDataSessions[_profileScope(profileId)]?.wsStatus.name ??
        BinanceAccountStreamStatus.disconnected.name;
  }

  @override
  Future<void> refreshSpotSnapshot() async {
    await refreshSpotSnapshotForSymbol(_spotClientSymbol ?? 'BTCUSDT');
  }

  Future<void> refreshSpotSnapshotForSymbol(String symbol) async {
    final normalizedSymbol = symbol.toUpperCase();
    await connectSpotForSymbol(normalizedSymbol);
    final client = _spotClient;
    final repository = _spotRepository;
    if (client == null || repository == null) {
      return;
    }
    try {
      _spotRestStatus = BinanceAccountStreamStatus.waitingSnapshot;
      _emitState();
      final snapshot = await _runBinanceRest(client.getAccountSnapshot);
      final openOrders = await _runBinanceRest(
        () => client.getOpenOrders(symbol: normalizedSymbol),
      );
      final historical = await _runBinanceRest(
        () => client.getAllOrders(symbol: normalizedSymbol),
      );
      final trades = await _runBinanceRest(
        () => client.getMyTrades(symbol: normalizedSymbol),
      );
      await repository.saveSnapshot(
        snapshot,
        accountType: 'spotSubAccount',
        keyProfileId: _spotKeyProfileId,
        accountBindingId: _spotAccountBindingId,
      );
      await repository.saveOpenOrders(
        openOrders,
        environment: 'live',
        symbol: normalizedSymbol,
        keyProfileId: _spotKeyProfileId,
        accountBindingId: _spotAccountBindingId,
      );
      await repository.saveHistoricalOrders(
        historical,
        environment: 'live',
        keyProfileId: _spotKeyProfileId,
        accountBindingId: _spotAccountBindingId,
      );
      await repository.saveTrades(
        trades,
        environment: 'live',
        keyProfileId: _spotKeyProfileId,
        accountBindingId: _spotAccountBindingId,
      );
      await _saveProfile(
        accountType: 'spotSubAccount',
        alias: 'Spot Live',
        apiKey: _credentialsVault.cache.credentials?.spotApiKey,
        secretKey: _credentialsVault.cache.credentials?.spotSecretKey,
        lastError: null,
      );
      _lastError = null;
      _spotRestStatus = BinanceAccountStreamStatus.ready;
      _spotWsStatus = BinanceAccountStreamStatus.ready;
      _consecutiveWriteFailures = 0;
    } catch (error) {
      _spotRestStatus = BinanceAccountStreamStatus.error;
      _lastError = error.toString();
      await _saveProfile(
        accountType: 'spotSubAccount',
        alias: 'Spot Live',
        apiKey: _credentialsVault.cache.credentials?.spotApiKey,
        secretKey: _credentialsVault.cache.credentials?.spotSecretKey,
        lastError: _lastError,
      );
      rethrow;
    } finally {
      _emitState();
    }
  }

  @override
  Future<void> refreshFuturesSnapshot() async {
    await refreshFuturesSnapshotForSymbol(_futuresClientSymbol ?? 'BTCUSDT');
  }

  Future<void> refreshFuturesSnapshotForSymbol(
    String symbol, {
    bool includeHistory = true,
  }) async {
    final normalizedSymbol = symbol.toUpperCase();
    try {
      await connectFuturesForSymbol(normalizedSymbol);
    } catch (error) {
      _futuresRestStatus = BinanceAccountStreamStatus.error;
      _lastError = error.toString();
      _emitState();
      await _logRepository.append(
        level: 'warning',
        module: 'FUTURES_ACCOUNT',
        message: 'Futures snapshot skipped by account config error',
        extraJson: jsonEncode({
          'symbol': normalizedSymbol,
          'error': error.toString(),
        }),
      );
      rethrow;
    }
    final client = _futuresClient;
    final repository = _futuresRepository;
    if (client == null ||
        _futuresClientSymbol != normalizedSymbol ||
        repository == null) {
      return;
    }
    await _refreshFuturesSnapshotForClient(
      symbol: normalizedSymbol,
      client: client,
      keyProfileId: _profileScope(_futuresKeyProfileId),
      accountBindingId: _futuresAccountBindingId,
      includeHistory: includeHistory,
    );
  }

  Future<void> _refreshFuturesSnapshotForClient({
    required String symbol,
    required BinanceFuturesAccountClient client,
    required String keyProfileId,
    required String? accountBindingId,
    required bool includeHistory,
  }) async {
    final normalizedSymbol = symbol.toUpperCase();
    final repository = _futuresRepository ??= FuturesAccountRepository(_db);
    try {
      _futuresRestStatus = BinanceAccountStreamStatus.waitingSnapshot;
      _emitState();
      final snapshot = await _loadSharedFuturesAccountSnapshot(
        client: client,
        keyProfileId: keyProfileId,
        accountBindingId: accountBindingId,
      );
      final openOrders = await _runBinanceRest(
        () => client.getOpenOrders(symbol: normalizedSymbol),
      );
      await repository.saveSnapshot(
        snapshot,
        keyProfileId: keyProfileId,
        accountBindingId: accountBindingId,
      );
      await repository.saveOpenOrders(
        openOrders,
        environment: 'live',
        symbol: normalizedSymbol,
        keyProfileId: keyProfileId,
        accountBindingId: accountBindingId,
      );
      if (includeHistory) {
        final now = DateTime.now().toUtc();
        final start = now.subtract(const Duration(days: 1));
        final historical = await _runBinanceRest(
          () => client.getAllOrders(
            symbol: normalizedSymbol,
            startTime: start,
            endTime: now,
          ),
        );
        final trades = await _runBinanceRest(
          () => client.getUserTrades(
            symbol: normalizedSymbol,
            startTime: start,
            endTime: now,
          ),
        );
        final funding = await _runBinanceRest(
          () => client.getFundingFees(symbol: normalizedSymbol),
        );
        await repository.saveHistoricalOrders(
          historical,
          environment: 'live',
          keyProfileId: keyProfileId,
          accountBindingId: accountBindingId,
        );
        await repository.saveTrades(
          trades,
          environment: 'live',
          keyProfileId: keyProfileId,
          accountBindingId: accountBindingId,
        );
        await repository.saveFundingFees(
          funding,
          keyProfileId: keyProfileId,
          accountBindingId: accountBindingId,
        );
      }
      await _saveProfile(
        accountType: 'futuresSubAccount',
        alias: 'Futures Live',
        apiKey: _credentialsVault.cache.credentials?.futuresApiKey,
        secretKey: _credentialsVault.cache.credentials?.futuresSecretKey,
        lastError: null,
      );
      _futuresRestStatus = BinanceAccountStreamStatus.ready;
      _lastError = null;
      _consecutiveWriteFailures = 0;
    } catch (error) {
      _futuresRestStatus = BinanceAccountStreamStatus.error;
      _lastError = error.toString();
      await _saveProfile(
        accountType: 'futuresSubAccount',
        alias: 'Futures Live',
        apiKey: _credentialsVault.cache.credentials?.futuresApiKey,
        secretKey: _credentialsVault.cache.credentials?.futuresSecretKey,
        lastError: _lastError,
      );
      rethrow;
    } finally {
      _emitState();
    }
  }

  Future<void> refreshRecentFuturesHistoryForSymbol(
    String symbol, {
    Duration lookback = const Duration(days: 1),
  }) async {
    final normalizedSymbol = symbol.toUpperCase();
    try {
      await connectFuturesForSymbol(normalizedSymbol);
    } catch (_) {
      return;
    }
    final client = _futuresClient;
    final keyProfileId = _profileScope(_futuresKeyProfileId);
    final accountBindingId = _futuresAccountBindingId;
    final repository = _futuresRepository ??= FuturesAccountRepository(_db);
    if (client == null || _futuresClientSymbol != normalizedSymbol) {
      return;
    }
    final now = DateTime.now().toUtc();
    final start = now.subtract(lookback);
    try {
      final historical = await _runBinanceRest(
        () => client.getAllOrders(
          symbol: normalizedSymbol,
          startTime: start,
          endTime: now,
        ),
      );
      final trades = await _runBinanceRest(
        () => client.getUserTrades(
          symbol: normalizedSymbol,
          startTime: start,
          endTime: now,
        ),
      );
      await repository.saveHistoricalOrders(
        historical,
        environment: 'live',
        keyProfileId: keyProfileId,
        accountBindingId: accountBindingId,
      );
      await repository.saveTrades(
        trades,
        environment: 'live',
        keyProfileId: keyProfileId,
        accountBindingId: accountBindingId,
      );
    } catch (error) {
      if (_isBinanceRateLimited(error)) {
        rethrow;
      }
    }
  }

  Future<FuturesAccountSnapshot> _loadSharedFuturesAccountSnapshot({
    required BinanceFuturesAccountClient client,
    required String keyProfileId,
    required String? accountBindingId,
  }) {
    final cacheKey = _futuresAccountCacheKey(keyProfileId, accountBindingId);
    final cached = _futuresAccountSnapshotCache[cacheKey];
    final loadedAt = _futuresAccountSnapshotLoadedAt[cacheKey];
    final now = DateTime.now().toUtc();
    if (cached != null &&
        loadedAt != null &&
        now.difference(loadedAt) < _futuresAccountSnapshotCacheTtl) {
      return Future.value(cached);
    }
    final inflight = _futuresAccountSnapshotInflight[cacheKey];
    if (inflight != null) {
      return inflight;
    }
    final future = _runBinanceRest(client.getAccountSnapshot);
    _futuresAccountSnapshotInflight[cacheKey] = future;
    future.then((snapshot) {
      _futuresAccountSnapshotCache[cacheKey] = snapshot;
      _futuresAccountSnapshotLoadedAt[cacheKey] = DateTime.now().toUtc();
    }).whenComplete(() {
      _futuresAccountSnapshotInflight.remove(cacheKey);
    });
    return future;
  }

  String _futuresAccountCacheKey(
    String keyProfileId,
    String? accountBindingId,
  ) {
    final binding = accountBindingId == null || accountBindingId.isEmpty
        ? 'default'
        : accountBindingId;
    return '$keyProfileId|$binding';
  }

  Future<T> _runBinanceRest<T>(Future<T> Function() request) {
    final completer = Completer<T>();
    _binanceRestQueue = _binanceRestQueue.catchError((_) {}).then((_) async {
      try {
        _throwIfBinanceRestCoolingDown();
        await _waitForBinanceRestSlot();
        final value = await request();
        completer.complete(value);
      } catch (error, stackTrace) {
        if (_isBinanceRateLimited(error) && !_isLocalRestCooldown(error)) {
          _binanceRestNextAllowedAt = DateTime.now().toUtc().add(
                _binanceRestRateLimitCooldown,
              );
          _binanceRestCooldownReason = error.toString();
          _lastError = error.toString();
          _emitState();
        }
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _throwIfBinanceRestCoolingDown() {
    final cooldownUntil = _binanceRestNextAllowedAt;
    if (cooldownUntil == null) {
      return;
    }
    final now = DateTime.now().toUtc();
    if (!now.isBefore(cooldownUntil)) {
      _binanceRestNextAllowedAt = null;
      _binanceRestCooldownReason = null;
      _emitState();
      return;
    }
    final remaining = cooldownUntil.difference(now);
    throw BinanceRequestException(
      type: BinanceRequestExceptionType.rateLimited,
      message: 'Binance REST 正在冷却中，剩余 ${remaining.inSeconds} 秒。'
          '自动监听仍使用 WebSocket，REST 请求不会继续排队等待。',
      statusCode: 429,
      binanceCode: -1003,
    );
  }

  Future<void> _waitForBinanceRestSlot() async {
    if (_binanceRestNextAllowedAt != null &&
        !DateTime.now().toUtc().isBefore(_binanceRestNextAllowedAt!)) {
      _binanceRestNextAllowedAt = null;
      _binanceRestCooldownReason = null;
      _emitState();
    }
    final afterCooldown = DateTime.now().toUtc();
    final nextByInterval = _binanceRestLastRequestAt.add(
      _binanceRestMinInterval,
    );
    if (afterCooldown.isBefore(nextByInterval)) {
      await Future.delayed(nextByInterval.difference(afterCooldown));
    }
    _binanceRestLastRequestAt = DateTime.now().toUtc();
  }

  bool _isBinanceRateLimited(Object error) {
    if (error is BinanceRequestException) {
      return error.type == BinanceRequestExceptionType.rateLimited ||
          error.statusCode == 429 ||
          error.binanceCode == -1003;
    }
    if (error is DioException) {
      return error.response?.statusCode == 429;
    }
    final text = error.toString();
    return text.contains('status code of 429') ||
        text.contains('statusCode: 429') ||
        text.contains('code: -1003') ||
        text.contains('Too many requests');
  }

  bool _isLocalRestCooldown(Object error) {
    return error is BinanceRequestException &&
        error.statusCode == 429 &&
        error.binanceCode == -1003 &&
        error.message.contains('REST 正在冷却中');
  }

  Future<void> placeSpotTestOrder({
    String symbol = 'BTCUSDT',
    required String side,
    required String type,
    Decimal? quantity,
    Decimal? price,
    Decimal? quoteOrderQty,
  }) async {
    final normalizedSymbol = symbol.toUpperCase();
    await connectSpotForSymbol(normalizedSymbol);
    final client = _spotClient;
    if (client == null) {
      throw StateError('Spot live not connected');
    }
    await client.placeTestOrder(
      symbol: normalizedSymbol,
      side: side,
      type: type,
      quantity: quantity,
      price: price,
      quoteOrderQty: quoteOrderQty,
      timeInForce: type == 'LIMIT' ? 'GTC' : null,
      clientOrderId: _clientOrderId('GH_LIVE_TEST_SPOT'),
    );
  }

  Future<void> testFuturesSignature({String symbol = 'BTCUSDT'}) async {
    if (_futuresClient == null) {
      throw StateError('Futures live not connected');
    }
    await refreshFuturesSnapshotForSymbol(symbol);
  }

  Future<void> querySpotOrder(String clientOrderId, {String? symbol}) async {
    final local = await _orderRepository.getOrderDetailsByClientOrderId(
      clientOrderId,
    );
    final querySymbol = local?.order.symbol ??
        symbol?.toUpperCase() ??
        _spotClientSymbol ??
        'BTCUSDT';
    await connectSpotForSymbol(querySymbol);
    final client = _spotClient;
    if (client == null) {
      throw StateError('Spot live not connected');
    }
    final SpotOpenOrder? remote;
    try {
      remote = await client.getOrderByClientOrderId(
        symbol: querySymbol,
        clientOrderId: clientOrderId,
      );
    } catch (error) {
      if (_isOrderDoesNotExist(error) &&
          local != null &&
          await _markLocalOrderNotCreated(local.order, error)) {
        await refreshSpotSnapshot();
        return;
      }
      rethrow;
    }
    if (remote == null) {
      throw StateError('Spot order not found: $clientOrderId');
    }
    if (local != null) {
      await _mergeSpotOrderResponse(local.order.id, remote);
    }
    await refreshSpotSnapshot();
  }

  Future<void> queryFuturesOrder(String clientOrderId, {String? symbol}) async {
    final local = await _orderRepository.getOrderDetailsByClientOrderId(
      clientOrderId,
    );
    final querySymbol =
        local?.order.symbol ?? symbol?.toUpperCase() ?? 'BTCUSDT';
    await connectFuturesForSymbol(querySymbol);
    final client = _futuresClient;
    if (client == null || _futuresClientSymbol != querySymbol) {
      throw StateError('Futures live not connected for $querySymbol');
    }
    final FuturesHistoricalOrder? remote;
    try {
      remote = await client.getOrderByClientOrderId(
        symbol: querySymbol,
        clientOrderId: clientOrderId,
      );
    } catch (error) {
      if (_isOrderDoesNotExist(error) &&
          local != null &&
          await _markLocalOrderNotCreated(local.order, error)) {
        await refreshFuturesSnapshotForSymbol(querySymbol);
        return;
      }
      rethrow;
    }
    if (remote == null) {
      throw StateError('Futures order not found: $clientOrderId');
    }
    if (local != null) {
      await _mergeFuturesOrderResponse(local.order.id, remote);
    }
    await refreshFuturesSnapshotForSymbol(querySymbol);
  }

  Future<bool> syncFuturesOrderFromBinance(Order order) async {
    final querySymbol = order.symbol.toUpperCase();
    await connectFuturesForSymbol(querySymbol);
    final client = _futuresClient;
    if (client == null || _futuresClientSymbol != querySymbol) {
      return false;
    }
    final FuturesHistoricalOrder? remote;
    try {
      remote = await _runBinanceRest(
        () => client.getOrderByClientOrderId(
          symbol: querySymbol,
          clientOrderId: order.clientOrderId,
        ),
      );
    } catch (error) {
      if (_isOrderDoesNotExist(error)) {
        return false;
      }
      rethrow;
    }
    if (remote == null) {
      return false;
    }
    await _mergeFuturesOrderResponse(order.id, remote);
    final updated = await (_db.select(_db.orders)
          ..where((tbl) => tbl.id.equals(order.id)))
        .getSingleOrNull();
    if (updated != null) {
      await (_futuresRepository ??= FuturesAccountRepository(_db))
          .saveHistoricalOrderFromLocalOrder(
        updated,
        environment: 'live',
        keyProfileId: _profileScope(updated.keyProfileId),
        accountBindingId: updated.accountBindingId,
      );
    }
    return true;
  }

  @override
  Future<String> placeSpotLimitOrder({
    String symbol = 'BTCUSDT',
    required String side,
    required Decimal quantity,
    required Decimal price,
  }) async {
    _ensureWritesAllowed();
    final normalizedSymbol = symbol.toUpperCase();
    await connectSpotForSymbol(normalizedSymbol);
    final client = _spotClient;
    final rules = await ensureSpotRules(symbol: normalizedSymbol);
    if (client == null || rules == null) {
      throw StateError('Spot live not connected');
    }
    final quantizedQuantity = rules.quantizeQuantity(quantity);
    final quantizedPrice = rules.quantizePrice(price);
    if (!rules.isAcceptableOrder(
      price: quantizedPrice,
      quantity: quantizedQuantity,
    )) {
      throw StateError(
        'Spot order does not satisfy tickSize/stepSize/minQty/minNotional',
      );
    }
    final notional = quantizedPrice * quantizedQuantity;
    await _ensureManualSpotOrderLimit(notional);
    await _ensureDailySpotLimit(notional);
    final clientOrderId = _clientOrderId('GH_LIVE_TEST_SPOT');
    return _executeSpotOrder(
      symbol: normalizedSymbol,
      clientOrderId: clientOrderId,
      side: side,
      quantity: quantizedQuantity,
      price: quantizedPrice,
      orderType: 'LIMIT',
      quoteOrderQty: null,
      timeInForce: 'GTC',
    );
  }

  @override
  Future<String> placeSpotMarketOrder({
    String symbol = 'BTCUSDT',
    required String side,
    Decimal? quantity,
    Decimal? quoteOrderQty,
  }) async {
    _ensureWritesAllowed();
    final normalizedSymbol = symbol.toUpperCase();
    await connectSpotForSymbol(normalizedSymbol);
    final client = _spotClient;
    final rules = await ensureSpotRules(symbol: normalizedSymbol);
    if (client == null || rules == null) {
      throw StateError('Spot live not connected');
    }
    final reference = _spotReferencePrice(side);
    final quantizedQuantity =
        quantity == null ? null : rules.quantizeQuantity(quantity);
    final quantizedPrice = rules.quantizePrice(reference);
    if (quoteOrderQty == null) {
      final orderQty = quantizedQuantity ?? Decimal.zero;
      if (!rules.isAcceptableOrder(price: quantizedPrice, quantity: orderQty)) {
        throw StateError(
          'Spot market order does not satisfy tickSize/stepSize/minQty/minNotional',
        );
      }
    }
    final notional =
        quoteOrderQty ?? ((quantizedQuantity ?? Decimal.zero) * quantizedPrice);
    await _ensureManualSpotOrderLimit(notional);
    await _ensureDailySpotLimit(notional);
    final clientOrderId = _clientOrderId('GH_LIVE_TEST_SPOT');
    return _executeSpotOrder(
      symbol: normalizedSymbol,
      clientOrderId: clientOrderId,
      side: side,
      quantity: quantizedQuantity,
      price: quantizedPrice,
      orderType: 'MARKET',
      quoteOrderQty: quoteOrderQty,
      timeInForce: null,
    );
  }

  Future<String> placeAutoSpotGridLimitOrder({
    String symbol = 'BTCUSDT',
    required String strategyId,
    required String gridLevelId,
    required String side,
    required Decimal quantity,
    required Decimal price,
    String? parentOrderId,
  }) async {
    _ensureWritesAllowed();
    final normalizedSymbol = symbol.toUpperCase();
    await connectSpotForSymbol(normalizedSymbol);
    final client = _spotClient;
    final rules = await ensureSpotRules(symbol: normalizedSymbol);
    if (client == null || rules == null) {
      throw StateError('Spot live not connected');
    }
    final quantizedQuantity = rules.quantizeQuantity(quantity);
    final quantizedPrice = rules.quantizePrice(price);
    if (!rules.isAcceptableOrder(
      price: quantizedPrice,
      quantity: quantizedQuantity,
    )) {
      throw StateError(
        'Auto spot grid order does not satisfy tickSize/stepSize/minQty/minNotional',
      );
    }
    final notional = quantizedPrice * quantizedQuantity;
    final orderLimit = await autoSpotGridOrderLimit();
    if (notional > orderLimit) {
      throw StateError('Auto spot grid order exceeds $orderLimit USDT');
    }
    await _ensureDailyAutoSpotLimit(
      newOrderNotional: notional,
      strategyId: strategyId,
      symbol: normalizedSymbol,
    );
    final clientOrderId = _clientOrderId('GH_LIVE_GRID_SPOT');
    return _executeSpotOrder(
      symbol: normalizedSymbol,
      clientOrderId: clientOrderId,
      strategyId: strategyId,
      source: 'autoSpotGrid',
      side: side,
      quantity: quantizedQuantity,
      price: quantizedPrice,
      orderType: 'LIMIT',
      quoteOrderQty: null,
      timeInForce: 'GTC',
      purpose: side == 'BUY' ? 'gridBuy' : 'gridSell',
      gridLevelId: gridLevelId,
      parentOrderId: parentOrderId,
    );
  }

  Future<String> submitExistingAutoSpotGridLimitOrder(Order order) async {
    _ensureWritesAllowed();
    if (order.source != 'autoSpotGrid' ||
        order.marketType != 'spot' ||
        order.orderType != 'LIMIT') {
      throw StateError(
        'Only local auto spot grid LIMIT orders can be submitted',
      );
    }
    final exchangeOrderId = order.exchangeOrderId;
    if (exchangeOrderId != null && exchangeOrderId.isNotEmpty) {
      return order.id;
    }
    final executedQuantity =
        Decimal.tryParse(order.executedQuantity) ?? Decimal.zero;
    if (executedQuantity != Decimal.zero) {
      throw StateError('Cannot submit a local order that already has fills');
    }
    final normalizedSymbol = order.symbol.toUpperCase();
    await connectSpotForSymbol(normalizedSymbol);
    final client = _spotClient;
    final rules = await ensureSpotRules(symbol: normalizedSymbol);
    if (client == null || rules == null) {
      throw StateError('Spot live not connected');
    }
    final priceValue = Decimal.tryParse(order.price ?? '');
    final quantityValue = Decimal.tryParse(order.originalQuantity);
    if (priceValue == null ||
        quantityValue == null ||
        priceValue <= Decimal.zero ||
        quantityValue <= Decimal.zero) {
      throw StateError('Local grid order has invalid price or quantity');
    }
    final price = rules.quantizePrice(priceValue);
    final quantity = rules.quantizeQuantity(quantityValue);
    if (!rules.isAcceptableOrder(price: price, quantity: quantity)) {
      throw StateError(
        'Local auto spot grid order does not satisfy tickSize/stepSize/minQty/minNotional',
      );
    }
    final notional = price * quantity;
    final orderLimit = await autoSpotGridOrderLimit();
    if (notional > orderLimit) {
      throw StateError('Auto spot grid order exceeds $orderLimit USDT');
    }
    await _ensureDailyAutoSpotLimit(
      newOrderNotional: notional,
      strategyId: order.strategyId,
      symbol: normalizedSymbol,
    );
    final now = DateTime.now().toUtc();
    await (_db.update(_db.orders)..where((tbl) => tbl.id.equals(order.id)))
        .write(
      OrdersCompanion(
        status: const Value('submitting'),
        price: Value(price.toString()),
        originalQuantity: Value(quantity.toString()),
        submittedAt: Value(now),
        updatedAt: Value(now),
        completedAt: const Value(null),
        cancelledAt: const Value(null),
        errorCode: const Value(null),
        errorMessage: const Value(null),
        keyProfileId: Value(_spotKeyProfileId),
        accountBindingId: Value(_spotAccountBindingId),
      ),
    );
    try {
      final response = await client.placeLimitOrder(
        symbol: normalizedSymbol,
        side: order.side,
        quantity: quantity,
        price: price,
        clientOrderId: order.clientOrderId,
        timeInForce: order.timeInForce ?? 'GTC',
      );
      await _mergeSpotOrderResponse(order.id, response);
      await refreshSpotSnapshotForSymbol(normalizedSymbol);
      return order.id;
    } catch (error) {
      if (await _markLocalGridSubmissionRejected(order, error)) {
        rethrow;
      }
      await _recoverOrderByClientOrderId(
        orderId: order.id,
        clientOrderId: order.clientOrderId,
        symbol: normalizedSymbol,
        marketType: 'spot',
        error: error,
      );
      final recovered = await (_db.select(_db.orders)
            ..where((tbl) => tbl.id.equals(order.id)))
          .getSingleOrNull();
      final recoveredExchangeOrderId = recovered?.exchangeOrderId;
      final recoveredStatus = recovered?.status;
      if (recovered != null &&
          recoveredExchangeOrderId != null &&
          recoveredExchangeOrderId.isNotEmpty &&
          const {
            'new',
            'partiallyFilled',
            'filled',
          }.contains(recoveredStatus)) {
        return order.id;
      }
      rethrow;
    }
  }

  Future<String> placeAutoSpotGridMarketBuy({
    String symbol = 'BTCUSDT',
    required String strategyId,
    required Decimal quoteOrderQty,
  }) async {
    _ensureWritesAllowed();
    final normalizedSymbol = symbol.toUpperCase();
    await connectSpotForSymbol(normalizedSymbol);
    final client = _spotClient;
    final rules = await ensureSpotRules(symbol: normalizedSymbol);
    if (client == null || rules == null) {
      throw StateError('Spot live not connected');
    }
    if (quoteOrderQty > Decimal.fromInt(5)) {
      throw StateError('Initial inventory chunk exceeds 5 USDT');
    }
    if (quoteOrderQty < rules.minNotional) {
      throw StateError(
        'Initial inventory chunk is below minNotional ${rules.minNotional} USDT',
      );
    }
    await _ensureDailyAutoSpotLimit(
      newOrderNotional: quoteOrderQty,
      strategyId: strategyId,
      symbol: normalizedSymbol,
    );
    final clientOrderId = _clientOrderId('GH_LIVE_GRID_SPOT');
    return _executeSpotOrder(
      symbol: normalizedSymbol,
      clientOrderId: clientOrderId,
      strategyId: strategyId,
      source: 'autoSpotGrid',
      side: 'BUY',
      quantity: null,
      price: _spotReferencePrice('BUY'),
      orderType: 'MARKET',
      quoteOrderQty: quoteOrderQty,
      timeInForce: null,
      purpose: 'initialSpotBuy',
    );
  }

  @override
  Future<void> cancelSpotOrder(String clientOrderId) async {
    _ensureWritesAllowed();
    final local = await _orderRepository.getOrderDetailsByClientOrderId(
      clientOrderId,
    );
    final symbol = local?.order.symbol ?? _spotClientSymbol ?? 'BTCUSDT';
    await connectSpotForSymbol(symbol);
    final client = _spotClient;
    if (client == null) {
      throw StateError('Spot live not connected');
    }
    await client.cancelOrder(symbol: symbol, clientOrderId: clientOrderId);
    await _updateLocalOrderStatus(
      clientOrderId,
      status: 'cancelled',
      cancelledAt: DateTime.now().toUtc(),
    );
    await refreshSpotSnapshot();
  }

  Future<CancelAllSpotOpenOrdersReport> cancelAllSpotOpenOrders({
    String? symbol,
  }) async {
    _ensureWritesAllowed();
    final normalizedSymbol = symbol?.toUpperCase();
    if (normalizedSymbol != null) {
      await connectSpotForSymbol(normalizedSymbol);
    }
    final client = _spotClient;
    final repository = _spotRepository;
    if (client == null || repository == null) {
      throw StateError('Spot live not connected');
    }

    final openOrders = await client.getOpenOrders(symbol: normalizedSymbol);
    await repository.saveOpenOrders(openOrders, environment: 'live');

    var cancelled = 0;
    final failures = <String>[];
    for (final order in openOrders) {
      try {
        await client.cancelOrder(
          symbol: order.symbol,
          clientOrderId: order.clientOrderId,
        );
        cancelled += 1;
        await _updateLocalOrderStatus(
          order.clientOrderId,
          status: 'cancelled',
          cancelledAt: DateTime.now().toUtc(),
        );
      } catch (error) {
        failures.add(
          '${order.symbol} ${order.side} client=${order.clientOrderId} exchange=${order.orderId}: $error',
        );
      }
    }

    await refreshSpotSnapshot();
    return CancelAllSpotOpenOrdersReport(
      totalOpenOrders: openOrders.length,
      cancelledOrders: cancelled,
      failedOrders: failures.length,
      failures: failures,
    );
  }

  @override
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
  }) async {
    return _runFuturesTradeOperation(symbol, () async {
      _ensureWritesAllowed();
      final normalizedSymbol = symbol.toUpperCase();
      await connectFuturesForSymbol(normalizedSymbol);
      final rules = await ensureFuturesRules(symbol: normalizedSymbol);
      final client = _futuresClient;
      if (client == null || _futuresClientSymbol != normalizedSymbol) {
        throw StateError('Futures live not connected for $normalizedSymbol');
      }
      final quantizedQuantity = rules.quantizeQuantity(quantity);
      final quantizedPrice = rules.quantizePrice(price);
      if (!rules.isAcceptableOrder(
        price: quantizedPrice,
        quantity: quantizedQuantity,
      )) {
        throw StateError(
          'Futures order does not satisfy tickSize/stepSize/minQty/minNotional',
        );
      }
      await _ensureFuturesLeverage(
        symbol: normalizedSymbol,
        leverage: leverage,
      );
      final currentShortNotional = await _currentFuturesShortNotional(
        normalizedSymbol,
      );
      final currentLongNotional = await _currentFuturesLongNotional(
        normalizedSymbol,
      );
      await _ensureManualFuturesOrderLimit(
        notional: quantizedPrice * quantizedQuantity,
        side: side,
        reduceOnly: reduceOnly,
        allowLongOpen: _isAutoFuturesLongOpen(
          source: source,
          positionSide: positionSide,
          side: side,
          reduceOnly: reduceOnly,
        ),
        currentShortNotional: currentShortNotional,
        currentLongNotional: currentLongNotional,
      );
      final clientOrderId = _clientOrderId(
        source == 'autoFuturesLongGrid'
            ? 'GH_LONG_GRID_FUTURES'
            : 'GH_LIVE_TEST_FUTURES',
      );
      return _executeFuturesOrder(
        clientOrderId: clientOrderId,
        symbol: normalizedSymbol,
        strategyId: strategyId,
        source: source,
        side: side,
        quantity: quantizedQuantity,
        price: quantizedPrice,
        reduceOnly: reduceOnly,
        orderType: 'LIMIT',
        positionSide: positionSide,
        gridLevelId: gridLevelId,
        purpose: purpose,
      );
    });
  }

  @override
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
  }) async {
    return _runFuturesTradeOperation(symbol, () async {
      _ensureWritesAllowed();
      final normalizedSymbol = symbol.toUpperCase();
      await connectFuturesForSymbol(normalizedSymbol);
      final rules = await ensureFuturesRules(symbol: normalizedSymbol);
      final client = _futuresClient;
      if (client == null || _futuresClientSymbol != normalizedSymbol) {
        throw StateError('Futures live not connected for $normalizedSymbol');
      }
      await _ensureFuturesLeverage(
        symbol: normalizedSymbol,
        leverage: leverage,
      );
      final reference = _futuresReferencePrice(normalizedSymbol);
      final quantizedQuantity = rules.quantizeQuantity(quantity);
      if (!rules.isAcceptableOrder(
        price: rules.quantizePrice(reference),
        quantity: quantizedQuantity,
      )) {
        throw StateError(_futuresMarketRuleError(quantity, reference));
      }
      await _ensureManualFuturesOrderLimit(
        notional: reference * quantizedQuantity,
        side: side,
        reduceOnly: reduceOnly,
        allowLongOpen: _isAutoFuturesLongOpen(
          source: source,
          positionSide: positionSide,
          side: side,
          reduceOnly: reduceOnly,
        ),
        currentShortNotional: await _currentFuturesShortNotional(
          normalizedSymbol,
        ),
        currentLongNotional: await _currentFuturesLongNotional(
          normalizedSymbol,
        ),
      );
      final clientOrderId = _clientOrderId('GH_LIVE_TEST_FUTURES');
      return _executeFuturesOrder(
        clientOrderId: clientOrderId,
        symbol: normalizedSymbol,
        strategyId: strategyId,
        source: source,
        side: side,
        quantity: quantizedQuantity,
        price: rules.quantizePrice(reference),
        reduceOnly: reduceOnly,
        orderType: 'MARKET',
        positionSide: positionSide,
        gridLevelId: gridLevelId,
        purpose: purpose,
      );
    });
  }

  Future<String> placeHedgeFuturesMarketOrder({
    required String strategyId,
    required String side,
    required Decimal quantity,
    required bool reduceOnly,
    String symbol = 'BTCUSDT',
    int leverage = 1,
    String source = 'autoHedge',
    String? purpose,
    String? gridLevelId,
  }) async {
    return _runFuturesTradeOperation(symbol, () async {
      _ensureWritesAllowed();
      final normalizedSymbol = symbol.toUpperCase();
      await connectFuturesForSymbol(normalizedSymbol);
      final rules = await ensureFuturesRules(symbol: normalizedSymbol);
      final client = _futuresClient;
      if (client == null || _futuresClientSymbol != normalizedSymbol) {
        throw StateError('Futures live not connected for $normalizedSymbol');
      }
      if (side == 'BUY' && !reduceOnly) {
        throw StateError('Hedge BUY must be reduceOnly');
      }
      if (side != 'BUY' && side != 'SELL') {
        throw StateError('Unsupported hedge futures side: $side');
      }
      await _ensureFuturesLeverage(
        symbol: normalizedSymbol,
        leverage: leverage,
      );
      final reference = _futuresReferencePrice(normalizedSymbol);
      final quantizedQuantity = rules.quantizeQuantity(quantity);
      final referencePrice = rules.quantizePrice(reference);
      if (!rules.isAcceptableOrder(
        price: referencePrice,
        quantity: quantizedQuantity,
      )) {
        throw StateError(_futuresMarketRuleError(quantity, reference));
      }
      await _ensureManualFuturesOrderLimit(
        notional: reference * quantizedQuantity,
        side: side,
        reduceOnly: reduceOnly,
        allowExistingLongExposure: side == 'SELL' && !reduceOnly,
        currentShortNotional: await _currentFuturesShortNotional(
          normalizedSymbol,
        ),
        currentLongNotional: await _currentFuturesLongNotional(
          normalizedSymbol,
        ),
      );
      final clientOrderId = _clientOrderId('GH_LIVE_HEDGE_FUTURES');
      return _executeFuturesOrder(
        clientOrderId: clientOrderId,
        symbol: normalizedSymbol,
        strategyId: strategyId,
        source: source,
        side: side,
        quantity: quantizedQuantity,
        price: referencePrice,
        reduceOnly: reduceOnly,
        orderType: 'MARKET',
        positionSide: 'SHORT',
        gridLevelId: gridLevelId,
        purpose: purpose ?? (side == 'SELL' ? 'increaseHedge' : 'reduceHedge'),
      );
    });
  }

  String _futuresMarketRuleError(Decimal requestedQuantity, Decimal reference) {
    final rules = _futuresRules;
    if (rules == null) {
      return 'Futures trading rules are not loaded';
    }
    final referencePrice = rules.quantizePrice(reference);
    final quantizedQuantity = rules.quantizeQuantity(requestedQuantity);
    final notional = referencePrice * quantizedQuantity;
    final minQtyByNotional = referencePrice <= Decimal.zero
        ? rules.minQty
        : _ceilToStep(
            (rules.minNotional / referencePrice).toDecimal(
              scaleOnInfinitePrecision: 18,
            ),
            rules.stepSize,
          );
    final minLegalQuantity =
        minQtyByNotional > rules.minQty ? minQtyByNotional : rules.minQty;
    final minLegalNotional = referencePrice * minLegalQuantity;
    return 'Futures market order does not satisfy Binance filters. '
        'requestedQty=$requestedQuantity, formattedQty=$quantizedQuantity, '
        'referencePrice=$referencePrice, notional=$notional, '
        'minQty=${rules.minQty}, stepSize=${rules.stepSize}, '
        'minNotional=${rules.minNotional}, '
        'minimumLegalQty=$minLegalQuantity, '
        'minimumLegalNotional=$minLegalNotional.';
  }

  Decimal _ceilToStep(Decimal value, Decimal step) {
    if (step == Decimal.zero) {
      return value;
    }
    return (value / step).toDecimal(scaleOnInfinitePrecision: 18).ceil() * step;
  }

  @override
  Future<void> cancelFuturesOrder(
    String clientOrderId, {
    String symbol = 'BTCUSDT',
  }) async {
    _ensureWritesAllowed();
    final local = await _orderRepository.getOrderDetailsByClientOrderId(
      clientOrderId,
    );
    final normalizedSymbol = (local?.order.symbol ?? symbol).toUpperCase();
    await connectFuturesForSymbol(normalizedSymbol);
    final client = _futuresClient;
    if (client == null || _futuresClientSymbol != normalizedSymbol) {
      throw StateError('Futures live not connected for $normalizedSymbol');
    }
    await client.cancelOrder(
      symbol: normalizedSymbol,
      clientOrderId: clientOrderId,
    );
    await _updateLocalOrderStatus(
      clientOrderId,
      status: 'cancelled',
      cancelledAt: DateTime.now().toUtc(),
    );
    await refreshFuturesSnapshotForSymbol(normalizedSymbol);
  }

  @override
  Future<void> emergencyExit({required bool sellSpot}) async {
    _ensureWritesAllowed();
    await _cancelAppOrders(prefix: 'GH_LIVE_TEST_SPOT');
    await _cancelAppOrders(prefix: 'GH_LIVE_TEST_FUTURES');
    final shortQty = await _currentFuturesShortQuantity(
      _futuresClientSymbol ?? 'BTCUSDT',
    );
    if (shortQty > Decimal.zero) {
      await placeFuturesMarketOrder(
        side: 'BUY',
        quantity: shortQty,
        reduceOnly: true,
      );
    }
    if (sellSpot) {
      final spotQty = await _currentSpotBtcQuantity();
      if (spotQty > Decimal.zero) {
        await placeSpotMarketOrder(side: 'SELL', quantity: spotQty);
      }
    }
    _liveTradingGateService.disable(scope: _currentWriteScope());
    await _logState('LIVE_EMERGENCY_EXIT');
  }

  Future<void> markWritesBlocked(String reason) async {
    _writesBlocked = true;
    _lastError = reason;
    _consecutiveWriteFailures += 1;
    if (_consecutiveWriteFailures >= 2) {
      _liveTradingGateService.disable(scope: _currentWriteScope());
    }
    _emitState();
    await _logState('WRITES_BLOCKED');
  }

  Future<void> clearWritesBlocked() async {
    _writesBlocked = false;
    _lastError = null;
    _consecutiveWriteFailures = 0;
    _emitState();
    await _logState('WRITES_CLEARED');
  }

  void _ensureWritesAllowed() {
    if (!_liveTradingGateService.isEnabledForScope(_currentWriteScope())) {
      throw StateError('LIVE write operations are disabled');
    }
    if (_writesBlocked) {
      throw StateError(_lastError ?? 'LIVE write operations are blocked');
    }
  }

  Future<Decimal> _decimalSetting(
    String key,
    Decimal defaultValue, {
    String? symbol,
    String? keyProfileId,
  }) async {
    final raw = await AppUiSettings.readScopedSettingValue(
      _db,
      key: key,
      symbol: symbol,
      keyProfileId: keyProfileId,
    );
    if (raw == null) {
      return defaultValue;
    }
    final parsed = Decimal.tryParse(raw);
    if (parsed == null || parsed <= Decimal.zero) {
      return defaultValue;
    }
    return parsed;
  }

  Future<void> _ensureManualSpotOrderLimit(Decimal notional) async {
    final limit = await manualSpotOrderLimit();
    if (notional > limit) {
      throw StateError('Spot order notional exceeds $limit USDT');
    }
  }

  Future<void> _ensureManualFuturesOrderLimit({
    required Decimal notional,
    required String side,
    required bool reduceOnly,
    bool allowLongOpen = false,
    bool allowExistingLongExposure = false,
    required Decimal currentShortNotional,
    required Decimal currentLongNotional,
  }) async {
    final orderLimit = await manualFuturesOrderLimit();
    final shortLimit = await manualFuturesShortLimit();
    if (!reduceOnly && notional > orderLimit) {
      throw StateError('Futures order notional exceeds $orderLimit USDT');
    }
    if (side == 'BUY' && !reduceOnly && !allowLongOpen) {
      throw StateError('Non reduceOnly BUY is disabled for live futures');
    }
    if (!reduceOnly &&
        currentLongNotional > Decimal.zero &&
        !allowLongOpen &&
        !allowExistingLongExposure) {
      throw StateError('Long futures exposure is disabled for live futures');
    }
    if (side == 'SELL' && !reduceOnly) {
      final projected = currentShortNotional + notional;
      if (projected > shortLimit) {
        throw StateError('Futures short notional exceeds $shortLimit USDT');
      }
    }
    if (reduceOnly && side == 'BUY' && notional > currentShortNotional) {
      throw StateError('ReduceOnly buy exceeds current short exposure');
    }
    if (reduceOnly && side == 'SELL' && notional > currentLongNotional) {
      throw StateError('ReduceOnly sell exceeds current long exposure');
    }
  }

  bool _isAutoFuturesLongOpen({
    required String source,
    required String? positionSide,
    required String side,
    required bool reduceOnly,
  }) {
    return source == 'autoFuturesLongGrid' &&
        positionSide == 'LONG' &&
        side == 'BUY' &&
        !reduceOnly;
  }

  Future<void> _ensureDailySpotLimit(Decimal newOrderNotional) async {
    final now = DateTime.now().toUtc();
    final start = DateTime.utc(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 1));
    final rows = await (_db.select(_db.orders)
          ..where(
            (tbl) =>
                tbl.environment.equals('live') &
                tbl.source.equals('manualTest') &
                tbl.marketType.equals('spot') &
                tbl.status.equals('filled') &
                tbl.completedAt.isBiggerOrEqualValue(start) &
                tbl.completedAt.isSmallerThanValue(end),
          ))
        .get();
    var total = Decimal.zero;
    for (final row in rows) {
      total += Decimal.tryParse(row.quoteQuantity ?? '0') ?? Decimal.zero;
    }
    final limit = await manualSpotDailyLimit();
    if (total + newOrderNotional > limit) {
      throw StateError(
        'Daily live spot verification turnover exceeds $limit USDT',
      );
    }
  }

  Future<void> _ensureDailyAutoSpotLimit({
    required Decimal newOrderNotional,
    required String strategyId,
    required String symbol,
  }) async {
    final normalizedSymbol = symbol.toUpperCase();
    final total = await dailyAutoSpotGridTurnover(
      strategyId: strategyId,
      symbol: normalizedSymbol,
    );
    final limit = await autoSpotGridDailyTurnoverLimit();
    if (total + newOrderNotional > limit) {
      throw StateError(
        'Daily live auto spot grid turnover exceeds $limit USDT for $normalizedSymbol strategy $strategyId',
      );
    }
  }

  Future<Decimal> dailyAutoSpotGridTurnover({
    required String strategyId,
    required String symbol,
    DateTime? now,
  }) async {
    final utcNow = (now ?? DateTime.now()).toUtc();
    final start = DateTime.utc(utcNow.year, utcNow.month, utcNow.day);
    final end = start.add(const Duration(days: 1));
    final normalizedSymbol = symbol.toUpperCase();
    final rows = await (_db.select(_db.orders)
          ..where(
            (tbl) =>
                (tbl.environment.equals('live') |
                    tbl.environment.equals('LIVE_SPOT_GRID')) &
                tbl.source.equals('autoSpotGrid') &
                tbl.marketType.equals('spot') &
                tbl.strategyId.equals(strategyId) &
                tbl.symbol.equals(normalizedSymbol) &
                tbl.status.equals('filled') &
                tbl.completedAt.isBiggerOrEqualValue(start) &
                tbl.completedAt.isSmallerThanValue(end),
          ))
        .get();
    var total = Decimal.zero;
    for (final row in rows) {
      total += Decimal.tryParse(row.quoteQuantity ?? '0') ?? Decimal.zero;
    }
    return total;
  }

  Future<String> _executeSpotOrder({
    String symbol = 'BTCUSDT',
    required String clientOrderId,
    String? strategyId,
    String source = 'manualTest',
    required String side,
    Decimal? quantity,
    required Decimal price,
    required String orderType,
    Decimal? quoteOrderQty,
    String? timeInForce,
    String purpose = 'liveTradingVerification',
    String? gridLevelId,
    String? parentOrderId,
  }) async {
    final existing = await _orderRepository.getOrderDetailsByClientOrderId(
      clientOrderId,
    );
    if (existing != null) {
      return existing.order.id;
    }
    final now = DateTime.now().toUtc();
    final orderId = _uuid.v4();
    await _insertIntentOrder(
      orderId: orderId,
      clientOrderId: clientOrderId,
      strategyId: strategyId ?? _strategyId(),
      source: source,
      marketType: 'spot',
      accountType: 'spotSubAccount',
      side: side,
      orderType: orderType,
      price: price,
      quantity: quantity,
      quoteOrderQty: quoteOrderQty,
      reduceOnly: false,
      purpose: purpose,
      gridLevelId: gridLevelId,
      parentOrderId: parentOrderId,
      symbol: symbol,
      keyProfileId: _spotKeyProfileId,
      accountBindingId: _spotAccountBindingId,
      createdAt: now,
    );
    final client = _spotClient!;
    await _updateOrderStatus(
      orderId,
      status: 'submitting',
      submittedAt: now,
      updatedAt: now,
    );
    try {
      final response = quoteOrderQty != null
          ? await client.placeMarketOrder(
              symbol: symbol,
              side: side,
              quoteOrderQty: quoteOrderQty,
              clientOrderId: clientOrderId,
            )
          : (timeInForce == null
              ? await client.placeMarketOrder(
                  symbol: symbol,
                  side: side,
                  quantity: quantity,
                  clientOrderId: clientOrderId,
                )
              : await client.placeLimitOrder(
                  symbol: symbol,
                  side: side,
                  quantity: quantity!,
                  price: price,
                  clientOrderId: clientOrderId,
                  timeInForce: timeInForce,
                ));
      await _mergeSpotOrderResponse(orderId, response);
      await refreshSpotSnapshot();
      return orderId;
    } catch (error) {
      await _recoverOrderByClientOrderId(
        orderId: orderId,
        clientOrderId: clientOrderId,
        symbol: symbol,
        marketType: 'spot',
        error: error,
      );
      return orderId;
    }
  }

  Future<String> _executeFuturesOrder({
    required String clientOrderId,
    required String symbol,
    String? strategyId,
    String source = 'manualTest',
    required String side,
    required Decimal quantity,
    required Decimal price,
    required bool reduceOnly,
    required String orderType,
    String? positionSide,
    String? gridLevelId,
    String purpose = 'liveTradingVerification',
  }) async {
    final existing = await _orderRepository.getOrderDetailsByClientOrderId(
      clientOrderId,
    );
    if (existing != null) {
      return existing.order.id;
    }
    await connectFuturesForSymbol(symbol);
    final now = DateTime.now().toUtc();
    final orderId = _uuid.v4();
    await _insertIntentOrder(
      orderId: orderId,
      clientOrderId: clientOrderId,
      symbol: symbol,
      strategyId: strategyId ?? _strategyId(),
      source: source,
      marketType: 'usdtFutures',
      accountType: 'futuresSubAccount',
      side: side,
      orderType: orderType,
      price: price,
      quantity: quantity,
      quoteOrderQty: null,
      reduceOnly: reduceOnly,
      purpose: purpose,
      gridLevelId: gridLevelId,
      keyProfileId: _futuresKeyProfileId,
      accountBindingId: _futuresAccountBindingId,
      createdAt: now,
    );
    var client = _futuresClient;
    if (client == null || _futuresClientSymbol != symbol.toUpperCase()) {
      throw StateError(
        'Futures live not connected for ${symbol.toUpperCase()}',
      );
    }
    await _updateOrderStatus(
      orderId,
      status: 'submitting',
      submittedAt: now,
      updatedAt: now,
    );
    try {
      final positionMode = await _currentPositionMode(symbol: symbol);
      await connectFuturesForSymbol(symbol);
      client = _futuresClient;
      if (client == null || _futuresClientSymbol != symbol.toUpperCase()) {
        throw StateError(
          'Futures live not connected for ${symbol.toUpperCase()}',
        );
      }
      final resolvedPositionSide = positionMode == 'HEDGE'
          ? (positionSide ?? (side == 'SELL' ? 'SHORT' : 'SHORT'))
          : 'BOTH';
      final response = orderType == 'MARKET'
          ? await client.placeMarketOrder(
              symbol: symbol,
              side: side,
              quantity: quantity,
              clientOrderId: clientOrderId,
              positionSide: resolvedPositionSide,
              reduceOnly: reduceOnly,
            )
          : await client.placeLimitOrder(
              symbol: symbol,
              side: side,
              quantity: quantity,
              price: price,
              clientOrderId: clientOrderId,
              positionSide: resolvedPositionSide,
              reduceOnly: reduceOnly,
            );
      await _mergeFuturesOrderResponse(orderId, response);
      await refreshFuturesSnapshotForSymbol(symbol);
      return orderId;
    } catch (error) {
      await _recoverOrderByClientOrderId(
        orderId: orderId,
        clientOrderId: clientOrderId,
        symbol: symbol,
        marketType: 'usdtFutures',
        error: error,
      );
      return orderId;
    }
  }

  Future<void> _recoverOrderByClientOrderId({
    required String orderId,
    required String clientOrderId,
    required String symbol,
    required String marketType,
    required Object error,
  }) async {
    if (error is TimeoutException || _isDuplicateOrderSent(error)) {
      if (marketType == 'spot') {
        try {
          final recovered = await _spotClient?.getOrderByClientOrderId(
            symbol: symbol,
            clientOrderId: clientOrderId,
          );
          if (recovered != null) {
            await _mergeSpotOrderResponse(orderId, recovered);
            return;
          }
        } catch (queryError) {
          if (_isOrderDoesNotExist(queryError)) {
            final local = await (_db.select(_db.orders)
                  ..where((tbl) => tbl.id.equals(orderId)))
                .getSingleOrNull();
            if (local != null &&
                await _markLocalOrderNotCreated(local, queryError)) {
              return;
            }
          }
          rethrow;
        }
      } else {
        try {
          await connectFuturesForSymbol(symbol);
          final futuresClient = _futuresClient;
          if (futuresClient == null ||
              _futuresClientSymbol != symbol.toUpperCase()) {
            throw StateError(
              'Futures live not connected for ${symbol.toUpperCase()}',
            );
          }
          final recovered = await futuresClient.getOrderByClientOrderId(
            symbol: symbol,
            clientOrderId: clientOrderId,
          );
          if (recovered != null) {
            await _mergeFuturesOrderResponse(orderId, recovered);
            return;
          }
        } catch (queryError) {
          if (_isOrderDoesNotExist(queryError)) {
            final local = await (_db.select(_db.orders)
                  ..where((tbl) => tbl.id.equals(orderId)))
                .getSingleOrNull();
            if (local != null &&
                await _markLocalOrderNotCreated(local, queryError)) {
              return;
            }
          }
          rethrow;
        }
      }
    }
    await _updateOrderStatus(
      orderId,
      status: 'unknown',
      errorCode: 'UNKNOWN',
      errorMessage: error.toString(),
      updatedAt: DateTime.now().toUtc(),
    );
    if (marketType == 'spot') {
      await markWritesBlocked(
        'Unable to confirm order status for $clientOrderId',
      );
    }
  }

  bool _isOrderDoesNotExist(Object error) {
    return error is BinanceRequestException && error.binanceCode == -2013;
  }

  bool _isDuplicateOrderSent(Object error) {
    return error is BinanceRequestException &&
        error.binanceCode == -2010 &&
        error.message.toLowerCase().contains('duplicate order sent');
  }

  bool _isDefinitiveSpotSubmitRejection(Object error) {
    if (error is! BinanceRequestException) {
      return false;
    }
    if (_isDuplicateOrderSent(error)) {
      return false;
    }
    return const {
      -2010,
      -2011,
      -2013,
      -1013,
      -1100,
    }.contains(error.binanceCode);
  }

  Future<bool> _markLocalGridSubmissionRejected(
    Order order,
    Object error,
  ) async {
    final exchangeOrderId = order.exchangeOrderId;
    final isLocalOnly = order.source == 'autoSpotGrid' &&
        order.marketType == 'spot' &&
        (exchangeOrderId == null || exchangeOrderId.isEmpty) &&
        (Decimal.tryParse(order.executedQuantity) ?? Decimal.zero) ==
            Decimal.zero;
    if (!isLocalOnly || !_isDefinitiveSpotSubmitRejection(error)) {
      return false;
    }
    await _updateOrderStatus(
      order.id,
      status: 'failed',
      errorCode: error is BinanceRequestException
          ? error.binanceCode?.toString()
          : 'REJECTED',
      errorMessage: error.toString(),
      updatedAt: DateTime.now().toUtc(),
      completedAt: DateTime.now().toUtc(),
    );
    return true;
  }

  Future<bool> _markLocalOrderNotCreated(Order order, Object error) async {
    final exchangeOrderId = order.exchangeOrderId;
    final isLocalOnly = (exchangeOrderId == null || exchangeOrderId.isEmpty) &&
        (Decimal.tryParse(order.executedQuantity) ?? Decimal.zero) ==
            Decimal.zero;
    final canResolve = const {
      'created',
      'submitting',
      'unknown',
      'failed',
    }.contains(order.status);
    if (!isLocalOnly || !canResolve) {
      return false;
    }
    await _updateOrderStatus(
      order.id,
      status: 'failed',
      errorCode: '-2013',
      errorMessage: error.toString(),
      updatedAt: DateTime.now().toUtc(),
      completedAt: DateTime.now().toUtc(),
    );
    return true;
  }

  Future<void> _mergeSpotOrderResponse(
    String orderId,
    SpotOpenOrder response,
  ) async {
    final now = DateTime.now().toUtc();
    await _updateOrderStatus(
      orderId,
      exchangeOrderId: response.orderId,
      status: _normalizeOrderStatus(response.status),
      executedQuantity: response.executedQuantity,
      averagePrice: response.price,
      quoteQuantity: response.price * response.executedQuantity,
      updatedAt: now,
      completedAt: _terminalTimestamp(response.status, now),
      cancelledAt: response.status.toUpperCase() == 'CANCELED' ? now : null,
    );
  }

  Future<void> _mergeFuturesOrderResponse(
    String orderId,
    FuturesOrder response,
  ) async {
    final now = DateTime.now().toUtc();
    await _updateOrderStatus(
      orderId,
      exchangeOrderId: response.orderId,
      status: _normalizeOrderStatus(response.status),
      executedQuantity: response.executedQuantity,
      averagePrice: response.averagePrice,
      quoteQuantity: response.price * response.executedQuantity,
      updatedAt: now,
      completedAt: _terminalTimestamp(response.status, now),
      cancelledAt: response.status.toUpperCase() == 'CANCELED' ? now : null,
    );
  }

  Future<void> _insertIntentOrder({
    required String orderId,
    required String clientOrderId,
    required String strategyId,
    String symbol = 'BTCUSDT',
    required String source,
    required String marketType,
    required String accountType,
    required String side,
    required String orderType,
    required Decimal price,
    required Decimal? quantity,
    required Decimal? quoteOrderQty,
    required bool reduceOnly,
    required String purpose,
    String? gridLevelId,
    String? parentOrderId,
    String? keyProfileId,
    String? accountBindingId,
    required DateTime createdAt,
  }) async {
    await _db.into(_db.orders).insert(
          OrdersCompanion.insert(
            id: orderId,
            strategyId: strategyId,
            accountType: accountType,
            marketType: marketType,
            environment: const Value('live'),
            source: Value(source),
            symbol: symbol.toUpperCase(),
            clientOrderId: clientOrderId,
            side: side,
            orderType: orderType,
            timeInForce: Value(orderType == 'LIMIT' ? 'GTC' : null),
            price: Value(orderType == 'LIMIT' ? price.toString() : null),
            originalQuantity: quantity == null ? '0' : quantity.toString(),
            quoteQuantity: Value(quoteOrderQty?.toString()),
            reduceOnly: Value(reduceOnly),
            status: 'created',
            purpose: purpose,
            gridLevelId: Value(gridLevelId),
            parentOrderId: Value(parentOrderId),
            keyProfileId: Value(keyProfileId),
            accountBindingId: Value(accountBindingId),
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<void> _updateOrderStatus(
    String orderId, {
    String? exchangeOrderId,
    required String status,
    Decimal? executedQuantity,
    Decimal? averagePrice,
    Decimal? quoteQuantity,
    DateTime? submittedAt,
    DateTime? updatedAt,
    DateTime? completedAt,
    DateTime? cancelledAt,
    String? errorCode,
    String? errorMessage,
  }) async {
    final now = updatedAt ?? DateTime.now().toUtc();
    await (_db.update(_db.orders)..where((tbl) => tbl.id.equals(orderId)))
        .write(
      OrdersCompanion(
        exchangeOrderId: Value(exchangeOrderId),
        status: Value(status),
        executedQuantity: executedQuantity == null
            ? const Value.absent()
            : Value(executedQuantity.toString()),
        averagePrice: averagePrice == null
            ? const Value.absent()
            : Value(averagePrice.toString()),
        quoteQuantity: quoteQuantity == null
            ? const Value.absent()
            : Value(quoteQuantity.toString()),
        submittedAt: Value(submittedAt),
        updatedAt: Value(now),
        completedAt: Value(completedAt),
        cancelledAt: Value(cancelledAt),
        errorCode: errorCode == null ? const Value(null) : Value(errorCode),
        errorMessage:
            errorMessage == null ? const Value(null) : Value(errorMessage),
      ),
    );
  }

  Future<void> _updateLocalOrderStatus(
    String clientOrderId, {
    required String status,
    DateTime? cancelledAt,
  }) async {
    final order = await (_db.select(_db.orders)
          ..where(
            (tbl) => tbl.clientOrderId.equals(clientOrderId),
          ))
        .getSingleOrNull();
    if (order == null) {
      return;
    }
    await _updateOrderStatus(
      order.id,
      status: status,
      cancelledAt: cancelledAt,
      completedAt: status == 'filled' ? DateTime.now().toUtc() : null,
    );
  }

  Future<void> _cancelAppOrders({required String prefix}) async {
    final orders = await (_db.select(_db.orders)
          ..where(
            (tbl) =>
                tbl.environment.equals('live') &
                tbl.clientOrderId.like('$prefix%') &
                tbl.status.isIn([
                  'created',
                  'submitting',
                  'new',
                  'partiallyFilled',
                  'planned',
                ]),
          ))
        .get();
    for (final order in orders) {
      try {
        if (order.marketType == 'spot') {
          final normalizedSymbol = order.symbol.toUpperCase();
          await connectSpotForSymbol(normalizedSymbol);
          final client = _spotClient;
          if (client == null || _spotClientSymbol != normalizedSymbol) {
            throw StateError('Spot live not connected for $normalizedSymbol');
          }
          await client.cancelOrder(
            symbol: normalizedSymbol,
            clientOrderId: order.clientOrderId,
          );
        } else {
          final normalizedSymbol = order.symbol.toUpperCase();
          await connectFuturesForSymbol(normalizedSymbol);
          final client = _futuresClient;
          if (client == null || _futuresClientSymbol != normalizedSymbol) {
            throw StateError(
              'Futures live not connected for $normalizedSymbol',
            );
          }
          await client.cancelOrder(
            symbol: normalizedSymbol,
            clientOrderId: order.clientOrderId,
          );
        }
        await _updateOrderStatus(
          order.id,
          status: 'cancelled',
          cancelledAt: DateTime.now().toUtc(),
        );
      } catch (_) {
        await markWritesBlocked('Failed to cancel ${order.clientOrderId}');
      }
    }
  }

  Future<Decimal> _currentSpotBtcQuantity() async {
    final row = await (_db.select(_db.spotAccountSnapshots)
          ..orderBy([(t) => OrderingTerm.desc(t.recordedAt)])
          ..limit(1))
        .getSingleOrNull();
    return row == null
        ? Decimal.zero
        : Decimal.tryParse(row.btcFree) ?? Decimal.zero;
  }

  Future<Decimal> currentFuturesLongQuantity(String symbol) =>
      _currentFuturesLongQuantity(symbol);

  Future<Decimal> currentFuturesShortQuantity(String symbol) =>
      _currentFuturesShortQuantity(symbol);

  Future<Decimal> _currentFuturesLongQuantity(String symbol) async {
    final rows = await (_db.select(_db.futuresPositions)
          ..where(
            (tbl) =>
                tbl.symbol.equals(symbol.toUpperCase()) &
                tbl.positionSide.isIn(['LONG', 'BOTH']),
          ))
        .get();
    var total = Decimal.zero;
    for (final row in rows) {
      final amount = Decimal.tryParse(row.positionAmount) ?? Decimal.zero;
      if (row.positionSide == 'LONG' || amount > Decimal.zero) {
        total += amount.abs();
      }
    }
    return total;
  }

  Future<Decimal> _currentFuturesShortQuantity(String symbol) async {
    final rows = await (_db.select(_db.futuresPositions)
          ..where(
            (tbl) =>
                tbl.symbol.equals(symbol.toUpperCase()) &
                tbl.positionSide.isIn(['SHORT', 'BOTH']),
          ))
        .get();
    var total = Decimal.zero;
    for (final row in rows) {
      final amount = Decimal.tryParse(row.positionAmount) ?? Decimal.zero;
      if (row.positionSide == 'SHORT' || amount < Decimal.zero) {
        total += amount.abs();
      }
    }
    return total;
  }

  Future<Decimal> _currentFuturesLongNotional(String symbol) async {
    final long = await _currentFuturesLongQuantity(symbol);
    return long.abs() * _futuresReferencePrice(symbol);
  }

  Future<Decimal> _currentFuturesShortNotional(String symbol) async {
    final short = await _currentFuturesShortQuantity(symbol);
    return short.abs() * _futuresReferencePrice(symbol);
  }

  Future<String> _currentPositionMode({String symbol = 'BTCUSDT'}) async {
    final normalizedSymbol = symbol.toUpperCase();
    await connectFuturesForSymbol(normalizedSymbol);
    final client = _futuresClient;
    if (client != null && _futuresClientSymbol == normalizedSymbol) {
      try {
        return await client.getPositionMode() ? 'HEDGE' : 'ONE_WAY';
      } catch (_) {
        // Fall back to the last persisted snapshot if the position-mode query fails.
      }
    }
    final snapshot = await (_db.select(_db.futuresAccountSnapshots)
          ..orderBy([(t) => OrderingTerm.desc(t.recordedAt)])
          ..limit(1))
        .getSingleOrNull();
    return snapshot?.positionMode ?? 'ONE_WAY';
  }

  Future<void> _ensureFuturesLeverage({
    String symbol = 'BTCUSDT',
    required int leverage,
  }) async {
    final normalizedSymbol = symbol.toUpperCase();
    final targetLeverage = leverage.clamp(1, 125);
    await refreshFuturesSnapshotForSymbol(normalizedSymbol);
    final positions = await (_db.select(_db.futuresPositions)
          ..where((tbl) => tbl.symbol.equals(normalizedSymbol)))
        .get();
    final currentLeverages = positions
        .map((position) => int.tryParse(position.leverage ?? '') ?? 0)
        .where((value) => value > 0)
        .toSet();
    if (currentLeverages.length == 1 &&
        currentLeverages.single == targetLeverage) {
      return;
    }
    await connectFuturesForSymbol(normalizedSymbol);
    final client = _futuresClient;
    if (client == null || _futuresClientSymbol != normalizedSymbol) {
      throw StateError('Futures live not connected for $normalizedSymbol');
    }
    await client.changeInitialLeverage(
      symbol: normalizedSymbol,
      leverage: targetLeverage,
    );
    await refreshFuturesSnapshotForSymbol(normalizedSymbol);
  }

  Future<void> _loadCredentials() async {
    if (_credentialsVault.cache.status != CredentialsCacheStatus.loaded) {
      await _credentialsVault.readOnce();
    }
    final loader = BinanceCredentialLoader(_credentialsVault.cache);
    final spot = await loader.loadSpot();
    final futures = await loader.loadFutures();
    if (spot == null || futures == null) {
      throw StateError('Live credentials are not fully configured');
    }
    _spotCredentials = spot;
    _futuresCredentials = futures;
  }

  Future<void> _loadRules() async {
    await ensureSpotRules(symbol: 'BTCUSDT', force: true);
    _futuresRules = await _exchangeInfoService.loadFuturesRules(
      symbol: 'BTCUSDT',
    );
  }

  Future<BinanceSymbolRules?> ensureSpotRules({
    String symbol = 'BTCUSDT',
    bool force = false,
  }) async {
    final normalized = symbol.toUpperCase();
    final now = DateTime.now().toUtc();
    final loadedAt = _spotRulesLoadedAtBySymbol[normalized];
    final cachedRules = _spotRulesBySymbol[normalized];
    if (!force &&
        cachedRules != null &&
        loadedAt != null &&
        now.difference(loadedAt) < const Duration(minutes: 10)) {
      _spotRulesDiagnostics = SpotExchangeRulesDiagnostics(
        url: 'https://api.binance.com/api/v3/exchangeInfo?symbol=$normalized',
        loaded: true,
        lastSuccessAt: loadedAt,
        lastAttemptAt: now,
        usingCache: true,
      );
      _spotRulesDiagnosticsBySymbol[normalized] = _spotRulesDiagnostics!;
      _spotRules = cachedRules;
      _spotRulesLoadedAt = loadedAt;
      return cachedRules;
    }
    final url =
        '${_exchangeInfoService.spotBaseUrl}/api/v3/exchangeInfo?symbol=$normalized';
    try {
      _spotRulesDiagnostics = SpotExchangeRulesDiagnostics(
        url: url,
        loaded: cachedRules != null,
        lastSuccessAt: loadedAt,
        lastAttemptAt: now,
        usingCache: cachedRules != null,
      );
      _spotRulesDiagnosticsBySymbol[normalized] = _spotRulesDiagnostics!;
      final rules = await _exchangeInfoService.loadSpotRules(
        symbol: normalized,
      );
      _spotRulesBySymbol[normalized] = rules;
      _spotRules = rules;
      _spotRulesLoadedAt = DateTime.now().toUtc();
      _spotRulesLoadedAtBySymbol[normalized] = _spotRulesLoadedAt!;
      _spotRulesDiagnostics = SpotExchangeRulesDiagnostics(
        url: url,
        loaded: true,
        lastSuccessAt: _spotRulesLoadedAt,
        lastAttemptAt: now,
      );
      _spotRulesDiagnosticsBySymbol[normalized] = _spotRulesDiagnostics!;
      return rules;
    } on DioException catch (error) {
      final data = error.response?.data;
      int? code;
      String? message;
      if (data is Map) {
        code = int.tryParse('${data['code'] ?? ''}');
        message = data['msg']?.toString();
      }
      _spotRulesDiagnostics = SpotExchangeRulesDiagnostics(
        url: url,
        loaded: cachedRules != null,
        httpStatus: error.response?.statusCode,
        binanceCode: code,
        binanceMessage: message,
        lastSuccessAt: loadedAt,
        lastAttemptAt: now,
        usingCache: cachedRules != null,
        lastError: error.message,
      );
      _spotRulesDiagnosticsBySymbol[normalized] = _spotRulesDiagnostics!;
      if (cachedRules != null) {
        _spotRules = cachedRules;
        _spotRulesLoadedAt = loadedAt;
        return cachedRules;
      }
      rethrow;
    } catch (error) {
      _spotRulesDiagnostics = SpotExchangeRulesDiagnostics(
        url: url,
        loaded: cachedRules != null,
        lastSuccessAt: loadedAt,
        lastAttemptAt: now,
        usingCache: cachedRules != null,
        lastError: error.toString(),
      );
      _spotRulesDiagnosticsBySymbol[normalized] = _spotRulesDiagnostics!;
      if (cachedRules != null) {
        _spotRules = cachedRules;
        _spotRulesLoadedAt = loadedAt;
        return cachedRules;
      }
      rethrow;
    }
  }

  Future<void> ensureFuturesHedgeMode(
    String symbol, {
    bool refreshSnapshot = true,
  }) async {
    final normalizedSymbol = symbol.toUpperCase();
    await connectFuturesForSymbol(normalizedSymbol);
    final currentMode = await _currentPositionMode(symbol: normalizedSymbol);
    if (currentMode == 'HEDGE') {
      if (refreshSnapshot) {
        await refreshFuturesSnapshotForSymbol(normalizedSymbol);
      }
      return;
    }
    final client = _futuresClient;
    if (client == null || _futuresClientSymbol != normalizedSymbol) {
      throw StateError('Futures live not connected for $normalizedSymbol');
    }
    try {
      await client.changePositionMode(hedgeMode: true);
    } catch (error) {
      if (error is BinanceRequestException && error.binanceCode == -4059) {
        final modeAfterNoop = await _currentPositionMode(
          symbol: normalizedSymbol,
        );
        if (modeAfterNoop == 'HEDGE') {
          await refreshFuturesSnapshotForSymbol(normalizedSymbol);
          return;
        }
      }
      throw StateError(
        'Binance Futures 当前不是双向持仓模式，且自动切换失败: $error。'
        '请先确认该合约账户没有未成交挂单或不兼容持仓，然后在 Binance Futures 开启 Hedge Mode/双向持仓模式。',
      );
    }
    await refreshFuturesSnapshotForSymbol(normalizedSymbol);
    final refreshedMode = await _currentPositionMode(symbol: normalizedSymbol);
    if (refreshedMode != 'HEDGE') {
      throw StateError(
        'Binance Futures 持仓模式仍不是双向持仓模式，当前=$refreshedMode。'
        '请在 Binance Futures 开启 Hedge Mode/双向持仓模式后重试。',
      );
    }
  }

  Future<void> _handleFuturesUserDataMessage(
    dynamic message, {
    required String symbol,
    required String keyProfileId,
  }) async {
    final session = _futuresUserDataSessions[keyProfileId];
    session?.lastEventAt = DateTime.now().toUtc();
    if (message is! String) {
      return;
    }
    late final Object? decoded;
    try {
      decoded = jsonDecode(message);
    } catch (error) {
      await _logRepository.append(
        level: 'warning',
        module: 'FUTURES_USER_STREAM',
        message: 'Unable to decode futures user stream message',
        extraJson: jsonEncode({'error': error.toString()}),
      );
      return;
    }
    if (decoded is! Map) {
      return;
    }
    final event = Map<String, dynamic>.from(decoded);
    final eventType = event['e']?.toString();
    if (eventType == 'ORDER_TRADE_UPDATE') {
      await _handleFuturesOrderTradeUpdate(
        event,
        fallbackSymbol: symbol,
        keyProfileId: keyProfileId,
      );
      return;
    }
    if (eventType == 'ACCOUNT_UPDATE') {
      await _refreshFuturesSnapshotFromUserData(
        symbol,
        keyProfileId: keyProfileId,
      );
    }
  }

  Future<void> _handleFuturesOrderTradeUpdate(
    Map<String, dynamic> event, {
    required String fallbackSymbol,
    required String keyProfileId,
  }) async {
    final rawOrder = event['o'];
    if (rawOrder is! Map) {
      return;
    }
    final session = _futuresUserDataSessions[keyProfileId];
    final orderEvent = Map<String, dynamic>.from(rawOrder);
    final clientOrderId = orderEvent['c']?.toString();
    if (clientOrderId == null || clientOrderId.isEmpty) {
      return;
    }
    final local = await (_db.select(_db.orders)
          ..where(
            (tbl) => tbl.clientOrderId.equals(clientOrderId),
          ))
        .getSingleOrNull();
    final symbol = orderEvent['s']?.toString() ?? fallbackSymbol;
    _debugTrace(
      'FUTURES_WS',
      'ORDER_TRADE_UPDATE symbol=$symbol profile=$keyProfileId '
          'client=$clientOrderId side=${orderEvent['S']} '
          'status=${orderEvent['X']} executed=${orderEvent['z']} '
          'avg=${orderEvent['ap']} local=${local?.id ?? '-'} '
          'grid=${local?.gridLevelId ?? '-'}',
    );
    if (local == null) {
      if (_isTerminalFuturesExchangeStatus(orderEvent['X']?.toString())) {
        _debugTrace(
          'FUTURES_WS',
          'local order not found; fallback snapshot symbol=$symbol '
              'client=$clientOrderId',
        );
        await _refreshFuturesSnapshotFromUserData(
          symbol,
          keyProfileId: keyProfileId,
        );
      }
      return;
    }
    final now = _eventTime(event['E']) ?? DateTime.now().toUtc();
    final status = _normalizeOrderStatus(orderEvent['X']?.toString() ?? '');
    final executed = _decimalFrom(orderEvent['z']);
    final averagePrice = _decimalFrom(orderEvent['ap']);
    final limitPrice = _decimalFrom(orderEvent['p']);
    final avg = averagePrice > Decimal.zero ? averagePrice : limitPrice;
    await _updateOrderStatus(
      local.id,
      exchangeOrderId: orderEvent['i']?.toString(),
      status: status,
      executedQuantity: executed,
      averagePrice: avg > Decimal.zero ? avg : null,
      quoteQuantity: avg > Decimal.zero ? avg * executed : null,
      updatedAt: now,
      completedAt: _terminalTimestamp(status, now),
      cancelledAt: status == 'cancelled' ? now : null,
      errorCode: status == 'rejected' ? orderEvent['r']?.toString() : null,
      errorMessage: status == 'rejected' ? orderEvent['r']?.toString() : null,
    );
    final updated = await (_db.select(_db.orders)
          ..where((tbl) => tbl.id.equals(local.id)))
        .getSingleOrNull();
    if (updated != null) {
      await (_futuresRepository ??= FuturesAccountRepository(_db))
          .saveHistoricalOrderFromLocalOrder(
        updated,
        environment: 'live',
        keyProfileId: keyProfileId,
        accountBindingId: session?.accountBindingId,
      );
      _debugTrace(
        'FUTURES_WS',
        'local order updated client=${updated.clientOrderId} '
            'side=${updated.side} status=${updated.status} '
            'executed=${updated.executedQuantity} '
            'grid=${updated.gridLevelId ?? '-'} historicalCache=written',
      );
    }
    if (updated != null && updated.source == 'autoFuturesLongGrid') {
      await _updateFuturesLongGridLevelFromOrder(updated);
    }
    if (updated != null && !_futuresUserOrderUpdateController.isClosed) {
      _futuresUserOrderUpdateController.add(
        FuturesUserOrderUpdate(
          symbol: symbol.toUpperCase(),
          clientOrderId: clientOrderId,
          gridLevelId: updated.gridLevelId,
          side: updated.side,
          status: updated.status,
          source: updated.source,
          strategyId: updated.strategyId,
          isTerminal: _isTerminalFuturesExchangeStatus(
            orderEvent['X']?.toString(),
          ),
          receivedAt: now,
        ),
      );
    }
    if (_isTerminalFuturesExchangeStatus(orderEvent['X']?.toString())) {
      await _refreshFuturesSnapshotFromUserData(
        symbol,
        keyProfileId: keyProfileId,
      );
    }
  }

  Future<void> _refreshFuturesSnapshotFromUserData(
    String symbol, {
    required String keyProfileId,
  }) async {
    final session = _futuresUserDataSessions[keyProfileId];
    if (session == null || session.refreshing) {
      return;
    }
    session.refreshing = true;
    try {
      await _refreshFuturesSnapshotForClient(
        symbol: symbol,
        client: session.client,
        keyProfileId: session.keyProfileId,
        accountBindingId: session.accountBindingId,
        includeHistory: false,
      );
    } catch (error) {
      _lastError = error.toString();
      await _logRepository.append(
        level: 'warning',
        module: 'FUTURES_USER_STREAM',
        message: 'Futures user data fallback snapshot failed',
        extraJson: jsonEncode({
          'symbol': symbol.toUpperCase(),
          'keyProfileId': keyProfileId,
          'error': error.toString(),
        }),
      );
    } finally {
      session.refreshing = false;
    }
  }

  Future<void> _keepAliveFuturesUserDataListenKey(String keyProfileId) async {
    final session = _futuresUserDataSessions[keyProfileId];
    final listenKey = session?.listenKey;
    final client = session?.client;
    if (listenKey == null || client == null) {
      return;
    }
    try {
      await client.keepAliveListenKey(listenKey);
    } catch (error) {
      _scheduleFuturesUserDataReconnect(keyProfileId);
      await _logRepository.append(
        level: 'warning',
        module: 'FUTURES_USER_STREAM',
        message: 'Futures listenKey keepAlive failed',
        extraJson: jsonEncode({
          'keyProfileId': keyProfileId,
          'error': error.toString(),
        }),
      );
    }
  }

  Future<void> _handleFuturesUserDataDisconnect({
    required String symbol,
    required String keyProfileId,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    final session = _futuresUserDataSessions[keyProfileId];
    if (session == null) {
      return;
    }
    await _closeFuturesUserDataConnection(
      session: session,
      closeListenKey: false,
    );
    if (!session.enabled) {
      session.wsStatus = BinanceAccountStreamStatus.disconnected;
      _syncCurrentFuturesWsStatus();
      _emitState();
      return;
    }
    session.wsStatus = BinanceAccountStreamStatus.reconnecting;
    _syncCurrentFuturesWsStatus();
    _emitState();
    await _logRepository.append(
      level: error == null ? 'warning' : 'error',
      module: 'FUTURES_USER_STREAM',
      message: 'Futures user data stream disconnected',
      extraJson: jsonEncode({
        'symbol': symbol.toUpperCase(),
        'keyProfileId': keyProfileId,
        if (error != null) 'error': error.toString(),
        if (stackTrace != null) 'stackTrace': stackTrace.toString(),
      }),
    );
    await _refreshFuturesSnapshotFromUserData(
      symbol,
      keyProfileId: keyProfileId,
    );
    _scheduleFuturesUserDataReconnect(keyProfileId);
  }

  void _scheduleFuturesUserDataReconnect(String keyProfileId) {
    final session = _futuresUserDataSessions[keyProfileId];
    if (session == null ||
        !session.enabled ||
        session.reconnectTimer?.isActive == true) {
      return;
    }
    session.wsStatus = BinanceAccountStreamStatus.reconnecting;
    _syncCurrentFuturesWsStatus();
    _emitState();
    session.reconnectTimer = Timer(const Duration(seconds: 5), () {
      session.reconnectTimer = null;
      if (session.enabled) {
        unawaited(
          startFuturesUserDataStream(
            symbol: session.symbol,
            consumerKey:
                session.consumers.isEmpty ? 'default' : session.consumers.first,
          ),
        );
      }
    });
  }

  bool _isRetryableFuturesUserDataError(Object error) {
    final message = error.toString();
    return !message.contains('未绑定') &&
        !message.contains('未验证通过') &&
        !message.contains('Profile 不存在') &&
        !message.contains('API Key Profile') &&
        !message.contains('Key 类型错误');
  }

  Future<void> _closeFuturesUserDataConnection({
    required _FuturesUserDataSession session,
    required bool closeListenKey,
  }) async {
    session.keepAliveTimer?.cancel();
    session.keepAliveTimer = null;
    await session.subscription?.cancel();
    session.subscription = null;
    final channel = session.channel;
    session.channel = null;
    await channel?.sink.close();
    final listenKey = session.listenKey;
    session.listenKey = null;
    if (closeListenKey && listenKey != null) {
      try {
        await session.client.closeListenKey(listenKey);
      } catch (_) {
        // Closing a listenKey is best-effort; expired keys are harmless here.
      }
    }
  }

  Future<void> _updateFuturesLongGridLevelFromOrder(Order order) async {
    final gridLevelId = order.gridLevelId;
    if (gridLevelId == null || gridLevelId.isEmpty) {
      return;
    }
    final completedSell =
        order.side.toUpperCase() == 'SELL' && order.status == 'filled';
    final gridStatus =
        completedSell ? 'waitingBuy' : _gridStatusAfterFuturesLongOrder(order);
    final currentLevel = completedSell
        ? await (_db.select(_db.gridLevels)
              ..where((tbl) => tbl.id.equals(gridLevelId)))
            .getSingleOrNull()
        : null;
    final nextCycleNumber =
        currentLevel == null || currentLevel.lastCompletedOrderId == order.id
            ? currentLevel?.cycleNumber
            : currentLevel.cycleNumber + 1;
    _debugTrace(
      'LONG_STATE',
      'advance grid=$gridLevelId order=${order.clientOrderId} '
          'side=${order.side} orderStatus=${order.status} '
          'old=${currentLevel?.lifecycleStatus ?? currentLevel?.status ?? '-'} '
          'new=$gridStatus oldCycle=${currentLevel?.cycleNumber ?? '-'} '
          'newCycle=${nextCycleNumber ?? '-'}',
    );
    await (_db.update(_db.gridLevels)
          ..where((tbl) => tbl.id.equals(gridLevelId)))
        .write(
      GridLevelsCompanion(
        status: Value(gridStatus),
        lifecycleStatus: Value(gridStatus),
        linkedOrderId: completedSell ? const Value(null) : Value(order.id),
        activeOrderId: completedSell
            ? const Value(null)
            : _isActiveOrder(order)
                ? Value(order.id)
                : const Value(null),
        lastBuyOrderId: order.side == 'BUY'
            ? Value(order.id)
            : completedSell
                ? const Value(null)
                : const Value.absent(),
        lastSellOrderId: completedSell
            ? const Value(null)
            : order.side == 'SELL'
                ? Value(order.id)
                : const Value(null),
        lastCompletedOrderId:
            completedSell ? Value(order.id) : const Value.absent(),
        cycleNumber: nextCycleNumber == null
            ? const Value.absent()
            : Value(nextCycleNumber),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  String _gridStatusAfterFuturesLongOrder(Order order) {
    final side = order.side.toUpperCase();
    final executed = Decimal.tryParse(order.executedQuantity) ?? Decimal.zero;
    if (order.status == 'created' || order.status == 'submitting') {
      return side == 'BUY' ? 'buySubmitting' : 'sellSubmitting';
    }
    if (order.status == 'new') {
      return side == 'BUY' ? 'buyOpen' : 'sellOpen';
    }
    if (order.status == 'partiallyFilled') {
      return side == 'BUY' ? 'buyPartiallyFilled' : 'sellPartiallyFilled';
    }
    if (order.status == 'filled') {
      return side == 'BUY' ? 'buyFilled' : 'sellFilled';
    }
    if (side == 'BUY' &&
        executed == Decimal.zero &&
        const {'cancelled', 'rejected', 'expired'}.contains(order.status)) {
      return 'waitingBuy';
    }
    return 'error';
  }

  bool _isActiveOrder(Order order) {
    return const {
      'created',
      'submitting',
      'new',
      'partiallyFilled',
      'cancelling',
      'unknown',
    }.contains(order.status);
  }

  bool _isTerminalFuturesExchangeStatus(String? status) {
    return const {
      'FILLED',
      'CANCELED',
      'CANCELLED',
      'REJECTED',
      'EXPIRED',
    }.contains(status?.toUpperCase());
  }

  DateTime? _eventTime(Object? value) {
    final millis = value is int ? value : int.tryParse(value?.toString() ?? '');
    if (millis == null || millis <= 0) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  Decimal _decimalFrom(Object? value) {
    return Decimal.tryParse(value?.toString() ?? '') ?? Decimal.zero;
  }

  Future<void> _saveProfile({
    required String accountType,
    required String alias,
    required String? apiKey,
    required String? secretKey,
    required String? lastError,
  }) async {
    final now = DateTime.now().toUtc();
    await _db.into(_db.apiAccountProfiles).insertOnConflictUpdate(
          ApiAccountProfilesCompanion.insert(
            id: accountType,
            accountType: accountType,
            alias: alias,
            maskedApiKey: _maskApiKey(apiKey),
            isConfigured: Value(
              apiKey != null &&
                  apiKey.isNotEmpty &&
                  secretKey != null &&
                  secretKey.isNotEmpty,
            ),
            lastValidatedAt: Value(now),
            connectionStatus: const Value('connected'),
            permissionCheckResult: const Value('tradeEnabled'),
            lastError: Value(lastError),
            updatedAt: now,
          ),
        );
  }

  String _maskApiKey(String? apiKey) {
    if (apiKey == null || apiKey.trim().isEmpty) return '未配置';
    final value = apiKey.trim();
    if (value.length <= 8) return '****';
    return '${value.substring(0, 4)}****${value.substring(value.length - 4)}';
  }

  String _clientOrderId(String prefix) {
    const maxClientOrderIdLength = 36;
    final normalizedPrefix = prefix.endsWith('_') ? prefix : '${prefix}_';
    final suffixLength = maxClientOrderIdLength - normalizedPrefix.length;
    if (suffixLength <= 0) {
      throw StateError('Client order id prefix is too long: $prefix');
    }
    final suffix = _uuid.v4().replaceAll('-', '').substring(0, suffixLength);
    return '$normalizedPrefix$suffix';
  }

  String _strategyId() => 'live_manual_lab';

  Decimal _spotReferencePrice(String side) {
    final ticker = _marketDataCoordinator.latestSpotTicker;
    if (ticker == null) {
      return Decimal.fromInt(60000);
    }
    return side == 'BUY' ? ticker.askPrice : ticker.bidPrice;
  }

  Decimal _futuresReferencePrice([String? symbol]) {
    final normalized = symbol?.toUpperCase();
    return (normalized == null
                ? _marketDataCoordinator.latestFuturesMarkPrice
                : _marketDataCoordinator.latestFuturesMarkPriceFor(normalized))
            ?.markPrice ??
        Decimal.fromInt(60000);
  }

  Future<void> _logState(String message) async {
    await _logRepository.append(
      level: 'info',
      module: 'LIVE_EXECUTION',
      message: message,
      extraJson:
          '{"connected":$_connected,"writesBlocked":$writesBlocked,"failures":$_consecutiveWriteFailures}',
    );
  }

  void _emitState() {
    _syncCurrentFuturesWsStatus();
    if (!_stateController.isClosed) {
      _stateController.add(
        LiveExecutionState(
          spotRestStatus: _spotRestStatus.name,
          spotWsStatus: _spotWsStatus.name,
          futuresRestStatus: _futuresRestStatus.name,
          futuresWsStatus: _futuresWsStatus.name,
          writesBlocked: writesBlocked,
          liveTradingEnabled: _liveTradingGateService.isEnabledForScope(
            _currentWriteScope(),
          ),
          lastError: _lastError,
          restCooldownUntil: _binanceRestNextAllowedAt,
          restCooldownReason: _binanceRestCooldownReason,
        ),
      );
    }
  }

  _FuturesUserDataSession? _currentFuturesUserDataSession() {
    final profileId = _futuresKeyProfileId;
    if (profileId == null || profileId.trim().isEmpty) {
      return null;
    }
    return _futuresUserDataSessions[_profileScope(profileId)];
  }

  void _syncCurrentFuturesWsStatus() {
    final session = _currentFuturesUserDataSession();
    _futuresWsStatus =
        session?.wsStatus ?? BinanceAccountStreamStatus.disconnected;
  }

  String _profileScope(String? keyProfileId) {
    final value = keyProfileId?.trim();
    return value == null || value.isEmpty ? 'legacy' : value;
  }

  String _currentWriteScope() {
    final symbol = _futuresClientSymbol ?? _spotClientSymbol ?? 'global';
    final profileId = _futuresKeyProfileId ?? _spotKeyProfileId;
    return LiveTradingGateService.scopeFor(
      symbol: symbol,
      keyProfileId: profileId,
    );
  }

  String _normalizeOrderStatus(String status) {
    switch (status.toUpperCase()) {
      case 'NEW':
        return 'new';
      case 'PARTIALLY_FILLED':
        return 'partiallyFilled';
      case 'FILLED':
        return 'filled';
      case 'CANCELED':
      case 'CANCELLED':
        return 'cancelled';
      case 'REJECTED':
        return 'rejected';
      case 'EXPIRED':
        return 'expired';
      default:
        return 'unknown';
    }
  }

  DateTime? _terminalTimestamp(String status, DateTime now) {
    final normalized = _normalizeOrderStatus(status);
    if (normalized == 'filled' ||
        normalized == 'cancelled' ||
        normalized == 'rejected' ||
        normalized == 'expired') {
      return now;
    }
    return null;
  }

  void _debugTrace(String tag, String message) {
    assert(() {
      // ignore: avoid_print
      print('[GH_DIAG][$tag] $message');
      return true;
    }());
  }
}
