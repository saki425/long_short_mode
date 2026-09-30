import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/app_navigation_controller.dart';
import '../controllers/order_center_controller.dart';
import '../controllers/symbol_workspace_controller.dart';
import '../database/app_database.dart';
import '../database/mock/mock_order_seed.dart';
import '../pages/dashboard_page.dart';
import '../pages/accounts/account_page.dart';
import '../pages/filled_orders_page.dart';
import '../pages/grid_page.dart';
import '../pages/grid_future_page.dart';
import '../pages/long_future_page.dart';
import '../pages/logs_page.dart';
import '../pages/orders/order_center_page.dart';
import '../pages/live_trading_test_page.dart';
import '../pages/pnl_page.dart';
import '../pages/risk_page.dart';
import '../pages/settings_page.dart';
import '../pages/short_future_recover_page.dart';
import '../pages/strategy_page.dart';
import '../pages/validation_stats_page.dart';
import '../pages/market_data/futures_ws_connection_dialog.dart';
import '../repositories/order_repository.dart';
import '../repositories/live_validation_repository.dart';
import '../repositories/basic_repositories.dart';
import '../services/export/csv_export_service.dart';
import '../services/security/secure_key_storage.dart';
import '../services/security/api_key_profile_service.dart';
import '../services/binance/auth/binance_client_provider.dart';
import '../services/binance/user_data/key_profile_user_data_stream_manager.dart';
import '../services/market_data/market_data_coordinator.dart';
import '../services/market_data/market_data_status.dart';
import '../services/market_data/market_tick.dart';
import '../services/execution/live_exchange_execution_service.dart';
import '../services/execution/live_trading_gate_service.dart';
import '../services/execution/auto_spot_grid_execution_service.dart';
import '../services/execution/futures_history_sync_scheduler.dart';
import '../services/execution/future_grid_engine.dart';
import '../services/execution/recovery_short_engine.dart';
import '../services/app_ui_settings.dart';
import '../services/hedge/live_hedge_service.dart';
import '../services/pnl/completed_grid_cycle_service.dart';
import '../services/pnl/strategy_performance_service.dart';
import '../services/reconciliation/account_reconciliation_service.dart';
import '../strategy/paper/paper_trading_service.dart';
import '../controllers/live_trading_test_controller.dart';

class GridHedgeApp extends StatelessWidget {
  const GridHedgeApp._({required this.db});

  final AppDatabase db;

  static Future<GridHedgeApp> bootstrap() async {
    final db = AppDatabase.local();
    final orderRepository = OrderRepository(db);
    final liveValidationRepository = LiveValidationRepository(db);
    final logRepository = LogRepository(db);
    final marketDataCoordinator = MarketDataCoordinator(
      db: db,
      logRepository: logRepository,
    );
    final reconciliationService = AccountReconciliationService(db);
    final paperTradingService = PaperTradingService(db)
      ..attachMarketDataService(marketDataCoordinator);
    final credentialsCache = CredentialsSessionCache();
    final credentialsVault = CredentialsVault(
      cache: credentialsCache,
      logRepository: logRepository,
      bundleIdentifier: 'com.gridhedge.gridHedgeTrader',
    );
    final secureKeyStorage = SecureKeyStorage(vault: credentialsVault);
    final apiKeyProfileService = ApiKeyProfileService(
      db: db,
      logRepository: logRepository,
    );
    final binanceClientProvider = BinanceClientProvider(
      db: db,
      profileService: apiKeyProfileService,
    );
    final keyProfileUserDataStreamManager = KeyProfileUserDataStreamManager();
    final defaultBinding = await apiKeyProfileService.getBinding(
      symbol: 'BTCUSDT',
      environment: 'live',
    );
    final needsLegacyCredentials = defaultBinding == null ||
        (defaultBinding.spotKeyProfileId ?? '').trim().isEmpty ||
        (defaultBinding.futuresKeyProfileId ?? '').trim().isEmpty;
    final legacyCredentials = needsLegacyCredentials
        ? await credentialsVault.readOnce().catchError((_) => null)
        : null;
    await apiKeyProfileService.ensureLegacyDefaultBinding(
      symbol: 'BTCUSDT',
      environment: 'live',
      credentials: legacyCredentials,
    );
    final liveTradingGateService = LiveTradingGateService()..resetForAppStart();
    final liveExecutionService = LiveExchangeExecutionService(
      db: db,
      orderRepository: orderRepository,
      logRepository: logRepository,
      credentialsVault: credentialsVault,
      clientProvider: binanceClientProvider,
      marketDataCoordinator: marketDataCoordinator,
      liveTradingGateService: liveTradingGateService,
    );
    final futureGridEngine = FutureGridEngine(
      db: db,
      liveExecution: liveExecutionService,
    );
    final autoSpotGridExecutionService = AutoSpotGridExecutionService(
      db: db,
      liveExecution: liveExecutionService,
      liveTradingGate: liveTradingGateService,
      marketData: marketDataCoordinator,
      logRepository: logRepository,
      futureGridEngine: futureGridEngine,
    );
    final recoveryShortEngine = RecoveryShortEngine(
      db: db,
      liveExecution: liveExecutionService,
      gridExecution: autoSpotGridExecutionService,
      marketData: marketDataCoordinator,
    )..start();
    final liveHedgeService = LiveHedgeService(
      db: db,
      liveExecution: liveExecutionService,
      marketData: marketDataCoordinator,
      logRepository: logRepository,
    );
    final futuresHistorySyncScheduler = FuturesHistorySyncScheduler(
      liveExecution: liveExecutionService,
      db: db,
      marketData: marketDataCoordinator,
      gridExecution: autoSpotGridExecutionService,
    );
    final completedGridCycleService = CompletedGridCycleService(db);
    final strategyPerformanceService = StrategyPerformanceService(
      db,
      marketDataCoordinator,
    );
    final symbolWorkspaceController = SymbolWorkspaceController(
      db: db,
      marketData: marketDataCoordinator,
      futuresHistorySyncScheduler: futuresHistorySyncScheduler,
    );
    Get.put<AppDatabase>(db, permanent: true);
    Get.put<OrderRepository>(orderRepository, permanent: true);
    Get.put<LiveValidationRepository>(
      liveValidationRepository,
      permanent: true,
    );
    Get.put<LogRepository>(logRepository, permanent: true);
    Get.put<MarketDataCoordinator>(marketDataCoordinator, permanent: true);
    Get.put<AccountReconciliationService>(
      reconciliationService,
      permanent: true,
    );
    Get.put<PaperTradingService>(paperTradingService, permanent: true);
    Get.put<CsvExportService>(CsvExportService(), permanent: true);
    Get.put<CredentialsSessionCache>(credentialsCache, permanent: true);
    Get.put<CredentialsVault>(credentialsVault, permanent: true);
    Get.put<SecureKeyStorage>(secureKeyStorage, permanent: true);
    Get.put<ApiKeyProfileService>(apiKeyProfileService, permanent: true);
    Get.put<BinanceClientProvider>(binanceClientProvider, permanent: true);
    Get.put<KeyProfileUserDataStreamManager>(
      keyProfileUserDataStreamManager,
      permanent: true,
    );
    Get.put<LiveTradingGateService>(liveTradingGateService, permanent: true);
    Get.put<LiveExchangeExecutionService>(
      liveExecutionService,
      permanent: true,
    );
    Get.put<FutureGridEngine>(futureGridEngine, permanent: true);
    Get.put<AutoSpotGridExecutionService>(
      autoSpotGridExecutionService,
      permanent: true,
    );
    Get.put<RecoveryShortEngine>(recoveryShortEngine, permanent: true);
    Get.put<LiveHedgeService>(liveHedgeService, permanent: true);
    Get.put<FuturesHistorySyncScheduler>(
      futuresHistorySyncScheduler,
      permanent: true,
    );
    Get.put<CompletedGridCycleService>(
      completedGridCycleService,
      permanent: true,
    );
    Get.put<StrategyPerformanceService>(
      strategyPerformanceService,
      permanent: true,
    );
    Get.put<SymbolWorkspaceController>(
      symbolWorkspaceController,
      permanent: true,
    );
    Get.put<AppNavigationController>(
      AppNavigationController(),
      permanent: true,
    );
    Get.put<OrderCenterController>(
      OrderCenterController(
        orderRepository: orderRepository,
        csvExportService: Get.find<CsvExportService>(),
        liveExecutionService: liveExecutionService,
        autoSpotGridService: autoSpotGridExecutionService,
        logRepository: logRepository,
      ),
      permanent: true,
    );
    Get.put<LiveTradingTestController>(
      LiveTradingTestController(
        executionService: liveExecutionService,
        orderRepository: orderRepository,
        secureKeyStorage: secureKeyStorage,
        csvExportService: Get.find<CsvExportService>(),
        marketDataCoordinator: marketDataCoordinator,
        liveTradingGateService: liveTradingGateService,
      ),
      permanent: true,
    );
    await symbolWorkspaceController.load();
    unawaited(marketDataCoordinator.setMode(MarketDataMode.binanceLive));
    await MockOrderSeed(db).seedIfEmpty();
    return GridHedgeApp._(db: db);
  }

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Grid Hedge Trader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: false,
        primarySwatch: Colors.indigo,
        visualDensity: VisualDensity.compact,
      ),
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => AppShellState();
}

class _NavigationEntry {
  const _NavigationEntry({
    required this.page,
    required this.icon,
    required this.label,
    this.hideWhenSpotHidden = false,
    this.allowWithoutSymbol = false,
  });

  final Widget page;
  final Widget icon;
  final Widget label;
  final bool hideWhenSpotHidden;
  final bool allowWithoutSymbol;
}

class AppShellState extends State<AppShell> with WidgetsBindingObserver {
  static const _navigationEntries = [
    _NavigationEntry(
      page: DashboardPage(),
      icon: Icon(Icons.dashboard),
      label: Text('Dashboard'),
    ),
    _NavigationEntry(
      page: StrategyPage(),
      icon: Icon(Icons.tune),
      label: Text('Strategy'),
    ),
    _NavigationEntry(
      page: GridPage(),
      icon: Icon(Icons.grid_on),
      label: Text('Grid'),
      hideWhenSpotHidden: true,
    ),
    _NavigationEntry(
      page: LongFuturePage(),
      icon: Icon(Icons.trending_up),
      label: Text('Long Future'),
    ),
    _NavigationEntry(
      page: GridFuturePage(),
      icon: Icon(Icons.grid_view),
      label: Text('Short Future'),
    ),
    _NavigationEntry(
      page: OrderCenterPage(),
      icon: Icon(Icons.receipt_long),
      label: Text('Orders'),
    ),
    _NavigationEntry(
      page: FilledOrdersPage(),
      icon: Icon(Icons.done_all),
      label: Text('成交记录'),
    ),
    _NavigationEntry(
      page: LiveTradingTestPage(),
      icon: Icon(Icons.science),
      label: Text('交易测试'),
    ),
    _NavigationEntry(
      page: PnlPage(),
      icon: Icon(Icons.show_chart),
      label: Text('PnL'),
    ),
    _NavigationEntry(
      page: ValidationStatsPage(),
      icon: Icon(Icons.fact_check),
      label: Text('验证统计'),
    ),
    _NavigationEntry(
      page: AccountPage(),
      icon: Icon(Icons.account_balance_wallet),
      label: Text('账户'),
    ),
    _NavigationEntry(
      page: RiskPage(),
      icon: Icon(Icons.warning),
      label: Text('Risk'),
    ),
    _NavigationEntry(
      page: LogsPage(),
      icon: Icon(Icons.article),
      label: Text('Logs'),
    ),
    _NavigationEntry(
      page: ShortFutureRecoverPage(),
      icon: Icon(Icons.health_and_safety),
      label: Text('Short Recover'),
    ),
    _NavigationEntry(
      page: SettingsPage(),
      icon: Icon(Icons.settings),
      label: Text('Settings'),
      allowWithoutSymbol: true,
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void selectPage(int index) {
    if (index < 0 || index >= _navigationEntries.length) {
      return;
    }
    Get.find<AppNavigationController>().selectPage(index);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final market = Get.find<MarketDataCoordinator>();
      if (market.status.mode == MarketDataMode.binanceLive) {
        market.onAppResumed();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final navigation = Get.find<AppNavigationController>();
    final db = Get.find<AppDatabase>();
    return Scaffold(
      body: Column(
        children: [
          const _SymbolTabsBar(),
          const _TopStatusBar(),
          Expanded(
            child: Obx(() {
              final activeSymbol = Get.find<SymbolWorkspaceController>()
                  .activeSymbol
                  .value
                  ?.symbol;
              return StreamBuilder<bool>(
                stream: AppUiSettings.watchHideSpotUiForSymbol(
                  db,
                  symbol: activeSymbol,
                ),
                initialData: false,
                builder: (context, snapshot) {
                  final hideSpot = snapshot.data ?? false;
                  final entries = _navigationEntries
                      .where((entry) => !hideSpot || !entry.hideWhenSpotHidden)
                      .toList(growable: false);
                  return Row(
                    children: [
                      Obx(() {
                        final selectedIndex = navigation.selectedIndex.value;
                        final effectiveIndex = selectedIndex.clamp(
                          0,
                          entries.length - 1,
                        );
                        if (selectedIndex != effectiveIndex) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            navigation.selectPage(effectiveIndex);
                          });
                        }
                        return SizedBox(
                          width: 206,
                          child: ListView.builder(
                            itemCount: entries.length,
                            itemBuilder: (context, index) {
                              final selected = index == effectiveIndex;
                              return ListTile(
                                dense: true,
                                selected: selected,
                                leading: entries[index].icon,
                                title: entries[index].label,
                                onTap: () => navigation.selectPage(index),
                              );
                            },
                          ),
                        );
                      }),
                      const VerticalDivider(width: 1),
                      Obx(() {
                        final index = navigation.selectedIndex.value
                            .clamp(0, entries.length - 1)
                            .toInt();
                        final entry = entries[index];
                        final workspace = Get.find<SymbolWorkspaceController>();
                        if (workspace.activeSymbol.value == null &&
                            !entry.allowWithoutSymbol) {
                          return const Expanded(
                            child: _NoSymbolWorkspaceState(),
                          );
                        }
                        return Expanded(child: entry.page);
                      }),
                    ],
                  );
                },
              );
            }),
          ),
          const _BottomStatusBar(),
        ],
      ),
    );
  }
}

class _SymbolTabsBar extends StatelessWidget {
  const _SymbolTabsBar();

  @override
  Widget build(BuildContext context) {
    final workspace = Get.find<SymbolWorkspaceController>();
    final market = Get.find<MarketDataCoordinator>();
    return StreamBuilder<Map<String, MarketTick>>(
      stream: market.allMarketTicksStream,
      initialData: market.currentMarketTicks,
      builder: (context, tickSnapshot) {
        final ticks = tickSnapshot.data ?? const <String, MarketTick>{};
        return Obx(() {
          final rows = workspace.workspaces;
          final active = workspace.activeSymbol.value?.symbol;
          return Container(
            height: 42,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _showAddSymbolDialog(context),
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(rows.isEmpty ? '添加币对' : ''),
                  ),
                  const SizedBox(width: 8),
                  for (final row in rows) ...[
                    _SymbolTab(
                      workspace: row,
                      selected: row.symbol == active,
                      price: ticks[row.symbol]?.spot?.midPrice.toString(),
                      onTap: () => workspace.selectSymbol(row.symbol),
                      onClose: () => workspace.hideSymbol(row.symbol),
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          );
        });
      },
    );
  }

  Future<void> _showAddSymbolDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const _AddSymbolDialog(),
    );
  }
}

class _SymbolTab extends StatelessWidget {
  const _SymbolTab({
    required this.workspace,
    required this.selected,
    required this.onTap,
    required this.onClose,
    this.price,
  });

  final SymbolWorkspace workspace;
  final bool selected;
  final String? price;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.indigo : Colors.grey.shade700;
    return Material(
      color: selected ? Colors.indigo.withValues(alpha: 0.12) : Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.only(left: 12, right: 4),
          height: 32,
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? Colors.indigo : Colors.grey.shade300,
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                price == null
                    ? workspace.displayName
                    : '${workspace.displayName} $price',
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 4),
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onClose,
                child: Icon(Icons.close, size: 16, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddSymbolDialog extends StatefulWidget {
  const _AddSymbolDialog();

  @override
  State<_AddSymbolDialog> createState() => _AddSymbolDialogState();
}

class _AddSymbolDialogState extends State<_AddSymbolDialog> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final workspace = Get.find<SymbolWorkspaceController>();
    final query = _search.text.trim().toUpperCase();
    final candidates =
        SymbolWorkspaceController.commonSymbols.where((candidate) {
      if (query.isEmpty) {
        return true;
      }
      return candidate.symbol.contains(query) ||
          candidate.displayName.toUpperCase().contains(query);
    }).toList();
    return AlertDialog(
      title: const Text('添加交易币对'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _search,
              decoration: const InputDecoration(
                labelText: '搜索',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: candidates.length,
                itemBuilder: (context, index) {
                  final candidate = candidates[index];
                  final added = workspace.isAdded(candidate.symbol);
                  return ListTile(
                    title: Text(candidate.displayName),
                    subtitle: Text(
                      '${candidate.symbol}  base=${candidate.baseAsset} quote=${candidate.quoteAsset} '
                      'Spot=${candidate.spotEnabled ? '是' : '否'} Futures=${candidate.futuresEnabled ? '是' : '否'}',
                    ),
                    trailing: added
                        ? const Chip(label: Text('已添加'))
                        : FilledButton(
                            onPressed: () async {
                              await workspace.addSymbol(candidate);
                              if (context.mounted) {
                                Navigator.of(context).pop();
                              }
                            },
                            child: const Text('添加'),
                          ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _NoSymbolWorkspaceState extends StatelessWidget {
  const _NoSymbolWorkspaceState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('请先添加交易币对'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _AddSymbolDialog(),
                ),
                icon: const Icon(Icons.add),
                label: const Text('添加币对'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopStatusBar extends StatelessWidget {
  const _TopStatusBar();

  @override
  Widget build(BuildContext context) {
    final market = Get.find<MarketDataCoordinator>();
    final liveGate = Get.find<LiveTradingGateService>();
    final liveExecution = Get.find<LiveExchangeExecutionService>();
    final workspace = Get.find<SymbolWorkspaceController>();
    final db = Get.find<AppDatabase>();
    return StreamBuilder<MarketDataStatus>(
      stream: market.statusStream,
      initialData: market.status,
      builder: (context, statusSnapshot) {
        return StreamBuilder<LiveExecutionState>(
          stream: liveExecution.stateStream,
          builder: (context, executionSnapshot) {
            return StreamBuilder<MarketTick>(
              stream: market.uiMarketStream,
              initialData: market.currentMarketTick,
              builder: (context, tickSnapshot) {
                final status = statusSnapshot.data ?? market.status;
                final executionState = executionSnapshot.data;
                final restCooldown = _restCooldownText(executionState);
                final activeSymbol = workspace.activeSymbol.value;
                final tick = activeSymbol == null
                    ? tickSnapshot.data
                    : market.currentMarketTicks[activeSymbol.symbol];
                final spot = tick?.spot;
                final futures = tick?.futures;
                return Obx(
                  () => Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    color: liveGate.liveTradingEnabled.value
                        ? Colors.red.shade700
                        : status.overallStatus == MarketConnectionStatus.stale
                            ? Colors.red.shade700
                            : Colors.indigo.shade700,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          const Text(
                            '环境: PRODUCTION / LIVE',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 16),
                          _StatusPill(
                            label: '行情',
                            value: status.mode == MarketDataMode.binanceLive
                                ? 'BINANCE LIVE'
                                : status.mode.name,
                          ),
                          const _StatusPill(label: '交易', value: 'BINANCE LIVE'),
                          _StatusPill(
                            label: '真实资金',
                            value: liveGate.liveTradingEnabled.value
                                ? 'ENABLED'
                                : 'DISABLED',
                          ),
                          StreamBuilder<bool>(
                            stream: AppUiSettings.watchHideSpotUiForSymbol(
                              db,
                              symbol: activeSymbol?.symbol,
                            ),
                            initialData: false,
                            builder: (context, hideSpotSnapshot) {
                              final hideSpot = hideSpotSnapshot.data ?? false;
                              if (!hideSpot) {
                                return _StatusPill(
                                  label: '现货WS',
                                  value: _statusText(
                                    status.spotConnectionStatus,
                                  ),
                                );
                              }
                              return FutureBuilder<String>(
                                future: liveExecution
                                    .futuresUserDataStatusForSymbol(
                                  activeSymbol?.symbol,
                                ),
                                builder: (context, accountWsSnapshot) {
                                  return _StatusPill(
                                    label: '账户WS',
                                    value: _accountWsStatusText(
                                      accountWsSnapshot.data ??
                                          executionState?.futuresWsStatus ??
                                          'disconnected',
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                          _StatusPill(
                            label: '合约WS',
                            value: _statusText(status.futuresConnectionStatus),
                            onTap: () => showDialog<void>(
                              context: context,
                              builder: (_) => const FuturesWsConnectionDialog(),
                            ),
                          ),
                          _StatusPill(
                            label: 'REST',
                            value: restCooldown ?? '正常',
                            onTap: executionState?.restCooldownReason == null
                                ? null
                                : () => _showRestCooldownDialog(
                                      context,
                                      executionState!,
                                    ),
                          ),
                          const _StatusPill(label: '数据库', value: '本地SQLite'),
                          const SizedBox(width: 24),
                          Text(
                            '${activeSymbol?.displayName ?? '未选择币对'} Spot: ${spot?.midPrice.toString() ?? '-'}',
                            style: const TextStyle(color: Colors.white),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Future: ${futures?.markPrice.toString() ?? '-'}',
                            style: const TextStyle(color: Colors.white),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Ask: ${spot?.askPrice.toString() ?? '-'}',
                            style: const TextStyle(color: Colors.white),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Mark: ${futures?.markPrice.toString() ?? '-'}',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  String? _restCooldownText(LiveExecutionState? state) {
    final until = state?.restCooldownUntil;
    if (until == null) {
      return null;
    }
    final remaining = until.difference(DateTime.now().toUtc());
    if (remaining <= Duration.zero) {
      return null;
    }
    final minutes = remaining.inMinutes;
    final seconds =
        remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '冷却 ${minutes.toString().padLeft(2, '0')}:$seconds';
  }

  void _showRestCooldownDialog(BuildContext context, LiveExecutionState state) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Binance REST 冷却中'),
        content: SelectableText(
          [
            if (state.restCooldownUntil != null)
              '冷却结束：${state.restCooldownUntil!.toLocal()}',
            if ((state.restCooldownReason ?? '').isNotEmpty)
              '原因：${state.restCooldownReason}',
          ].join('\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  String _statusText(MarketConnectionStatus status) {
    switch (status) {
      case MarketConnectionStatus.disconnected:
        return '未连接';
      case MarketConnectionStatus.connecting:
      case MarketConnectionStatus.waitingFirstData:
        return '连接中';
      case MarketConnectionStatus.ready:
        return '正常';
      case MarketConnectionStatus.reconnecting:
        return '重连中';
      case MarketConnectionStatus.stale:
        return '数据过期';
      case MarketConnectionStatus.error:
        return '错误';
      case MarketConnectionStatus.stopped:
        return '停止';
      case MarketConnectionStatus.connected:
        return '已连接';
      case MarketConnectionStatus.reconciling:
        return '对账中';
    }
  }

  String _accountWsStatusText(String status) {
    switch (status) {
      case 'disconnected':
        return '未连接';
      case 'connecting':
      case 'waitingSnapshot':
        return '连接中';
      case 'ready':
        return '正常';
      case 'reconnecting':
        return '重连中';
      case 'error':
        return '错误';
      default:
        return status;
    }
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.value, this.onTap});

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                '$label: $value',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomStatusBar extends StatelessWidget {
  const _BottomStatusBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: Colors.grey.shade200,
      child: const Text(
        'LIVE 手动交易实验室 / 真实资金默认关闭 / 不自动下单',
        style: TextStyle(fontSize: 12),
      ),
    );
  }
}
