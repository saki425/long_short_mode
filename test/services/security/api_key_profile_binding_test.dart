import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/database/app_database.dart';
import 'package:grid_hedge_trader/services/binance/auth/binance_client_provider.dart';
import 'package:grid_hedge_trader/services/binance/user_data/key_profile_user_data_stream_manager.dart';
import 'package:grid_hedge_trader/services/security/api_key_profile_service.dart';
import 'package:grid_hedge_trader/services/security/secure_key_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late MemorySecretStore secretStore;
  late ApiKeyProfileService profileService;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    secretStore = MemorySecretStore();
    profileService = ApiKeyProfileService(db: db, secretStore: secretStore);
  });

  tearDown(() async {
    await db.close();
  });

  test('creates profile with secret only in keychain store', () async {
    final profile = await profileService.createProfile(
      name: 'BTC Spot',
      environment: 'live',
      accountType: 'spot',
      apiKey: 'ABCDEFGHIJKLMNOP',
      apiSecret: 'super-secret',
      isValid: true,
    );

    final row = await profileService.getProfile(profile.id);
    final credentials = await profileService.loadCredentials(profile.id);

    expect(row, isNotNull);
    expect(row!.apiKeyMasked, 'ABCD****MNOP');
    expect(row.keychainAccount, startsWith('live_spot_'));
    expect(credentials.apiKey, 'ABCDEFGHIJKLMNOP');
    expect(credentials.secretKey, 'super-secret');

    final rawRows = await db.select(db.apiKeyProfiles).get();
    final sqliteText = rawRows.map((item) => item.toString()).join('\n');
    expect(sqliteText.contains('super-secret'), isFalse);
    expect(sqliteText.contains('ABCDEFGHIJKLMNOP'), isFalse);
  });

  test('binds BTC and ETH to different spot profiles', () async {
    final btcProfile = await profileService.createProfile(
      name: 'BTC Spot',
      environment: 'live',
      accountType: 'spot',
      apiKey: 'BTCSPOTAPIKEY0001',
      apiSecret: 'btc-secret',
      isValid: true,
    );
    final ethProfile = await profileService.createProfile(
      name: 'ETH Spot',
      environment: 'live',
      accountType: 'spot',
      apiKey: 'ETHSPOTAPIKEY0001',
      apiSecret: 'eth-secret',
      isValid: true,
    );

    await profileService.bindSpotProfile(
      symbol: 'BTCUSDT',
      environment: 'live',
      profileId: btcProfile.id,
    );
    await profileService.bindSpotProfile(
      symbol: 'ETHUSDT',
      environment: 'live',
      profileId: ethProfile.id,
    );

    final provider = BinanceClientProvider(
      db: db,
      profileService: profileService,
    );
    final btcClient = await provider.getSpotClientForSymbol('BTCUSDT', 'live');
    final ethClient = await provider.getSpotClientForSymbol('ETHUSDT', 'live');

    expect(btcClient.keyProfileId, btcProfile.id);
    expect(ethClient.keyProfileId, ethProfile.id);
    expect(btcClient.client.credentials.apiKey, 'BTCSPOTAPIKEY0001');
    expect(ethClient.client.credentials.apiKey, 'ETHSPOTAPIKEY0001');
  });

  test('unbound symbol cannot create private client', () async {
    final provider = BinanceClientProvider(
      db: db,
      profileService: profileService,
    );

    expect(
      () => provider.getSpotClientForSymbol('ETHUSDT', 'live'),
      throwsA(isA<StateError>()),
    );
  });

  test('user data stream sessions are keyed by key profile', () async {
    final manager = KeyProfileUserDataStreamManager();
    addTearDown(manager.dispose);

    manager.ensureSpotProfile(
      keyProfileId: 'profile-a',
      symbols: const ['BTCUSDT'],
    );
    manager.ensureSpotProfile(
      keyProfileId: 'profile-a',
      symbols: const ['ETHUSDT'],
    );
    manager.ensureSpotProfile(
      keyProfileId: 'profile-b',
      symbols: const ['SOLUSDT'],
    );

    expect(manager.spotSessionCount, 2);
    expect(manager.spotSessions['profile-a']!.boundSymbols, {
      'BTCUSDT',
      'ETHUSDT',
    });

    final eventFuture = manager.events.first;
    manager.dispatchSpotEvent(
      keyProfileId: 'profile-a',
      symbol: 'ETHUSDT',
      payload: {'e': 'executionReport'},
    );
    final event = await eventFuture;

    expect(event.keyProfileId, 'profile-a');
    expect(event.symbol, 'ETHUSDT');
    expect(event.accountType, 'spot');
  });

  test('migrates legacy BTCUSDT credentials into default binding', () async {
    await profileService.ensureLegacyDefaultBinding(
      symbol: 'BTCUSDT',
      environment: 'live',
      credentials: const BinanceCredentialsBundle(
        spotApiKey: 'LEGACYSPOTAPIKEY',
        spotSecretKey: 'legacy-spot-secret',
        futuresApiKey: 'LEGACYFUTURESAPIKEY',
        futuresSecretKey: 'legacy-futures-secret',
      ),
    );

    final binding = await profileService.getBinding(
      symbol: 'BTCUSDT',
      environment: 'live',
    );
    expect(binding, isNotNull);
    expect(binding!.spotKeyProfileId, isNotNull);
    expect(binding.futuresKeyProfileId, isNotNull);

    final spotProfile = await profileService.getProfile(
      binding.spotKeyProfileId!,
    );
    final futuresProfile = await profileService.getProfile(
      binding.futuresKeyProfileId!,
    );

    expect(spotProfile!.name, 'Default Binance Spot');
    expect(spotProfile.accountType, 'spot');
    expect(spotProfile.isValid, isTrue);
    expect(futuresProfile!.name, 'Default Binance Futures');
    expect(futuresProfile.accountType, 'futures');
    expect(futuresProfile.isValid, isTrue);

    final provider = BinanceClientProvider(
      db: db,
      profileService: profileService,
    );
    final spotClient = await provider.getSpotClientForSymbol('BTCUSDT', 'live');
    final futuresClient = await provider.getFuturesClientForSymbol(
      'BTCUSDT',
      'live',
    );

    expect(spotClient.client.credentials.apiKey, 'LEGACYSPOTAPIKEY');
    expect(futuresClient.client.credentials.apiKey, 'LEGACYFUTURESAPIKEY');
  });
}
