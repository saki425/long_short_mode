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
import 'futures_account_models.dart';

class BinanceFuturesAccountClient {
  BinanceFuturesAccountClient({
    required this.credentials,
    required this.timeService,
    Dio? dio,
    this.baseUrl = 'https://fapi.binance.com/fapi',
  })  : _dio = dio ??
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

  Future<FuturesAccountSnapshot> getAccountSnapshot() async {
    final data = await _signedGet('/v3/account');
    return FuturesAccountSnapshot.fromJson(data as Map<String, dynamic>);
  }

  Future<List<FuturesPosition>> getPositionRisk({
    String symbol = 'BTCUSDT',
  }) async {
    final data = await _signedGet(
      '/v3/positionRisk',
      params: {'symbol': symbol},
    );
    return (data as List)
        .whereType<Map>()
        .map(
          (item) => FuturesPosition.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList();
  }

  Future<List<FuturesOpenOrder>> getOpenOrders({
    String symbol = 'BTCUSDT',
  }) async {
    final data = await _signedGet('/v1/openOrders', params: {'symbol': symbol});
    return (data as List)
        .whereType<Map>()
        .map(
          (item) => FuturesOpenOrder.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList();
  }

  Future<List<FuturesHistoricalOrder>> getAllOrders({
    String symbol = 'BTCUSDT',
    int limit = 500,
    DateTime? startTime,
    DateTime? endTime,
  }) async {
    final data = await _signedGet(
      '/v1/allOrders',
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
              FuturesHistoricalOrder.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList();
  }

  Future<List<FuturesTrade>> getUserTrades({
    String symbol = 'BTCUSDT',
    int limit = 500,
    DateTime? startTime,
    DateTime? endTime,
  }) async {
    final data = await _signedGet(
      '/v1/userTrades',
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
        .map((item) => FuturesTrade.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<void> changeInitialLeverage({
    required String symbol,
    required int leverage,
  }) async {
    await _signedRequest(
      method: 'POST',
      path: '/v1/leverage',
      params: {
        'symbol': symbol,
        'leverage': leverage,
      },
    );
  }

  Future<void> changePositionMode({required bool hedgeMode}) async {
    await _signedRequest(
      method: 'POST',
      path: '/v1/positionSide/dual',
      params: {
        'dualSidePosition': hedgeMode.toString(),
      },
    );
  }

  Future<bool> getPositionMode() async {
    final data = await _signedGet('/v1/positionSide/dual');
    if (data is Map) {
      return data['dualSidePosition'] == true ||
          data['dualSidePosition']?.toString().toLowerCase() == 'true';
    }
    return false;
  }

  Future<List<FundingFeeRecord>> getFundingFees({
    String symbol = 'BTCUSDT',
    int limit = 500,
    DateTime? startTime,
    DateTime? endTime,
  }) async {
    final data = await _signedGet(
      '/v1/income',
      params: {
        'symbol': symbol,
        'incomeType': 'FUNDING_FEE',
        'limit': limit,
        if (startTime != null)
          'startTime': startTime.toUtc().millisecondsSinceEpoch,
        if (endTime != null) 'endTime': endTime.toUtc().millisecondsSinceEpoch,
      },
    );
    return (data as List)
        .whereType<Map>()
        .map(
          (item) => FundingFeeRecord.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList();
  }

  Future<FuturesHistoricalOrder?> getOrderByClientOrderId({
    required String symbol,
    required String clientOrderId,
  }) async {
    final data = await _signedGet(
      '/v1/order',
      params: {'symbol': symbol, 'origClientOrderId': clientOrderId},
    );
    if (data is Map) {
      return FuturesHistoricalOrder.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  Future<FuturesOpenOrder> placeLimitOrder({
    required String symbol,
    required String side,
    required Decimal quantity,
    required Decimal price,
    required String clientOrderId,
    String timeInForce = 'GTC',
    String positionSide = 'BOTH',
    bool reduceOnly = false,
  }) async {
    final data = await _signedRequest(
      method: 'POST',
      path: '/v1/order',
      params: {
        'symbol': symbol,
        'side': side,
        'type': 'LIMIT',
        'timeInForce': timeInForce,
        'quantity': quantity.toString(),
        'price': price.toString(),
        'newClientOrderId': clientOrderId,
        'positionSide': positionSide,
        if (positionSide == 'BOTH') 'reduceOnly': reduceOnly.toString(),
        'newOrderRespType': 'RESULT',
      },
    );
    return FuturesOpenOrder.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<FuturesOpenOrder> placeMarketOrder({
    required String symbol,
    required String side,
    required Decimal quantity,
    required String clientOrderId,
    String positionSide = 'BOTH',
    bool reduceOnly = false,
  }) async {
    final data = await _signedRequest(
      method: 'POST',
      path: '/v1/order',
      params: {
        'symbol': symbol,
        'side': side,
        'type': 'MARKET',
        'quantity': quantity.toString(),
        'newClientOrderId': clientOrderId,
        'positionSide': positionSide,
        if (positionSide == 'BOTH') 'reduceOnly': reduceOnly.toString(),
        'newOrderRespType': 'RESULT',
      },
    );
    return FuturesOpenOrder.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<void> cancelOrder({
    required String symbol,
    required String clientOrderId,
  }) async {
    await _signedRequest(
      method: 'DELETE',
      path: '/v1/order',
      params: {'symbol': symbol, 'origClientOrderId': clientOrderId},
    );
  }

  Future<String> createListenKey() async {
    final data = await _apiKeyRequest(method: 'POST', path: '/v1/listenKey');
    if (data is Map && data['listenKey'] != null) {
      return data['listenKey'].toString();
    }
    throw const BinanceRequestException(
      type: BinanceRequestExceptionType.unknown,
      message: 'Binance futures listenKey response missing listenKey',
    );
  }

  Future<void> keepAliveListenKey(String listenKey) async {
    await _apiKeyRequest(
      method: 'PUT',
      path: '/v1/listenKey',
      params: {'listenKey': listenKey},
    );
  }

  Future<void> closeListenKey(String listenKey) async {
    await _apiKeyRequest(
      method: 'DELETE',
      path: '/v1/listenKey',
      params: {'listenKey': listenKey},
    );
  }

  Future<Object?> _apiKeyRequest({
    required String method,
    required String path,
    Map<String, Object?> params = const {},
  }) async {
    try {
      final response = await _dio.request<Object?>(
        '$baseUrl$path',
        queryParameters: params,
        options: Options(
          method: method,
          headers: {'X-MBX-APIKEY': credentials.apiKey},
        ),
      );
      return response.data;
    } catch (error) {
      if (error is SocketException ||
          error is HandshakeException ||
          error is TlsException ||
          error is TimeoutException) {
        throw const BinanceRequestException(
          type: BinanceRequestExceptionType.network,
          message: 'Network or TLS failure while calling Binance futures API',
        );
      }
      throw _errorMapper.map(error);
    }
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
        timestamp: timeService.calibratedFuturesTimestamp(),
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
          message: 'Network or TLS failure while calling Binance futures API',
        );
      }
      final mapped = _errorMapper.map(error);
      if (!retried && mapped.type == BinanceRequestExceptionType.timestamp) {
        await timeService.syncFutures();
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
