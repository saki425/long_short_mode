import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';
import '../../repositories/basic_repositories.dart';
import '../../services/binance/auth/binance_credentials.dart';
import 'secure_key_storage.dart';

class ApiKeyProfileSecret {
  const ApiKeyProfileSecret({required this.apiKey, required this.apiSecret});

  final String apiKey;
  final String apiSecret;

  Map<String, String> toJson() => {'apiKey': apiKey, 'apiSecret': apiSecret};

  static ApiKeyProfileSecret fromJson(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('API key profile secret must be an object');
    }
    return ApiKeyProfileSecret(
      apiKey: decoded['apiKey']?.toString().trim() ?? '',
      apiSecret: decoded['apiSecret']?.toString().trim() ?? '',
    );
  }
}

class ApiKeyProfileService {
  ApiKeyProfileService({
    required this.db,
    SecureSecretStore? secretStore,
    LogRepository? logRepository,
  })  : _secretStore = secretStore ??
            createDefaultSecureSecretStore(accountName: keychainService),
        _logRepository = logRepository;

  static const keychainService = 'grid_hedge_desktop_binance';
  static const _preferencesSecretPrefix =
      'grid_hedge_desktop.api_key_profile_secret.';

  final AppDatabase db;
  final SecureSecretStore _secretStore;
  final LogRepository? _logRepository;
  final Uuid _uuid = const Uuid();
  final Map<String, BinanceCredentials> _sessionCredentialsByProfileId = {};
  final Map<String, Future<BinanceCredentials>> _pendingCredentialLoads = {};

  int get sessionCredentialCount => _sessionCredentialsByProfileId.length;

  void clearSessionCache() {
    _sessionCredentialsByProfileId.clear();
    _pendingCredentialLoads.clear();
  }

  Future<ApiKeyProfile> createProfile({
    required String name,
    required String environment,
    required String accountType,
    required String apiKey,
    required String apiSecret,
    String exchange = 'binance',
    bool isValid = false,
    DateTime? lastValidatedAt,
    String? lastError,
  }) async {
    final now = DateTime.now().toUtc();
    final profileId = _uuid.v4();
    final account = keychainAccountFor(
      environment: environment,
      accountType: accountType,
      profileId: profileId,
    );
    await _writeSecret(
      profileId: profileId,
      account: account,
      secret: ApiKeyProfileSecret(apiKey: apiKey, apiSecret: apiSecret),
    );
    final companion = ApiKeyProfilesCompanion.insert(
      id: profileId,
      name: name,
      exchange: Value(exchange),
      environment: environment,
      accountType: accountType,
      keychainService: keychainService,
      keychainAccount: account,
      apiKeyMasked: SecureKeyStorage.maskApiKeyStatic(apiKey),
      isValid: Value(isValid),
      lastValidatedAt: Value(lastValidatedAt),
      lastError: Value(lastError),
      createdAt: now,
      updatedAt: now,
    );
    await db.into(db.apiKeyProfiles).insert(companion);
    _cacheCredentials(
      profileId: profileId,
      accountType: accountType,
      apiKey: apiKey,
      apiSecret: apiSecret,
    );
    return (db.select(db.apiKeyProfiles)
          ..where((tbl) => tbl.id.equals(profileId)))
        .getSingle();
  }

  Future<void> updateProfileSecret({
    required String profileId,
    required String apiKey,
    required String apiSecret,
    bool? isValid,
    DateTime? lastValidatedAt,
    String? lastError,
  }) async {
    final profile = await getProfile(profileId);
    if (profile == null) {
      throw StateError('API Key Profile not found: $profileId');
    }
    await _writeSecret(
      profileId: profileId,
      account: profile.keychainAccount,
      secret: ApiKeyProfileSecret(apiKey: apiKey, apiSecret: apiSecret),
    );
    _cacheCredentials(
      profileId: profileId,
      accountType: profile.accountType,
      apiKey: apiKey,
      apiSecret: apiSecret,
    );
    await (db.update(db.apiKeyProfiles)
          ..where((tbl) => tbl.id.equals(profileId)))
        .write(
      ApiKeyProfilesCompanion(
        apiKeyMasked: Value(SecureKeyStorage.maskApiKeyStatic(apiKey)),
        isValid: isValid == null ? const Value.absent() : Value(isValid),
        lastValidatedAt: lastValidatedAt == null
            ? const Value.absent()
            : Value(lastValidatedAt),
        lastError: Value(lastError),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<ApiKeyProfile?> getProfile(String profileId) {
    return (db.select(db.apiKeyProfiles)
          ..where((tbl) => tbl.id.equals(profileId)))
        .getSingleOrNull();
  }

  Future<List<ApiKeyProfile>> listProfiles({
    String? environment,
    String? accountType,
  }) {
    final query = db.select(db.apiKeyProfiles);
    if (environment != null) {
      query.where((tbl) => tbl.environment.equals(environment));
    }
    if (accountType != null) {
      query.where((tbl) => tbl.accountType.equals(accountType));
    }
    query.orderBy([
      (tbl) => OrderingTerm.asc(tbl.accountType),
      (tbl) => OrderingTerm.asc(tbl.name),
    ]);
    return query.get();
  }

  Future<BinanceCredentials> loadCredentials(String profileId) async {
    final cached = _sessionCredentialsByProfileId[profileId];
    if (cached != null) {
      return cached;
    }
    final pending = _pendingCredentialLoads[profileId];
    if (pending != null) {
      return pending;
    }
    final load = _loadCredentialsFromKeychain(profileId);
    _pendingCredentialLoads[profileId] = load;
    try {
      final credentials = await load;
      _sessionCredentialsByProfileId[profileId] = credentials;
      return credentials;
    } finally {
      _pendingCredentialLoads.remove(profileId);
    }
  }

  Future<BinanceCredentials> _loadCredentialsFromKeychain(
    String profileId,
  ) async {
    final profile = await getProfile(profileId);
    if (profile == null) {
      throw StateError('API Key Profile not found: $profileId');
    }
    final raw = await _readSecret(profile);
    if (raw == null || raw.trim().isEmpty) {
      throw StateError('API Key Profile secret missing: $profileId');
    }
    final secret = ApiKeyProfileSecret.fromJson(raw);
    if (secret.apiKey.isEmpty || secret.apiSecret.isEmpty) {
      throw StateError('API Key Profile secret incomplete: $profileId');
    }
    return BinanceCredentials(
      apiKey: secret.apiKey,
      secretKey: secret.apiSecret,
      accountType: profile.accountType,
    );
  }

  Future<void> updateProfileValidation({
    required String profileId,
    required bool isValid,
    DateTime? lastValidatedAt,
    String? lastError,
  }) async {
    await (db.update(db.apiKeyProfiles)
          ..where((tbl) => tbl.id.equals(profileId)))
        .write(
      ApiKeyProfilesCompanion(
        isValid: Value(isValid),
        lastValidatedAt: Value(lastValidatedAt),
        lastError: Value(lastError),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<SymbolAccountBinding> bindSpotProfile({
    required String symbol,
    required String environment,
    required String profileId,
  }) {
    return upsertBinding(
      symbol: symbol,
      environment: environment,
      spotKeyProfileId: profileId,
    );
  }

  Future<SymbolAccountBinding> bindFuturesProfile({
    required String symbol,
    required String environment,
    required String profileId,
  }) {
    return upsertBinding(
      symbol: symbol,
      environment: environment,
      futuresKeyProfileId: profileId,
    );
  }

  Future<SymbolAccountBinding> upsertBinding({
    required String symbol,
    required String environment,
    String? spotKeyProfileId,
    String? futuresKeyProfileId,
  }) async {
    final normalizedSymbol = symbol.toUpperCase();
    final normalizedEnvironment = environment.toLowerCase();
    final now = DateTime.now().toUtc();
    final existing = await getBinding(
      symbol: normalizedSymbol,
      environment: normalizedEnvironment,
    );
    if (existing == null) {
      final id = _uuid.v4();
      await db.into(db.symbolAccountBindings).insert(
            SymbolAccountBindingsCompanion.insert(
              id: id,
              symbol: normalizedSymbol,
              environment: normalizedEnvironment,
              spotKeyProfileId: Value(spotKeyProfileId),
              futuresKeyProfileId: Value(futuresKeyProfileId),
              createdAt: now,
              updatedAt: now,
            ),
          );
      return (db.select(db.symbolAccountBindings)
            ..where((tbl) => tbl.id.equals(id)))
          .getSingle();
    }
    await (db.update(db.symbolAccountBindings)
          ..where((tbl) => tbl.id.equals(existing.id)))
        .write(
      SymbolAccountBindingsCompanion(
        spotKeyProfileId: spotKeyProfileId == null
            ? const Value.absent()
            : Value(spotKeyProfileId),
        futuresKeyProfileId: futuresKeyProfileId == null
            ? const Value.absent()
            : Value(futuresKeyProfileId),
        updatedAt: Value(now),
      ),
    );
    return (db.select(db.symbolAccountBindings)
          ..where((tbl) => tbl.id.equals(existing.id)))
        .getSingle();
  }

  Future<SymbolAccountBinding?> getBinding({
    required String symbol,
    required String environment,
  }) {
    return (db.select(db.symbolAccountBindings)
          ..where(
            (tbl) =>
                tbl.symbol.equals(symbol.toUpperCase()) &
                tbl.environment.equals(environment.toLowerCase()),
          ))
        .getSingleOrNull();
  }

  Future<SymbolAccountBinding> clearSpotBinding({
    required String symbol,
    required String environment,
  }) async {
    final binding = await getBinding(symbol: symbol, environment: environment);
    if (binding == null) {
      throw StateError('Symbol account binding not found: $symbol');
    }
    await (db.update(db.symbolAccountBindings)
          ..where((tbl) => tbl.id.equals(binding.id)))
        .write(
      SymbolAccountBindingsCompanion(
        spotKeyProfileId: const Value(null),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    return (db.select(db.symbolAccountBindings)
          ..where((tbl) => tbl.id.equals(binding.id)))
        .getSingle();
  }

  Future<SymbolAccountBinding> clearFuturesBinding({
    required String symbol,
    required String environment,
  }) async {
    final binding = await getBinding(symbol: symbol, environment: environment);
    if (binding == null) {
      throw StateError('Symbol account binding not found: $symbol');
    }
    await (db.update(db.symbolAccountBindings)
          ..where((tbl) => tbl.id.equals(binding.id)))
        .write(
      SymbolAccountBindingsCompanion(
        futuresKeyProfileId: const Value(null),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    return (db.select(db.symbolAccountBindings)
          ..where((tbl) => tbl.id.equals(binding.id)))
        .getSingle();
  }

  Stream<SymbolAccountBinding?> watchBinding({
    required String symbol,
    required String environment,
  }) {
    return (db.select(db.symbolAccountBindings)
          ..where(
            (tbl) =>
                tbl.symbol.equals(symbol.toUpperCase()) &
                tbl.environment.equals(environment.toLowerCase()),
          ))
        .watchSingleOrNull();
  }

  Future<void> deleteProfile(String profileId) async {
    final profile = await getProfile(profileId);
    if (profile == null) return;
    final bindings = await (db.select(db.symbolAccountBindings)
          ..where(
            (tbl) =>
                tbl.spotKeyProfileId.equals(profileId) |
                tbl.futuresKeyProfileId.equals(profileId),
          ))
        .get();
    if (bindings.isNotEmpty) {
      throw StateError('API Key Profile is still bound to symbol workspaces');
    }
    await _deletePreferenceSecret(profileId);
    _sessionCredentialsByProfileId.remove(profileId);
    _pendingCredentialLoads.remove(profileId);
    await (db.delete(db.apiKeyProfiles)
          ..where((tbl) => tbl.id.equals(profileId)))
        .go();
  }

  Future<void> ensureLegacyDefaultBinding({
    required String symbol,
    required String environment,
    required BinanceCredentialsBundle? credentials,
  }) async {
    final normalizedSymbol = symbol.toUpperCase();
    final normalizedEnvironment = environment.toLowerCase();
    final existing = await getBinding(
      symbol: normalizedSymbol,
      environment: normalizedEnvironment,
    );
    var spotProfileId = existing?.spotKeyProfileId;
    var futuresProfileId = existing?.futuresKeyProfileId;
    final legacyCredentials = credentials;

    if ((spotProfileId == null || spotProfileId.isEmpty) &&
        legacyCredentials != null &&
        legacyCredentials.spotConfigured) {
      spotProfileId = await _ensureDefaultProfile(
        name: 'Default Binance Spot',
        environment: normalizedEnvironment,
        accountType: 'spot',
        apiKey: legacyCredentials.spotApiKey,
        apiSecret: legacyCredentials.spotSecretKey,
      );
    }

    if ((futuresProfileId == null || futuresProfileId.isEmpty) &&
        legacyCredentials != null &&
        legacyCredentials.futuresConfigured) {
      futuresProfileId = await _ensureDefaultProfile(
        name: 'Default Binance Futures',
        environment: normalizedEnvironment,
        accountType: 'futures',
        apiKey: legacyCredentials.futuresApiKey,
        apiSecret: legacyCredentials.futuresSecretKey,
      );
    }

    if (existing == null ||
        spotProfileId != existing.spotKeyProfileId ||
        futuresProfileId != existing.futuresKeyProfileId) {
      await upsertBinding(
        symbol: normalizedSymbol,
        environment: normalizedEnvironment,
        spotKeyProfileId: spotProfileId,
        futuresKeyProfileId: futuresProfileId,
      );
    }
  }

  Future<String> _ensureDefaultProfile({
    required String name,
    required String environment,
    required String accountType,
    required String apiKey,
    required String apiSecret,
  }) async {
    final existing = await (db.select(db.apiKeyProfiles)
          ..where(
            (tbl) =>
                tbl.name.equals(name) &
                tbl.environment.equals(environment) &
                tbl.accountType.equals(accountType),
          )
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) {
      await updateProfileSecret(
        profileId: existing.id,
        apiKey: apiKey,
        apiSecret: apiSecret,
        isValid: true,
        lastValidatedAt: DateTime.now().toUtc(),
        lastError: null,
      );
      return existing.id;
    }
    final profile = await createProfile(
      name: name,
      environment: environment,
      accountType: accountType,
      apiKey: apiKey,
      apiSecret: apiSecret,
      isValid: true,
      lastValidatedAt: DateTime.now().toUtc(),
    );
    return profile.id;
  }

  String keychainAccountFor({
    required String environment,
    required String accountType,
    required String profileId,
  }) {
    return '${environment.toLowerCase()}_${accountType.toLowerCase()}_$profileId';
  }

  Future<void> _writeSecret({
    required String profileId,
    required String account,
    required ApiKeyProfileSecret secret,
  }) async {
    final raw = jsonEncode(secret.toJson());
    await _writePreferenceSecret(profileId, raw);
    await _log('KEY_PROFILE_PREFERENCES_WRITE_SUCCESS', {'account': account});
  }

  Future<String?> _readSecret(ApiKeyProfile profile) async {
    final preferenceSecret = await _readPreferenceSecret(profile.id);
    if (preferenceSecret != null && preferenceSecret.trim().isNotEmpty) {
      return preferenceSecret;
    }
    final keychainSecret =
        await _secretStore.read(key: profile.keychainAccount);
    if (keychainSecret != null && keychainSecret.trim().isNotEmpty) {
      await _writePreferenceSecret(profile.id, keychainSecret);
    }
    return keychainSecret;
  }

  Future<void> _writePreferenceSecret(String profileId, String raw) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_preferenceSecretKey(profileId), raw);
  }

  Future<String?> _readPreferenceSecret(String profileId) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_preferenceSecretKey(profileId));
  }

  Future<void> _deletePreferenceSecret(String profileId) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_preferenceSecretKey(profileId));
  }

  String _preferenceSecretKey(String profileId) {
    return '$_preferencesSecretPrefix$profileId';
  }

  void _cacheCredentials({
    required String profileId,
    required String accountType,
    required String apiKey,
    required String apiSecret,
  }) {
    _sessionCredentialsByProfileId[profileId] = BinanceCredentials(
      apiKey: apiKey.trim(),
      secretKey: apiSecret.trim(),
      accountType: accountType,
    );
    _pendingCredentialLoads.remove(profileId);
  }

  Future<void> _log(String message, Map<String, Object?> extra) async {
    final repository = _logRepository;
    if (repository == null) return;
    await repository.append(
      level: 'info',
      module: 'SECURITY',
      message: message,
      extraJson: jsonEncode(extra),
    );
  }
}
