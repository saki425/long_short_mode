import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/database/app_database.dart';
import 'package:grid_hedge_trader/services/accounts/account_asset_display_service.dart';

void main() {
  const service = AccountAssetDisplayService();

  AccountAsset asset(
    String symbol, {
    String free = '0',
    String locked = '0',
    String? total,
  }) {
    return AccountAsset(
      id: 'spotSubAccount-$symbol',
      accountType: 'spotSubAccount',
      keyProfileId: 'legacy',
      asset: symbol,
      free: free,
      locked: locked,
      total: total ?? free,
      source: 'binanceExchange',
      updatedAt: DateTime.utc(2026, 1, 1),
    );
  }

  test('free=0 and locked=0 asset is hidden by default', () {
    final result = service.filterAndSort(
      assets: [asset('ZERO'), asset('USDT', free: '1')],
      hideZeroAssets: true,
    );

    expect(result.assets.map((item) => item.asset), ['USDT']);
    expect(result.hiddenZeroCount, 1);
  });

  test('free greater than zero is not hidden', () {
    final result = service.filterAndSort(
      assets: [asset('BNB', free: '0.0001')],
      hideZeroAssets: true,
    );

    expect(result.assets.single.asset, 'BNB');
  });

  test('locked greater than zero is not hidden', () {
    final result = service.filterAndSort(
      assets: [asset('BTC', locked: '0.0001')],
      hideZeroAssets: true,
    );

    expect(result.assets.single.asset, 'BTC');
  });

  test('BTC and USDT are prioritized before other non-zero assets', () {
    final result = service.filterAndSort(
      assets: [
        asset('ETH', free: '100', total: '100'),
        asset('BTC', free: '0.1', total: '0.1'),
        asset('USDT', free: '1', total: '1'),
      ],
      hideZeroAssets: false,
    );

    expect(result.assets.map((item) => item.asset).toList(), [
      'USDT',
      'BTC',
      'ETH',
    ]);
  });

  test('show all restores zero assets and leaves them last', () {
    final result = service.filterAndSort(
      assets: [asset('ZERO'), asset('ETH', free: '2', total: '2')],
      hideZeroAssets: false,
    );

    expect(result.assets.map((item) => item.asset).toList(), ['ETH', 'ZERO']);
    expect(result.hiddenZeroCount, 0);
  });

  test('filtering does not mutate or delete source records', () {
    final source = [asset('ZERO'), asset('USDT', free: '1')];

    service.filterAndSort(assets: source, hideZeroAssets: true);

    expect(source, hasLength(2));
    expect(source.first.asset, 'ZERO');
  });
}
