import 'package:dio/dio.dart';

class BinanceServerTimeService {
  BinanceServerTimeService({
    Dio? dio,
    this.spotBaseUrl = 'https://api.binance.com',
    this.futuresBaseUrl = 'https://fapi.binance.com/fapi',
  }) : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 8), receiveTimeout: const Duration(seconds: 8)));

  final Dio _dio;
  final String spotBaseUrl;
  final String futuresBaseUrl;
  int _spotOffsetMs = 0;
  int _futuresOffsetMs = 0;

  int get spotOffsetMs => _spotOffsetMs;
  int get futuresOffsetMs => _futuresOffsetMs;

  int calibratedSpotTimestamp() => DateTime.now().toUtc().millisecondsSinceEpoch + _spotOffsetMs;
  int calibratedFuturesTimestamp() => DateTime.now().toUtc().millisecondsSinceEpoch + _futuresOffsetMs;

  Future<int> syncSpot() async {
    final response = await _dio.get<Map<String, dynamic>>('$spotBaseUrl/api/v3/time');
    final serverTime = _readServerTime(response.data);
    _spotOffsetMs = serverTime - DateTime.now().toUtc().millisecondsSinceEpoch;
    return _spotOffsetMs;
  }

  Future<int> syncFutures() async {
    final response = await _dio.get<Map<String, dynamic>>('$futuresBaseUrl/v1/time');
    final serverTime = _readServerTime(response.data);
    _futuresOffsetMs = serverTime - DateTime.now().toUtc().millisecondsSinceEpoch;
    return _futuresOffsetMs;
  }

  int _readServerTime(Map<String, dynamic>? data) {
    final value = data?['serverTime'];
    if (value is int) return value;
    final parsed = int.tryParse(value?.toString() ?? '');
    if (parsed == null) {
      throw StateError('Binance serverTime missing');
    }
    return parsed;
  }
}
