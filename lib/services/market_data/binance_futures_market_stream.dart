import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../repositories/basic_repositories.dart';
import 'binance_spot_market_stream.dart';
import 'futures_mark_price.dart';
import 'futures_ws_diagnostics.dart';
import 'market_data_connection.dart';
import 'market_data_status.dart';

class BinanceFuturesMarketStream {
  BinanceFuturesMarketStream({
    this.symbol = 'BTCUSDT',
    WebSocketFactory? streamFactory,
    math.Random? random,
    LogRepository? logRepository,
  })  : _streamFactory = streamFactory,
        _random = random ?? math.Random(),
        _logRepository = logRepository,
        _serviceInstanceId = const Uuid().v4(),
        _diagnostics = FuturesWsDiagnostics.initial(
          url: futuresMarkPriceStreamUrl('BTCUSDT'),
          streamName: futuresMarkPriceStreamName('BTCUSDT'),
        );

  final String symbol;
  final WebSocketFactory? _streamFactory;
  final math.Random _random;
  final LogRepository? _logRepository;
  final String _serviceInstanceId;
  final StreamController<MarketStreamEvent<FuturesMarkPrice>> _controller =
      StreamController.broadcast();
  final StreamController<FuturesWsDiagnostics> _diagnosticsController =
      StreamController.broadcast();

  StreamSubscription<dynamic>? _subscription;
  IOWebSocketChannel? _channel;
  WebSocket? _socket;
  Timer? _connectTimeoutTimer;
  Timer? _firstMessageTimer;
  Timer? _staleTimer;
  Timer? _reconnectTimer;
  bool _isConnecting = false;
  bool _isClosing = false;
  bool _disposed = false;
  int _terminatedGeneration = -1;
  bool _stopped = true;
  bool _connected = false;
  bool _firstMessageReceived = false;
  int _generation = 0;
  int _activeConnectionCount = 0;
  int reconnectAttempt = 0;
  int parseErrorCount = 0;
  String? _lastRawMessage;
  String? _lastJsonParseError;
  String? _lastExceptionType;
  String? _lastExceptionMessage;
  String? _lastStackTrace;
  int? _httpStatusCode;
  int? _closeCode;
  String? _closeReason;
  DateTime? _startedAt;
  DateTime? _lastConnectedAt;
  DateTime? _lastMessageAt;
  Duration? _nextReconnectDelay;
  bool _autoReconnect = true;
  MarketConnectionStatus _status = MarketConnectionStatus.disconnected;
  FuturesWsDiagnostics _diagnostics;

  Stream<MarketStreamEvent<FuturesMarkPrice>> get events => _controller.stream;

  Stream<FuturesWsDiagnostics> get diagnosticsStream =>
      _diagnosticsController.stream;

  FuturesWsDiagnostics get diagnostics => _diagnostics;
  MarketConnectionStatus get status => _status;
  bool get isConnected => _connected;
  int get activeConnectionCount => _activeConnectionCount;
  String get serviceInstanceId => _serviceInstanceId;
  String? get lastRawMessage => _lastRawMessage;
  String? get lastJsonParseError => _lastJsonParseError;

  Future<void> connect({
    Duration connectTimeout = const Duration(seconds: 10),
    Duration firstMessageTimeout = const Duration(seconds: 10),
    bool autoReconnect = true,
  }) async {
    if (_disposed || _isConnecting || _isClosing) {
      return;
    }
    _isConnecting = true;
    _autoReconnect = autoReconnect;
    _stopped = false;
    _connected = false;
    _firstMessageReceived = false;
    parseErrorCount = 0;
    final generation = ++_generation;
    _terminatedGeneration = -1;
    final uri = Uri.parse(futuresMarkPriceStreamUrl(symbol));
    _startedAt ??= DateTime.now().toUtc();
    _httpStatusCode = null;
    _closeCode = null;
    _closeReason = null;
    _lastExceptionType = null;
    _lastExceptionMessage = null;
    _lastStackTrace = null;
    _lastJsonParseError = null;
    _nextReconnectDelay = null;
    _setStatus(MarketConnectionStatus.connecting);
    _updateDiagnostics(
      status: MarketConnectionStatus.connecting,
      startedAt: _startedAt ?? DateTime.now().toUtc(),
      url: uri.toString(),
      streamName: futuresMarkPriceStreamName(symbol),
      reconnectCount: reconnectAttempt,
      currentReconnectDelay: null,
    );
    await _log(
      level: 'info',
      message: 'Futures WebSocket connecting',
      extra: {
        'serviceInstanceId': _serviceInstanceId,
        'url': uri.toString(),
        'stream': futuresMarkPriceStreamName(symbol),
        'attempt': reconnectAttempt,
        'connectTimeoutMs': connectTimeout.inMilliseconds,
        'firstMessageTimeoutMs': firstMessageTimeout.inMilliseconds,
      },
    );

    try {
      final streamFactory = _streamFactory;
      if (streamFactory != null) {
        final stream = streamFactory(uri);
        _subscription = stream.listen(
          (message) => _handleMessage(message, generation: generation),
          onError: (Object error, StackTrace stackTrace) {
            if (_disposed || _isClosing || generation != _generation) {
              return;
            }
            _handleStreamError(
              error,
              stackTrace,
              generation: generation,
              phase: 'stream',
              connectTimeout: connectTimeout,
              firstMessageTimeout: firstMessageTimeout,
            );
          },
          onDone: () {
            if (_disposed || _isClosing || generation != _generation) {
              return;
            }
            _handleStreamDone(generation: generation);
          },
          cancelOnError: false,
        );
        _connected = true;
        _activeConnectionCount = 1;
        _lastConnectedAt = DateTime.now().toUtc();
        _updateDiagnostics(
          status: MarketConnectionStatus.waitingFirstData,
          lastConnectedAt: _lastConnectedAt,
        );
        _setStatus(MarketConnectionStatus.waitingFirstData);
        _firstMessageTimer?.cancel();
        _firstMessageTimer = Timer(firstMessageTimeout, () {
          if (!_isCurrent(generation) || _firstMessageReceived || _stopped) {
            return;
          }
          _handleTimeout(
            generation: generation,
            timeoutType: 'firstMessageTimeout',
            message:
                'Futures WebSocket first message timeout after ${firstMessageTimeout.inSeconds}s',
            connectTimeout: connectTimeout,
            firstMessageTimeout: firstMessageTimeout,
          );
        });
        return;
      }
      final channel = IOWebSocketChannel.connect(
        uri,
        connectTimeout: connectTimeout,
        pingInterval: const Duration(seconds: 20),
      );
      _channel = channel;
      _subscription = channel.stream.listen(
        (message) => _handleMessage(message, generation: generation),
        onError: (Object error, StackTrace stackTrace) {
          if (_disposed || _isClosing || generation != _generation) {
            return;
          }
          _handleStreamError(
            error,
            stackTrace,
            generation: generation,
            phase: 'stream',
            connectTimeout: connectTimeout,
            firstMessageTimeout: firstMessageTimeout,
          );
        },
        onDone: () {
          if (_disposed || _isClosing || generation != _generation) {
            return;
          }
          _handleStreamDone(generation: generation);
        },
        cancelOnError: false,
      );
      channel.ready.then((_) {
        if (!_isCurrent(generation) || _disposed) {
          unawaited(_safeCloseChannel(channel));
          return;
        }
        _connected = true;
        _activeConnectionCount = 1;
        _lastConnectedAt = DateTime.now().toUtc();
        _updateDiagnostics(
          status: MarketConnectionStatus.waitingFirstData,
          lastConnectedAt: _lastConnectedAt,
        );
        _setStatus(MarketConnectionStatus.waitingFirstData);
        _log(
          level: 'info',
          message: 'Futures WebSocket connected',
          extra: {
            'serviceInstanceId': _serviceInstanceId,
            'url': uri.toString(),
            'stream': futuresMarkPriceStreamName(symbol),
            'attempt': reconnectAttempt,
          },
        );
        _firstMessageTimer?.cancel();
        _firstMessageTimer = Timer(firstMessageTimeout, () {
          if (!_isCurrent(generation) || _firstMessageReceived || _stopped) {
            return;
          }
          _handleTimeout(
            generation: generation,
            timeoutType: 'firstMessageTimeout',
            message:
                'Futures WebSocket first message timeout after ${firstMessageTimeout.inSeconds}s',
            connectTimeout: connectTimeout,
            firstMessageTimeout: firstMessageTimeout,
          );
        });
      }).catchError((Object error, StackTrace stackTrace) {
        if (!_isCurrent(generation) || _disposed) {
          return;
        }
        _handleStreamError(
          error,
          stackTrace,
          generation: generation,
          phase: 'connect',
          connectTimeout: connectTimeout,
          firstMessageTimeout: firstMessageTimeout,
        );
      });
    } catch (error, stackTrace) {
      if (!_isCurrent(generation)) {
        return;
      }
      _handleStreamError(
        error,
        stackTrace,
        generation: generation,
        phase: 'connect-throw',
        connectTimeout: connectTimeout,
        firstMessageTimeout: firstMessageTimeout,
      );
    } finally {
      if (generation == _generation) {
        _isConnecting = false;
      }
    }
  }

  Future<FuturesWsProbeResult> probeConnection({
    Duration connectTimeout = const Duration(seconds: 10),
    Duration firstMessageTimeout = const Duration(seconds: 10),
  }) async {
    final probe = BinanceFuturesMarketStream(
      symbol: symbol,
      logRepository: _logRepository,
      random: _random,
    );
    final completer = Completer<FuturesWsProbeResult>();
    late final StreamSubscription<MarketStreamEvent<FuturesMarkPrice>> sub;
    sub = probe.events.listen((event) {
      if (event.data != null && !completer.isCompleted) {
        completer.complete(
          FuturesWsProbeResult(
            success: true,
            details: 'WebSocket ready: ${event.data!.symbol}',
          ),
        );
        unawaited(probe.disconnect());
        unawaited(sub.cancel());
      } else if (event.status == MarketConnectionStatus.error &&
          event.error != null &&
          !completer.isCompleted) {
        completer.complete(
          FuturesWsProbeResult(success: false, details: event.error!),
        );
        unawaited(probe.disconnect());
        unawaited(sub.cancel());
      }
    });
    await probe.connect(
      connectTimeout: connectTimeout,
      firstMessageTimeout: firstMessageTimeout,
      autoReconnect: false,
    );
    return completer.future.timeout(
      connectTimeout + firstMessageTimeout + const Duration(seconds: 2),
      onTimeout: () {
        unawaited(probe.disconnect());
        return const FuturesWsProbeResult(
          success: false,
          details:
              'Probe timed out before first valid markPrice message arrived.',
        );
      },
    );
  }

  Future<void> disconnect() async {
    _stopped = true;
    _isClosing = true;
    _reconnectTimer?.cancel();
    _connectTimeoutTimer?.cancel();
    _firstMessageTimer?.cancel();
    _staleTimer?.cancel();
    _connectTimeoutTimer = null;
    _firstMessageTimer = null;
    _staleTimer = null;
    _reconnectTimer = null;
    await _closeCurrentConnection();
    _connected = false;
    _isClosing = false;
    _setStatus(MarketConnectionStatus.stopped);
    _updateDiagnostics(status: MarketConnectionStatus.stopped);
    await _log(level: 'info', message: 'Futures WebSocket stopped');
  }

  Future<void> reconnect() async {
    if (_disposed || _isConnecting) {
      return;
    }
    await _closeCurrentConnection();
    if (_disposed) {
      return;
    }
    await connect(autoReconnect: _autoReconnect);
  }

  Future<void> _restartConnection({required String reason}) async {
    if (_stopped || _disposed) {
      return;
    }
    await _closeCurrentConnection();
    reconnectAttempt += 1;
    final delay = BinanceSpotMarketStream.reconnectDelayForAttempt(
      reconnectAttempt,
      _random,
    );
    _nextReconnectDelay = delay;
    _setStatus(MarketConnectionStatus.reconnecting);
    _updateDiagnostics(
      status: MarketConnectionStatus.reconnecting,
      reconnectCount: reconnectAttempt,
      currentReconnectDelay: delay,
      lastErrorSummary: reason,
    );
    await _log(
      level: 'warning',
      message: 'MARKET_RECONNECT_SCHEDULED',
      extra: {
        'serviceInstanceId': _serviceInstanceId,
        'reason': reason,
        'attempt': reconnectAttempt,
        'nextRetryMs': delay.inMilliseconds,
      },
    );
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!_stopped && !_disposed) {
        unawaited(connect());
      }
    });
  }

  Future<void> _closeCurrentConnection() async {
    _isClosing = true;
    _connectTimeoutTimer?.cancel();
    _firstMessageTimer?.cancel();
    _staleTimer?.cancel();
    _reconnectTimer?.cancel();
    _connectTimeoutTimer = null;
    _firstMessageTimer = null;
    _staleTimer = null;
    _reconnectTimer = null;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      try {
        await subscription.cancel();
      } catch (error, stackTrace) {
        await _log(
          level: 'debug',
          message: 'MARKET_FUTURES_SUBSCRIPTION_CANCEL_FAILED',
          extra: {
            'serviceInstanceId': _serviceInstanceId,
            'errorType': error.runtimeType.toString(),
            'message': error.toString(),
            'stackTrace': stackTrace.toString(),
          },
        );
      }
    }
    final channel = _channel;
    _channel = null;
    final socket = _socket;
    _socket = null;
    try {
      if (channel != null) {
        await channel.sink.close();
      } else if (socket != null) {
        await socket.close(WebSocketStatus.normalClosure, 'client reconnect');
      }
    } catch (error, stackTrace) {
      if (!isExpectedSocketClose(error)) {
        await _log(
          level: 'debug',
          message: 'MARKET_FUTURES_SOCKET_CLOSE_FAILED',
          extra: {
            'serviceInstanceId': _serviceInstanceId,
            'errorType': error.runtimeType.toString(),
            'message': error.toString(),
            'stackTrace': stackTrace.toString(),
          },
        );
      }
    }
    _connected = false;
    _activeConnectionCount = 0;
    _isClosing = false;
  }

  void _handleMessage(dynamic message, {required int generation}) {
    if (_disposed || _isClosing || generation != _generation || _stopped) {
      return;
    }
    final raw = message?.toString() ?? '';
    _lastRawMessage = raw;
    _lastMessageAt = DateTime.now().toUtc();
    _updateDiagnostics(lastMessageAt: _lastMessageAt, lastRawMessage: raw);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && decoded['e'] == 'serverShutdown') {
        _closeCode = _channel?.closeCode;
        _closeReason = _channel?.closeReason;
        _updateDiagnostics(
          status: MarketConnectionStatus.reconnecting,
          closeCode: _closeCode,
          closeReason: _closeReason,
          lastErrorSummary: 'serverShutdown received',
        );
        _setStatus(MarketConnectionStatus.reconnecting);
        _emit(
          status: MarketConnectionStatus.reconnecting,
          serverShutdown: true,
          error:
              'Futures WebSocket serverShutdown: closeCode=${_closeCode ?? '-'}, closeReason=${_closeReason ?? '-'}',
        );
        _log(
          level: 'warning',
          message: 'MARKET_SERVER_SHUTDOWN',
          extra: {
            'serviceInstanceId': _serviceInstanceId,
            'url': _currentUrl,
            'closeCode': _closeCode,
            'closeReason': _closeReason,
          },
        );
        _terminateGeneration(generation, 'serverShutdown');
        return;
      }
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Futures payload is not a JSON object');
      }
      final markPrice = FuturesMarkPrice.fromJson(decoded);
      final isFirstValidMessage = !_firstMessageReceived;
      _firstMessageReceived = true;
      _connectTimeoutTimer?.cancel();
      _firstMessageTimer?.cancel();
      parseErrorCount = 0;
      reconnectAttempt = 0;
      _updateDiagnostics(
        status: MarketConnectionStatus.ready,
        lastMessageAt: _lastMessageAt,
        lastRawMessage: raw,
        lastJsonParseError: null,
        exceptionType: null,
        exceptionMessage: null,
        stackTrace: null,
        reconnectCount: 0,
        currentReconnectDelay: null,
      );
      _setStatus(MarketConnectionStatus.ready);
      _emit(data: markPrice, status: MarketConnectionStatus.ready);
      if (isFirstValidMessage) {
        unawaited(
          _log(
            level: 'info',
            message: 'Futures WebSocket ready',
            extra: {'symbol': markPrice.symbol},
          ),
        );
      }
    } catch (error, stackTrace) {
      parseErrorCount += 1;
      final errorText = error.toString();
      _lastJsonParseError = errorText;
      _lastExceptionType = error.runtimeType.toString();
      _lastExceptionMessage = errorText;
      _lastStackTrace = stackTrace.toString();
      _updateDiagnostics(
        status: MarketConnectionStatus.error,
        lastJsonParseError: errorText,
        exceptionType: _lastExceptionType,
        exceptionMessage: _lastExceptionMessage,
        stackTrace: _lastStackTrace,
        lastErrorSummary: 'parse error: $errorText',
      );
      _setStatus(MarketConnectionStatus.error);
      _emit(
        status: MarketConnectionStatus.error,
        error: 'Futures JSON parse error: $errorText',
      );
      unawaited(
        _log(
          level: 'error',
          message: 'MARKET_PARSE_ERROR',
          extra: {
            'url': _currentUrl,
            'raw': raw,
            'errorType': error.runtimeType.toString(),
            'errorMessage': errorText,
            'stackTrace': stackTrace.toString(),
            'parseErrorCount': parseErrorCount,
          },
        ),
      );
      if (parseErrorCount >= 3) {
        _terminateGeneration(generation, 'consecutive parse errors');
      }
    }
  }

  void _handleStreamError(
    Object error,
    StackTrace stackTrace, {
    required int generation,
    required String phase,
    Duration? connectTimeout,
    Duration? firstMessageTimeout,
  }) {
    if (_disposed || _isClosing || generation != _generation || _stopped) {
      return;
    }
    final errorText = error.toString();
    final errorType = error.runtimeType.toString();
    _lastExceptionType = errorType;
    _lastExceptionMessage = errorText;
    _lastStackTrace = stackTrace.toString();
    final isTimeout =
        error is TimeoutException || errorText.contains('TimeoutException');
    if (error is WebSocketChannelException) {
      _httpStatusCode = _extractStatusCode(errorText);
    }
    _updateDiagnostics(
      status: MarketConnectionStatus.error,
      httpStatusCode: _httpStatusCode,
      closeCode: _channel?.closeCode ?? _closeCode,
      closeReason: _channel?.closeReason ?? _closeReason,
      exceptionType: errorType,
      exceptionMessage: errorText,
      stackTrace: stackTrace.toString(),
      lastErrorSummary:
          isTimeout ? '$phase timeout' : '$phase failed: $errorText',
    );
    _setStatus(MarketConnectionStatus.error);
    _emit(
      status: MarketConnectionStatus.error,
      error: _buildFailureMessage(errorType, errorText),
    );
    unawaited(
      _log(
        level: 'error',
        message: 'MARKET_SERVER_ERROR',
        extra: {
          'serviceInstanceId': _serviceInstanceId,
          'phase': phase,
          'url': _currentUrl,
          'errorType': errorType,
          'message': errorText,
          'stackTrace': stackTrace.toString(),
          'closeCode': _channel?.closeCode ?? _closeCode,
          'closeReason': _channel?.closeReason ?? _closeReason,
          'connectTimeoutMs': connectTimeout?.inMilliseconds,
          'firstMessageTimeoutMs': firstMessageTimeout?.inMilliseconds,
        },
      ),
    );
    if (_autoReconnect) {
      _terminateGeneration(generation, '$phase error');
    }
  }

  void _handleStreamDone({required int generation}) {
    if (_disposed || _isClosing || generation != _generation || _stopped) {
      return;
    }
    _closeCode = _channel?.closeCode ?? _closeCode;
    _closeReason = _channel?.closeReason ?? _closeReason;
    _updateDiagnostics(
      status: MarketConnectionStatus.reconnecting,
      closeCode: _closeCode,
      closeReason: _closeReason,
      lastErrorSummary: 'stream done',
    );
    _setStatus(MarketConnectionStatus.reconnecting);
    _emit(
      status: MarketConnectionStatus.reconnecting,
      error:
          'Futures WebSocket closed: closeCode=${_closeCode ?? '-'}, closeReason=${_closeReason ?? '-'}',
    );
    unawaited(
      _log(
        level: 'warning',
        message: 'MARKET_FUTURES_DISCONNECTED',
        extra: {
          'serviceInstanceId': _serviceInstanceId,
          'url': _currentUrl,
          'closeCode': _closeCode,
          'closeReason': _closeReason,
        },
      ),
    );
    if (_autoReconnect) {
      _terminateGeneration(generation, 'stream done');
    }
  }

  void _handleTimeout({
    required int generation,
    required String timeoutType,
    required String message,
    required Duration connectTimeout,
    required Duration firstMessageTimeout,
  }) {
    if (_disposed || _isClosing || generation != _generation || _stopped) {
      return;
    }
    _lastExceptionType = 'TimeoutException';
    _lastExceptionMessage = message;
    _lastStackTrace = null;
    _updateDiagnostics(
      status: MarketConnectionStatus.error,
      exceptionType: _lastExceptionType,
      exceptionMessage: message,
      stackTrace: null,
      lastErrorSummary: timeoutType,
    );
    _setStatus(MarketConnectionStatus.error);
    _emit(status: MarketConnectionStatus.error, error: message);
    unawaited(
      _log(
        level: 'error',
        message: 'MARKET_FUTURES_TIMEOUT',
        extra: {
          'serviceInstanceId': _serviceInstanceId,
          'timeoutType': timeoutType,
          'url': _currentUrl,
          'connectTimeoutMs': connectTimeout.inMilliseconds,
          'firstMessageTimeoutMs': firstMessageTimeout.inMilliseconds,
        },
      ),
    );
    if (_autoReconnect) {
      _terminateGeneration(generation, timeoutType);
    }
  }

  bool _isCurrent(int generation) => generation == _generation;

  void _setStatus(MarketConnectionStatus status) {
    _status = status;
  }

  void _emit({
    FuturesMarkPrice? data,
    MarketConnectionStatus? status,
    String? error,
    bool serverShutdown = false,
    Duration? reconnectDelay,
  }) {
    if (!_controller.isClosed) {
      _controller.add(
        MarketStreamEvent(
          data: data,
          status: status,
          error: error,
          serverShutdown: serverShutdown,
          reconnectDelay: reconnectDelay,
        ),
      );
    }
  }

  void _updateDiagnostics({
    MarketConnectionStatus? status,
    String? url,
    String? streamName,
    DateTime? startedAt,
    DateTime? lastConnectedAt,
    DateTime? lastMessageAt,
    int? reconnectCount,
    Duration? currentReconnectDelay,
    int? httpStatusCode,
    int? closeCode,
    String? closeReason,
    String? exceptionType,
    String? exceptionMessage,
    String? stackTrace,
    String? lastRawMessage,
    String? lastJsonParseError,
    String? lastErrorSummary,
  }) {
    _diagnostics = _diagnostics.copyWith(
      status: status,
      url: url,
      streamName: streamName,
      startedAt: startedAt,
      lastConnectedAt: lastConnectedAt,
      lastMessageAt: lastMessageAt,
      reconnectCount: reconnectCount,
      currentReconnectDelay: currentReconnectDelay,
      httpStatusCode: httpStatusCode,
      closeCode: closeCode,
      closeReason: closeReason,
      exceptionType: exceptionType,
      exceptionMessage: exceptionMessage,
      stackTrace: stackTrace,
      lastRawMessage: lastRawMessage,
      lastJsonParseError: lastJsonParseError,
      lastErrorSummary: lastErrorSummary,
    );
    if (!_diagnosticsController.isClosed) {
      _diagnosticsController.add(_diagnostics);
    }
  }

  Future<void> _log({
    required String level,
    required String message,
    Map<String, Object?>? extra,
  }) async {
    final repo = _logRepository;
    if (repo == null) {
      return;
    }
    await repo.append(
      level: level,
      module: 'MARKET_FUTURES',
      message: message,
      extraJson: extra == null ? null : jsonEncode(_redact(extra)),
    );
  }

  Map<String, Object?> _redact(Map<String, Object?> extra) {
    final output = <String, Object?>{};
    for (final entry in extra.entries) {
      if (_isSensitiveKey(entry.key)) {
        output[entry.key] = '<redacted>';
      } else if (entry.value is Map<String, Object?>) {
        output[entry.key] = _redact(entry.value as Map<String, Object?>);
      } else {
        output[entry.key] = entry.value;
      }
    }
    return output;
  }

  bool _isSensitiveKey(String key) {
    final lower = key.toLowerCase();
    return lower.contains('secret') ||
        lower.contains('signature') ||
        lower.contains('apikey') ||
        lower.contains('api_key') ||
        lower.contains('x-mbx-apikey');
  }

  int? _extractStatusCode(String message) {
    final match = RegExp(r'(\d{3})').firstMatch(message);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(1)!);
  }

  String _buildFailureMessage(String type, String message) {
    return 'Futures WebSocket connection failed\n'
        'URL: $_currentUrl\n'
        'Error type: $type\n'
        'Message: $message\n'
        'Close code: ${_channel?.closeCode ?? _closeCode ?? '-'}\n'
        'Close reason: ${_channel?.closeReason ?? _closeReason ?? '-'}\n'
        'Attempt: $reconnectAttempt\n'
        'Next retry: ${formatDurationLabel(_nextReconnectDelay)}';
  }

  String get _currentUrl => futuresMarkPriceStreamUrl(symbol);

  void _terminateGeneration(int generation, String reason) {
    if (_disposed || generation != _generation) {
      return;
    }
    if (_terminatedGeneration == generation) {
      return;
    }
    _terminatedGeneration = generation;
    if (_autoReconnect) {
      unawaited(_restartConnection(reason: reason));
    }
  }

  Future<void> disposeAsync() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    ++_generation;
    await _closeCurrentConnection();
    if (!_controller.isClosed) {
      await _controller.close();
    }
    if (!_diagnosticsController.isClosed) {
      await _diagnosticsController.close();
    }
  }

  bool isExpectedSocketClose(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('reading from a closed socket') ||
        message.contains('socket is closed') ||
        message.contains('connection reset') ||
        message.contains('broken pipe') ||
        message.contains('connection closed');
  }

  Future<void> _safeCloseChannel(IOWebSocketChannel channel) async {
    try {
      await channel.sink.close();
    } catch (_) {
      // best effort
    }
  }
}

String futuresMarkPriceStreamUrl(String symbol) =>
    'wss://fstream.binance.com/market/ws/${symbol.toLowerCase()}@markPrice@1s';

String futuresMarkPriceStreamName(String symbol) =>
    '${symbol.toLowerCase()}@markPrice@1s';
