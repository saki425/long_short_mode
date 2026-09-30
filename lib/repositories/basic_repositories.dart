import 'package:drift/drift.dart';

import '../database/app_database.dart';

class StrategyRepository {
  StrategyRepository(this.db);
  final AppDatabase db;
}

class GridRepository {
  GridRepository(this.db);
  final AppDatabase db;
}

class FillRepository {
  FillRepository(this.db);
  final AppDatabase db;
}

class HedgeRepository {
  HedgeRepository(this.db);
  final AppDatabase db;
}

class AccountSnapshotRepository {
  AccountSnapshotRepository(this.db);
  final AppDatabase db;
}

class PnlRepository {
  PnlRepository(this.db);
  final AppDatabase db;
}

class RiskEventRepository {
  RiskEventRepository(this.db);
  final AppDatabase db;
}

class LogRepository {
  LogRepository(this.db);
  final AppDatabase db;

  Future<void> append({
    String? strategyId,
    required String level,
    required String module,
    required String message,
    String? extraJson,
    DateTime? createdAt,
  }) async {}

  Stream<List<AppLog>> watchLogs({
    String? module,
    String? level,
    int limit = 200,
  }) {
    final query = db.select(db.appLogs);
    if (module != null) {
      query.where((tbl) => tbl.module.equals(module));
    }
    if (level != null) {
      query.where((tbl) => tbl.level.equals(level));
    }
    query.orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]);
    query.limit(limit);
    return query.watch();
  }

  Future<List<AppLog>> getRecentLogs({String? module, int limit = 20}) {
    final query = db.select(db.appLogs);
    if (module != null) {
      query.where((tbl) => tbl.module.equals(module));
    }
    query.orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]);
    query.limit(limit);
    return query.get();
  }
}
