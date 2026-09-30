import 'package:decimal/decimal.dart';

import '../../database/app_database.dart';

class AccountAssetDisplayResult {
  const AccountAssetDisplayResult({
    required this.assets,
    required this.totalCount,
    required this.nonZeroCount,
    required this.hiddenZeroCount,
  });

  final List<AccountAsset> assets;
  final int totalCount;
  final int nonZeroCount;
  final int hiddenZeroCount;
}

class AccountAssetDisplayService {
  const AccountAssetDisplayService();

  AccountAssetDisplayResult filterAndSort({
    required List<AccountAsset> assets,
    required bool hideZeroAssets,
    SpotAccountSnapshot? latestSpotSnapshot,
    Set<String> keepAssets = const {},
  }) {
    final sorted = [...assets]..sort(_compareAssets);
    final nonZeroCount = sorted.where(_hasVisibleBalance).length;
    final visible =
        hideZeroAssets
            ? sorted
                .where(
                  (asset) =>
                      !_isZeroAsset(asset) ||
                      _mustKeepAsset(asset, latestSpotSnapshot, keepAssets),
                )
                .toList()
            : sorted;
    return AccountAssetDisplayResult(
      assets: visible,
      totalCount: sorted.length,
      nonZeroCount: nonZeroCount,
      hiddenZeroCount: sorted.length - visible.length,
    );
  }

  bool isZeroAsset(AccountAsset asset) => _isZeroAsset(asset);

  bool _isZeroAsset(AccountAsset asset) {
    return _decimal(asset.free) == Decimal.zero &&
        _decimal(asset.locked) == Decimal.zero;
  }

  bool _hasVisibleBalance(AccountAsset asset) {
    return _decimal(asset.free) > Decimal.zero ||
        _decimal(asset.locked) > Decimal.zero;
  }

  bool _mustKeepAsset(
    AccountAsset asset,
    SpotAccountSnapshot? snapshot,
    Set<String> keepAssets,
  ) {
    final symbol = asset.asset.toUpperCase();
    if (keepAssets.map((item) => item.toUpperCase()).contains(symbol)) {
      return true;
    }
    if (_decimal(asset.locked) > Decimal.zero) {
      return true;
    }
    if (symbol == 'BTC' && snapshot != null) {
      return _decimal(snapshot.strategyTrackedBtc) > Decimal.zero ||
          _decimal(snapshot.externalBtc) > Decimal.zero ||
          _decimal(snapshot.unclassifiedBtc) > Decimal.zero ||
          _decimal(snapshot.btcLocked) > Decimal.zero;
    }
    return false;
  }

  int _compareAssets(AccountAsset a, AccountAsset b) {
    final aHasBalance = _hasVisibleBalance(a);
    final bHasBalance = _hasVisibleBalance(b);
    if (aHasBalance != bHasBalance) {
      return aHasBalance ? -1 : 1;
    }
    final aPriority = _priority(a.asset);
    final bPriority = _priority(b.asset);
    if (aPriority != bPriority) {
      return aPriority.compareTo(bPriority);
    }
    final totalCompare = _decimal(b.total).compareTo(_decimal(a.total));
    if (totalCompare != 0) {
      return totalCompare;
    }
    return a.asset.compareTo(b.asset);
  }

  int _priority(String asset) {
    return switch (asset.toUpperCase()) {
      'USDT' => 0,
      'BTC' => 1,
      _ => 2,
    };
  }

  Decimal _decimal(String value) => Decimal.tryParse(value) ?? Decimal.zero;
}
