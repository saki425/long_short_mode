import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/symbol_workspace_controller.dart';
import '../database/app_database.dart';
import '../services/app_ui_settings.dart';
import '../services/execution/auto_spot_grid_execution_service.dart';
import '../services/execution/live_exchange_execution_service.dart';
import '../services/execution/live_trading_gate_service.dart';
import '../services/market_data/market_data_coordinator.dart';
import '../services/market_data/market_data_status.dart';
import '../services/security/api_key_profile_service.dart';
import '../services/security/secure_key_storage.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _spotApiKeyController = TextEditingController();
  final _spotSecretKeyController = TextEditingController();
  final _futuresApiKeyController = TextEditingController();
  final _futuresSecretKeyController = TextEditingController();
  final _liveConfirmController = TextEditingController(
    text: '我确认当前使用正式账户和真实资金',
  );
  final _liveEnableController = TextEditingController(
    text: 'ENABLE LIVE TRADING',
  );
  late final CredentialsVault _credentialsVault;
  late final CredentialsSessionCache _credentialsCache;
  late final MarketDataCoordinator _marketData;
  late final LiveExchangeExecutionService _liveExecution;
  late final LiveTradingGateService _liveTradingGate;
  late final ApiKeyProfileService _apiKeyProfiles;
  late final SymbolWorkspaceController _symbolWorkspace;
  late final AppDatabase _db;

  ApiKeyProfile? _spotProfile;
  ApiKeyProfile? _futuresProfile;
  LiveExecutionState? _executionState;
  String _message = '';
  Worker? _symbolWorker;

  @override
  void initState() {
    super.initState();
    _credentialsVault = Get.find<CredentialsVault>();
    _credentialsCache = Get.find<CredentialsSessionCache>();
    _marketData = Get.find<MarketDataCoordinator>();
    _liveExecution = Get.find<LiveExchangeExecutionService>();
    _liveTradingGate = Get.find<LiveTradingGateService>();
    _apiKeyProfiles = Get.find<ApiKeyProfileService>();
    _symbolWorkspace = Get.find<SymbolWorkspaceController>();
    _db = Get.find<AppDatabase>();
    _loadSymbolBindingDisplay();
    _symbolWorker = ever(_symbolWorkspace.activeSymbol, (_) {
      _clearInputs();
      _loadSymbolBindingDisplay();
    });
    _liveExecution.stateStream.listen((state) {
      if (mounted) {
        setState(() => _executionState = state);
        unawaited(_loadSymbolBindingDisplay());
      }
    });
  }

  @override
  void dispose() {
    _spotApiKeyController.dispose();
    _spotSecretKeyController.dispose();
    _futuresApiKeyController.dispose();
    _futuresSecretKeyController.dispose();
    _liveConfirmController.dispose();
    _liveEnableController.dispose();
    _symbolWorker?.dispose();
    super.dispose();
  }

  Future<void> _loadSymbolBindingDisplay() async {
    final active = _symbolWorkspace.activeSymbol.value;
    if (active == null) {
      if (mounted) {
        setState(() {
          _spotProfile = null;
          _futuresProfile = null;
        });
      }
      return;
    }
    final requestedSymbol = active.symbol;
    final binding = await _apiKeyProfiles.getBinding(
      symbol: requestedSymbol,
      environment: 'live',
    );
    final spotProfileId = binding?.spotKeyProfileId;
    final futuresProfileId = binding?.futuresKeyProfileId;
    final spot =
        spotProfileId == null || spotProfileId.isEmpty
            ? null
            : await _apiKeyProfiles.getProfile(spotProfileId);
    final futures =
        futuresProfileId == null || futuresProfileId.isEmpty
            ? null
            : await _apiKeyProfiles.getProfile(futuresProfileId);
    if (!mounted ||
        _symbolWorkspace.activeSymbol.value?.symbol != requestedSymbol) {
      return;
    }
    setState(() {
      _spotProfile = spot;
      _futuresProfile = futures;
    });
    _liveTradingGate.setActiveScope(
      _liveWriteScope(
        symbol: requestedSymbol,
        spotProfileId: spot?.id,
        futuresProfileId: futures?.id,
      ),
    );
  }

  Future<void> _saveSpotAndVerify() async {
    await _saveProfileAndVerify(
      accountType: 'spot',
      apiKey: _spotApiKeyController.text,
      apiSecret: _spotSecretKeyController.text,
      reconnectSpot: true,
    );
  }

  Future<void> _saveFuturesAndVerify() async {
    await _saveProfileAndVerify(
      accountType: 'futures',
      apiKey: _futuresApiKeyController.text,
      apiSecret: _futuresSecretKeyController.text,
      reconnectFutures: true,
    );
  }

  Future<void> _saveProfileAndVerify({
    required String accountType,
    required String apiKey,
    required String apiSecret,
    bool reconnectSpot = false,
    bool reconnectFutures = false,
  }) async {
    final active = _symbolWorkspace.activeSymbol.value;
    if (active == null) {
      setState(() => _message = '请先选择或添加交易币对。');
      return;
    }
    final normalizedApiKey = apiKey.trim();
    final normalizedSecret = apiSecret.trim();
    final existing = accountType == 'spot' ? _spotProfile : _futuresProfile;
    if (existing == null &&
        (normalizedApiKey.isEmpty || normalizedSecret.isEmpty)) {
      setState(
        () =>
            _message =
                '${active.displayName} 尚未绑定 ${accountType == 'spot' ? 'Spot' : 'Futures'} API Key，请输入 API Key 和 Secret Key。',
      );
      return;
    }
    ApiKeyProfile? profile;
    try {
      profile = await _upsertProfileForActiveSymbol(
        active,
        accountType: accountType,
        apiKey: normalizedApiKey,
        apiSecret: normalizedSecret,
        existing: existing,
      );
      if (accountType == 'spot') {
        await _apiKeyProfiles.bindSpotProfile(
          symbol: active.symbol,
          environment: 'live',
          profileId: profile.id,
        );
      } else {
        await _apiKeyProfiles.bindFuturesProfile(
          symbol: active.symbol,
          environment: 'live',
          profileId: profile.id,
        );
      }
      await _apiKeyProfiles.updateProfileValidation(
        profileId: profile.id,
        isValid: true,
        lastError: null,
      );
      _clearInputs();
      await _loadSymbolBindingDisplay();
      await _reconnectActiveSymbol(
        reconnectSpot: reconnectSpot,
        reconnectFutures: reconnectFutures,
      );
      await _apiKeyProfiles.updateProfileValidation(
        profileId: profile.id,
        isValid: true,
        lastValidatedAt: DateTime.now().toUtc(),
        lastError: null,
      );
      await _loadSymbolBindingDisplay();
      if (mounted) {
        setState(
          () =>
              _message =
                  '${active.displayName} ${accountType == 'spot' ? 'Spot' : 'Futures'} Key Profile 已保存、绑定并验证通过。',
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _message = '密钥保存失败：${error.message ?? error.code}');
      }
    } catch (error) {
      final profileId =
          profile?.id ??
          (accountType == 'spot' ? _spotProfile : _futuresProfile)?.id;
      if (profileId != null) {
        await _apiKeyProfiles.updateProfileValidation(
          profileId: profileId,
          isValid: false,
          lastError: error.toString(),
        );
      }
      await _loadSymbolBindingDisplay();
      if (mounted) {
        setState(() => _message = '保存或验证失败：$error');
      }
    }
  }

  Future<ApiKeyProfile> _upsertProfileForActiveSymbol(
    SymbolWorkspace active, {
    required String accountType,
    required String apiKey,
    required String apiSecret,
    required ApiKeyProfile? existing,
  }) async {
    if (existing != null) {
      if (apiKey.isNotEmpty || apiSecret.isNotEmpty) {
        if (apiKey.isEmpty || apiSecret.isEmpty) {
          throw StateError('更新密钥时 API Key 和 Secret Key 必须同时填写。');
        }
        await _apiKeyProfiles.updateProfileSecret(
          profileId: existing.id,
          apiKey: apiKey,
          apiSecret: apiSecret,
          isValid: true,
          lastError: null,
        );
      }
      return (await _apiKeyProfiles.getProfile(existing.id)) ?? existing;
    }
    return _apiKeyProfiles.createProfile(
      name:
          '${active.displayName} ${accountType == 'spot' ? 'Spot' : 'Futures'}',
      environment: 'live',
      accountType: accountType,
      apiKey: apiKey,
      apiSecret: apiSecret,
      isValid: true,
    );
  }

  Future<void> _deleteSpot() async {
    await _clearCurrentSymbolBinding(accountType: 'spot');
  }

  Future<void> _deleteFutures() async {
    await _clearCurrentSymbolBinding(accountType: 'futures');
  }

  Future<void> _clearCurrentSymbolBinding({required String accountType}) async {
    final active = _symbolWorkspace.activeSymbol.value;
    if (active == null) {
      setState(() => _message = '请先选择或添加交易币对。');
      return;
    }
    try {
      if (accountType == 'spot') {
        await _apiKeyProfiles.clearSpotBinding(
          symbol: active.symbol,
          environment: 'live',
        );
      } else {
        await _apiKeyProfiles.clearFuturesBinding(
          symbol: active.symbol,
          environment: 'live',
        );
      }
      await _loadSymbolBindingDisplay();
      if (mounted) {
        setState(
          () =>
              _message =
                  '已解除 ${active.displayName} ${accountType == 'spot' ? 'Spot' : 'Futures'} Key 绑定。Key Profile 未删除。',
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _message = '密钥删除失败：${error.message ?? error.code}');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = '删除失败：$error');
      }
    }
  }

  Future<void> _reconnect({
    required bool reconnectSpot,
    required bool reconnectFutures,
  }) async {
    try {
      await _reconnectActiveSymbol(
        reconnectSpot: reconnectSpot,
        reconnectFutures: reconnectFutures,
      );
      if (mounted) {
        setState(() => _message = '已重新连接当前币种正式账户。');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = '重新连接失败：$error');
      }
    }
  }

  String _activeSymbol() {
    final symbol = _symbolWorkspace.activeSymbol.value?.symbol;
    if (symbol == null || symbol.isEmpty) {
      throw StateError('请先选择或添加交易币对。');
    }
    return symbol;
  }

  Future<void> _reconnectActiveSymbol({
    required bool reconnectSpot,
    required bool reconnectFutures,
  }) async {
    final symbol = _activeSymbol();
    if (reconnectSpot) {
      if (_spotProfile == null) {
        throw StateError('$symbol 未绑定 Spot API Key，不能连接现货账户。');
      }
      await _liveExecution.refreshSpotSnapshotForSymbol(symbol);
    }
    if (reconnectFutures) {
      if (_futuresProfile == null) {
        throw StateError('$symbol 未绑定 Futures API Key，不能连接合约账户。');
      }
      await _liveExecution.refreshFuturesSnapshotForSymbol(symbol);
      await _liveExecution.startFuturesUserDataStream(
        symbol: symbol,
        consumerKey: _settingsFuturesUserStreamKey(symbol),
      );
    }
  }

  String _settingsFuturesUserStreamKey(String symbol) {
    return 'settingsFuturesUserStream.${symbol.toUpperCase()}';
  }

  Future<void> _reloadCredentials() async {
    try {
      _apiKeyProfiles.clearSessionCache();
      await _credentialsVault.readOnce(force: true);
      if (mounted) {
        setState(() => _message = '已从旧 Keychain 重新载入本次会话密钥。');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = '重新载入密钥失败：$error');
      }
    }
  }

  Future<void> _lockSession() async {
    _credentialsVault.lockSession();
    _apiKeyProfiles.clearSessionCache();
    _liveTradingGate.disable(reason: 'credentials session locked');
    await _liveExecution.disconnect();
    if (mounted) {
      setState(() => _message = '已锁定本次会话：内存密钥已清空，本地保存的密钥未删除。');
    }
  }

  Future<void> _clearDatabase() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('清理本地数据库'),
          content: const Text(
            '这会清空本机 SQLite 中的策略、网格、订单、成交、PnL、币对工作区、Key Profile 记录和本地设置。\n\n'
            '不会删除本地保存的 API Key/Secret，也不会向 Binance 发送撤单或下单请求。\n\n'
            '如果 Binance 还有真实挂单，请先手动撤销或确认风险。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确认清理数据库'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }

    try {
      _liveTradingGate.disable(reason: 'database cleared from settings');
      await _liveExecution.disconnect();
      final deletedRows = await _db.clearAllApplicationData();
      _symbolWorkspace.workspaces.clear();
      _symbolWorkspace.activeSymbol.value = null;
      await _marketData.setWorkspaceSymbols(const [], activeSymbol: null);
      if (mounted) {
        setState(
          () =>
              _message =
                  '数据库已清理，共删除 $deletedRows 行。本地密钥未删除。建议重启 App 后重新添加币对和绑定 Key。',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = '清理数据库失败：$error');
      }
    }
  }

  void _clearInputs() {
    _spotApiKeyController.clear();
    _spotSecretKeyController.clear();
    _futuresApiKeyController.clear();
    _futuresSecretKeyController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final spotConfigured = _spotProfile != null;
    final futuresConfigured = _futuresProfile != null;
    final maskedSpotApiKey = _spotProfile?.apiKeyMasked ?? '未绑定';
    final maskedFuturesApiKey = _futuresProfile?.apiKeyMasked ?? '未绑定';
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Obx(() {
            final active =
                Get.find<SymbolWorkspaceController>().activeSymbol.value;
            return StreamBuilder<bool>(
              stream: AppUiSettings.watchHideSpotUiForSymbol(
                _db,
                symbol: active?.symbol,
              ),
              initialData: false,
              builder: (context, snapshot) {
                final hideSpotUi = snapshot.data ?? false;
                return _SymbolSettingsContextCard(
                  displayName: active?.displayName ?? '未选择币对',
                  symbol: active?.symbol ?? '-',
                  hideSpotUi: hideSpotUi,
                  spotConfigured: spotConfigured,
                  futuresConfigured: futuresConfigured,
                  maskedSpotApiKey: maskedSpotApiKey,
                  maskedFuturesApiKey: maskedFuturesApiKey,
                );
              },
            );
          }),
          const SizedBox(height: 12),
          _UiDisplaySettingsCard(db: _db),
          const SizedBox(height: 12),
          const _SecurityNotice(),
          const SizedBox(height: 12),
          _CredentialsCacheStatusCard(
            cache: _credentialsCache,
            profileCredentialCount: _apiKeyProfiles.sessionCredentialCount,
            onReload: _reloadCredentials,
            onLock: _lockSession,
          ),
          const SizedBox(height: 12),
          Obx(() {
            final symbol =
                Get.find<SymbolWorkspaceController>()
                    .activeSymbol
                    .value
                    ?.symbol;
            return StreamBuilder<bool>(
              stream: AppUiSettings.watchHideSpotUiForSymbol(
                _db,
                symbol: symbol,
              ),
              initialData: false,
              builder: (context, snapshot) {
                final hideSpotUi = snapshot.data ?? false;
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final cards = <Widget>[
                      if (!hideSpotUi)
                        _AccountCard(
                          title: '现货子账户',
                          apiController: _spotApiKeyController,
                          secretController: _spotSecretKeyController,
                          configured: spotConfigured,
                          maskedApiKey: maskedSpotApiKey,
                          profileName: _spotProfile?.name ?? '未绑定',
                          profileValid: _spotProfile?.isValid,
                          profileLastValidatedAt: _spotProfile?.lastValidatedAt,
                          restStatus:
                              spotConfigured
                                  ? _executionState?.spotRestStatus ??
                                      'disconnected'
                                  : 'notConfigured',
                          wsStatus:
                              spotConfigured
                                  ? _executionState?.spotWsStatus ??
                                      'disconnected'
                                  : 'notConfigured',
                          lastError:
                              _executionState?.lastError ??
                              _spotProfile?.lastError,
                          onSave: _saveSpotAndVerify,
                          onReconnect:
                              () => _reconnect(
                                reconnectSpot: true,
                                reconnectFutures: false,
                              ),
                          onDelete: _deleteSpot,
                        ),
                      _AccountCard(
                        title: '合约子账户',
                        apiController: _futuresApiKeyController,
                        secretController: _futuresSecretKeyController,
                        configured: futuresConfigured,
                        maskedApiKey: maskedFuturesApiKey,
                        profileName: _futuresProfile?.name ?? '未绑定',
                        profileValid: _futuresProfile?.isValid,
                        profileLastValidatedAt:
                            _futuresProfile?.lastValidatedAt,
                        restStatus:
                            futuresConfigured
                                ? _executionState?.futuresRestStatus ??
                                    'disconnected'
                                : 'notConfigured',
                        wsStatus:
                            futuresConfigured
                                ? _executionState?.futuresWsStatus ??
                                    'disconnected'
                                : 'notConfigured',
                        lastError:
                            _executionState?.lastError ??
                            _futuresProfile?.lastError,
                        onSave: _saveFuturesAndVerify,
                        onReconnect:
                            () => _reconnect(
                              reconnectSpot: false,
                              reconnectFutures: true,
                            ),
                        onDelete: _deleteFutures,
                      ),
                    ];
                    if (cards.length == 1) {
                      return cards.first;
                    }
                    if (constraints.maxWidth < 1000) {
                      return Column(
                        children: [
                          cards[0],
                          const SizedBox(height: 12),
                          cards[1],
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: cards[0]),
                        const SizedBox(width: 12),
                        Expanded(child: cards[1]),
                      ],
                    );
                  },
                );
              },
            );
          }),
          if (_message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_message),
            ),
          const SizedBox(height: 20),
          _LiveTradingSettingsCard(
            gate: _liveTradingGate,
            scope: _liveWriteScope(
              symbol: _symbolWorkspace.activeSymbol.value?.symbol ?? 'global',
              spotProfileId: _spotProfile?.id,
              futuresProfileId: _futuresProfile?.id,
            ),
            confirmController: _liveConfirmController,
            enableController: _liveEnableController,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 20),
          _MarketDataSettings(marketData: _marketData),
          const SizedBox(height: 12),
          _DatabaseSettingsCard(onClearDatabase: _clearDatabase),
          const SizedBox(height: 12),
          const _RiskSettingsCard(),
          const SizedBox(height: 12),
          const _ConfigCard(
            title: '应用设置',
            rows: [
              '真实交易写权限不会持久化',
              'App 重启后自动关闭真实写操作',
              '同一次运行中，断线重连和网络恢复不会自动关闭真实写操作',
            ],
          ),
        ],
      ),
    );
  }

  String _liveWriteScope({
    required String symbol,
    String? spotProfileId,
    String? futuresProfileId,
  }) {
    return LiveTradingGateService.scopeFor(
      symbol: symbol,
      keyProfileId: futuresProfileId ?? spotProfileId,
    );
  }
}

class _SecurityNotice extends StatelessWidget {
  const _SecurityNotice();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '安全提示',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 8),
            Text('API Key必须关闭提币权限。'),
            Text('建议设置IP白名单。'),
            Text('密钥保存到 SharedPreferences，不写入 SQLite、日志或源码。'),
          ],
        ),
      ),
    );
  }
}

class _UiDisplaySettingsCard extends StatelessWidget {
  const _UiDisplaySettingsCard({required this.db});

  final AppDatabase db;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Obx(() {
        final active = Get.find<SymbolWorkspaceController>().activeSymbol.value;
        final symbol = active?.symbol;
        return StreamBuilder<bool>(
          stream: AppUiSettings.watchHideSpotUiForSymbol(db, symbol: symbol),
          initialData: false,
          builder: (context, snapshot) {
            final hideSpot = snapshot.data ?? false;
            return SwitchListTile(
              title: const Text('隐藏现货相关界面'),
              subtitle: Text(
                symbol == null
                    ? '请先选择币对。'
                    : '仅对 ${active?.displayName ?? symbol} 生效；开启后相关页面隐藏现货内容，只显示合约相关入口。',
              ),
              value: hideSpot,
              onChanged:
                  symbol == null
                      ? null
                      : (value) async {
                        await AppUiSettings.setHideSpotUiForSymbol(
                          db,
                          symbol: symbol,
                          value: value,
                        );
                      },
            );
          },
        );
      }),
    );
  }
}

class _SymbolSettingsContextCard extends StatelessWidget {
  const _SymbolSettingsContextCard({
    required this.displayName,
    required this.symbol,
    required this.hideSpotUi,
    required this.spotConfigured,
    required this.futuresConfigured,
    required this.maskedSpotApiKey,
    required this.maskedFuturesApiKey,
  });

  final String displayName;
  final String symbol;
  final bool hideSpotUi;
  final bool spotConfigured;
  final bool futuresConfigured;
  final String maskedSpotApiKey;
  final String maskedFuturesApiKey;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$displayName Settings',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: [
                Text('当前币对：$displayName'),
                Text('内部 symbol：$symbol'),
                if (!hideSpotUi)
                  Text('Spot Key：${spotConfigured ? maskedSpotApiKey : '未绑定'}'),
                Text(
                  'Futures Key：${futuresConfigured ? maskedFuturesApiKey : '未绑定'}',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '说明：当前页面按 activeSymbol 绑定独立 Key Profile；保存后会写入当前币对的 symbol_account_bindings。',
              style: TextStyle(color: Colors.grey.shade700),
            ),
          ],
        ),
      ),
    );
  }
}

class _CredentialsCacheStatusCard extends StatelessWidget {
  const _CredentialsCacheStatusCard({
    required this.cache,
    required this.profileCredentialCount,
    required this.onReload,
    required this.onLock,
  });

  final CredentialsSessionCache cache;
  final int profileCredentialCount;
  final VoidCallback onReload;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: cache,
      builder: (context, _) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '本次会话密钥缓存',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  children: [
                    Text('状态：${_cacheStatusText(cache.status)}'),
                    Text('旧Keychain读取次数：${cache.keychainReadCount}'),
                    Text('Profile内存Key：$profileCredentialCount'),
                    Text('错误：${cache.lastError ?? '-'}'),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: onReload,
                      icon: const Icon(Icons.key),
                      label: const Text('重新载入旧密钥'),
                    ),
                    OutlinedButton.icon(
                      onPressed: onLock,
                      icon: const Icon(Icons.lock),
                      label: const Text('锁定本次会话'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _cacheStatusText(CredentialsCacheStatus status) {
    return switch (status) {
      CredentialsCacheStatus.notLoaded => '未载入',
      CredentialsCacheStatus.loading => '载入中',
      CredentialsCacheStatus.loaded => '已载入',
      CredentialsCacheStatus.missing => '未配置',
      CredentialsCacheStatus.error => '错误',
    };
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.title,
    required this.apiController,
    required this.secretController,
    required this.configured,
    required this.maskedApiKey,
    required this.profileName,
    required this.profileValid,
    required this.profileLastValidatedAt,
    required this.restStatus,
    required this.wsStatus,
    required this.lastError,
    required this.onSave,
    required this.onReconnect,
    required this.onDelete,
  });

  final String title;
  final TextEditingController apiController;
  final TextEditingController secretController;
  final bool configured;
  final String maskedApiKey;
  final String profileName;
  final bool? profileValid;
  final DateTime? profileLastValidatedAt;
  final String restStatus;
  final String wsStatus;
  final String? lastError;
  final VoidCallback onSave;
  final VoidCallback onReconnect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _secretField(apiController, 'API Key', false),
            _secretField(secretController, 'Secret Key', true),
            const Divider(),
            _StatusRow('是否已配置', configured ? '是' : '否'),
            _StatusRow('Key Profile', profileName),
            _StatusRow('脱敏 API Key', maskedApiKey),
            _StatusRow(
              'Profile 验证',
              profileValid == null ? '-' : (profileValid! ? '通过' : '失败'),
            ),
            _StatusRow('REST 状态', restStatus),
            _StatusRow('账户 WebSocket 状态', wsStatus),
            _StatusRow(
              '最后验证时间',
              profileLastValidatedAt?.toLocal().toString() ?? '-',
            ),
            _StatusRow('最近错误', lastError ?? '-'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: onSave,
                  icon: const Icon(Icons.save),
                  label: const Text('保存并验证'),
                ),
                OutlinedButton.icon(
                  onPressed: onReconnect,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新连接'),
                ),
                OutlinedButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete),
                  label: const Text('删除密钥'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _secretField(
    TextEditingController controller,
    String label,
    bool obscure,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          helperText: '留空则不修改已保存值',
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _LiveTradingSettingsCard extends StatefulWidget {
  const _LiveTradingSettingsCard({
    required this.gate,
    required this.scope,
    required this.confirmController,
    required this.enableController,
    required this.onChanged,
  });

  final LiveTradingGateService gate;
  final String scope;
  final TextEditingController confirmController;
  final TextEditingController enableController;
  final VoidCallback onChanged;

  @override
  State<_LiveTradingSettingsCard> createState() =>
      _LiveTradingSettingsCardState();
}

class _LiveTradingSettingsCardState extends State<_LiveTradingSettingsCard> {
  @override
  void initState() {
    super.initState();
    widget.confirmController.addListener(_refresh);
    widget.enableController.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.confirmController.removeListener(_refresh);
    widget.enableController.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final enabled = widget.gate.isEnabledForScope(widget.scope);
      final disableReason = widget.gate.disableReason.value;
      final canEnable =
          widget.confirmController.text.trim() == '我确认当前使用正式账户和真实资金' &&
          widget.enableController.text.trim() == 'ENABLE LIVE TRADING';
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('真实交易写权限', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                enabled ? '当前已开启。正式订单会影响真实资金。' : '当前关闭。App 重启后也会保持关闭。',
                style: TextStyle(
                  color: enabled ? Colors.red.shade700 : Colors.black87,
                  fontWeight: enabled ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: widget.confirmController,
                      decoration: const InputDecoration(
                        labelText: '我确认当前使用正式账户和真实资金',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: widget.enableController,
                      decoration: const InputDecoration(
                        labelText: 'ENABLE LIVE TRADING',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed:
                        enabled || !canEnable
                            ? null
                            : () => widget.gate.setEnabled(
                              true,
                              scope: widget.scope,
                            ),
                    icon: const Icon(Icons.lock_open),
                    label: const Text('开启真实写操作'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed:
                        enabled
                            ? () => widget.gate.disable(
                              reason: 'manual disable in settings',
                              scope: widget.scope,
                            )
                            : null,
                    icon: const Icon(Icons.lock),
                    label: const Text('关闭真实写操作'),
                  ),
                ],
              ),
              if (disableReason.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('最近关闭原因: $disableReason'),
                ),
            ],
          ),
        ),
      );
    });
  }
}

class _MarketDataSettings extends StatelessWidget {
  const _MarketDataSettings({required this.marketData});

  final MarketDataCoordinator marketData;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('行情源', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            StreamBuilder<MarketDataStatus>(
              stream: marketData.statusStream,
              initialData: marketData.status,
              builder: (context, snapshot) {
                final status = snapshot.data ?? marketData.status;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Chip(
                      label: Text('Binance 实时行情'),
                      backgroundColor: Color(0xFFE0E0E0),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 18,
                      runSpacing: 6,
                      children: [
                        const Text('默认启动：Binance 实时行情'),
                        Text(
                          '现货WS：${_connectionText(status.spotConnectionStatus)}',
                        ),
                        Text(
                          '合约WS：${_connectionText(status.futuresConnectionStatus)}',
                        ),
                        Text('整体状态：${_connectionText(status.overallStatus)}'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed:
                          () => marketData.setMode(MarketDataMode.binanceLive),
                      icon: const Icon(Icons.refresh),
                      label: const Text('重新连接 Binance 行情'),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _connectionText(MarketConnectionStatus status) {
    return switch (status) {
      MarketConnectionStatus.disconnected => '未连接',
      MarketConnectionStatus.connecting => '连接中',
      MarketConnectionStatus.connected => '已连接',
      MarketConnectionStatus.waitingFirstData => '等待首条数据',
      MarketConnectionStatus.ready => '正常',
      MarketConnectionStatus.reconnecting => '重连中',
      MarketConnectionStatus.stale => '数据过期',
      MarketConnectionStatus.error => '错误',
      MarketConnectionStatus.stopped => '已停止',
      MarketConnectionStatus.reconciling => '对账中',
    };
  }
}

class _DatabaseSettingsCard extends StatelessWidget {
  const _DatabaseSettingsCard({required this.onClearDatabase});

  final VoidCallback onClearDatabase;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('数据库', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('SQLite: Application Support / grid_hedge.db'),
            const Text('WAL: enabled'),
            const Text('清理只影响本地 SQLite，不删除本地保存的密钥。'),
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: onClearDatabase,
              icon: const Icon(Icons.delete_forever),
              label: const Text('清理数据库，重新开始'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RiskSettingsCard extends StatefulWidget {
  const _RiskSettingsCard();

  @override
  State<_RiskSettingsCard> createState() => _RiskSettingsCardState();
}

class _RiskSettingsCardState extends State<_RiskSettingsCard> {
  final _spotOrderLimitController = TextEditingController(text: '5');
  final _spotDailyLimitController = TextEditingController(text: '20');
  final _futuresOrderLimitController = TextEditingController(text: '5');
  final _futuresShortLimitController = TextEditingController(text: '10');
  final _autoSpotGridCapitalLimitController = TextEditingController(text: '50');
  final _autoSpotGridOrderLimitController = TextEditingController(text: '10');
  final _autoSpotGridDailyTurnoverLimitController = TextEditingController(
    text: '100',
  );

  late final AppDatabase _db;
  late final SymbolWorkspaceController _symbolWorkspace;
  late final ApiKeyProfileService _apiKeyProfiles;
  Worker? _symbolWorker;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _db = Get.find<AppDatabase>();
    _symbolWorkspace = Get.find<SymbolWorkspaceController>();
    _apiKeyProfiles = Get.find<ApiKeyProfileService>();
    _symbolWorker = ever(_symbolWorkspace.activeSymbol, (_) => _load());
    _load();
  }

  @override
  void dispose() {
    _spotOrderLimitController.dispose();
    _spotDailyLimitController.dispose();
    _futuresOrderLimitController.dispose();
    _futuresShortLimitController.dispose();
    _autoSpotGridCapitalLimitController.dispose();
    _autoSpotGridOrderLimitController.dispose();
    _autoSpotGridDailyTurnoverLimitController.dispose();
    _symbolWorker?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final active = _symbolWorkspace.activeSymbol.value;
    final binding =
        active == null
            ? null
            : await _apiKeyProfiles.getBinding(
              symbol: active.symbol,
              environment: 'live',
            );
    Future<String> valueFor(String key, String defaultValue) async {
      return await AppUiSettings.readScopedSettingValue(
            _db,
            key: key,
            symbol: active?.symbol,
            keyProfileId: _profileIdForKey(binding, key),
          ) ??
          defaultValue;
    }

    final spotOrderLimit = await valueFor(
      LiveExchangeExecutionService.manualSpotOrderLimitKey,
      '5',
    );
    final spotDailyLimit = await valueFor(
      LiveExchangeExecutionService.manualSpotDailyLimitKey,
      '20',
    );
    final futuresOrderLimit = await valueFor(
      LiveExchangeExecutionService.manualFuturesOrderLimitKey,
      '5',
    );
    final futuresShortLimit = await valueFor(
      LiveExchangeExecutionService.manualFuturesShortLimitKey,
      '10',
    );
    final gridCapitalLimit = await valueFor(
      AutoSpotGridExecutionService.capitalLimitSettingKey,
      '50',
    );
    final gridOrderLimit = await valueFor(
      AutoSpotGridExecutionService.orderLimitSettingKey,
      '10',
    );
    final gridDailyTurnoverLimit = await valueFor(
      LiveExchangeExecutionService.autoSpotGridDailyTurnoverLimitKey,
      '100',
    );
    if (!mounted) return;
    _spotOrderLimitController.text = spotOrderLimit;
    _spotDailyLimitController.text = spotDailyLimit;
    _futuresOrderLimitController.text = futuresOrderLimit;
    _futuresShortLimitController.text = futuresShortLimit;
    _autoSpotGridCapitalLimitController.text = gridCapitalLimit;
    _autoSpotGridOrderLimitController.text = gridOrderLimit;
    _autoSpotGridDailyTurnoverLimitController.text = gridDailyTurnoverLimit;
  }

  Future<void> _save() async {
    try {
      final active = _symbolWorkspace.activeSymbol.value;
      if (active == null) {
        throw StateError('请先选择或添加交易币对');
      }
      final binding = await _apiKeyProfiles.getBinding(
        symbol: active.symbol,
        environment: 'live',
      );
      final values = {
        LiveExchangeExecutionService.manualSpotOrderLimitKey:
            _parsePositiveUsdt(_spotOrderLimitController.text, '现货单笔测试上限'),
        LiveExchangeExecutionService.manualSpotDailyLimitKey:
            _parsePositiveUsdt(_spotDailyLimitController.text, '现货每日测试成交上限'),
        LiveExchangeExecutionService.manualFuturesOrderLimitKey:
            _parsePositiveUsdt(_futuresOrderLimitController.text, '合约单笔测试上限'),
        LiveExchangeExecutionService.manualFuturesShortLimitKey:
            _parsePositiveUsdt(_futuresShortLimitController.text, '最大空单名义价值'),
        AutoSpotGridExecutionService.capitalLimitSettingKey: _parsePositiveUsdt(
          _autoSpotGridCapitalLimitController.text,
          '自动现货网格资金上限',
        ),
        AutoSpotGridExecutionService.orderLimitSettingKey: _parsePositiveUsdt(
          _autoSpotGridOrderLimitController.text,
          '自动现货网格单笔上限',
        ),
        LiveExchangeExecutionService
            .autoSpotGridDailyTurnoverLimitKey: _parsePositiveUsdt(
          _autoSpotGridDailyTurnoverLimitController.text,
          '自动现货网格每日成交额上限',
        ),
      };
      for (final entry in values.entries) {
        await AppUiSettings.setScopedSettingValue(
          _db,
          key: entry.key,
          symbol: active.symbol,
          keyProfileId: _profileIdForKey(binding, entry.key),
          value: entry.value.toString(),
        );
      }
      if (mounted) {
        setState(
          () => _message = '${active.displayName} 风险参数已保存。交易测试页点击刷新后会显示最新配置。',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = '风险参数保存失败：$error');
      }
    }
  }

  Decimal _parsePositiveUsdt(String raw, String label) {
    final value = Decimal.tryParse(raw.trim());
    if (value == null || value <= Decimal.zero) {
      throw StateError('$label 必须是大于 0 的 USDT 数值');
    }
    return value;
  }

  String? _profileIdForKey(SymbolAccountBinding? binding, String key) {
    if (key == LiveExchangeExecutionService.manualFuturesOrderLimitKey ||
        key == LiveExchangeExecutionService.manualFuturesShortLimitKey) {
      return binding?.futuresKeyProfileId;
    }
    return binding?.spotKeyProfileId ?? binding?.futuresKeyProfileId;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('风险参数', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('交易测试上限只影响“交易测试”手动下单。'),
            const Text('自动现货网格资金上限、单笔上限和每日成交额上限会实际影响 LIVE 网格生成、预演和下单风控。'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _numberField(
                  controller: _spotOrderLimitController,
                  label: '现货单笔测试上限 USDT',
                ),
                _numberField(
                  controller: _spotDailyLimitController,
                  label: '现货每日测试成交上限 USDT',
                ),
                _numberField(
                  controller: _futuresOrderLimitController,
                  label: '合约单笔测试上限 USDT',
                ),
                _numberField(
                  controller: _futuresShortLimitController,
                  label: '最大空单名义价值 USDT',
                ),
                _numberField(
                  controller: _autoSpotGridCapitalLimitController,
                  label: '自动现货网格资金上限 USDT',
                ),
                _numberField(
                  controller: _autoSpotGridOrderLimitController,
                  label: '自动现货网格单笔上限 USDT',
                ),
                _numberField(
                  controller: _autoSpotGridDailyTurnoverLimitController,
                  label: '自动现货网格每日成交额上限 USDT',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save),
                label: const Text('保存风险参数'),
              ),
            ),
            if (_message.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_message),
            ],
          ],
        ),
      ),
    );
  }

  Widget _numberField({
    required TextEditingController controller,
    required String label,
  }) {
    return SizedBox(
      width: 260,
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

class _ConfigCard extends StatelessWidget {
  const _ConfigCard({required this.title, required this.rows});

  final String title;
  final List<String> rows;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(row),
              ),
          ],
        ),
      ),
    );
  }
}
