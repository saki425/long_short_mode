import 'package:dio/dio.dart';

import '../../../database/app_database.dart';
import '../../security/api_key_profile_service.dart';
import '../futures/binance_futures_account_client.dart';
import '../spot/binance_spot_account_client.dart';
import 'binance_server_time_service.dart';

class BoundBinanceSpotClient {
  const BoundBinanceSpotClient({
    required this.symbol,
    required this.environment,
    required this.keyProfileId,
    required this.accountBindingId,
    required this.client,
  });

  final String symbol;
  final String environment;
  final String keyProfileId;
  final String accountBindingId;
  final BinanceSpotAccountClient client;
}

class BoundBinanceFuturesClient {
  const BoundBinanceFuturesClient({
    required this.symbol,
    required this.environment,
    required this.keyProfileId,
    required this.accountBindingId,
    required this.client,
  });

  final String symbol;
  final String environment;
  final String keyProfileId;
  final String accountBindingId;
  final BinanceFuturesAccountClient client;
}

class BinanceClientProvider {
  BinanceClientProvider({
    required this.db,
    required this.profileService,
    BinanceServerTimeService? timeService,
    Dio? dio,
  }) : _timeService = timeService ?? BinanceServerTimeService(),
       _dio = dio;

  final AppDatabase db;
  final ApiKeyProfileService profileService;
  final BinanceServerTimeService _timeService;
  final Dio? _dio;

  Future<BoundBinanceSpotClient> getSpotClientForSymbol(
    String symbol,
    String environment,
  ) async {
    final binding = await _loadBinding(symbol, environment);
    final profileId = binding.spotKeyProfileId;
    if (profileId == null || profileId.trim().isEmpty) {
      throw StateError('当前 ${_displaySymbol(symbol)} 未绑定 Spot API Key。');
    }
    final profile = await _loadValidProfile(
      profileId: profileId,
      accountType: 'spot',
      symbol: symbol,
    );
    final credentials = await profileService.loadCredentials(profile.id);
    return BoundBinanceSpotClient(
      symbol: symbol.toUpperCase(),
      environment: environment.toLowerCase(),
      keyProfileId: profile.id,
      accountBindingId: binding.id,
      client: BinanceSpotAccountClient(
        credentials: credentials,
        timeService: _timeService,
        dio: _dio,
      ),
    );
  }

  Future<BoundBinanceFuturesClient> getFuturesClientForSymbol(
    String symbol,
    String environment,
  ) async {
    final binding = await _loadBinding(symbol, environment);
    final profileId = binding.futuresKeyProfileId;
    if (profileId == null || profileId.trim().isEmpty) {
      throw StateError('当前 ${_displaySymbol(symbol)} 未绑定 Futures API Key。');
    }
    final profile = await _loadValidProfile(
      profileId: profileId,
      accountType: 'futures',
      symbol: symbol,
    );
    final credentials = await profileService.loadCredentials(profile.id);
    return BoundBinanceFuturesClient(
      symbol: symbol.toUpperCase(),
      environment: environment.toLowerCase(),
      keyProfileId: profile.id,
      accountBindingId: binding.id,
      client: BinanceFuturesAccountClient(
        credentials: credentials,
        timeService: _timeService,
        dio: _dio,
      ),
    );
  }

  Future<SymbolAccountBinding> _loadBinding(
    String symbol,
    String environment,
  ) async {
    final binding = await profileService.getBinding(
      symbol: symbol,
      environment: environment,
    );
    if (binding == null) {
      throw StateError('当前 ${_displaySymbol(symbol)} 未绑定 API Key。');
    }
    return binding;
  }

  Future<ApiKeyProfile> _loadValidProfile({
    required String profileId,
    required String accountType,
    required String symbol,
  }) async {
    final profile = await profileService.getProfile(profileId);
    if (profile == null) {
      throw StateError('当前 ${_displaySymbol(symbol)} 绑定的 API Key Profile 不存在。');
    }
    if (profile.accountType != accountType) {
      throw StateError(
        '当前 ${_displaySymbol(symbol)} 绑定的 Key 类型错误：${profile.accountType}。',
      );
    }
    if (!profile.isValid) {
      throw StateError(
        '当前 ${_displaySymbol(symbol)} 绑定的 API Key Profile 未验证通过。',
      );
    }
    return profile;
  }

  String _displaySymbol(String symbol) {
    final value = symbol.toUpperCase();
    if (value.endsWith('USDT') && value.length > 4) {
      return '${value.substring(0, value.length - 4)}/USDT';
    }
    return value;
  }
}
