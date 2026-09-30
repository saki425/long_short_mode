import 'package:dio/dio.dart';

import 'binance_request_exception.dart';

class BinanceErrorMapper {
  const BinanceErrorMapper();

  BinanceRequestException map(Object error) {
    if (error is BinanceRequestException) return error;
    if (error is DioException) {
      final response = error.response;
      final status = response?.statusCode;
      final data = response?.data;
      final code = data is Map ? _asInt(data['code']) : null;
      final message = data is Map ? (data['msg']?.toString() ?? 'Binance request failed') : error.message ?? 'Binance request failed';
      if (status == 429) {
        return BinanceRequestException(type: BinanceRequestExceptionType.rateLimited, message: message, statusCode: status, binanceCode: code);
      }
      if (status == 418) {
        return BinanceRequestException(type: BinanceRequestExceptionType.ipBanned, message: message, statusCode: status, binanceCode: code);
      }
      if (code == -1021) {
        return BinanceRequestException(type: BinanceRequestExceptionType.timestamp, message: message, statusCode: status, binanceCode: code);
      }
      if (code == -1022) {
        return BinanceRequestException(type: BinanceRequestExceptionType.signature, message: message, statusCode: status, binanceCode: code);
      }
      if (code == -2014 || code == -2015) {
        return BinanceRequestException(type: BinanceRequestExceptionType.invalidCredentials, message: message, statusCode: status, binanceCode: code);
      }
      if (status == 401 || status == 403) {
        return BinanceRequestException(type: BinanceRequestExceptionType.permissionDenied, message: message, statusCode: status, binanceCode: code);
      }
      return BinanceRequestException(type: BinanceRequestExceptionType.unknown, message: message, statusCode: status, binanceCode: code);
    }
    return BinanceRequestException(type: BinanceRequestExceptionType.network, message: error.toString());
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }
}
