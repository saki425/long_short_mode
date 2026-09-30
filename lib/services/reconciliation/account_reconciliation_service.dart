import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';
import 'futures_reconciler.dart';
import 'reconciliation_models.dart';
import 'spot_reconciler.dart';

class AccountReconciliationService {
  AccountReconciliationService(this.db)
      : _spot = SpotReconciler(db),
        _futures = FuturesReconciler(db);

  final AppDatabase db;
  final SpotReconciler _spot;
  final FuturesReconciler _futures;
  final Uuid _uuid = const Uuid();

  Future<ReconciliationResult> runReadOnlyReconciliation() async {
    final runId = _uuid.v4();
    final startedAt = DateTime.now().toUtc();
    await db.into(db.reconciliationRuns).insert(
          ReconciliationRunsCompanion.insert(
            id: runId,
            status: 'running',
            startedAt: startedAt,
          ),
        );
    final differences = <ReconciliationDifferenceModel>[];
    try {
      differences.addAll(await _spot.reconcile());
      differences.addAll(await _futures.reconcile());
      await _saveDifferences(runId, differences);
      await (db.update(db.reconciliationRuns)..where((tbl) => tbl.id.equals(runId))).write(
        ReconciliationRunsCompanion(
          status: const Value('completed'),
          completedAt: Value(DateTime.now().toUtc()),
          summaryJson: Value('{"differences":${differences.length}}'),
        ),
      );
      return ReconciliationResult(runId: runId, differences: differences);
    } catch (error) {
      await (db.update(db.reconciliationRuns)..where((tbl) => tbl.id.equals(runId))).write(
        ReconciliationRunsCompanion(
          status: const Value('error'),
          completedAt: Value(DateTime.now().toUtc()),
          errorMessage: Value(error.toString()),
        ),
      );
      rethrow;
    }
  }

  Future<void> _saveDifferences(String runId, List<ReconciliationDifferenceModel> differences) async {
    final now = DateTime.now().toUtc();
    await db.batch((batch) {
      for (final difference in differences) {
        batch.insert(
          db.reconciliationDifferences,
          ReconciliationDifferencesCompanion.insert(
            id: _uuid.v4(),
            runId: runId,
            severity: difference.severity,
            accountType: difference.accountType,
            differenceType: difference.type,
            localValue: Value(difference.localValue),
            exchangeValue: Value(difference.exchangeValue),
            suggestion: Value(difference.suggestion),
            firstSeenAt: now,
            lastSeenAt: now,
          ),
        );
        if (difference.type.startsWith('unexpected') || difference.type.startsWith('unknown')) {
          batch.insert(
            db.externalAccountEvents,
            ExternalAccountEventsCompanion.insert(
              id: _uuid.v4(),
              accountType: difference.accountType,
              eventType: difference.type,
              severity: difference.severity,
              message: difference.suggestion ?? difference.type,
              detectedAt: now,
            ),
          );
        }
      }
    });
  }
}
