import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/repositories/basic_repositories.dart';
import 'package:grid_hedge_trader/services/security/secure_key_storage.dart';

void main() {
  test('saves reads updates deletes and masks Binance API keys', () async {
    final store = MemorySecretStore();
    final cache = CredentialsSessionCache();
    final vault = CredentialsVault(store: store, cache: cache);
    final storage = SecureKeyStorage(vault: vault);

    await storage.saveSecret(ApiSecretField.spotApiKey, 'ABCD12345678WXYZ');
    await storage.saveSecret(ApiSecretField.spotSecretKey, 'spot-secret');
    await storage.saveSecret(ApiSecretField.futuresApiKey, 'FUTU12345678KEYS');
    await storage.saveSecret(ApiSecretField.futuresSecretKey, 'futures-secret');

    expect(
      await storage.readSecret(ApiSecretField.spotSecretKey),
      'spot-secret',
    );

    await storage.updateSecret(ApiSecretField.spotSecretKey, 'updated-secret');
    expect(
      await storage.readSecret(ApiSecretField.spotSecretKey),
      'updated-secret',
    );

    final display = await storage.loadDisplay();
    expect(display.spotConfigured, isTrue);
    expect(display.futuresConfigured, isTrue);
    expect(display.maskedSpotApiKey, 'ABCD****WXYZ');
    expect(display.maskedFuturesApiKey, 'FUTU****KEYS');

    await storage.deleteSecret(ApiSecretField.spotSecretKey);
    final afterDelete = await storage.loadDisplay();
    expect(afterDelete.spotConfigured, isFalse);
    expect(afterDelete.maskedSpotApiKey, 'ABCD****WXYZ');

    await storage.deleteAllBinanceSecrets();
    expect(await storage.hasRequiredSecrets(), isFalse);
  });

  test('app startup reads keychain once and later calls use cache', () async {
    final store = MemorySecretStore();
    const credentials = BinanceCredentialsBundle(
      spotApiKey: 'ABCD12345678WXYZ',
      spotSecretKey: 'spot-secret',
      futuresApiKey: 'FUTU12345678KEYS',
      futuresSecretKey: 'futures-secret',
    );
    final vault = CredentialsVault(
      store: store,
      cache: CredentialsSessionCache(),
    );
    await vault.save(credentials);
    expect(store.writeCount, 1);

    vault.cache.lock();
    await vault.readOnce();
    expect(store.readCount, 1);
    expect(vault.cache.status, CredentialsCacheStatus.loaded);

    await vault.readOnce();
    await vault.readOnce();
    expect(store.readCount, 1);

    final storage = SecureKeyStorage(vault: vault);
    await storage.loadDisplay();
    await storage.hasRequiredSecrets();
    await storage.readSecret(ApiSecretField.spotSecretKey);
    expect(store.readCount, 1);
  });

  test('saving updates memory without another keychain read', () async {
    final store = MemorySecretStore();
    final vault = CredentialsVault(
      store: store,
      cache: CredentialsSessionCache(),
    );
    await vault.updateFields({
      ApiSecretField.spotApiKey: 'ABCD12345678WXYZ',
      ApiSecretField.spotSecretKey: 'spot-secret',
      ApiSecretField.futuresApiKey: 'FUTU12345678KEYS',
      ApiSecretField.futuresSecretKey: 'futures-secret',
    });

    expect(store.writeCount, 1);
    expect(store.readCount, 0);
    expect(vault.cache.credentials?.spotSecretKey, 'spot-secret');
    expect(vault.cache.status, CredentialsCacheStatus.loaded);
  });

  test(
    'delete clears memory and secret values are not written to logs',
    () async {
      final db = TestLogSink();
      final store = MemorySecretStore();
      final vault = CredentialsVault(
        store: store,
        cache: CredentialsSessionCache(),
        logRepository: db,
      );
      await vault.save(
        const BinanceCredentialsBundle(
          spotApiKey: 'ABCD12345678WXYZ',
          spotSecretKey: 'spot-secret-never-log',
          futuresApiKey: 'FUTU12345678KEYS',
          futuresSecretKey: 'futures-secret-never-log',
        ),
      );
      await vault.deleteAll();

      expect(vault.cache.status, CredentialsCacheStatus.missing);
      final logs = db.messages.join('\n');
      expect(logs, isNot(contains('spot-secret-never-log')));
      expect(logs, isNot(contains('futures-secret-never-log')));
      expect(logs, isNot(contains('ABCD12345678WXYZ')));
      expect(logs, contains('ABCD****WXYZ'));
    },
  );

  test('single vault instance shares cache across wrappers', () async {
    final store = MemorySecretStore();
    final vault = CredentialsVault(
      store: store,
      cache: CredentialsSessionCache(),
    );
    final first = SecureKeyStorage(vault: vault);
    final second = SecureKeyStorage(vault: vault);

    await first.updateSecret(ApiSecretField.spotApiKey, 'ABCD12345678WXYZ');
    expect(
      await second.readSecret(ApiSecretField.spotApiKey),
      'ABCD12345678WXYZ',
    );
    expect(store.readCount, 0);
  });
}

class TestLogSink implements LogRepository {
  final messages = <String>[];

  @override
  Future<void> append({
    String? strategyId,
    required String level,
    required String module,
    required String message,
    String? extraJson,
    DateTime? createdAt,
  }) async {
    messages.add('$level $module $message ${extraJson ?? ''}');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
