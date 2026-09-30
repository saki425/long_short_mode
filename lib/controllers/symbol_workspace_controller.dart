import 'package:drift/drift.dart';
import 'package:get/get.dart' hide Value;
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../services/execution/futures_history_sync_scheduler.dart';
import '../services/market_data/market_data_coordinator.dart';

class SymbolCandidate {
  const SymbolCandidate({
    required this.symbol,
    required this.displayName,
    required this.baseAsset,
    required this.quoteAsset,
    required this.spotEnabled,
    required this.futuresEnabled,
  });

  final String symbol;
  final String displayName;
  final String baseAsset;
  final String quoteAsset;
  final bool spotEnabled;
  final bool futuresEnabled;
}

class SymbolWorkspaceController extends GetxController {
  SymbolWorkspaceController({
    required this.db,
    required this.marketData,
    FuturesHistorySyncScheduler? futuresHistorySyncScheduler,
  }) : _futuresHistorySyncScheduler = futuresHistorySyncScheduler;

  final AppDatabase db;
  final MarketDataCoordinator marketData;
  final FuturesHistorySyncScheduler? _futuresHistorySyncScheduler;
  final Uuid _uuid = const Uuid();

  final workspaces = <SymbolWorkspace>[].obs;
  final activeSymbol = Rxn<SymbolWorkspace>();
  final loading = false.obs;

  static const commonSymbols = <SymbolCandidate>[
    SymbolCandidate(
      symbol: 'BTCUSDT',
      displayName: 'BTC/USDT',
      baseAsset: 'BTC',
      quoteAsset: 'USDT',
      spotEnabled: true,
      futuresEnabled: true,
    ),
    SymbolCandidate(
      symbol: 'ETHUSDT',
      displayName: 'ETH/USDT',
      baseAsset: 'ETH',
      quoteAsset: 'USDT',
      spotEnabled: true,
      futuresEnabled: true,
    ),
    SymbolCandidate(
      symbol: 'BNBUSDT',
      displayName: 'BNB/USDT',
      baseAsset: 'BNB',
      quoteAsset: 'USDT',
      spotEnabled: true,
      futuresEnabled: true,
    ),
    SymbolCandidate(
      symbol: 'SOLUSDT',
      displayName: 'SOL/USDT',
      baseAsset: 'SOL',
      quoteAsset: 'USDT',
      spotEnabled: true,
      futuresEnabled: true,
    ),
    SymbolCandidate(
      symbol: 'XRPUSDT',
      displayName: 'XRP/USDT',
      baseAsset: 'XRP',
      quoteAsset: 'USDT',
      spotEnabled: true,
      futuresEnabled: true,
    ),
    SymbolCandidate(
      symbol: 'DOGEUSDT',
      displayName: 'DOGE/USDT',
      baseAsset: 'DOGE',
      quoteAsset: 'USDT',
      spotEnabled: true,
      futuresEnabled: true,
    ),
    SymbolCandidate(
      symbol: 'ADAUSDT',
      displayName: 'ADA/USDT',
      baseAsset: 'ADA',
      quoteAsset: 'USDT',
      spotEnabled: true,
      futuresEnabled: true,
    ),
  ];

  Future<void> load() async {
    loading.value = true;
    try {
      final rows = await _queryVisible();
      workspaces.assignAll(rows);
      final selected = _selectInitial(rows);
      activeSymbol.value = selected;
      await marketData.setWorkspaceSymbols(
        rows.map((row) => row.symbol),
        activeSymbol: selected?.symbol,
      );
      _futuresHistorySyncScheduler?.setSymbols(rows.map((row) => row.symbol));
      if (selected != null) {
        await selectSymbol(selected.symbol, persistOnly: true);
      }
    } finally {
      loading.value = false;
    }
  }

  Future<void> addSymbol(SymbolCandidate candidate) async {
    final now = DateTime.now().toUtc();
    final existing =
        await (db.select(db.symbolWorkspaces)..where(
          (tbl) => tbl.symbol.equals(candidate.symbol),
        )).getSingleOrNull();
    if (existing == null) {
      final nextSort =
          workspaces.isEmpty
              ? 0
              : workspaces
                      .map((row) => row.sortOrder)
                      .reduce((a, b) => a > b ? a : b) +
                  1;
      await db
          .into(db.symbolWorkspaces)
          .insert(
            SymbolWorkspacesCompanion.insert(
              id: _uuid.v4(),
              symbol: candidate.symbol,
              displayName: candidate.displayName,
              baseAsset: candidate.baseAsset,
              quoteAsset: candidate.quoteAsset,
              spotEnabled: Value(candidate.spotEnabled),
              futuresEnabled: Value(candidate.futuresEnabled),
              isSubscribed: const Value(true),
              sortOrder: Value(nextSort),
              createdAt: now,
              lastSelectedAt: Value(now),
            ),
          );
    } else {
      await (db.update(db.symbolWorkspaces)
        ..where((tbl) => tbl.id.equals(existing.id))).write(
        SymbolWorkspacesCompanion(
          isHidden: const Value(false),
          isSubscribed: const Value(true),
          lastSelectedAt: Value(now),
        ),
      );
    }
    await _reloadAndSelect(candidate.symbol);
  }

  Future<void> selectSymbol(String symbol, {bool persistOnly = false}) async {
    final workspace = workspaces.firstWhereOrNull(
      (row) => row.symbol == symbol,
    );
    if (workspace == null) {
      return;
    }
    final now = DateTime.now().toUtc();
    await (db.update(db.symbolWorkspaces)..where(
      (tbl) => tbl.id.equals(workspace.id),
    )).write(SymbolWorkspacesCompanion(lastSelectedAt: Value(now)));
    final updated = workspace.copyWith(lastSelectedAt: Value(now));
    final index = workspaces.indexWhere((row) => row.id == workspace.id);
    if (index >= 0) {
      workspaces[index] = updated;
    }
    activeSymbol.value = updated;
    marketData.setActiveSymbol(symbol);
    if (!persistOnly) {
      workspaces.refresh();
    }
  }

  Future<void> hideSymbol(String symbol) async {
    final workspace = workspaces.firstWhereOrNull(
      (row) => row.symbol == symbol,
    );
    if (workspace == null) {
      return;
    }
    await (db.update(db.symbolWorkspaces)..where(
      (tbl) => tbl.id.equals(workspace.id),
    )).write(const SymbolWorkspacesCompanion(isHidden: Value(true)));
    final rows = await _queryVisible();
    workspaces.assignAll(rows);
    final nextActive =
        activeSymbol.value?.symbol == symbol
            ? _selectInitial(rows)
            : activeSymbol.value;
    activeSymbol.value = nextActive;
    await marketData.setWorkspaceSymbols(
      rows.map((row) => row.symbol),
      activeSymbol: nextActive?.symbol,
    );
    _futuresHistorySyncScheduler?.setSymbols(rows.map((row) => row.symbol));
  }

  bool isAdded(String symbol) {
    return workspaces.any((row) => row.symbol == symbol);
  }

  Future<void> _reloadAndSelect(String symbol) async {
    final rows = await _queryVisible();
    workspaces.assignAll(rows);
    await marketData.setWorkspaceSymbols(
      rows.map((row) => row.symbol),
      activeSymbol: symbol,
    );
    _futuresHistorySyncScheduler?.setSymbols(rows.map((row) => row.symbol));
    await selectSymbol(symbol);
  }

  @override
  void onClose() {
    _futuresHistorySyncScheduler?.stop();
    super.onClose();
  }

  Future<List<SymbolWorkspace>> _queryVisible() {
    return (db.select(db.symbolWorkspaces)
          ..where((tbl) => tbl.isHidden.equals(false))
          ..orderBy([
            (tbl) => OrderingTerm.asc(tbl.sortOrder),
            (tbl) => OrderingTerm.asc(tbl.symbol),
          ]))
        .get();
  }

  SymbolWorkspace? _selectInitial(List<SymbolWorkspace> rows) {
    if (rows.isEmpty) {
      return null;
    }
    final sorted = [...rows]..sort((a, b) {
      final aSelected = a.lastSelectedAt;
      final bSelected = b.lastSelectedAt;
      if (aSelected != null && bSelected != null) {
        return bSelected.compareTo(aSelected);
      }
      if (aSelected != null) {
        return -1;
      }
      if (bSelected != null) {
        return 1;
      }
      return a.sortOrder.compareTo(b.sortOrder);
    });
    return sorted.first;
  }
}
