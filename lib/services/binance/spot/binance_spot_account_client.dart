import 'dart:async';
import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';

import '../auth/binance_credentials.dart';
import '../auth/binance_error_mapper.dart';
import '../auth/binance_request_exception.dart';
import '../auth/binance_server_time_service.dart';
import '../auth/binance_signed_request.dart';
import '../auth/binance_signature_service.dart';
import 'spot_account_models.dart';

class BinanceSpotAccountClient {
  BinanceSpotAccountClient({
    required this.credentials,
    required this.timeService,
    Dio? dio,
    this.baseUrl = 'https://api.binance.com',
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 10),
             ),
           ),
       _requestFactory = const BinanceSignedRequestFactory(
         signatureService: BinanceSignatureService(),
       );

  final BinanceCredentials credentials;
  final BinanceServerTimeService timeService;
  final Dio _dio;
  final String baseUrl;
  final BinanceSignedRequestFactory _requestFactory;
  final BinanceErrorMapper _errorMapper = const BinanceErrorMapper();

  Future<SpotAccountSnapshot> getAccountSnapshot() async {
    final data = await _signedGet('/api/v3/account');
    return SpotAccountSnapshot.fromJson(data as Map<String, dynamic>);
  }

  Future<List<SpotOpenOrder>> getOpenOrders({
    String? symbol = 'BTCUSDT',
  }) async {
    final data = await _signedGet(
      '/api/v3/openOrders',
      params: {if (symbol != null) 'symbol': symbol},
    );
    return (data as List)
        .whereType<Map>()
        .map((item) => SpotOpenOrder.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<List<SpotHistoricalOrder>> getAllOrders({
    String symbol = 'BTCUSDT',
    int limit = 500,
    DateTime? startTime,
    DateTime? endTime,
  }) async {
    final data = await _signedGet(
      '/api/v3/allOrders',
      params: {
        'symbol': symbol,
        'limit': limit,
        if (startTime != null)
          'startTime': startTime.toUtc().millisecondsSinceEpoch,
        if (endTime != null) 'endTime': endTime.toUtc().millisecondsSinceEpoch,
      },
    );
    return (data as List)
        .whereType<Map>()
        .map(
          (item) =>
              SpotHistoricalOrder.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList();
  }

  Future<List<SpotTrade>> getMyTrades({
    String symbol = 'BTCUSDT',
    int limit = 500,
    DateTime? startTime,
    DateTime? endTime,
  }) async {
    final data = await _signedGet(
      '/api/v3/myTrades',
      params: {
        'symbol': symbol,
        'limit': limit,
        if (startTime != null)
          'startTime': startTime.toUtc().millisecondsSinceEpoch,
        if (endTime != null) 'endTime': endTime.toUtc().millisecondsSinceEpoch,
      },
    );
    return (data as List)
        .whereType<Map>()
        .map((item) => SpotTrade.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<SpotOpenOrder> placeLimitOrder({
    required String symbol,
    required String side,
    required Decimal quantity,
    required Decimal price,
    required String clientOrderId,
    String timeInForce = 'GTC',
  }) async {
    final data = await _signedRequest(
      method: 'POST',
      path: '/api/v3/order',
      params: {
        'symbol': symbol,
        'side': side,
        'type': 'LIMIT',
        'timeInForce': timeInForce,
        'quantity': quantity.toString(),
        'price': price.toString(),
        'newClientOrderId': clientOrderId,
        'newOrderRespType': 'RESULT',
      },
    );
    return SpotOpenOrder.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<SpotOpenOrder> placeMarketOrder({
    required String symbol,
    required String side,
    Decimal? quantity,
    Decimal? quoteOrderQty,
    required String clientOrderId,
  }) async {
    final params = <String, Object?>{
      'symbol': symbol,
      'side': side,
      'type': 'MARKET',
      'newClientOrderId': clientOrderId,
      'newOrderRespType': 'RESULT',
      if (quantity != null) 'quantity': quantity.toString(),
      if (quoteOrderQty != null) 'quoteOrderQty': quoteOrderQty.toString(),
    };
    final data = await _signedRequest(
      method: 'POST',
      path: '/api/v3/order',
      params: params,
    );
    return SpotOpenOrder.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<void> placeTestOrder({
    required String symbol,
    required String side,
    required String type,
    Decimal? quantity,
    Decimal? price,
    Decimal? quoteOrderQty,
    String? timeInForce,
    required String clientOrderId,
  }) async {
    final params = <String, Object?>{
      'symbol': symbol,
      'side': side,
      'type': type,
      'newClientOrderId': clientOrderId,
      if (timeInForce != null) 'timeInForce': timeInForce,
      if (quantity != null) 'quantity': quantity.toString(),
      if (price != null) 'price': price.toString(),
      if (quoteOrderQty != null) 'quoteOrderQty': quoteOrderQty.toString(),
    };
    await _signedRequest(
      method: 'POST',
      path: '/api/v3/order/test',
      params: params,
    );
  }

  Future<SpotOpenOrder?> getOrderByClientOrderId({
    required String symbol,
    required String clientOrderId,
  }) async {
    final data = await _signedGet(
      '/api/v3/order',
      params: {'symbol': symbol, 'origClientOrderId': clientOrderId},
    );
    if (data is Map) {
      return SpotOpenOrder.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  Future<void> cancelOrder({
    required String symbol,
    required String clientOrderId,
  }) async {
    await _signedRequest(
      method: 'DELETE',
      path: '/api/v3/order',
      params: {'symbol': symbol, 'origClientOrderId': clientOrderId},
    );
  }

  Future<Object?> _signedGet(
    String path, {
    Map<String, Object?> params = const {},
    bool retried = false,
  }) async {
    return _signedRequest(
      method: 'GET',
      path: path,
      params: params,
      retried: retried,
    );
  }

  Future<Object?> _signedRequest({
    required String method,
    required String path,
    Map<String, Object?> params = const {},
    bool retried = false,
  }) async {
    try {
      final request = _requestFactory.get(
        path: path,
        credentials: credentials,
        timestamp: timeService.calibratedSpotTimestamp(),
        params: params,
      );
      final response = await _dio.request<Object?>(
        '$baseUrl${request.path}',
        queryParameters: request.queryParameters,
        options: Options(method: method, headers: request.headers),
      );
      return response.data;
    } catch (error) {
      if (error is SocketException ||
          error is HandshakeException ||
          error is TlsException ||
          error is TimeoutException) {
        throw const BinanceRequestException(
          type: BinanceRequestExceptionType.network,
          message: 'Network or TLS failure while calling Binance spot API',
        );
      }
      final mapped = _errorMapper.map(error);
      if (!retried && mapped.type == BinanceRequestExceptionType.timestamp) {
        await timeService.syncSpot();
        return _signedRequest(
          method: method,
          path: path,
          params: params,
          retried: true,
        );
      }
      throw mapped;
    }
  }
}
