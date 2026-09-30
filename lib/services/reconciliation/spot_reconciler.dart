import 'package:decimal/decimal.dart';

import '../../database/app_database.dart';
import 'reconciliation_models.dart';

class SpotReconciler {
  SpotReconciler(this.db);

  final AppDatabase db;

  Future<List<ReconciliationDifferenceModel>> reconcile() async {
    final differences = <ReconciliationDifferenceModel>[];
    final assets = await db.select(db.accountAssets).get();
    final btc = assets.where((asset) => asset.accountType == 'spotSubAccount' && asset.asset == 'BTC').firstOrNull;
    if (btc != null && Decimal.parse(btc.total) > Decimal.zero) {
      differences.add(
        ReconciliationDifferenceModel(
          severity: 'warning',
          accountType: 'spotSubAccount',
          type: 'unknownSpotBalanceChange',
          localValue: 'strategyTrackedBtc=0',
          exchangeValue: 'accountTotalBtc=${btc.total}',
          suggestion: '确认该 BTC 是否属于策略，未确认前真实策略不得启动。',
        ),
      );
    }
    final exchangeOpenOrders = await (db.select(db.exchangeOpenOrders)..where((tbl) => tbl.accountType.equals('spotSubAccount'))).get();
    for (final order in exchangeOpenOrders) {
      if (!order.clientOrderId.startsWith('DHG_')) {
        differences.add(
          ReconciliationDifferenceModel(
            severity: 'warning',
            accountType: 'spotSubAccount',
            type: 'localOrderMissingOnExchange',
            localValue: 'none',
            exchangeValue: '${order.symbol} ${order.side} ${order.price}',
            suggestion: '检测到非本程序现货挂单，启动真实策略前需要人工确认。',
          ),
        );
      }
    }
    return differences;
  }
}
