import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:get/get.dart';

import '../../controllers/symbol_workspace_controller.dart';
import '../../database/app_database.dart';
import '../../services/accounts/account_asset_display_service.dart';
import '../../services/app_ui_settings.dart';
import '../../services/reconciliation/account_reconciliation_service.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  late final AppDatabase _db;
  late final AccountReconciliationService _reconciliation;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _db = Get.find<AppDatabase>();
    _reconciliation = Get.find<AccountReconciliationService>();
  }

  Future<void> _runReconciliation() async {
    final result = await _reconciliation.runReadOnlyReconciliation();
    if (mounted) {
      setState(() => _message = '只读对账完成，差异 ${result.differences.length} 条。');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final symbol =
          Get.find<SymbolWorkspaceController>().activeSymbol.value?.symbol;
      return StreamBuilder<bool>(
        stream: AppUiSettings.watchHideSpotUiForSymbol(_db, symbol: symbol),
        initialData: false,
        builder: (context, snapshot) {
          final hideSpot = snapshot.data ?? false;
          return FutureBuilder<_AccountSymbolScope>(
            future: _loadScope(symbol),
            builder: (context, scopeSnapshot) {
              final scope = scopeSnapshot.data;
              if (scope == null) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }
              return DefaultTabController(
                key: ValueKey(
                  'account-${scope.symbol}-$hideSpot-${scope.spotKeyProfileId}-${scope.futuresKeyProfileId}',
                ),
                length: hideSpot ? 4 : 5,
                child: Scaffold(
                  appBar: AppBar(
                    title: Text('账户状态 / ${scope.displaySymbol}'),
                    actions: [
                      TextButton.icon(
                        onPressed: _runReconciliation,
                        icon: const Icon(Icons.sync, color: Colors.white),
                        label: const Text(
                          '只读对账',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                    bottom: TabBar(
                      tabs: [
                        if (!hideSpot) const Tab(text: '现货账户'),
                        const Tab(text: '合约账户'),
                        const Tab(text: '对账差异'),
                        const Tab(text: '外部操作'),
                        const Tab(text: '同步日志'),
                      ],
                    ),
                  ),
                  body: Column(
                    children: [
                      if (_message.isNotEmpty)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          color: Colors.blueGrey.shade50,
                          child: Text(_message),
                        ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            if (!hideSpot)
                              _SpotAccountTab(db: _db, scope: scope),
                            _FuturesAccountTab(db: _db, scope: scope),
                            _DifferencesTab(db: _db),
                            _ExternalEventsTab(db: _db),
                            _SyncRunsTab(db: _db),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    });
  }

  Future<_AccountSymbolScope> _loadScope(String? symbol) async {
    final normalized = symbol?.toUpperCase();
    if (normalized == null || normalized.isEmpty) {
      return const _AccountSymbolScope(
        symbol: '',
        spotKeyProfileId: null,
        futuresKeyProfileId: null,
      );
    }
    final binding =
        await (_db.select(_db.symbolAccountBindings)..where(
          (tbl) =>
              tbl.symbol.equals(normalized) & tbl.environment.equals('live'),
        )).getSingleOrNull();
    return _AccountSymbolScope(
      symbol: normalized,
      spotKeyProfileId: _cleanProfileId(binding?.spotKeyProfileId),
      futuresKeyProfileId: _cleanProfileId(binding?.futuresKeyProfileId),
    );
  }

  String? _cleanProfileId(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }
}

class _AccountSymbolScope {
  const _AccountSymbolScope({
    required this.symbol,
    required this.spotKeyProfileId,
    required this.futuresKeyProfileId,
  });

  final String symbol;
  final String? spotKeyProfileId;
  final String? futuresKeyProfileId;

  String get displaySymbol {
    if (symbol.endsWith('USDT') && symbol.length > 4) {
      return '${symbol.substring(0, symbol.length - 4)}/USDT';
    }
    return symbol.isEmpty ? '未选择' : symbol;
  }

  bool get hasSpotBinding => spotKeyProfileId != null;
  bool get hasFuturesBinding => futuresKeyProfileId != null;
}

class _UnboundAccountNotice extends StatelessWidget {
  const _UnboundAccountNotice({
    required this.scope,
    required this.accountLabel,
  });

  final _AccountSymbolScope scope;
  final String accountLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        '${scope.displaySymbol} 尚未绑定 $accountLabel API Key。\n'
        '请在 Settings 页面为当前币种保存并验证对应账户。',
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _SpotAccountTab extends StatefulWidget {
  const _SpotAccountTab({required this.db, required this.scope});

  final AppDatabase db;
  final _AccountSymbolScope scope;

  @override
  State<_SpotAccountTab> createState() => _SpotAccountTabState();
}

class _SpotAccountTabState extends State<_SpotAccountTab> {
  static const _hideZeroAssetsKey = 'hideZeroAssets';
  final _displayService = const AccountAssetDisplayService();
  bool _hideZeroAssets = true;
  bool _loadedSetting = false;

  AppDatabase get db => widget.db;

  @override
  void initState() {
    super.initState();
    _loadSetting();
  }

  Future<void> _loadSetting() async {
    final row =
        await (db.select(db.appSettings)..where(
          (tbl) => tbl.key.equals(_hideZeroAssetsKey),
        )).getSingleOrNull();
    if (!mounted) return;
    setState(() {
      _hideZeroAssets = row?.value == null ? true : row!.value == 'true';
      _loadedSetting = true;
    });
  }

  Future<void> _setHideZeroAssets(bool value) async {
    setState(() => _hideZeroAssets = value);
    await db
        .into(db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: _hideZeroAssetsKey,
            value: value.toString(),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loadedSetting) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!widget.scope.hasSpotBinding) {
      return _UnboundAccountNotice(scope: widget.scope, accountLabel: 'Spot');
    }
    final keyProfileId = widget.scope.spotKeyProfileId!;
    return StreamBuilder<List<AccountAsset>>(
      stream:
          (db.select(db.accountAssets)..where(
            (tbl) =>
                tbl.accountType.equals('spotSubAccount') &
                tbl.keyProfileId.equals(keyProfileId),
          )).watch(),
      builder: (context, snapshot) {
        return StreamBuilder<SpotAccountSnapshot?>(
          stream:
              (db.select(db.spotAccountSnapshots)
                    ..where((tbl) => tbl.keyProfileId.equals(keyProfileId))
                    ..orderBy([(tbl) => OrderingTerm.desc(tbl.recordedAt)])
                    ..limit(1))
                  .watchSingleOrNull(),
          builder: (context, spotSnapshot) {
            final result = _displayService.filterAndSort(
              assets: snapshot.data ?? const [],
              hideZeroAssets: _hideZeroAssets,
              latestSpotSnapshot: spotSnapshot.data,
            );
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('隐藏零资产'),
                        Switch(
                          value: _hideZeroAssets,
                          onChanged: _setHideZeroAssets,
                        ),
                      ],
                    ),
                    _AssetStat('全部资产数量', result.totalCount),
                    _AssetStat('有余额资产数量', result.nonZeroCount),
                    _AssetStat('已隐藏零资产数量', result.hiddenZeroCount),
                  ],
                ),
                const SizedBox(height: 12),
                _TableShell(
                  emptyText: '尚未写入现货账户快照。保存只读 API Key 后执行验证/对账。',
                  isEmpty: result.assets.isEmpty,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('资产')),
                      DataColumn(label: Text('可用')),
                      DataColumn(label: Text('冻结')),
                      DataColumn(label: Text('总量')),
                      DataColumn(label: Text('更新时间')),
                    ],
                    rows:
                        result.assets
                            .map(
                              (asset) => DataRow(
                                color:
                                    _isZeroAsset(asset)
                                        ? WidgetStatePropertyAll(
                                          Colors.grey.shade50,
                                        )
                                        : null,
                                cells: [
                                  DataCell(Text(asset.asset)),
                                  DataCell(Text(asset.free)),
                                  DataCell(Text(asset.locked)),
                                  DataCell(Text(asset.total)),
                                  DataCell(
                                    Text(asset.updatedAt.toLocal().toString()),
                                  ),
                                ],
                              ),
                            )
                            .toList(),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  bool _isZeroAsset(AccountAsset asset) {
    return (Decimal.tryParse(asset.free) ?? Decimal.zero) == Decimal.zero &&
        (Decimal.tryParse(asset.locked) ?? Decimal.zero) == Decimal.zero;
  }
}

class _AssetStat extends StatelessWidget {
  const _AssetStat(this.label, this.value);

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Chip(label: Text('$label：$value'));
  }
}

class _FuturesAccountTab extends StatelessWidget {
  const _FuturesAccountTab({required this.db, required this.scope});

  final AppDatabase db;
  final _AccountSymbolScope scope;

  @override
  Widget build(BuildContext context) {
    if (!scope.hasFuturesBinding) {
      return _UnboundAccountNotice(scope: scope, accountLabel: 'Futures');
    }
    final keyProfileId = scope.futuresKeyProfileId!;
    return StreamBuilder<FuturesAccountSnapshot?>(
      stream:
          (db.select(db.futuresAccountSnapshots)
                ..where((tbl) => tbl.keyProfileId.equals(keyProfileId))
                ..orderBy([(tbl) => OrderingTerm.desc(tbl.recordedAt)])
                ..limit(1))
              .watchSingleOrNull(),
      builder: (context, accountSnapshot) {
        final account = accountSnapshot.data;
        return StreamBuilder<List<FuturesPosition>>(
          stream:
              (db.select(db.futuresPositions)..where(
                (tbl) =>
                    tbl.keyProfileId.equals(keyProfileId) &
                    tbl.symbol.equals(scope.symbol),
              )).watch(),
          builder: (context, positionSnapshot) {
            final positions = positionSnapshot.data ?? const [];
            if (account == null && positions.isEmpty) {
              return const Center(child: Text('尚未写入合约账户快照。'));
            }
            final openPositions = positions
                .where(_isNonZeroPosition)
                .toList(growable: false);
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('合约资产', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _FuturesAssetStat('钱包余额', account?.walletBalance ?? '-'),
                    _FuturesAssetStat('可用余额', account?.availableBalance ?? '-'),
                    _FuturesAssetStat(
                      '未实现盈亏',
                      account?.totalUnrealizedPnl ?? '-',
                    ),
                    _FuturesAssetStat('空单数量', account?.shortQuantity ?? '-'),
                    _FuturesAssetStat('多单数量', account?.longQuantity ?? '-'),
                    _FuturesAssetStat('持仓数量', openPositions.length.toString()),
                    _FuturesAssetStat('仓位模式', account?.positionMode ?? '-'),
                    _FuturesAssetStat(
                      '更新时间',
                      account?.recordedAt.toLocal().toString() ?? '-',
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text('持仓明细', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (positions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(child: Text('暂无合约持仓。')),
                  )
                else
                  _HorizontalScrollArea(
                    child: DataTable(
                      columns: const [
                        DataColumn(label: Text('交易对')),
                        DataColumn(label: Text('方向')),
                        DataColumn(label: Text('数量')),
                        DataColumn(label: Text('开仓均价')),
                        DataColumn(label: Text('标记价')),
                        DataColumn(label: Text('未实现盈亏')),
                        DataColumn(label: Text('杠杆')),
                        DataColumn(label: Text('保证金')),
                      ],
                      rows:
                          positions
                              .map(
                                (position) => DataRow(
                                  cells: [
                                    DataCell(Text(position.symbol)),
                                    DataCell(Text(position.positionSide)),
                                    DataCell(Text(position.positionAmount)),
                                    DataCell(Text(position.entryPrice)),
                                    DataCell(Text(position.markPrice ?? '-')),
                                    DataCell(Text(position.unrealizedPnl)),
                                    DataCell(Text(position.leverage ?? '-')),
                                    DataCell(Text(position.marginType ?? '-')),
                                  ],
                                ),
                              )
                              .toList(),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  bool _isNonZeroPosition(FuturesPosition position) {
    return (Decimal.tryParse(position.positionAmount) ?? Decimal.zero) !=
        Decimal.zero;
  }
}

class _FuturesAssetStat extends StatelessWidget {
  const _FuturesAssetStat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Chip(label: Text('$label：$value'));
  }
}

class _DifferencesTab extends StatelessWidget {
  const _DifferencesTab({required this.db});

  final AppDatabase db;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ReconciliationDifference>>(
      stream:
          (db.select(db.reconciliationDifferences)
            ..orderBy([(tbl) => OrderingTerm.desc(tbl.lastSeenAt)])).watch(),
      builder: (context, snapshot) {
        final items = snapshot.data ?? const [];
        return _TableShell(
          emptyText: '暂无对账差异。',
          isEmpty: items.isEmpty,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('级别')),
              DataColumn(label: Text('账户')),
              DataColumn(label: Text('类型')),
              DataColumn(label: Text('本地值')),
              DataColumn(label: Text('交易所值')),
              DataColumn(label: Text('建议')),
              DataColumn(label: Text('最后发现')),
            ],
            rows:
                items
                    .map(
                      (item) => DataRow(
                        cells: [
                          DataCell(Text(item.severity)),
                          DataCell(Text(item.accountType)),
                          DataCell(Text(item.differenceType)),
                          DataCell(Text(item.localValue ?? '-')),
                          DataCell(Text(item.exchangeValue ?? '-')),
                          DataCell(Text(item.suggestion ?? '-')),
                          DataCell(Text(item.lastSeenAt.toLocal().toString())),
                        ],
                      ),
                    )
                    .toList(),
          ),
        );
      },
    );
  }
}

class _ExternalEventsTab extends StatelessWidget {
  const _ExternalEventsTab({required this.db});

  final AppDatabase db;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ExternalAccountEvent>>(
      stream:
          (db.select(db.externalAccountEvents)
            ..orderBy([(tbl) => OrderingTerm.desc(tbl.detectedAt)])).watch(),
      builder: (context, snapshot) {
        final items = snapshot.data ?? const [];
        return _TableShell(
          emptyText: '暂无外部账户操作事件。',
          isEmpty: items.isEmpty,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('级别')),
              DataColumn(label: Text('账户')),
              DataColumn(label: Text('事件')),
              DataColumn(label: Text('说明')),
              DataColumn(label: Text('发现时间')),
            ],
            rows:
                items
                    .map(
                      (item) => DataRow(
                        cells: [
                          DataCell(Text(item.severity)),
                          DataCell(Text(item.accountType)),
                          DataCell(Text(item.eventType)),
                          DataCell(Text(item.message)),
                          DataCell(Text(item.detectedAt.toLocal().toString())),
                        ],
                      ),
                    )
                    .toList(),
          ),
        );
      },
    );
  }
}

class _SyncRunsTab extends StatelessWidget {
  const _SyncRunsTab({required this.db});

  final AppDatabase db;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ReconciliationRun>>(
      stream:
          (db.select(db.reconciliationRuns)
            ..orderBy([(tbl) => OrderingTerm.desc(tbl.startedAt)])).watch(),
      builder: (context, snapshot) {
        final items = snapshot.data ?? const [];
        return _TableShell(
          emptyText: '暂无同步/对账日志。',
          isEmpty: items.isEmpty,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('状态')),
              DataColumn(label: Text('开始')),
              DataColumn(label: Text('完成')),
              DataColumn(label: Text('摘要')),
              DataColumn(label: Text('错误')),
            ],
            rows:
                items
                    .map(
                      (item) => DataRow(
                        cells: [
                          DataCell(Text(item.status)),
                          DataCell(Text(item.startedAt.toLocal().toString())),
                          DataCell(
                            Text(item.completedAt?.toLocal().toString() ?? '-'),
                          ),
                          DataCell(Text(item.summaryJson ?? '-')),
                          DataCell(Text(item.errorMessage ?? '-')),
                        ],
                      ),
                    )
                    .toList(),
          ),
        );
      },
    );
  }
}

class _TableShell extends StatelessWidget {
  const _TableShell({
    required this.emptyText,
    required this.isEmpty,
    required this.child,
  });

  final String emptyText;
  final bool isEmpty;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (isEmpty) {
      return Center(child: Text(emptyText));
    }
    return _HorizontalScrollArea(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}

class _HorizontalScrollArea extends StatefulWidget {
  const _HorizontalScrollArea({required this.child});

  final Widget child;

  @override
  State<_HorizontalScrollArea> createState() => _HorizontalScrollAreaState();
}

class _HorizontalScrollAreaState extends State<_HorizontalScrollArea> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      notificationPredicate: (notification) => notification.depth == 0,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        child: widget.child,
      ),
    );
  }
}
