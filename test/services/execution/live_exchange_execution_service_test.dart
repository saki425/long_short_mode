import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_hedge_trader/database/app_database.dart';
import 'package:grid_hedge_trader/repositories/basic_repositories.dart';
import 'package:grid_hedge_trader/repositories/order_repository.dart';
import 'package:grid_hedge_trader/services/execution/live_exchange_execution_service.dart';
import 'package:grid_hedge_trader/services/execution/live_trading_gate_service.dart';
import 'package:grid_hedge_trader/services/market_data/market_data_coordinator.dart';
import 'package:grid_hedge_trader/services/security/secure_key_storage.dart';

void main() {
  late AppDatabase db;
  late MarketDataCoordinator marketData;
  late LiveExchangeExecutionService service;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    final logRepository = LogRepository(db);
    marketData = MarketDataCoordinator(db: db, logRepository: logRepository);
    service = LiveExchangeExecutionService(
      db: db,
      orderRepository: OrderRepository(db),
      logRepository: logRepository,
      credentialsVault: CredentialsVault(
        store: MemorySecretStore(),
        cache: CredentialsSessionCache(),
        logRepository: logRepository,
      ),
      marketDataCoordinator: marketData,
      liveTradingGateService: LiveTradingGateService(),
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> insertPosition({
    required String keyProfileId,
    required String positionAmount,
  }) {
    return db
        .into(db.futuresPositions)
        .insert(
          FuturesPositionsCompanion.insert(
            id: '$keyProfileId-BNBUSDT-SHORT',
            keyProfileId: Value(keyProfileId),
            symbol: 'BNBUSDT',
            positionSide: 'SHORT',
            positionAmount: positionAmount,
            entryPrice: '600',
            unrealizedPnl: '0',
            updatedAt: DateTime.utc(2026, 10, 28),
          ),
        );
  }

  test(
    'scopes current futures short quantity to the requested profile',
    () async {
      await insertPosition(keyProfileId: 'profile-a', positionAmount: '-1.25');
      await insertPosition(keyProfileId: 'profile-b', positionAmount: '-8.5');

      expect(
        await service.currentFuturesShortQuantity(
          'BNBUSDT',
          keyProfileId: 'profile-a',
        ),
        Decimal.parse('1.25'),
      );
      expect(
        await service.currentFuturesShortQuantity(
          'BNBUSDT',
          keyProfileId: 'profile-b',
        ),
        Decimal.parse('8.5'),
      );
    },
  );
}
