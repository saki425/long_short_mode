import '../../../services/security/secure_key_storage.dart';

class BinanceCredentials {
  const BinanceCredentials({
    required this.apiKey,
    required this.secretKey,
    required this.accountType,
  });

  final String apiKey;
  final String secretKey;
  final String accountType;

  String get maskedApiKey => SecureKeyStorage.maskApiKeyStatic(apiKey);
}

class BinanceCredentialLoader {
  const BinanceCredentialLoader(this.cache);

  final CredentialsSessionCache cache;

  Future<BinanceCredentials?> loadSpot() async {
    final bundle = cache.credentials;
    final apiKey = bundle?.spotApiKey;
    final secretKey = bundle?.spotSecretKey;
    if (_blank(apiKey) || _blank(secretKey)) return null;
    return BinanceCredentials(
      apiKey: apiKey!.trim(),
      secretKey: secretKey!.trim(),
      accountType: 'spotSubAccount',
    );
  }

  Future<BinanceCredentials?> loadFutures() async {
    final bundle = cache.credentials;
    final apiKey = bundle?.futuresApiKey;
    final secretKey = bundle?.futuresSecretKey;
    if (_blank(apiKey) || _blank(secretKey)) return null;
    return BinanceCredentials(
      apiKey: apiKey!.trim(),
      secretKey: secretKey!.trim(),
      accountType: 'futuresSubAccount',
    );
  }

  bool _blank(String? value) => value == null || value.trim().isEmpty;
}
