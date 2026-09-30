import 'dart:async';
import 'dart:math' as math;

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';
import '../../models/paper_strategy_config.dart';
import '../../services/market_data/futures_mark_price.dart';
import '../../services/market_data/market_data_service.dart';
import '../../services/market_data/market_data_status.dart';
import '../../services/market_data/spot_book_ticker.dart';
import '../grid/grid_generator.dart';

class PaperTradingService {
  PaperTradingService(this.db, {GridGenerator gridGenerator = const GridGenerator()}) : _gridGenerator = gridGenerator;

  static const currentPriceKey = 'paper.currentPrice.BTCUSDT';
  static const lastStrategyIdKey = 'paper.lastStrategyId';

  final AppDatabase db;
  final GridGenerator _gridGenerator;
  final Uuid _uuid = const Uuid();
  final math.Random _random = math.Random(7);
  StreamSubscription<SpotBookTicker>? _spotMarketSubscription;
  StreamSubscription<FuturesMarkPrice>? _futuresMarketSubscription;
  StreamSubscription<MarketDataStatus>? _marketStatusSubscription;
  MarketDataService? _marketDataService;

  Stream<Strategy?> watchActiveStrategy() {
    return (db.select(db.strategies)
          ..where((tbl) => tbl.environment.equals('PAPER'))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)])
          ..limit(1))
        .watchSingleOrNull();
  }

  Stream<List<GridLevel>> watchGridLevels(String strategyId) {
    return (db.select(db.gridLevels)
          ..where((tbl) => tbl.strategyId.equals(strategyId))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.gridIndex)]))
        .watch();
  }

  Stream<List<HedgeAdjustment>> watchHedges(String strategyId) {
    return (db.select(db.hedgeAdjustments)
          ..where((tbl) => tbl.strategyId.equals(strategyId))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]))
        .watch();
  }

  Stream<List<PnlSnapshot>> watchPnl(String strategyId) {
    return (db.select(db.pnlSnapshots)
          ..where((tbl) => tbl.strategyId.equals(strategyId))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.recordedAt)])
          ..limit(100))
        .watch();
  }

  Stream<List<RiskEvent>> watchRiskEvents(String strategyId) {
    return (db.select(db.riskEvents)
          ..where((tbl) => tbl.strategyId.equals(strategyId))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]))
        .watch();
  }

  void attachMarketDataService(MarketDataService service) {
    _marketDataService = service;
    _spotMarketSubscription?.cancel();
    _futuresMarketSubscription?.cancel();
    _spotMarketSubscription = service.spotBookTickerStream.listen((ticker) async {
      final strategy = await _latestRunningStrategy();
      if (strategy == null || service.status.overallStatus != MarketConnectionStatus.ready) {
        return;
      }
      await onSpotBookTicker(strategy.id, ticker);
    });
    _futuresMarketSubscription = service.futuresMarkPriceStream.listen((markPrice) async {
      final strategy = await _latestRunningStrategy();
      if (strategy == null) {
        return;
      }
      await onFuturesMarkPrice(strategy.id, markPrice);
    });
    _marketStatusSubscription?.cancel();
    _marketStatusSubscription = service.statusStream.listen((status) async {
      if (status.overallStatus != MarketConnectionStatus.stale) {
        return;
      }
      final strategy = await _latestRunningStrategy();
      if (strategy == null) {
        return;
      }
      await _insertRiskEvent(
        strategyId: strategy.id,
        type: 'marketDataStale',
        level: 'critical',
        message: 'Market data stale; Paper strategy paused',
        currentValue: status.overallStatus.name,
        limitValue: 'ready',
        actionTaken: 'pause',
      );
      await pause(strategy.id);
    });
  }

  Future<String> createStrategy(PaperStrategyConfig config) async {
    final strategyId = 'paper_${_uuid.v4()}';
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await db.into(db.strategies).insert(
            StrategiesCompanion.insert(
              id: strategyId,
              name: config.name,
              symbol: config.symbol,
              environment: 'PAPER',
              status: 'idle',
              createdAt: now,
              lowerPrice: _s(config.lowerPrice),
              upperPrice: _s(config.upperPrice),
              centerPrice: _s(config.centerPrice),
              gridCount: config.gridCount,
              gridSpacingPercent: _s(config.gridSpacingPercent),
              gridMode: config.gridMode,
              spotCapital: _s(config.spotCapital),
              futuresCapital: _s(config.futuresCapital),
              reserveCapital: _s(config.reserveCapital),
              hedgeRatio: _s(config.hedgeRatio),
              maxLossUsdt: _s(config.maxLossUsdt),
              maxExposureUsdt: _s(config.maxExposureUsdt),
              strategySpotBtc: const Value('0'),
              externalSpotBtc: const Value('0'),
              updatedAt: now,
            ),
          );
      await _writeSetting(lastStrategyIdKey, strategyId);
      await _writeSetting(currentPriceKey, _s(config.centerPrice));
      await _insertGridAndOrders(strategyId, config);
      await _writeInitialSnapshots(strategyId, config.centerPrice);
    });
    return strategyId;
  }

  Future<void> start(String strategyId) async {
    if (_marketDataService?.status.mode == MarketDataMode.binanceLive && _marketDataService?.status.overallStatus != MarketConnectionStatus.ready) {
      await _insertRiskEvent(
        strategyId: strategyId,
        type: 'marketDataNotReady',
        level: 'warning',
        message: 'Binance market data is not ready; Paper start blocked',
        currentValue: _marketDataService?.status.overallStatus.name ?? 'unknown',
        limitValue: 'ready',
        actionTaken: 'blockStart',
      );
      return;
    }
    await _setStatus(strategyId, 'running', startedAt: DateTime.now().toUtc());
    await _submitReadyPlannedOrders(strategyId);
  }

  Future<void> pause(String strategyId) => _setStatus(strategyId, 'paused');

  Future<void> resume(String strategyId) => _setStatus(strategyId, 'running');

  Future<void> stop(String strategyId) async {
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await (db.update(db.orders)
            ..where((tbl) =>
                tbl.strategyId.equals(strategyId) &
                tbl.status.isIn(['planned', 'submitting', 'new', 'partiallyFilled'])))
          .write(OrdersCompanion(status: const Value('cancelled'), cancelledAt: Value(now), updatedAt: Value(now)));
      await _setStatus(strategyId, 'stopped', stoppedAt: now);
    });
  }

  Future<void> emergencyExit(String strategyId) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      return;
    }
    final price = await currentPrice();
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await stop(strategyId);
      if (_d(strategy.strategySpotBtc) > Decimal.zero) {
        await _insertFilledOrder(
          strategyId: strategyId,
          marketType: 'spot',
          side: 'SELL',
          purpose: 'emergencyCloseSpot',
          price: price,
          quantity: _d(strategy.strategySpotBtc),
          realizedPnl: Decimal.zero,
          createdAt: now,
        );
      }
      await _insertRiskEvent(
        strategyId: strategyId,
        type: 'emergencyExit',
        level: 'critical',
        message: 'Paper emergency exit completed',
        currentValue: '0',
        limitValue: strategy.maxLossUsdt,
        actionTaken: 'cancelOrdersAndClosePaperPositions',
      );
      await _setStatus(strategyId, 'stopped', stoppedAt: now);
    });
  }

  Future<Decimal> currentPrice() async {
    final row = await (db.select(db.appSettings)..where((tbl) => tbl.key.equals(currentPriceKey))).getSingleOrNull();
    return _d(row?.value ?? '60000');
  }

  Future<void> setManualPrice(String strategyId, Decimal price) async {
    await _writeSetting(currentPriceKey, _s(price));
    await onPriceTick(strategyId, price);
  }

  Future<void> randomPriceTick(String strategyId) async {
    final last = await currentPrice();
    final changeBps = Decimal.parse(((_random.nextDouble() - 0.5) * 120).toStringAsFixed(4));
    final multiplier = Decimal.fromInt(1) + (changeBps / Decimal.fromInt(10000)).toDecimal(scaleOnInfinitePrecision: 8);
    await setManualPrice(strategyId, Decimal.parse((last * multiplier).toStringAsFixed(2)));
  }

  Future<void> onPriceTick(String strategyId, Decimal price) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null || strategy.status != 'running') {
      return;
    }
    await _submitReadyPlannedOrders(strategyId);
    final openOrders = await (db.select(db.orders)
          ..where((tbl) => tbl.strategyId.equals(strategyId) & tbl.status.isIn(['new', 'partiallyFilled']))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.createdAt)]))
        .get();
    for (final order in openOrders) {
      final orderPrice = _d(order.price ?? '0');
      final touched = order.side == 'BUY' ? price <= orderPrice : price >= orderPrice;
      if (touched) {
        await _fillOrder(order, price);
      }
    }
    await _maybeHedge(strategyId, price, triggerReason: 'twoGridFills');
    await _writeSnapshots(strategyId, price);
    await _checkRisk(strategyId, price);
  }

  Future<void> onSpotBookTicker(String strategyId, SpotBookTicker ticker) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null || strategy.status != 'running') {
      return;
    }
    await _writeSetting(currentPriceKey, ticker.midPrice.toString());
    await _submitReadyPlannedOrders(strategyId);
    final openOrders = await (db.select(db.orders)
          ..where((tbl) => tbl.strategyId.equals(strategyId) & tbl.status.isIn(['new', 'partiallyFilled']))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.createdAt)]))
        .get();
    Order? touched;
    Decimal? referencePrice;
    for (final order in openOrders) {
      final orderPrice = _d(order.price ?? '0');
      if (order.side == 'BUY' && orderPrice >= ticker.askPrice) {
        touched = order;
        referencePrice = ticker.askPrice;
        break;
      }
      if (order.side == 'SELL' && orderPrice <= ticker.bidPrice) {
        touched = order;
        referencePrice = ticker.bidPrice;
        break;
      }
    }
    if (touched != null && referencePrice != null) {
      await _fillOrder(touched, referencePrice);
    }
    await _maybeHedge(strategyId, _marketDataService?.latestFuturesMarkPrice?.markPrice ?? ticker.midPrice, triggerReason: 'twoGridFills');
    await _writeSnapshots(strategyId, _marketDataService?.latestFuturesMarkPrice?.markPrice ?? ticker.midPrice);
    await _checkRisk(strategyId, _marketDataService?.latestFuturesMarkPrice?.markPrice ?? ticker.midPrice);
  }

  Future<void> onFuturesMarkPrice(String strategyId, FuturesMarkPrice markPrice) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null || strategy.status != 'running') {
      return;
    }
    await _maybeSettleFunding(strategyId, markPrice);
    await _writeSnapshots(strategyId, markPrice.markPrice);
    await _checkRisk(strategyId, markPrice.markPrice);
  }

  Future<void> _insertGridAndOrders(String strategyId, PaperStrategyConfig config) async {
    final now = DateTime.now().toUtc();
    final levels = _gridGenerator.generate(config);
    for (final level in levels) {
      final gridId = '${strategyId}_grid_${level.index}';
      final orderId = _uuid.v4();
      await db.into(db.gridLevels).insert(
            GridLevelsCompanion.insert(
              id: gridId,
              strategyId: strategyId,
              gridIndex: level.index,
              price: _s(level.price),
              nextUpperPrice: Value(level.nextUpperPrice == null ? null : _s(level.nextUpperPrice!)),
              nextLowerPrice: Value(level.nextLowerPrice == null ? null : _s(level.nextLowerPrice!)),
              plannedSide: level.side,
              plannedQuantity: _s(level.quantity),
              plannedQuoteAmount: _s(level.quoteAmount),
              status: 'ready',
              linkedOrderId: Value(orderId),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await db.into(db.orders).insert(
            OrdersCompanion.insert(
              id: orderId,
              strategyId: strategyId,
              accountType: 'spotSubAccount',
              marketType: 'spot',
              symbol: config.symbol,
              clientOrderId: _clientOrderId('spot', strategyId, level.side == 'BUY' ? 'gridBuy' : 'gridSell'),
              side: level.side,
              orderType: 'LIMIT',
              timeInForce: const Value('GTC'),
              price: Value(_s(level.price)),
              originalQuantity: _s(level.quantity),
              quoteQuantity: Value(_s(level.quoteAmount)),
              status: 'planned',
              purpose: level.side == 'BUY' ? 'gridBuy' : 'gridSell',
              gridLevelId: Value(gridId),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
  }

  Future<void> _submitReadyPlannedOrders(String strategyId) async {
    final now = DateTime.now().toUtc();
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      return;
    }
    var availableSpotBtc = _d(strategy.strategySpotBtc);
    final planned = await (db.select(db.orders)
          ..where((tbl) => tbl.strategyId.equals(strategyId) & tbl.status.equals('planned'))
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.createdAt)]))
        .get();
    for (final order in planned) {
      final quantity = _d(order.originalQuantity);
      if (order.side == 'SELL' && availableSpotBtc < quantity) {
        continue;
      }
      if (order.side == 'SELL') {
        availableSpotBtc -= quantity;
      }
      await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id))).write(
        OrdersCompanion(status: const Value('new'), submittedAt: Value(now), updatedAt: Value(now)),
      );
      if (order.gridLevelId != null) {
        await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(order.gridLevelId!)))
            .write(GridLevelsCompanion(status: const Value('submitted'), updatedAt: Value(now)));
      }
    }
  }

  Future<void> _fillOrder(Order order, Decimal fillPrice) async {
    final now = DateTime.now().toUtc();
    final price = _d(order.price ?? _s(fillPrice));
    final quantity = _d(order.originalQuantity);
    final quote = price * quantity;
    final fee = quote * Decimal.parse('0.001');
    await db.transaction(() async {
      await (db.update(db.orders)..where((tbl) => tbl.id.equals(order.id))).write(
        OrdersCompanion(
          status: const Value('filled'),
          executedQuantity: Value(_s(quantity)),
          averagePrice: Value(_s(price)),
          quoteQuantity: Value(_s(quote)),
          updatedAt: Value(now),
          completedAt: Value(now),
        ),
      );
      if (order.gridLevelId != null) {
        await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(order.gridLevelId!)))
            .write(GridLevelsCompanion(status: const Value('filled'), updatedAt: Value(now)));
      }
      await db.into(db.fills).insert(
            FillsCompanion.insert(
              id: _uuid.v4(),
              strategyId: order.strategyId,
              orderId: order.id,
              exchangeTradeId: 'paper_${order.id}_${now.microsecondsSinceEpoch}',
              symbol: order.symbol,
              side: order.side,
              price: _s(price),
              quantity: _s(quantity),
              quoteQuantity: _s(quote),
              commission: _s(fee),
              commissionAsset: 'USDT',
              realizedPnl: Value(order.side == 'SELL' ? _s(quote * Decimal.parse('0.01')) : '0'),
              tradeTime: now,
              createdAt: now,
            ),
          );
      await _updateSpotBtc(order.strategyId, order.side == 'BUY' ? quantity : -quantity);
      await _createReverseOrder(order, fillPrice, quantity, quote);
      await _incrementFillCounter(order.strategyId);
    });
  }

  Future<void> _createReverseOrder(Order filledOrder, Decimal fillReferencePrice, Decimal quantity, Decimal quote) async {
    final grid = filledOrder.gridLevelId == null
        ? null
        : await (db.select(db.gridLevels)..where((tbl) => tbl.id.equals(filledOrder.gridLevelId!))).getSingleOrNull();
    final reverseSide = filledOrder.side == 'BUY' ? 'SELL' : 'BUY';
    final reversePriceText = filledOrder.side == 'BUY' ? grid?.nextUpperPrice : grid?.nextLowerPrice;
    if (reversePriceText == null) {
      return;
    }
    final now = DateTime.now().toUtc();
    final reverseOrderId = _uuid.v4();
    await db.into(db.orders).insert(
          OrdersCompanion.insert(
            id: reverseOrderId,
            strategyId: filledOrder.strategyId,
            accountType: 'spotSubAccount',
            marketType: 'spot',
            symbol: filledOrder.symbol,
            clientOrderId: _clientOrderId('spot', filledOrder.strategyId, reverseSide == 'BUY' ? 'gridBuy' : 'gridSell'),
            side: reverseSide,
            orderType: 'LIMIT',
            timeInForce: const Value('GTC'),
            price: Value(reversePriceText),
            originalQuantity: _s(quantity),
            quoteQuantity: Value(_s(quote)),
            status: 'planned',
            purpose: reverseSide == 'BUY' ? 'gridBuy' : 'gridSell',
            gridLevelId: Value(filledOrder.gridLevelId),
            parentOrderId: Value(filledOrder.id),
            createdAt: now,
            updatedAt: now,
          ),
        );
    if (filledOrder.gridLevelId != null) {
      await (db.update(db.gridLevels)..where((tbl) => tbl.id.equals(filledOrder.gridLevelId!))).write(
        GridLevelsCompanion(
          status: const Value('ready'),
          plannedSide: Value(reverseSide),
          linkedOrderId: Value(reverseOrderId),
          updatedAt: Value(now),
        ),
      );
    }
  }

  Future<void> _maybeHedge(String strategyId, Decimal markPrice, {required String triggerReason}) async {
    final counter = await _intSetting('paper.$strategyId.fillsSinceHedge');
    final strategy = await _strategy(strategyId);
    if (strategy == null || counter < 2) {
      return;
    }
    final spotBtc = _d(strategy.strategySpotBtc);
    final shortBefore = await _decimalSetting('paper.$strategyId.shortBtc');
    final target = spotBtc * _d(strategy.hedgeRatio);
    final diff = target - shortBefore;
    final minQty = Decimal.parse('0.0015');
    if (diff.abs() < minQty) {
      await _insertHedge(strategyId, triggerReason, spotBtc, shortBefore, target, diff, 'noAction', Decimal.zero, Decimal.zero, markPrice);
      await _writeSetting('paper.$strategyId.fillsSinceHedge', '0');
      return;
    }
    final action = diff > Decimal.zero ? 'increaseShort' : 'reduceShort';
    final requested = diff.abs();
    final shortAfter = action == 'increaseShort' ? shortBefore + requested : shortBefore - requested;
    await _writeSetting('paper.$strategyId.shortBtc', _s(shortAfter));
    await _insertFilledOrder(
      strategyId: strategyId,
      marketType: 'usdtFutures',
      side: action == 'increaseShort' ? 'SELL' : 'BUY',
      purpose: action == 'increaseShort' ? 'increaseHedge' : 'reduceHedge',
      price: markPrice,
      quantity: requested,
      realizedPnl: Decimal.zero,
      createdAt: DateTime.now().toUtc(),
      reduceOnly: action == 'reduceShort',
    );
    await _insertHedge(strategyId, triggerReason, spotBtc, shortBefore, target, diff, action, requested, requested, markPrice);
    await _writeSetting('paper.$strategyId.fillsSinceHedge', '0');
  }

  Future<void> _insertHedge(
    String strategyId,
    String triggerReason,
    Decimal spotBefore,
    Decimal shortBefore,
    Decimal target,
    Decimal diff,
    String action,
    Decimal requested,
    Decimal filled,
    Decimal price,
  ) async {
    final now = DateTime.now().toUtc();
    final shortAfter = action == 'increaseShort'
        ? shortBefore + filled
        : action == 'reduceShort'
            ? shortBefore - filled
            : shortBefore;
    final netBtc = spotBefore - shortAfter;
    await db.into(db.hedgeAdjustments).insert(
          HedgeAdjustmentsCompanion.insert(
            id: _uuid.v4(),
            strategyId: strategyId,
            triggerReason: triggerReason,
            spotBtcBefore: _s(spotBefore),
            shortBtcBefore: _s(shortBefore),
            targetShortBtc: _s(target),
            differenceBtc: _s(diff),
            action: action,
            requestedQuantity: _s(requested),
            filledQuantity: Value(_s(filled)),
            averagePrice: Value(_s(price)),
            spotBtcAfter: Value(_s(spotBefore)),
            shortBtcAfter: Value(_s(shortAfter)),
            netExposureBtcAfter: Value(_s(netBtc)),
            netExposureUsdtAfter: Value(_s(netBtc * price)),
            createdAt: now,
            completedAt: Value(now),
            status: 'completed',
          ),
        );
  }

  Future<void> _writeInitialSnapshots(String strategyId, Decimal price) => _writeSnapshots(strategyId, price);

  Future<void> _writeSnapshots(String strategyId, Decimal price) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      return;
    }
    final now = DateTime.now().toUtc();
    final spotBtc = _d(strategy.strategySpotBtc);
    final shortBtc = await _decimalSetting('paper.$strategyId.shortBtc');
    final netBtc = spotBtc - shortBtc;
    final netExposure = netBtc * price;
    final realized = await _realizedPnl(strategyId);
    final fees = await _fees(strategyId);
    final funding = await _decimalSetting('paper.$strategyId.cumulativeFundingFees');
    final unrealized = spotBtc * (price - _d(strategy.centerPrice));
    final futuresUnrealized = shortBtc * (_d(strategy.centerPrice) - price);
    final totalPnl = realized + unrealized + futuresUnrealized - fees - funding;
    final totalEquity = _d(strategy.spotCapital) + _d(strategy.futuresCapital) + _d(strategy.reserveCapital) + totalPnl;
    await db.into(db.accountSnapshots).insert(
          AccountSnapshotsCompanion.insert(
            id: _uuid.v4(),
            strategyId: strategyId,
            spotUsdtFree: strategy.spotCapital,
            spotUsdtLocked: '0',
            spotBtcFree: _s(spotBtc),
            spotBtcLocked: '0',
            strategySpotBtc: _s(spotBtc),
            futuresWalletBalance: strategy.futuresCapital,
            futuresAvailableBalance: strategy.futuresCapital,
            futuresShortQuantity: _s(shortBtc),
            futuresEntryPrice: Value(strategy.centerPrice),
            futuresMarkPrice: Value(_s(price)),
            futuresUnrealizedPnl: _s(futuresUnrealized),
            netExposureBtc: _s(netBtc),
            netExposureUsdt: _s(netExposure),
            recordedAt: now,
          ),
        );
    await db.into(db.pnlSnapshots).insert(
          PnlSnapshotsCompanion.insert(
            id: _uuid.v4(),
            strategyId: strategyId,
            spotGridRealizedPnl: _s(realized),
            spotUnrealizedPnl: _s(unrealized),
            futuresRealizedPnl: '0',
            futuresUnrealizedPnl: _s(futuresUnrealized),
            spotFees: _s(fees),
            futuresFees: '0',
            fundingFees: _s(funding),
            totalPnl: _s(totalPnl),
            totalEquity: _s(totalEquity),
            recordedAt: now,
          ),
        );
  }

  Future<void> _checkRisk(String strategyId, Decimal price) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      return;
    }
    final latestPnl = await (db.select(db.pnlSnapshots)
          ..where((tbl) => tbl.strategyId.equals(strategyId))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.recordedAt)])
          ..limit(1))
        .getSingleOrNull();
    final latestAccount = await (db.select(db.accountSnapshots)
          ..where((tbl) => tbl.strategyId.equals(strategyId))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.recordedAt)])
          ..limit(1))
        .getSingleOrNull();
    if (latestPnl != null && _d(latestPnl.totalPnl) <= -_d(strategy.maxLossUsdt)) {
      await _insertRiskEvent(
        strategyId: strategyId,
        type: 'maxLoss',
        level: 'critical',
        message: 'Paper max loss reached',
        currentValue: latestPnl.totalPnl,
        limitValue: strategy.maxLossUsdt,
        actionTaken: 'pauseAndCancelOrders',
      );
      await pause(strategyId);
    }
    if (latestAccount != null && _d(latestAccount.netExposureUsdt).abs() > _d(strategy.maxExposureUsdt)) {
      await _insertRiskEvent(
        strategyId: strategyId,
        type: 'maxExposure',
        level: 'warning',
        message: 'Paper net exposure exceeded',
        currentValue: latestAccount.netExposureUsdt,
        limitValue: strategy.maxExposureUsdt,
        actionTaken: 'tryHedge',
      );
      await _maybeHedge(strategyId, price, triggerReason: 'exposureExceeded');
    }
    if (price < _d(strategy.lowerPrice) || price > _d(strategy.upperPrice)) {
      await _insertRiskEvent(
        strategyId: strategyId,
        type: 'outOfRange',
        level: 'critical',
        message: 'Paper price out of grid range',
        currentValue: _s(price),
        limitValue: '${strategy.lowerPrice}-${strategy.upperPrice}',
        actionTaken: 'pause',
      );
      await pause(strategyId);
    }
  }

  Future<void> _maybeSettleFunding(String strategyId, FuturesMarkPrice markPrice) async {
    final now = DateTime.now().toUtc();
    if (markPrice.nextFundingTime.isAfter(now)) {
      return;
    }
    final settledKey = 'paper.$strategyId.fundingSettled.${markPrice.nextFundingTime.millisecondsSinceEpoch}';
    final settled = await _intSetting(settledKey);
    if (settled == 1) {
      return;
    }
    final shortBtc = await _decimalSetting('paper.$strategyId.shortBtc');
    final notional = shortBtc * markPrice.markPrice;
    final shortFundingFee = -(notional * markPrice.fundingRate);
    final cumulativeKey = 'paper.$strategyId.cumulativeFundingFees';
    final cumulative = await _decimalSetting(cumulativeKey);
    await _writeSetting(cumulativeKey, _s(cumulative + shortFundingFee));
    await _writeSetting(settledKey, '1');
  }

  Future<void> _insertRiskEvent({
    required String strategyId,
    required String type,
    required String level,
    required String message,
    required String currentValue,
    required String limitValue,
    required String actionTaken,
  }) {
    final now = DateTime.now().toUtc();
    return db.into(db.riskEvents).insert(
          RiskEventsCompanion.insert(
            id: _uuid.v4(),
            strategyId: strategyId,
            type: type,
            level: level,
            message: message,
            currentValue: Value(currentValue),
            limitValue: Value(limitValue),
            actionTaken: Value(actionTaken),
            createdAt: now,
          ),
        );
  }

  Future<void> _insertFilledOrder({
    required String strategyId,
    required String marketType,
    required String side,
    required String purpose,
    required Decimal price,
    required Decimal quantity,
    required Decimal realizedPnl,
    required DateTime createdAt,
    bool reduceOnly = false,
  }) async {
    final orderId = _uuid.v4();
    final quote = price * quantity;
    await db.into(db.orders).insert(
          OrdersCompanion.insert(
            id: orderId,
            strategyId: strategyId,
            accountType: marketType == 'spot' ? 'spotSubAccount' : 'futuresSubAccount',
            marketType: marketType,
            symbol: 'BTCUSDT',
            clientOrderId: _clientOrderId(marketType, strategyId, purpose),
            side: side,
            orderType: 'MARKET',
            price: Value(_s(price)),
            originalQuantity: _s(quantity),
            executedQuantity: Value(_s(quantity)),
            averagePrice: Value(_s(price)),
            quoteQuantity: Value(_s(quote)),
            reduceOnly: Value(reduceOnly),
            status: 'filled',
            purpose: purpose,
            createdAt: createdAt,
            submittedAt: Value(createdAt),
            updatedAt: createdAt,
            completedAt: Value(createdAt),
          ),
        );
    await db.into(db.fills).insert(
          FillsCompanion.insert(
            id: _uuid.v4(),
            strategyId: strategyId,
            orderId: orderId,
            exchangeTradeId: 'paper_${orderId}_${createdAt.microsecondsSinceEpoch}',
            symbol: 'BTCUSDT',
            side: side,
            price: _s(price),
            quantity: _s(quantity),
            quoteQuantity: _s(quote),
            commission: _s(quote * Decimal.parse('0.001')),
            commissionAsset: 'USDT',
            realizedPnl: Value(_s(realizedPnl)),
            tradeTime: createdAt,
            createdAt: createdAt,
          ),
        );
  }

  Future<void> _updateSpotBtc(String strategyId, Decimal delta) async {
    final strategy = await _strategy(strategyId);
    if (strategy == null) {
      return;
    }
    final updated = _d(strategy.strategySpotBtc) + delta;
    final now = DateTime.now().toUtc();
    await (db.update(db.strategies)..where((tbl) => tbl.id.equals(strategyId)))
        .write(StrategiesCompanion(strategySpotBtc: Value(_s(updated)), updatedAt: Value(now)));
  }

  Future<Decimal> _realizedPnl(String strategyId) async {
    final fills = await (db.select(db.fills)..where((tbl) => tbl.strategyId.equals(strategyId))).get();
    return fills.fold<Decimal>(Decimal.zero, (sum, fill) => sum + _d(fill.realizedPnl ?? '0'));
  }

  Future<Decimal> _fees(String strategyId) async {
    final fills = await (db.select(db.fills)..where((tbl) => tbl.strategyId.equals(strategyId))).get();
    return fills.fold<Decimal>(Decimal.zero, (sum, fill) => sum + _d(fill.commission));
  }

  Future<void> _incrementFillCounter(String strategyId) async {
    final key = 'paper.$strategyId.fillsSinceHedge';
    final value = await _intSetting(key);
    await _writeSetting(key, '${value + 1}');
  }

  Future<int> _intSetting(String key) async {
    final row = await (db.select(db.appSettings)..where((tbl) => tbl.key.equals(key))).getSingleOrNull();
    return int.tryParse(row?.value ?? '0') ?? 0;
  }

  Future<Decimal> _decimalSetting(String key) async {
    final row = await (db.select(db.appSettings)..where((tbl) => tbl.key.equals(key))).getSingleOrNull();
    return _d(row?.value ?? '0');
  }

  Future<void> _writeSetting(String key, String value) {
    final now = DateTime.now().toUtc();
    return db.into(db.appSettings).insertOnConflictUpdate(AppSettingsCompanion.insert(key: key, value: value, updatedAt: now));
  }

  Future<void> _setStatus(String strategyId, String status, {DateTime? startedAt, DateTime? stoppedAt}) {
    final now = DateTime.now().toUtc();
    return (db.update(db.strategies)..where((tbl) => tbl.id.equals(strategyId))).write(
      StrategiesCompanion(status: Value(status), startedAt: Value(startedAt), stoppedAt: Value(stoppedAt), updatedAt: Value(now)),
    );
  }

  Future<Strategy?> _strategy(String strategyId) {
    return (db.select(db.strategies)..where((tbl) => tbl.id.equals(strategyId))).getSingleOrNull();
  }

  Future<Strategy?> _latestRunningStrategy() {
    return (db.select(db.strategies)
          ..where((tbl) => tbl.environment.equals('PAPER') & tbl.status.equals('running'))
          ..orderBy([(tbl) => OrderingTerm.desc(tbl.updatedAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  String _clientOrderId(String market, String strategyId, String purpose) {
    return 'DHG_${market}_${strategyId.substring(0, math.min(strategyId.length, 12))}_${purpose}_${_uuid.v4().substring(0, 8)}';
  }

  Decimal _d(String value) => Decimal.tryParse(value) ?? Decimal.zero;

  String _s(Decimal value) => value.toString();
}
