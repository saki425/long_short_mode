import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../repositories/basic_repositories.dart';

enum ApiSecretField {
  spotApiKey,
  spotSecretKey,
  futuresApiKey,
  futuresSecretKey,
}

enum CredentialsCacheStatus { notLoaded, loading, loaded, missing, error }

class ApiKeyDisplay {
  const ApiKeyDisplay({
    required this.spotConfigured,
    required this.futuresConfigured,
    required this.maskedSpotApiKey,
    required this.maskedFuturesApiKey,
  });

  final bool spotConfigured;
  final bool futuresConfigured;
  final String maskedSpotApiKey;
  final String maskedFuturesApiKey;
}

class BinanceCredentialsBundle {
  const BinanceCredentialsBundle({
    required this.spotApiKey,
    required this.spotSecretKey,
    required this.futuresApiKey,
    required this.futuresSecretKey,
  });

  final String spotApiKey;
  final String spotSecretKey;
  final String futuresApiKey;
  final String futuresSecretKey;

  bool get spotConfigured => _hasText(spotApiKey) && _hasText(spotSecretKey);
  bool get futuresConfigured =>
      _hasText(futuresApiKey) && _hasText(futuresSecretKey);
  bool get fullyConfigured => spotConfigured && futuresConfigured;

  BinanceCredentialsBundle copyWith({
    String? spotApiKey,
    String? spotSecretKey,
    String? futuresApiKey,
    String? futuresSecretKey,
  }) {
    return BinanceCredentialsBundle(
      spotApiKey: spotApiKey ?? this.spotApiKey,
      spotSecretKey: spotSecretKey ?? this.spotSecretKey,
      futuresApiKey: futuresApiKey ?? this.futuresApiKey,
      futuresSecretKey: futuresSecretKey ?? this.futuresSecretKey,
    );
  }

  Map<String, String> toJson() => {
    'spotApiKey': spotApiKey,
    'spotSecretKey': spotSecretKey,
    'futuresApiKey': futuresApiKey,
    'futuresSecretKey': futuresSecretKey,
  };

  static BinanceCredentialsBundle fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('credentials JSON must be an object');
    }
    return BinanceCredentialsBundle(
      spotApiKey: _string(value['spotApiKey']),
      spotSecretKey: _string(value['spotSecretKey']),
      futuresApiKey: _string(value['futuresApiKey']),
      futuresSecretKey: _string(value['futuresSecretKey']),
    );
  }

  static BinanceCredentialsBundle empty() => const BinanceCredentialsBundle(
    spotApiKey: '',
    spotSecretKey: '',
    futuresApiKey: '',
    futuresSecretKey: '',
  );

  static String _string(Object? value) => value?.toString().trim() ?? '';
  static bool _hasText(String value) => value.trim().isNotEmpty;
}

class CredentialsSessionCache extends ChangeNotifier {
  CredentialsCacheStatus _status = CredentialsCacheStatus.notLoaded;
  BinanceCredentialsBundle? _credentials;
  String? _lastError;
  int _keychainReadCount = 0;

  CredentialsCacheStatus get status => _status;
  BinanceCredentialsBundle? get credentials => _credentials;
  String? get lastError => _lastError;
  int get keychainReadCount => _keychainReadCount;
  bool get isLoaded => _status == CredentialsCacheStatus.loaded;

  void markLoading() {
    _status = CredentialsCacheStatus.loading;
    _lastError = null;
    notifyListeners();
  }

  void setLoaded(BinanceCredentialsBundle credentials) {
    _credentials = credentials;
    _status = CredentialsCacheStatus.loaded;
    _lastError = null;
    notifyListeners();
  }

  void setMissing() {
    _credentials = null;
    _status = CredentialsCacheStatus.missing;
    _lastError = null;
    notifyListeners();
  }

  void setError(Object error) {
    _credentials = null;
    _status = CredentialsCacheStatus.error;
    _lastError = error.toString();
    notifyListeners();
  }

  void lock() {
    _credentials = null;
    _status = CredentialsCacheStatus.notLoaded;
    _lastError = null;
    notifyListeners();
  }

  void noteKeychainRead() {
    _keychainReadCount += 1;
  }
}

abstract class SecureSecretStore {
  Future<void> write({required String key, required String value});
  Future<String?> read({required String key});
  Future<void> delete({required String key});
}

class FlutterSecureSecretStore implements SecureSecretStore {
  FlutterSecureSecretStore({
    FlutterSecureStorage? storage,
    String accountName = CredentialsVault.keychainService,
  }) : _storage =
           storage ??
           FlutterSecureStorage(
             mOptions: MacOsOptions(
               accountName: accountName,
               accessibility: KeychainAccessibility.unlocked,
               synchronizable: false,
             ),
           );

  final FlutterSecureStorage _storage;

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);
}

class MacOsMethodChannelSecretStore implements SecureSecretStore {
  const MacOsMethodChannelSecretStore({
    this.accountName = CredentialsVault.keychainService,
  });

  final String accountName;

  static const MethodChannel _channel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  Map<String, String> get _baseOptions => <String, String>{
    'accountName': accountName,
    'accessibility': 'unlocked',
    'synchronizable': 'false',
    'useDataProtectionKeyChain': 'false',
  };

  @override
  Future<void> write({required String key, required String value}) async {
    await _channel.invokeMethod<void>('write', <String, Object?>{
      'key': key,
      'value': value,
      'options': _baseOptions,
    });
  }

  @override
  Future<String?> read({required String key}) {
    return _channel.invokeMethod<String?>('read', <String, Object?>{
      'key': key,
      'options': _baseOptions,
    });
  }

  @override
  Future<void> delete({required String key}) async {
    await _channel.invokeMethod<void>('delete', <String, Object?>{
      'key': key,
      'options': _baseOptions,
    });
  }
}

SecureSecretStore createDefaultSecureSecretStore({
  String accountName = CredentialsVault.keychainService,
}) {
  if (Platform.isMacOS) {
    return MacOsMethodChannelSecretStore(accountName: accountName);
  }
  return FlutterSecureSecretStore(accountName: accountName);
}

class CredentialsVault {
  CredentialsVault({
    SecureSecretStore? store,
    CredentialsSessionCache? cache,
    LogRepository? logRepository,
    String? bundleIdentifier,
    String? teamIdentifier,
    String buildMode =
        kReleaseMode
            ? 'release'
            : kProfileMode
            ? 'profile'
            : 'debug',
  }) : _store = store ?? createDefaultSecureSecretStore(),
       cache = cache ?? CredentialsSessionCache(),
       _logRepository = logRepository,
       _bundleIdentifier = bundleIdentifier,
       _teamIdentifier = teamIdentifier,
       _buildMode = buildMode;

  static const keychainService = 'com.gridhedge.desktop.binance';
  static const keychainAccount = 'production_credentials';

  final SecureSecretStore _store;
  final CredentialsSessionCache cache;
  final LogRepository? _logRepository;
  final String? _bundleIdentifier;
  final String? _teamIdentifier;
  final String _buildMode;

  Future<BinanceCredentialsBundle?> readOnce({bool force = false}) async {
    if (!force && cache.status == CredentialsCacheStatus.loaded) {
      await _log(
        level: 'debug',
        module: 'SECURITY',
        message: 'CREDENTIALS_CACHE_HIT',
      );
      return cache.credentials;
    }
    if (!force && cache.status == CredentialsCacheStatus.loading) {
      await _log(
        level: 'debug',
        module: 'SECURITY',
        message: 'CREDENTIALS_CACHE_MISS loading',
      );
      return null;
    }

    cache.markLoading();
    cache.noteKeychainRead();
    await _log(
      level: 'info',
      module: 'SECURITY',
      message: 'KEYCHAIN_READ_START',
      extra: _diagnostics(),
    );
    try {
      final raw = await _store.read(key: keychainAccount);
      if (raw == null || raw.trim().isEmpty) {
        cache.setMissing();
        await _log(
          level: 'info',
          module: 'SECURITY',
          message: 'KEYCHAIN_READ_SUCCESS missing',
          extra: _diagnostics(),
        );
        return null;
      }
      final credentials = BinanceCredentialsBundle.fromJson(jsonDecode(raw));
      if (!credentials.fullyConfigured) {
        cache.setMissing();
        await _log(
          level: 'warning',
          module: 'SECURITY',
          message: 'KEYCHAIN_READ_SUCCESS incomplete',
          extra: _diagnostics(),
        );
        return credentials;
      }
      cache.setLoaded(credentials);
      await _log(
        level: 'info',
        module: 'SECURITY',
        message: 'KEYCHAIN_READ_SUCCESS',
        extra: {
          ..._diagnostics(),
          'spotConfigured': credentials.spotConfigured,
          'futuresConfigured': credentials.futuresConfigured,
          'maskedSpotApiKey': SecureKeyStorage.maskApiKeyStatic(
            credentials.spotApiKey,
          ),
          'maskedFuturesApiKey': SecureKeyStorage.maskApiKeyStatic(
            credentials.futuresApiKey,
          ),
        },
      );
      return credentials;
    } catch (error) {
      cache.setError(error);
      await _log(
        level: 'error',
        module: 'SECURITY',
        message: 'KEYCHAIN_READ_FAILED ${error.runtimeType}',
        extra: _diagnostics(),
      );
      rethrow;
    }
  }

  Future<void> save(BinanceCredentialsBundle credentials) async {
    await _log(
      level: 'info',
      module: 'SECURITY',
      message: 'KEYCHAIN_WRITE_START',
      extra: _diagnostics(),
    );
    await _store.write(
      key: keychainAccount,
      value: jsonEncode(credentials.toJson()),
    );
    cache.setLoaded(credentials);
    await _log(
      level: 'info',
      module: 'SECURITY',
      message: 'KEYCHAIN_WRITE_SUCCESS',
      extra: {
        ..._diagnostics(),
        'spotConfigured': credentials.spotConfigured,
        'futuresConfigured': credentials.futuresConfigured,
        'maskedSpotApiKey': SecureKeyStorage.maskApiKeyStatic(
          credentials.spotApiKey,
        ),
        'maskedFuturesApiKey': SecureKeyStorage.maskApiKeyStatic(
          credentials.futuresApiKey,
        ),
      },
    );
  }

  Future<void> updateFields(Map<ApiSecretField, String> values) async {
    final current = cache.credentials ?? BinanceCredentialsBundle.empty();
    var next = current;
    for (final entry in values.entries) {
      final value = entry.value.trim();
      if (value.isEmpty) {
        continue;
      }
      next = switch (entry.key) {
        ApiSecretField.spotApiKey => next.copyWith(spotApiKey: value),
        ApiSecretField.spotSecretKey => next.copyWith(spotSecretKey: value),
        ApiSecretField.futuresApiKey => next.copyWith(futuresApiKey: value),
        ApiSecretField.futuresSecretKey => next.copyWith(
          futuresSecretKey: value,
        ),
      };
    }
    await save(next);
  }

  Future<void> deleteAll() async {
    await _store.delete(key: keychainAccount);
    cache.setMissing();
    await _log(
      level: 'info',
      module: 'SECURITY',
      message: 'KEYCHAIN_DELETE',
      extra: _diagnostics(),
    );
  }

  void lockSession() {
    cache.lock();
  }

  ApiKeyDisplay displayFromCache() {
    final credentials = cache.credentials;
    return ApiKeyDisplay(
      spotConfigured: credentials?.spotConfigured ?? false,
      futuresConfigured: credentials?.futuresConfigured ?? false,
      maskedSpotApiKey: SecureKeyStorage.maskApiKeyStatic(
        credentials?.spotApiKey,
      ),
      maskedFuturesApiKey: SecureKeyStorage.maskApiKeyStatic(
        credentials?.futuresApiKey,
      ),
    );
  }

  Map<String, Object?> _diagnostics() => {
    'bundleIdentifier': _bundleIdentifier ?? 'unknown',
    'teamIdentifier': _teamIdentifier ?? 'unknown',
    'keychainService': keychainService,
    'keychainAccount': keychainAccount,
    'buildMode': _buildMode,
  };

  Future<void> _log({
    required String level,
    required String module,
    required String message,
    Map<String, Object?>? extra,
  }) async {
    final repository = _logRepository;
    if (repository == null) {
      return;
    }
    await repository.append(
      level: level,
      module: module,
      message: message,
      extraJson: extra == null ? null : jsonEncode(extra),
    );
  }
}

class SecureKeyStorage {
  SecureKeyStorage({CredentialsVault? vault, SecureSecretStore? store})
    : _vault =
          vault ??
          CredentialsVault(store: store, cache: CredentialsSessionCache());

  final CredentialsVault _vault;

  Future<void> saveSecret(ApiSecretField field, String value) {
    return updateSecret(field, value);
  }

  Future<void> updateSecret(ApiSecretField field, String value) {
    return _vault.updateFields({field: value});
  }

  Future<String?> readSecret(ApiSecretField field) async {
    final credentials = _vault.cache.credentials;
    if (credentials == null) {
      return null;
    }
    return switch (field) {
      ApiSecretField.spotApiKey => credentials.spotApiKey,
      ApiSecretField.spotSecretKey => credentials.spotSecretKey,
      ApiSecretField.futuresApiKey => credentials.futuresApiKey,
      ApiSecretField.futuresSecretKey => credentials.futuresSecretKey,
    };
  }

  Future<void> deleteSecret(ApiSecretField field) async {
    final current =
        _vault.cache.credentials ?? BinanceCredentialsBundle.empty();
    final next = switch (field) {
      ApiSecretField.spotApiKey => current.copyWith(spotApiKey: ''),
      ApiSecretField.spotSecretKey => current.copyWith(spotSecretKey: ''),
      ApiSecretField.futuresApiKey => current.copyWith(futuresApiKey: ''),
      ApiSecretField.futuresSecretKey => current.copyWith(futuresSecretKey: ''),
    };
    await _vault.save(next);
  }

  Future<void> deleteAllBinanceSecrets() => _vault.deleteAll();

  Future<ApiKeyDisplay> loadDisplay() async => _vault.displayFromCache();

  Future<bool> hasRequiredSecrets() async {
    return _vault.cache.credentials?.fullyConfigured ?? false;
  }

  String maskApiKey(String? apiKey) => maskApiKeyStatic(apiKey);

  static String maskApiKeyStatic(String? apiKey) {
    if (apiKey == null || apiKey.trim().isEmpty) {
      return '未配置';
    }
    final value = apiKey.trim();
    if (value.length <= 8) {
      return '****';
    }
    return '${value.substring(0, 4)}****${value.substring(value.length - 4)}';
  }

  Future<bool> isConfigured(
    ApiSecretField apiKeyField,
    ApiSecretField secretField,
  ) async {
    final apiKey = await readSecret(apiKeyField);
    final secretKey = await readSecret(secretField);
    return apiKey != null &&
        apiKey.trim().isNotEmpty &&
        secretKey != null &&
        secretKey.trim().isNotEmpty;
  }

  Future<String> maskedKey(ApiSecretField field) async {
    return maskApiKey(await readSecret(field));
  }
}

class MemorySecretStore implements SecureSecretStore {
  final Map<String, String> _values = {};
  int readCount = 0;
  int writeCount = 0;
  int deleteCount = 0;

  @override
  Future<void> write({required String key, required String value}) async {
    writeCount += 1;
    _values[key] = value;
  }

  @override
  Future<String?> read({required String key}) async {
    readCount += 1;
    return _values[key];
  }

  @override
  Future<void> delete({required String key}) async {
    deleteCount += 1;
    _values.remove(key);
  }
}
