import 'package:decimal/decimal.dart';

class RiskDecision {
  const RiskDecision.allowed()
      : allowed = true,
        reason = '';

  const RiskDecision.blocked(this.reason) : allowed = false;

  final bool allowed;
  final String reason;
}

class RiskManager {
  RiskManager({
    Decimal? maxSpotOrderNotional,
    Decimal? maxFuturesOrderNotional,
    Decimal? maxFuturesShortNotional,
    this.maxLeverage = 1,
    this.maxConsecutiveFailures = 3,
  })  : maxSpotOrderNotional = maxSpotOrderNotional ?? Decimal.fromInt(20),
        maxFuturesOrderNotional =
            maxFuturesOrderNotional ?? Decimal.fromInt(20),
        maxFuturesShortNotional =
            maxFuturesShortNotional ?? Decimal.fromInt(50);

  final Decimal maxSpotOrderNotional;
  final Decimal maxFuturesOrderNotional;
  final Decimal maxFuturesShortNotional;
  final int maxLeverage;
  final int maxConsecutiveFailures;

  RiskDecision validateSpotOrder({required Decimal notional}) {
    if (notional > maxSpotOrderNotional) {
      return RiskDecision.blocked(
        'Spot order notional exceeds $maxSpotOrderNotional USDT',
      );
    }
    return const RiskDecision.allowed();
  }

  RiskDecision validateFuturesOrder({
    required Decimal notional,
    required String side,
    required bool reduceOnly,
    bool allowExistingLongExposure = false,
    required Decimal currentShortNotional,
    required Decimal currentLongNotional,
  }) {
    if (!reduceOnly && notional > maxFuturesOrderNotional) {
      return RiskDecision.blocked(
        'Futures order notional exceeds $maxFuturesOrderNotional USDT',
      );
    }
    if (side == 'BUY' && !reduceOnly) {
      return const RiskDecision.blocked(
        'Non reduceOnly BUY is disabled for live futures',
      );
    }
    if (currentLongNotional > Decimal.zero && !allowExistingLongExposure) {
      return const RiskDecision.blocked(
        'Long futures exposure is disabled for live futures',
      );
    }
    if (side == 'SELL' && !reduceOnly) {
      final projected = currentShortNotional + notional;
      if (projected > maxFuturesShortNotional) {
        return RiskDecision.blocked(
          'Futures short notional exceeds $maxFuturesShortNotional USDT',
        );
      }
    }
    if (reduceOnly && side == 'BUY' && notional > currentShortNotional) {
      return const RiskDecision.blocked(
        'ReduceOnly buy exceeds current short exposure',
      );
    }
    return const RiskDecision.allowed();
  }

  RiskDecision validateLeverage(int leverage) {
    if (leverage > maxLeverage) {
      return RiskDecision.blocked(
        'Leverage $leverage exceeds max leverage $maxLeverage',
      );
    }
    return const RiskDecision.allowed();
  }
}
