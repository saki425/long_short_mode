import 'package:decimal/decimal.dart';

import '../../database/app_database.dart';
import 'reconciliation_models.dart';

class FuturesReconciler {
  FuturesReconciler(this.db);

  final AppDatabase db;

  Future<List<ReconciliationDifferenceModel>> reconcile() async {
    final differences = <ReconciliationDifferenceModel>[];
    final positions = await (db.select(db.futuresPositions)..where((tbl) => tbl.symbol.equals('BTCUSDT'))).get();
    for (final position in positions) {
      final amount = Decimal.parse(position.positionAmount);
      final isLong = position.positionSide == 'LONG' || (position.positionSide == 'BOTH' && amount > Decimal.zero);
      final isShort = position.positionSide == 'SHORT' || (position.positionSide == 'BOTH' && amount < Decimal.zero);
      if (isLong && amount != Decimal.zero) {
        differences.add(
          ReconciliationDifferenceModel(
            severity: 'critical',
            accountType: 'futuresSubAccount',
            type: 'unexpectedLongPosition',
            localValue: 'strategyLong=0',
            exchangeValue: '${position.positionSide} ${position.positionAmount}',
            suggestion: '检测到多仓。本阶段只记录风险，禁止自动平仓。',
          ),
        );
      }
      if (isShort && amount != Decimal.zero) {
        differences.add(
          ReconciliationDifferenceModel(
            severity: 'warning',
            accountType: 'futuresSubAccount',
            type: 'unexpectedShortPosition',
            localValue: 'strategyShort=0',
            exchangeValue: '${position.positionSide} ${position.positionAmount}',
            suggestion: '确认是否为本策略空仓，未确认前真实策略不得启动。',
          ),
        );
      }
    }
    return differences;
  }
}
