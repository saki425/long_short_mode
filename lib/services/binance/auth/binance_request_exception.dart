class BinanceRequestException implements Exception {
  const BinanceRequestException({
    required this.type,
    required this.message,
    this.statusCode,
    this.binanceCode,
  });

  final BinanceRequestExceptionType type;
  final String message;
  final int? statusCode;
  final int? binanceCode;

  @override
  String toString() => 'BinanceRequestException($type, statusCode: $statusCode, code: $binanceCode, message: $message)';
}

enum BinanceRequestExceptionType {
  invalidCredentials,
  timestamp,
  signature,
  permissionDenied,
  rateLimited,
  ipBanned,
  network,
  unknown,
}
