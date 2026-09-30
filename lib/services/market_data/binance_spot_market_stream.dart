import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'market_data_connection.dart';
import 'market_data_status.dart';
import 'spot_book_ticker.dart';

class MarketStreamEvent<T> {
  const MarketStreamEvent({
    this.data,
    this.status,
    this.error,
    this.serverShutdown = false,
    this.reconnectDelay,
  });

  final T? data;
  final MarketConnectionStatus? status;
  final String? error;
  final bool serverShutdown;
  final Duration? reconnectDelay;
}

class BinanceSpotMarketStream {
  BinanceSpotMarketStream({
    this.symbol = 'BTCUSDT',
    WebSocketFactory? streamFactory,
    math.Random? random,
  }) : _streamFactory = streamFactory ?? _defaultStreamFactory,
       _random = random ?? math.Random(),
       _serviceInstanceId = const Uuid().v4();

  final String symbol;
  final WebSocketFactory _streamFactory;
  final math.Random _random;
  final String _serviceInstanceId;
  final StreamController<MarketStreamEvent<SpotBookTicker>> _controller =
      StreamController.broadcast();
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  bool _isConnecting = false;
  bool _isClosing = false;
  bool _disposed = false;
  int _generation = 0;
  int _terminatedGeneration = -1;
  bool _stopped = true;
  int _activeConnectionCount = 0;
  int reconnectAttempt = 0;
  int parseErrorCount = 0;

  Stream<MarketStreamEvent<SpotBookTicker>> get events => _controller.stream;
  int get activeConnectionCount => _activeConnectionCount;
  String get serviceInstanceId => _serviceInstanceId;

  Future<void> connect() async {
    if (_disposed || _isConnecting || _isClosing) {
      return;
    }
    _isConnecting = true;
    _stopped = false;
    _emit(status: MarketConnectionStatus.connecting);
    final uri = Uri.parse(
      'wss://stream.binance.com:9443/ws/${symbol.toLowerCase()}@bookTicker',
    );
    _emit(status: MarketConnectionStatus.waitingFirstData);
    final generation = ++_generation;
    _terminatedGeneration = -1;
    try {
      await _closeCurrentConnection();
      if (_disposed || generation != _generation) {
        return;
      }
      _subscription = MarketDataConnection(
        uri: uri,
        streamFactory: _streamFactory,
      ).connect().listen(
        (message) => _handleMessage(message, generation: generation),
        onError: (Object error, StackTrace stackTrace) {
          if (_disposed || _isClosing || generation != _generation) {
            return;
          }
          _terminateGeneration(
            generation,
            'spot onError: ${error.runtimeType}',
          );
        },
        onDone: () {
          if (_disposed || _isClosing || generation != _generation) {
            return;
          }
          _terminateGeneration(generation, 'spot onDone');
        },
        cancelOnError: false,
      );
      _activeConnectionCount = 1;
    } catch (error) {
      if (!_disposed && generation == _generation) {
        _terminateGeneration(
          generation,
          'spot connect failed: ${error.runtimeType}',
        );
      }
    } finally {
      if (generation == _generation) {
        _isConnecting = false;
      }
    }
  }

  Future<void> disconnect() async {
    _stopped = true;
    _isClosing = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeCurrentConnection();
    _isClosing = false;
    _emit(status: MarketConnectionStatus.stopped);
  }

  Future<void> reconnect() async {
    if (_disposed || _isClosing || _isConnecting) {
      return;
    }
    await _closeCurrentConnection();
    if (_disposed) {
      return;
    }
    await connect();
  }

  void _handleMessage(dynamic message, {required int generation}) {
    if (_disposed || _isClosing || generation != _generation || _stopped) {
      return;
    }
    try {
      final decoded = jsonDecode(message as String);
      if (decoded is Map<String, dynamic> && decoded['e'] == 'serverShutdown') {
        _emit(
          status: MarketConnectionStatus.reconnecting,
          serverShutdown: true,
        );
        unawaited(reconnect());
        return;
      }
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Spot payload is not object');
      }
      final ticker = SpotBookTicker.fromJson(decoded);
      parseErrorCount = 0;
      reconnectAttempt = 0;
      _emit(data: ticker, status: MarketConnectionStatus.ready);
    } catch (error) {
      parseErrorCount += 1;
      _emit(
        status: MarketConnectionStatus.error,
        error: 'spot parse error: $error',
      );
      if (parseErrorCount >= 3) {
        _terminateGeneration(generation, 'spot consecutive parse errors');
      }
    }
  }

  void _scheduleReconnect(String error) {
    if (_stopped || _disposed || _isConnecting || _isClosing) {
      return;
    }
    if (_reconnectTimer?.isActive == true) {
      return;
    }
    reconnectAttempt += 1;
    final delay = reconnectDelayForAttempt(reconnectAttempt, _random);
    _emit(
      status: MarketConnectionStatus.reconnecting,
      error: error,
      reconnectDelay: delay,
    );
    _reconnectTimer = Timer(delay, () {
      if (!_stopped && !_disposed) {
        unawaited(connect());
      }
    });
  }

  Future<void> _closeCurrentConnection() async {
    _isClosing = true;
    final subscription = _subscription;
    _subscription = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (subscription != null) {
      try {
        await subscription.cancel();
      } catch (_) {
        // ignored
      }
    }
    _activeConnectionCount = 0;
    _isClosing = false;
  }

  void _terminateGeneration(int generation, String reason) {
    if (_disposed || generation != _generation) {
      return;
    }
    if (_terminatedGeneration == generation) {
      return;
    }
    _terminatedGeneration = generation;
    _scheduleReconnect(reason);
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
  }

  void _emit({
    SpotBookTicker? data,
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

  static Duration reconnectDelayForAttempt(int attempt, math.Random random) {
    final seconds = math.min(30, math.pow(2, math.max(0, attempt - 1)).toInt());
    return Duration(seconds: seconds, milliseconds: random.nextInt(501));
  }

  static Stream<dynamic> _defaultStreamFactory(Uri uri) {
    return WebSocketChannel.connect(uri).stream;
  }
}
