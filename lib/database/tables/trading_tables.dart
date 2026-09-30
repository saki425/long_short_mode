import 'package:drift/drift.dart';

class SymbolWorkspaces extends Table {
  TextColumn get id => text()();
  TextColumn get symbol => text()();
  TextColumn get displayName => text()();
  TextColumn get baseAsset => text()();
  TextColumn get quoteAsset => text()();
  BoolColumn get spotEnabled => boolean().withDefault(const Constant(true))();
  BoolColumn get futuresEnabled =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
  BoolColumn get isHidden => boolean().withDefault(const Constant(false))();
  BoolColumn get isSubscribed => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get lastTickerPrice => text().nullable()();
  TextColumn get lastBid => text().nullable()();
  TextColumn get lastAsk => text().nullable()();
  DateTimeColumn get lastSpotWsUpdateAt => dateTime().nullable()();
  DateTimeColumn get lastFuturesWsUpdateAt => dateTime().nullable()();
  DateTimeColumn get lastRestSyncAt => dateTime().nullable()();
  BoolColumn get hasRunningStrategy =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get hasOpenOrders =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get hasError => boolean().withDefault(const Constant(false))();
  TextColumn get badgeLevel => text().withDefault(const Constant('none'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get lastSelectedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {symbol},
  ];
}

class Strategies extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get symbol => text()();
  TextColumn get environment => text()();
  TextColumn get status => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get startedAt => dateTime().nullable()();
  DateTimeColumn get stoppedAt => dateTime().nullable()();
  TextColumn get lowerPrice => text()();
  TextColumn get upperPrice => text()();
  TextColumn get centerPrice => text()();
  IntColumn get gridCount => integer()();
  TextColumn get gridSpacingPercent => text()();
  TextColumn get gridMode => text()();
  TextColumn get spotCapital => text()();
  TextColumn get futuresCapital => text()();
  TextColumn get reserveCapital => text()();
  TextColumn get hedgeRatio => text()();
  TextColumn get maxLossUsdt => text()();
  TextColumn get maxExposureUsdt => text()();
  TextColumn get strategySpotBtc => text().withDefault(const Constant('0'))();
  TextColumn get externalSpotBtc => text().withDefault(const Constant('0'))();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class GridLevels extends Table {
  TextColumn get id => text()();
  TextColumn get strategyId => text().references(Strategies, #id)();
  IntColumn get gridIndex => integer()();
  TextColumn get price => text()();
  TextColumn get nextUpperPrice => text().nullable()();
  TextColumn get nextLowerPrice => text().nullable()();
  TextColumn get buyPrice => text().nullable()();
  TextColumn get sellPrice => text().nullable()();
  TextColumn get plannedSide => text()();
  TextColumn get plannedQuantity => text()();
  TextColumn get plannedQuoteAmount => text()();
  TextColumn get status => text()();
  TextColumn get linkedOrderId => text().nullable()();
  TextColumn get lifecycleStatus => text().nullable()();
  TextColumn get activeOrderId => text().nullable()();
  TextColumn get lastBuyOrderId => text().nullable()();
  TextColumn get lastSellOrderId => text().nullable()();
  TextColumn get lastCompletedOrderId => text().nullable()();
  IntColumn get cycleNumber => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {strategyId, gridIndex},
  ];
}

class Orders extends Table {
  TextColumn get id => text()();
  TextColumn get strategyId => text().references(Strategies, #id)();
  TextColumn get environment => text().withDefault(const Constant('paper'))();
  TextColumn get source =>
      text().withDefault(const Constant('localStrategy'))();
  TextColumn get accountType => text()();
  TextColumn get marketType => text()();
  TextColumn get symbol => text()();
  TextColumn get clientOrderId => text()();
  TextColumn get exchangeOrderId => text().nullable()();
  TextColumn get side => text()();
  TextColumn get positionSide => text().nullable()();
  TextColumn get orderType => text()();
  TextColumn get timeInForce => text().nullable()();
  TextColumn get price => text().nullable()();
  TextColumn get originalQuantity => text()();
  TextColumn get executedQuantity => text().withDefault(const Constant('0'))();
  TextColumn get averagePrice => text().nullable()();
  TextColumn get quoteQuantity => text().nullable()();
  BoolColumn get reduceOnly => boolean().withDefault(const Constant(false))();
  TextColumn get status => text()();
  TextColumn get purpose => text()();
  TextColumn get gridLevelId => text().nullable().references(GridLevels, #id)();
  TextColumn get parentOrderId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get submittedAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  DateTimeColumn get cancelledAt => dateTime().nullable()();
  TextColumn get errorCode => text().nullable()();
  TextColumn get errorMessage => text().nullable()();
  TextColumn get keyProfileId => text().nullable()();
  TextColumn get accountBindingId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {clientOrderId},
  ];
}

class Fills extends Table {
  TextColumn get id => text()();
  TextColumn get strategyId => text().references(Strategies, #id)();
  TextColumn get orderId => text().references(Orders, #id)();
  TextColumn get exchangeTradeId => text()();
  TextColumn get symbol => text()();
  TextColumn get side => text()();
  TextColumn get price => text()();
  TextColumn get quantity => text()();
  TextColumn get quoteQuantity => text()();
  TextColumn get commission => text()();
  TextColumn get commissionAsset => text()();
  TextColumn get realizedPnl => text().nullable()();
  DateTimeColumn get tradeTime => dateTime()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {exchangeTradeId},
  ];
}

class CompletedGridCycles extends Table {
  TextColumn get id => text()();
  TextColumn get strategyId => text().references(Strategies, #id)();
  TextColumn get gridId => text().references(GridLevels, #id)();
  IntColumn get cycleNumber => integer()();
  TextColumn get buyOrderId => text()();
  TextColumn get sellOrderId => text()();
  TextColumn get buyExchangeOrderId => text().nullable()();
  TextColumn get sellExchangeOrderId => text().nullable()();
  TextColumn get buyClientOrderId => text()();
  TextColumn get sellClientOrderId => text()();
  TextColumn get buyAvgPrice => text()();
  TextColumn get sellAvgPrice => text()();
  TextColumn get baseQty => text()();
  TextColumn get buyQuoteAmount => text()();
  TextColumn get sellQuoteAmount => text()();
  TextColumn get buyFeeUsdt => text()();
  TextColumn get sellFeeUsdt => text()();
  TextColumn get grossPnl => text()();
  TextColumn get netPnl => text()();
  TextColumn get pnlPct => text()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get completedAt => dateTime()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {strategyId, gridId, cycleNumber},
    {buyOrderId, sellOrderId},
  ];
}

class FutureGridOrders extends Table {
  TextColumn get id => text()();
  TextColumn get strategyId => text().references(Strategies, #id)();
  TextColumn get symbol => text()();
  IntColumn get gridLevel => integer()();
  TextColumn get side => text()();
  TextColumn get price => text()();
  TextColumn get quantity => text()();
  TextColumn get status => text()();
  TextColumn get spotGridOrderId => text().references(GridLevels, #id)();
  TextColumn get futuresOrderId => text().nullable()();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {strategyId, spotGridOrderId},
  ];
}

class RecoveryShortLevels extends Table {
  TextColumn get id => text()();
  TextColumn get strategyId => text().references(Strategies, #id)();
  TextColumn get symbol => text()();
  IntColumn get partIndex => integer()();
  TextColumn get entryPercent => text()();
  TextColumn get entryPrice => text()();
  TextColumn get quantity => text().withDefault(const Constant('0'))();
  TextColumn get remainingQuantity => text().withDefault(const Constant('0'))();
  TextColumn get status => text()();
  BoolColumn get armedForExit => boolean().withDefault(const Constant(false))();
  BoolColumn get armedForEntry => boolean().withDefault(const Constant(true))();
  TextColumn get lowestPercentSinceOpen => text().nullable()();
  TextColumn get highestPercentSinceClose => text().nullable()();
  TextColumn get entryOrderId => text().nullable().references(Orders, #id)();
  TextColumn get exitOrderId => text().nullable().references(Orders, #id)();
  IntColumn get roundId => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {strategyId, partIndex},
  ];
}

class HedgeAdjustments extends Table {
  TextColumn get id => text()();
  TextColumn get strategyId => text().references(Strategies, #id)();
  TextColumn get triggerReason => text()();
  TextColumn get spotBtcBefore => text()();
  TextColumn get shortBtcBefore => text()();
  TextColumn get targetShortBtc => text()();
  TextColumn get differenceBtc => text()();
  TextColumn get action => text()();
  TextColumn get requestedQuantity => text()();
  TextColumn get filledQuantity => text().nullable()();
  TextColumn get averagePrice => text().nullable()();
  TextColumn get futuresOrderId => text().nullable()();
  TextColumn get spotBtcAfter => text().nullable()();
  TextColumn get shortBtcAfter => text().nullable()();
  TextColumn get netExposureBtcAfter => text().nullable()();
  TextColumn get netExposureUsdtAfter => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  TextColumn get status => text()();
  TextColumn get errorMessage => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class HedgeStates extends Table {
  TextColumn get id => text()();
  TextColumn get strategyId => text().references(Strategies, #id)();
  TextColumn get symbol => text()();
  BoolColumn get hedgeEnabled => boolean().withDefault(const Constant(false))();
  TextColumn get hedgeRatio => text().withDefault(const Constant('0.5'))();
  TextColumn get maxHedgeQty => text().withDefault(const Constant('0.01'))();
  TextColumn get minAdjustQty =>
      text().withDefault(const Constant('0.00001'))();
  TextColumn get minAdjustNotional => text().withDefault(const Constant('5'))();
  IntColumn get checkIntervalSeconds =>
      integer().withDefault(const Constant(30))();
  BoolColumn get allowAutoOpenShort =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get allowAutoCloseShort =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get hedgeDryRun => boolean().withDefault(const Constant(true))();
  TextColumn get exposedSpotQty => text().withDefault(const Constant('0'))();
  TextColumn get targetShortQty => text().withDefault(const Constant('0'))();
  TextColumn get currentShortQty => text().withDefault(const Constant('0'))();
  TextColumn get diffQty => text().withDefault(const Constant('0'))();
  TextColumn get lastAction => text().nullable()();
  TextColumn get lastActionQty => text().nullable()();
  TextColumn get lastActionStatus => text().nullable()();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get lastCalculatedAt => dateTime().nullable()();
  DateTimeColumn get lastSyncedAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {strategyId, symbol},
  ];
}

class HedgeActions extends Table {
  TextColumn get id => text()();
  TextColumn get strategyId => text().references(Strategies, #id)();
  TextColumn get gridId => text().nullable().references(GridLevels, #id)();
  IntColumn get cycleNumber => integer().nullable()();
  TextColumn get hedgeTriggerEventId => text().nullable()();
  TextColumn get actionType => text()();
  TextColumn get symbol => text()();
  TextColumn get side => text()();
  TextColumn get quantity => text()();
  TextColumn get price => text().nullable()();
  BoolColumn get reduceOnly => boolean().withDefault(const Constant(false))();
  BoolColumn get dryRun => boolean().withDefault(const Constant(true))();
  TextColumn get status => text()();
  TextColumn get futuresOrderId => text().nullable()();
  TextColumn get clientOrderId => text().nullable()();
  TextColumn get reason => text().nullable()();
  TextColumn get errorCode => text().nullable()();
  TextColumn get errorMessage => text().nullable()();
  TextColumn get keyProfileId => text().nullable()();
  TextColumn get accountBindingId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {strategyId, hedgeTriggerEventId, actionType},
  ];
}

class ApiKeyProfiles extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get exchange => text().withDefault(const Constant('binance'))();
  TextColumn get environment => text()();
  TextColumn get accountType => text()();
  TextColumn get keychainService => text()();
  TextColumn get keychainAccount => text()();
  TextColumn get apiKeyMasked => text()();
  BoolColumn get isValid => boolean().withDefault(const Constant(false))();
  DateTimeColumn get lastValidatedAt => dateTime().nullable()();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class SymbolAccountBindings extends Table {
  TextColumn get id => text()();
  TextColumn get symbol => text()();
  TextColumn get environment => text()();
  TextColumn get spotKeyProfileId => text().nullable()();
  TextColumn get futuresKeyProfileId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {symbol, environment},
  ];
}

class AccountSnapshots extends Table {
  TextColumn get id => text()();
  TextColumn get strategyId => text().references(Strategies, #id)();
  TextColumn get spotUsdtFree => text()();
  TextColumn get spotUsdtLocked => text()();
  TextColumn get spotBtcFree => text()();
  TextColumn get spotBtcLocked => text()();
  TextColumn get strategySpotBtc => text()();
  TextColumn get futuresWalletBalance => text()();
  TextColumn get futuresAvailableBalance => text()();
  TextColumn get futuresShortQuantity => text()();
  TextColumn get futuresEntryPrice => text().nullable()();
  TextColumn get futuresMarkPrice => text().nullable()();
  TextColumn get futuresUnrealizedPnl => text()();
  TextColumn get netExposureBtc => text()();
  TextColumn get netExposureUsdt => text()();
  DateTimeColumn get recordedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class PnlSnapshots extends Table {
  TextColumn get id => text()();
  TextColumn get strategyId => text().references(Strategies, #id)();
  TextColumn get spotGridRealizedPnl => text()();
  TextColumn get spotUnrealizedPnl => text()();
  TextColumn get futuresRealizedPnl => text()();
  TextColumn get futuresUnrealizedPnl => text()();
  TextColumn get spotFees => text()();
  TextColumn get futuresFees => text()();
  TextColumn get fundingFees => text()();
  TextColumn get totalPnl => text()();
  TextColumn get totalEquity => text()();
  DateTimeColumn get recordedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class RiskEvents extends Table {
  TextColumn get id => text()();
  TextColumn get strategyId => text().references(Strategies, #id)();
  TextColumn get type => text()();
  TextColumn get level => text()();
  TextColumn get message => text()();
  TextColumn get currentValue => text().nullable()();
  TextColumn get limitValue => text().nullable()();
  TextColumn get actionTaken => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get resolvedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class MarketSnapshots extends Table {
  TextColumn get id => text()();
  TextColumn get source => text()();
  TextColumn get symbol => text()();
  TextColumn get spotBid => text().nullable()();
  TextColumn get spotAsk => text().nullable()();
  TextColumn get spotMid => text().nullable()();
  TextColumn get futuresMarkPrice => text().nullable()();
  TextColumn get indexPrice => text().nullable()();
  TextColumn get fundingRate => text().nullable()();
  TextColumn get basis => text().nullable()();
  TextColumn get basisPercent => text().nullable()();
  DateTimeColumn get recordedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class AppLogs extends Table {
  TextColumn get id => text()();
  TextColumn get strategyId => text().nullable().references(Strategies, #id)();
  TextColumn get level => text()();
  TextColumn get module => text()();
  TextColumn get message => text()();
  TextColumn get extraJson => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {key};
}

class ApiAccountProfiles extends Table {
  TextColumn get id => text()();
  TextColumn get accountType => text()();
  TextColumn get alias => text()();
  TextColumn get maskedApiKey => text()();
  BoolColumn get isConfigured => boolean().withDefault(const Constant(false))();
  DateTimeColumn get lastValidatedAt => dateTime().nullable()();
  TextColumn get connectionStatus =>
      text().withDefault(const Constant('notConfigured'))();
  TextColumn get permissionCheckResult => text().nullable()();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class AccountAssets extends Table {
  TextColumn get id => text()();
  TextColumn get accountType => text()();
  TextColumn get keyProfileId => text().withDefault(const Constant('legacy'))();
  TextColumn get accountBindingId => text().nullable()();
  TextColumn get asset => text()();
  TextColumn get free => text()();
  TextColumn get locked => text()();
  TextColumn get total => text()();
  TextColumn get source =>
      text().withDefault(const Constant('binanceExchange'))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {accountType, keyProfileId, asset},
  ];
}

class SpotAccountSnapshots extends Table {
  TextColumn get id => text()();
  TextColumn get accountType =>
      text().withDefault(const Constant('spotSubAccount'))();
  TextColumn get keyProfileId => text().withDefault(const Constant('legacy'))();
  TextColumn get accountBindingId => text().nullable()();
  TextColumn get usdtFree => text()();
  TextColumn get usdtLocked => text()();
  TextColumn get btcFree => text()();
  TextColumn get btcLocked => text()();
  TextColumn get accountTotalBtc => text()();
  TextColumn get strategyTrackedBtc =>
      text().withDefault(const Constant('0'))();
  TextColumn get externalBtc => text().withDefault(const Constant('0'))();
  TextColumn get unclassifiedBtc => text().withDefault(const Constant('0'))();
  BoolColumn get canTrade => boolean().nullable()();
  BoolColumn get canWithdraw => boolean().nullable()();
  TextColumn get permissionsJson => text().nullable()();
  DateTimeColumn get exchangeUpdateTime => dateTime().nullable()();
  DateTimeColumn get recordedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class FuturesAccountSnapshots extends Table {
  TextColumn get id => text()();
  TextColumn get accountType =>
      text().withDefault(const Constant('futuresSubAccount'))();
  TextColumn get keyProfileId => text().withDefault(const Constant('legacy'))();
  TextColumn get accountBindingId => text().nullable()();
  TextColumn get walletBalance => text()();
  TextColumn get availableBalance => text()();
  TextColumn get totalUnrealizedPnl => text()();
  TextColumn get shortQuantity => text().withDefault(const Constant('0'))();
  TextColumn get longQuantity => text().withDefault(const Constant('0'))();
  TextColumn get shortEntryPrice => text().nullable()();
  TextColumn get longEntryPrice => text().nullable()();
  TextColumn get markPrice => text().nullable()();
  TextColumn get leverage => text().nullable()();
  TextColumn get marginType => text().nullable()();
  TextColumn get positionMode => text().nullable()();
  DateTimeColumn get recordedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class ExchangeOpenOrders extends Table {
  TextColumn get id => text()();
  TextColumn get accountType => text()();
  TextColumn get keyProfileId => text().withDefault(const Constant('legacy'))();
  TextColumn get accountBindingId => text().nullable()();
  TextColumn get marketType => text()();
  TextColumn get environment => text()();
  TextColumn get source =>
      text().withDefault(const Constant('binanceExchange'))();
  TextColumn get symbol => text()();
  TextColumn get exchangeOrderId => text()();
  TextColumn get clientOrderId => text()();
  TextColumn get side => text()();
  TextColumn get positionSide => text().nullable()();
  TextColumn get orderType => text()();
  TextColumn get timeInForce => text().nullable()();
  TextColumn get price => text()();
  TextColumn get originalQuantity => text()();
  TextColumn get executedQuantity => text()();
  TextColumn get averagePrice => text().nullable()();
  TextColumn get status => text()();
  BoolColumn get reduceOnly => boolean().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get syncedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {accountType, keyProfileId, marketType, exchangeOrderId},
  ];
}

class ExchangeHistoricalOrders extends Table {
  TextColumn get id => text()();
  TextColumn get accountType => text()();
  TextColumn get keyProfileId => text().withDefault(const Constant('legacy'))();
  TextColumn get accountBindingId => text().nullable()();
  TextColumn get marketType => text()();
  TextColumn get environment => text()();
  TextColumn get source =>
      text().withDefault(const Constant('binanceExchange'))();
  TextColumn get symbol => text()();
  TextColumn get exchangeOrderId => text()();
  TextColumn get clientOrderId => text()();
  TextColumn get side => text()();
  TextColumn get positionSide => text().nullable()();
  TextColumn get orderType => text()();
  TextColumn get timeInForce => text().nullable()();
  TextColumn get price => text()();
  TextColumn get originalQuantity => text()();
  TextColumn get executedQuantity => text()();
  TextColumn get averagePrice => text().nullable()();
  TextColumn get quoteQuantity => text().nullable()();
  TextColumn get status => text()();
  BoolColumn get reduceOnly => boolean().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get syncedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {accountType, keyProfileId, marketType, exchangeOrderId},
  ];
}

class ExchangeTrades extends Table {
  TextColumn get id => text()();
  TextColumn get accountType => text()();
  TextColumn get keyProfileId => text().withDefault(const Constant('legacy'))();
  TextColumn get accountBindingId => text().nullable()();
  TextColumn get marketType => text()();
  TextColumn get environment => text()();
  TextColumn get source =>
      text().withDefault(const Constant('binanceExchange'))();
  TextColumn get symbol => text()();
  TextColumn get exchangeTradeId => text()();
  TextColumn get exchangeOrderId => text().nullable()();
  TextColumn get side => text()();
  TextColumn get price => text()();
  TextColumn get quantity => text()();
  TextColumn get quoteQuantity => text()();
  TextColumn get commission => text()();
  TextColumn get commissionAsset => text()();
  TextColumn get realizedPnl => text().nullable()();
  BoolColumn get isMaker => boolean().nullable()();
  DateTimeColumn get tradeTime => dateTime()();
  DateTimeColumn get syncedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {accountType, keyProfileId, marketType, exchangeTradeId},
  ];
}

class FuturesPositions extends Table {
  TextColumn get id => text()();
  TextColumn get accountType =>
      text().withDefault(const Constant('futuresSubAccount'))();
  TextColumn get keyProfileId => text().withDefault(const Constant('legacy'))();
  TextColumn get accountBindingId => text().nullable()();
  TextColumn get symbol => text()();
  TextColumn get positionSide => text()();
  TextColumn get positionAmount => text()();
  TextColumn get entryPrice => text()();
  TextColumn get markPrice => text().nullable()();
  TextColumn get unrealizedPnl => text()();
  TextColumn get leverage => text().nullable()();
  TextColumn get marginType => text().nullable()();
  TextColumn get liquidationPrice => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {keyProfileId, symbol, positionSide},
  ];
}

class FundingFeeRecords extends Table {
  TextColumn get id => text()();
  TextColumn get accountType =>
      text().withDefault(const Constant('futuresSubAccount'))();
  TextColumn get keyProfileId => text().withDefault(const Constant('legacy'))();
  TextColumn get accountBindingId => text().nullable()();
  TextColumn get symbol => text()();
  TextColumn get income => text()();
  TextColumn get asset => text()();
  TextColumn get info => text().nullable()();
  TextColumn get transactionId => text().nullable()();
  DateTimeColumn get incomeTime => dateTime()();
  DateTimeColumn get syncedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {accountType, keyProfileId, symbol, incomeTime, income},
  ];
}

class ReconciliationRuns extends Table {
  TextColumn get id => text()();
  TextColumn get status => text()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  TextColumn get summaryJson => text().nullable()();
  TextColumn get errorMessage => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class ReconciliationDifferences extends Table {
  TextColumn get id => text()();
  TextColumn get runId => text().references(ReconciliationRuns, #id)();
  TextColumn get severity => text()();
  TextColumn get accountType => text()();
  TextColumn get differenceType => text()();
  TextColumn get localValue => text().nullable()();
  TextColumn get exchangeValue => text().nullable()();
  TextColumn get suggestion => text().nullable()();
  DateTimeColumn get firstSeenAt => dateTime()();
  DateTimeColumn get lastSeenAt => dateTime()();
  BoolColumn get stillExists => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

class ExternalAccountEvents extends Table {
  TextColumn get id => text()();
  TextColumn get accountType => text()();
  TextColumn get eventType => text()();
  TextColumn get severity => text()();
  TextColumn get message => text()();
  TextColumn get rawJson => text().nullable()();
  DateTimeColumn get detectedAt => dateTime()();
  DateTimeColumn get resolvedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class AssetClassificationEvents extends Table {
  TextColumn get id => text()();
  TextColumn get asset => text()();
  TextColumn get quantity => text()();
  TextColumn get fromClassification => text()();
  TextColumn get toClassification => text()();
  TextColumn get strategyId => text().nullable().references(Strategies, #id)();
  TextColumn get reason => text()();
  DateTimeColumn get confirmedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
