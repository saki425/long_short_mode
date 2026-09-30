import '../database/app_database.dart';

class AppUiSettings {
  const AppUiSettings._();

  static const hideSpotUiKey = 'hideSpotUi';
  static const shortRecoverEnabledKey = 'shortRecoverEnabled';

  static Stream<bool> watchHideSpotUi(AppDatabase db) {
    return (db.select(db.appSettings)..where(
      (tbl) => tbl.key.equals(hideSpotUiKey),
    )).watchSingleOrNull().map((row) => row?.value == 'true');
  }

  static Stream<bool> watchHideSpotUiForSymbol(
    AppDatabase db, {
    required String? symbol,
  }) {
    final normalizedSymbol = symbol?.trim().toUpperCase();
    if (normalizedSymbol == null || normalizedSymbol.isEmpty) {
      return watchHideSpotUi(db);
    }
    final scopedKey = scopedSettingKey(
      key: hideSpotUiKey,
      symbol: normalizedSymbol,
    );
    return db.select(db.appSettings).watch().map((rows) {
      String? scopedValue;
      String? globalValue;
      for (final row in rows) {
        if (row.key == scopedKey) {
          scopedValue = row.value;
        } else if (row.key == hideSpotUiKey) {
          globalValue = row.value;
        }
      }
      return (scopedValue ?? globalValue) == 'true';
    });
  }

  static Future<bool> hideSpotUi(AppDatabase db) async {
    final row =
        await (db.select(db.appSettings)
          ..where((tbl) => tbl.key.equals(hideSpotUiKey))).getSingleOrNull();
    return row?.value == 'true';
  }

  static Future<bool> hideSpotUiForSymbol(
    AppDatabase db, {
    required String? symbol,
  }) async {
    final value = await readScopedSettingValue(
      db,
      key: hideSpotUiKey,
      symbol: symbol,
    );
    return value == 'true';
  }

  static Future<void> setHideSpotUi(AppDatabase db, bool value) {
    return db
        .into(db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: hideSpotUiKey,
            value: value ? 'true' : 'false',
            updatedAt: DateTime.now().toUtc(),
          ),
        );
  }

  static Future<void> setHideSpotUiForSymbol(
    AppDatabase db, {
    required String symbol,
    required bool value,
  }) {
    return setScopedSettingValue(
      db,
      key: hideSpotUiKey,
      symbol: symbol,
      value: value ? 'true' : 'false',
    );
  }

  static Stream<bool> watchShortRecoverEnabledForSymbol(
    AppDatabase db, {
    required String? symbol,
  }) {
    final normalizedSymbol = symbol?.trim().toUpperCase();
    if (normalizedSymbol == null || normalizedSymbol.isEmpty) {
      return const Stream<bool>.empty();
    }
    final scopedKey = scopedSettingKey(
      key: shortRecoverEnabledKey,
      symbol: normalizedSymbol,
    );
    return (db.select(db.appSettings)..where(
      (tbl) => tbl.key.equals(scopedKey),
    )).watchSingleOrNull().map((row) => row?.value == 'true');
  }

  static Future<bool> shortRecoverEnabledForSymbol(
    AppDatabase db, {
    required String? symbol,
  }) async {
    final value = await readScopedSettingValue(
      db,
      key: shortRecoverEnabledKey,
      symbol: symbol,
    );
    return value == 'true';
  }

  static Future<void> setShortRecoverEnabledForSymbol(
    AppDatabase db, {
    required String symbol,
    required bool value,
  }) {
    return setScopedSettingValue(
      db,
      key: shortRecoverEnabledKey,
      symbol: symbol,
      value: value ? 'true' : 'false',
    );
  }

  static String scopedSettingKey({
    required String key,
    required String symbol,
    String? keyProfileId,
  }) {
    final normalizedSymbol = symbol.toUpperCase();
    final profile = _profileScope(keyProfileId);
    return '$key.$normalizedSymbol.$profile';
  }

  static Future<String?> readScopedSettingValue(
    AppDatabase db, {
    required String key,
    String? symbol,
    String? keyProfileId,
  }) async {
    final normalizedSymbol = symbol?.trim().toUpperCase();
    if (normalizedSymbol != null && normalizedSymbol.isNotEmpty) {
      final scopedKey = scopedSettingKey(
        key: key,
        symbol: normalizedSymbol,
        keyProfileId: keyProfileId,
      );
      final scopedRow =
          await (db.select(db.appSettings)
            ..where((tbl) => tbl.key.equals(scopedKey))).getSingleOrNull();
      if (scopedRow != null) {
        return scopedRow.value;
      }
    }
    final row =
        await (db.select(db.appSettings)
          ..where((tbl) => tbl.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  static Future<void> setScopedSettingValue(
    AppDatabase db, {
    required String key,
    required String symbol,
    String? keyProfileId,
    required String value,
  }) {
    return db
        .into(db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: scopedSettingKey(
              key: key,
              symbol: symbol,
              keyProfileId: keyProfileId,
            ),
            value: value,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
  }

  static String _profileScope(String? keyProfileId) {
    final value = keyProfileId?.trim();
    return value == null || value.isEmpty ? 'legacy' : value;
  }
}
