import 'binance_credentials.dart';
import 'binance_signature_service.dart';

class BinanceSignedRequest {
  const BinanceSignedRequest({
    required this.path,
    required this.queryParameters,
    required this.headers,
  });

  final String path;
  final Map<String, Object?> queryParameters;
  final Map<String, String> headers;
}

class BinanceSignedRequestFactory {
  const BinanceSignedRequestFactory({
    required this.signatureService,
    this.recvWindowMs = 5000,
  });

  final BinanceSignatureService signatureService;
  final int recvWindowMs;

  BinanceSignedRequest get({
    required String path,
    required BinanceCredentials credentials,
    required int timestamp,
    Map<String, Object?> params = const {},
  }) {
    final unsigned = {
      ...params,
      'recvWindow': recvWindowMs,
      'timestamp': timestamp,
    };
    return BinanceSignedRequest(
      path: path,
      queryParameters: signatureService.sign(secretKey: credentials.secretKey, params: unsigned),
      headers: {'X-MBX-APIKEY': credentials.apiKey},
    );
  }
}
