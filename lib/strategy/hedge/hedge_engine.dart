import 'dart:convert';

import 'package:decimal/decimal.dart';

import '../../services/binance/trading/binance_symbol_rules.dart';

enum HedgeActionType {
  increaseShort,
  reduceShort,
  syncOnly,
  skipTooSmall,
  skipDisabled,
  skipRiskBlocked,
}

enum HedgeStage {
  noExposure,
  aboveMidNoHedge,
  belowMidLightHedge,
  nearLowerMediumHedge,
  belowLowerStrongHedge,
  deepBelowLowerEmergencyHedge,
  needIncreaseShort,
  needReduceShort,
  skipTooSmall,
  dryRunOnly,
  blockedByRisk,
  externalPositionDetected,
  syncRequired,
  error,
}

class HedgeGridExposure {
  const HedgeGridExposure({
    required this.gridId,
    required this.cycleNumber,
    required this.buyFilledQty,
    required this.sellFilledQty,
    required this.phase,
  });

  final String gridId;
  final int cycleNumber;
  final Decimal buyFilledQty;
  final Decimal sellFilledQty;
  final String phase;

  Decimal get exposedQty {
    final exposed = buyFilledQty - sellFilledQty;
    return exposed > Decimal.zero ? exposed : Decimal.zero;
  }

  bool get countsForHedge {
    return const {
          'buyFilled',
          'sellSubmitting',
          'sellOpen',
          'sellPartiallyFilled',
          'replacementMissing',
          'hedgePending',
        }.contains(phase) &&
        exposedQty > Decimal.zero;
  }
}

class HedgeCalculationInput {
  const HedgeCalculationInput({
    required this.hedgeEnabled,
    required this.hedgeDryRun,
    required this.hedgeRatio,
    required this.currentPrice,
    required this.lowerPrice,
    required this.upperPrice,
    required this.currentShortQty,
    required this.markPrice,
    required this.minAdjustQty,
    required this.minAdjustNotional,
    required this.maxHedgeQty,
    required this.futuresRules,
    required this.gridExposures,
    required this.maxHedgeRatio,
    required this.emergencyHedgeRatio,
    required this.hedgeReleaseBufferPct,
    this.hedgePower = 2,
    this.blockReason,
  });

  final bool hedgeEnabled;
  final bool hedgeDryRun;
  final Decimal hedgeRatio;
  final Decimal currentPrice;
  final Decimal lowerPrice;
  final Decimal upperPrice;
  final Decimal currentShortQty;
  final Decimal markPrice;
  final Decimal minAdjustQty;
  final Decimal minAdjustNotional;
  final Decimal maxHedgeQty;
  final BinanceSymbolRules? futuresRules;
  final List<HedgeGridExposure> gridExposures;
  final int hedgePower;
  final Decimal maxHedgeRatio;
  final Decimal emergencyHedgeRatio;
  final Decimal hedgeReleaseBufferPct;
  final String? blockReason;
}

class HedgeCalculationResult {
  const HedgeCalculationResult({
    required this.exposedSpotQty,
    required this.targetShortQty,
    required this.currentShortQty,
    required this.diffQty,
    required this.actionType,
    required this.actionQty,
    required this.actionNotional,
    required this.dryRun,
    required this.reason,
    required this.debug,
    required this.hedgeStage,
    required this.hedgeStageText,
    required this.hedgeReasonText,
    required this.hedgeNextActionText,
    required this.currentPrice,
    required this.midPrice,
    required this.lowerPrice,
    required this.riskScore,
    required this.effectiveHedgeRatio,
  });

  final Decimal exposedSpotQty;
  final Decimal targetShortQty;
  final Decimal currentShortQty;
  final Decimal diffQty;
  final HedgeActionType actionType;
  final Decimal actionQty;
  final Decimal actionNotional;
  final bool dryRun;
  final String reason;
  final HedgeCalculationDebug debug;
  final HedgeStage hedgeStage;
  final String hedgeStageText;
  final String hedgeReasonText;
  final String hedgeNextActionText;
  final Decimal currentPrice;
  final Decimal midPrice;
  final Decimal lowerPrice;
  final Decimal riskScore;
  final Decimal effectiveHedgeRatio;

  String get side {
    return switch (actionType) {
      HedgeActionType.increaseShort => 'SELL',
      HedgeActionType.reduceShort => 'BUY',
      _ => '-',
    };
  }

  bool get reduceOnly => actionType == HedgeActionType.reduceShort;
  bool get canSubmit =>
      actionType == HedgeActionType.increaseShort ||
      actionType == HedgeActionType.reduceShort;
}

class HedgeCalculationDebug {
  const HedgeCalculationDebug({
    required this.exposedSpotBtc,
    required this.hedgeRatio,
    required this.effectiveHedgeRatio,
    required this.currentPrice,
    required this.midPrice,
    required this.lowerPrice,
    required this.riskScore,
    required this.rawTargetShortQty,
    required this.futuresStepSize,
    required this.adjustedTargetShortQty,
    required this.currentShortQty,
    required this.rawDiffQty,
    required this.adjustedDiffQty,
    required this.markPrice,
    required this.notional,
    required this.minAdjustQty,
    required this.minAdjustNotional,
    required this.futuresMinQty,
    required this.futuresMinNotional,
    required this.skipReason,
  });

  final Decimal exposedSpotBtc;
  final Decimal hedgeRatio;
  final Decimal effectiveHedgeRatio;
  final Decimal currentPrice;
  final Decimal midPrice;
  final Decimal lowerPrice;
  final Decimal riskScore;
  final Decimal rawTargetShortQty;
  final Decimal futuresStepSize;
  final Decimal adjustedTargetShortQty;
  final Decimal currentShortQty;
  final Decimal rawDiffQty;
  final Decimal adjustedDiffQty;
  final Decimal markPrice;
  final Decimal notional;
  final Decimal minAdjustQty;
  final Decimal minAdjustNotional;
  final Decimal futuresMinQty;
  final Decimal futuresMinNotional;
  final String skipReason;

  String toJsonText() {
    return jsonEncode({
      'exposedSpotBtc': exposedSpotBtc.toString(),
      'hedgeRatio': hedgeRatio.toString(),
      'effectiveHedgeRatio': effectiveHedgeRatio.toString(),
      'currentPrice': currentPrice.toString(),
      'midPrice': midPrice.toString(),
      'lowerPrice': lowerPrice.toString(),
      'riskScore': riskScore.toString(),
      'rawTargetShortQty': rawTargetShortQty.toString(),
      'futuresStepSize': futuresStepSize.toString(),
      'adjustedTargetShortQty': adjustedTargetShortQty.toString(),
      'currentShortQty': currentShortQty.toString(),
      'rawDiffQty': rawDiffQty.toString(),
      'adjustedDiffQty': adjustedDiffQty.toString(),
      'markPrice': markPrice.toString(),
      'notional': notional.toString(),
      'minAdjustQty': minAdjustQty.toString(),
      'minAdjustNotional': minAdjustNotional.toString(),
      'futuresMinQty': futuresMinQty.toString(),
      'futuresMinNotional': futuresMinNotional.toString(),
      'skipReason': skipReason,
    });
  }
}

class HedgeEngine {
  const HedgeEngine();

  HedgeCalculationResult calculate(HedgeCalculationInput input) {
    final exposed = input.gridExposures
        .where((grid) => grid.countsForHedge)
        .fold(Decimal.zero, (sum, grid) => sum + grid.exposedQty);
    final priceModel = _priceModel(input);
    final ratio = exposed <= Decimal.zero ? Decimal.zero : priceModel.ratio;
    final rawTarget = exposed * ratio;
    final rules = input.futuresRules;
    final target = rawTarget;
    final diff = target - input.currentShortQty;
    final absDiff = diff.abs();
    final actionQty = rules == null ? absDiff : rules.quantizeQuantity(absDiff);
    final actionNotional = actionQty * input.markPrice;

    if (!input.hedgeEnabled) {
      return _result(
        input,
        exposed: exposed,
        target: target,
        diff: diff,
        actionType: HedgeActionType.skipDisabled,
        reason: 'hedge disabled',
        rawTarget: rawTarget,
        priceModel: priceModel,
        actionQty: actionQty,
        actionNotional: actionNotional,
      );
    }
    if (exposed <= Decimal.zero) {
      if (input.currentShortQty > Decimal.zero &&
          rules != null &&
          actionQty >= input.minAdjustQty &&
          actionNotional >= input.minAdjustNotional) {
        final reduceQty =
            actionQty > input.currentShortQty
                ? input.currentShortQty
                : actionQty;
        return _result(
          input,
          exposed: exposed,
          target: Decimal.zero,
          diff: Decimal.zero - input.currentShortQty,
          actionType: HedgeActionType.reduceShort,
          actionQty: rules.quantizeQuantity(reduceQty),
          actionNotional: rules.quantizeQuantity(reduceQty) * input.markPrice,
          reason: 'no exposed spot BTC; reduce strategy hedge only',
          rawTarget: Decimal.zero,
          priceModel: priceModel,
        );
      }
      return _result(
        input,
        exposed: exposed,
        target: Decimal.zero,
        diff: Decimal.zero - input.currentShortQty,
        actionType: HedgeActionType.syncOnly,
        reason: 'no BUY filled and SELL unfilled exposure',
        rawTarget: Decimal.zero,
        priceModel: priceModel,
        actionQty: Decimal.zero,
        actionNotional: Decimal.zero,
      );
    }
    if (input.blockReason != null && input.blockReason!.isNotEmpty) {
      return _result(
        input,
        exposed: exposed,
        target: target,
        diff: diff,
        actionType: HedgeActionType.skipRiskBlocked,
        reason: input.blockReason!,
        rawTarget: rawTarget,
        priceModel: priceModel,
        actionQty: actionQty,
        actionNotional: actionNotional,
      );
    }
    if (rules == null) {
      return _result(
        input,
        exposed: exposed,
        target: target,
        diff: diff,
        actionType: HedgeActionType.skipRiskBlocked,
        reason: 'futures rules missing',
        rawTarget: rawTarget,
        priceModel: priceModel,
        actionQty: actionQty,
        actionNotional: actionNotional,
      );
    }
    if (ratio == Decimal.zero && input.currentShortQty <= Decimal.zero) {
      return _result(
        input,
        exposed: exposed,
        target: Decimal.zero,
        diff: Decimal.zero,
        actionType: HedgeActionType.syncOnly,
        reason: 'price above strategy mid; hedge ratio is 0',
        rawTarget: Decimal.zero,
        priceModel: priceModel,
        actionQty: Decimal.zero,
        actionNotional: Decimal.zero,
      );
    }

    if (actionQty < input.minAdjustQty ||
        actionQty < rules.minQty ||
        actionNotional < input.minAdjustNotional ||
        actionNotional < rules.minNotional) {
      final skipReason = _smallSkipReason(
        actionQty: actionQty,
        actionNotional: actionNotional,
        input: input,
        rules: rules,
      );
      return _result(
        input,
        exposed: exposed,
        target: target,
        diff: diff,
        actionType: HedgeActionType.skipTooSmall,
        actionQty: actionQty,
        actionNotional: actionNotional,
        reason: skipReason,
        rawTarget: rawTarget,
        priceModel: priceModel,
      );
    }
    if (target > input.maxHedgeQty) {
      return _result(
        input,
        exposed: exposed,
        target: target,
        diff: diff,
        actionType: HedgeActionType.skipRiskBlocked,
        actionQty: actionQty,
        actionNotional: actionNotional,
        reason: 'target short exceeds max hedge quantity',
        rawTarget: rawTarget,
        priceModel: priceModel,
      );
    }
    if (diff > Decimal.zero) {
      return _result(
        input,
        exposed: exposed,
        target: target,
        diff: diff,
        actionType: HedgeActionType.increaseShort,
        actionQty: actionQty,
        actionNotional: actionNotional,
        reason: 'current short below target',
        rawTarget: rawTarget,
        priceModel: priceModel,
      );
    }
    if (diff < Decimal.zero) {
      final releaseLine =
          priceModel.midPrice *
          (Decimal.fromInt(1) + input.hedgeReleaseBufferPct);
      final obviousReduce =
          target * Decimal.parse('1.2') < input.currentShortQty;
      if (input.currentPrice <= releaseLine && !obviousReduce) {
        return _result(
          input,
          exposed: exposed,
          target: target,
          diff: diff,
          actionType: HedgeActionType.skipTooSmall,
          actionQty: Decimal.zero,
          actionNotional: Decimal.zero,
          reason:
              'release buffer not reached; currentPrice ${input.currentPrice} <= $releaseLine',
          rawTarget: rawTarget,
          priceModel: priceModel,
        );
      }
      final reduceQty =
          actionQty > input.currentShortQty ? input.currentShortQty : actionQty;
      return _result(
        input,
        exposed: exposed,
        target: target,
        diff: diff,
        actionType: HedgeActionType.reduceShort,
        actionQty: rules.quantizeQuantity(reduceQty),
        actionNotional: rules.quantizeQuantity(reduceQty) * input.markPrice,
        reason: 'current short above target',
        rawTarget: rawTarget,
        priceModel: priceModel,
      );
    }
    return _result(
      input,
      exposed: exposed,
      target: target,
      diff: diff,
      actionType: HedgeActionType.syncOnly,
      reason: 'short position matches target',
      rawTarget: rawTarget,
      priceModel: priceModel,
      actionQty: actionQty,
      actionNotional: actionNotional,
    );
  }

  HedgeCalculationResult _result(
    HedgeCalculationInput input, {
    required Decimal exposed,
    required Decimal target,
    required Decimal diff,
    required HedgeActionType actionType,
    Decimal? actionQty,
    Decimal? actionNotional,
    required String reason,
    required Decimal rawTarget,
    required _HedgePriceModel priceModel,
  }) {
    final qty = actionQty ?? Decimal.zero;
    final rules = input.futuresRules;
    final notional = actionNotional ?? (qty * input.markPrice);
    final stage = _stageFor(
      input: input,
      exposed: exposed,
      actionType: actionType,
      reason: reason,
      priceModel: priceModel,
    );
    final stageText = _stageText(stage);
    final reasonText = _reasonText(
      stage: stage,
      input: input,
      exposed: exposed,
      target: target,
      diff: diff,
      reason: reason,
      priceModel: priceModel,
    );
    final nextText = _nextActionText(stage, input, actionType);
    return HedgeCalculationResult(
      exposedSpotQty: exposed,
      targetShortQty: target,
      currentShortQty: input.currentShortQty,
      diffQty: diff,
      actionType: actionType,
      actionQty: qty,
      actionNotional: notional,
      dryRun: input.hedgeDryRun,
      reason: reason,
      hedgeStage: stage,
      hedgeStageText: stageText,
      hedgeReasonText: reasonText,
      hedgeNextActionText: nextText,
      currentPrice: input.currentPrice,
      midPrice: priceModel.midPrice,
      lowerPrice: input.lowerPrice,
      riskScore: priceModel.riskScore,
      effectiveHedgeRatio: priceModel.ratio,
      debug: HedgeCalculationDebug(
        exposedSpotBtc: exposed,
        hedgeRatio: input.hedgeRatio,
        effectiveHedgeRatio: priceModel.ratio,
        currentPrice: input.currentPrice,
        midPrice: priceModel.midPrice,
        lowerPrice: input.lowerPrice,
        riskScore: priceModel.riskScore,
        rawTargetShortQty: rawTarget,
        futuresStepSize: rules?.stepSize ?? Decimal.zero,
        adjustedTargetShortQty:
            rules == null ? target : rules.quantizeQuantity(target),
        currentShortQty: input.currentShortQty,
        rawDiffQty: rawTarget - input.currentShortQty,
        adjustedDiffQty: qty,
        markPrice: input.markPrice,
        notional: notional,
        minAdjustQty: input.minAdjustQty,
        minAdjustNotional: input.minAdjustNotional,
        futuresMinQty: rules?.minQty ?? Decimal.zero,
        futuresMinNotional: rules?.minNotional ?? Decimal.zero,
        skipReason: reason,
      ),
    );
  }

  String _smallSkipReason({
    required Decimal actionQty,
    required Decimal actionNotional,
    required HedgeCalculationInput input,
    required BinanceSymbolRules rules,
  }) {
    final reasons = <String>[];
    if (actionQty < input.minAdjustQty) {
      reasons.add(
        'adjustedDiffQty $actionQty < minAdjustQty ${input.minAdjustQty}',
      );
    }
    if (actionQty < rules.minQty) {
      reasons.add('adjustedDiffQty $actionQty < futuresMinQty ${rules.minQty}');
    }
    if (actionNotional < input.minAdjustNotional) {
      reasons.add(
        'notional $actionNotional < minAdjustNotional ${input.minAdjustNotional}',
      );
    }
    if (actionNotional < rules.minNotional) {
      reasons.add(
        'notional $actionNotional < futuresMinNotional ${rules.minNotional}',
      );
    }
    return reasons.isEmpty
        ? 'diff below min adjust or Binance filters'
        : reasons.join('; ');
  }

  Decimal _clamp(Decimal value, Decimal min, Decimal max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  _HedgePriceModel _priceModel(HedgeCalculationInput input) {
    final maxRatio =
        input.maxHedgeRatio == Decimal.zero
            ? _clamp(input.hedgeRatio, Decimal.zero, Decimal.fromInt(1))
            : _clamp(input.maxHedgeRatio, Decimal.zero, Decimal.fromInt(1));
    final emergency = _clamp(
      input.emergencyHedgeRatio,
      Decimal.zero,
      Decimal.fromInt(1),
    );
    final mid = ((input.lowerPrice + input.upperPrice) / Decimal.fromInt(2))
        .toDecimal(scaleOnInfinitePrecision: 12);
    final deepLine = input.lowerPrice * Decimal.parse('0.95');
    if (input.currentPrice <= deepLine) {
      return _HedgePriceModel(
        midPrice: mid,
        riskScore: Decimal.fromInt(1),
        ratio: emergency,
        priceStage: HedgeStage.deepBelowLowerEmergencyHedge,
      );
    }
    if (input.currentPrice <= input.lowerPrice) {
      return _HedgePriceModel(
        midPrice: mid,
        riskScore: Decimal.fromInt(1),
        ratio: maxRatio,
        priceStage: HedgeStage.belowLowerStrongHedge,
      );
    }
    if (input.currentPrice >= mid || mid <= input.lowerPrice) {
      return _HedgePriceModel(
        midPrice: mid,
        riskScore: Decimal.zero,
        ratio: Decimal.zero,
        priceStage: HedgeStage.aboveMidNoHedge,
      );
    }
    final rawScore = ((mid - input.currentPrice) / (mid - input.lowerPrice))
        .toDecimal(scaleOnInfinitePrecision: 12);
    final riskScore = _clamp(rawScore, Decimal.zero, Decimal.fromInt(1));
    var powered = Decimal.fromInt(1);
    for (var i = 0; i < input.hedgePower; i += 1) {
      powered *= riskScore;
    }
    final ratio = _clamp(powered * maxRatio, Decimal.zero, Decimal.fromInt(1));
    final priceStage =
        riskScore >= Decimal.parse('0.7')
            ? HedgeStage.nearLowerMediumHedge
            : HedgeStage.belowMidLightHedge;
    return _HedgePriceModel(
      midPrice: mid,
      riskScore: riskScore,
      ratio: ratio,
      priceStage: priceStage,
    );
  }

  HedgeStage _stageFor({
    required HedgeCalculationInput input,
    required Decimal exposed,
    required HedgeActionType actionType,
    required String reason,
    required _HedgePriceModel priceModel,
  }) {
    if (reason.contains('external futures position')) {
      return HedgeStage.externalPositionDetected;
    }
    if (actionType == HedgeActionType.skipRiskBlocked) {
      return HedgeStage.blockedByRisk;
    }
    if (exposed <= Decimal.zero && actionType == HedgeActionType.reduceShort) {
      return HedgeStage.needReduceShort;
    }
    if (exposed <= Decimal.zero) {
      return HedgeStage.noExposure;
    }
    if (actionType == HedgeActionType.skipTooSmall) {
      return HedgeStage.skipTooSmall;
    }
    if (actionType == HedgeActionType.increaseShort) {
      return HedgeStage.needIncreaseShort;
    }
    if (actionType == HedgeActionType.reduceShort) {
      return HedgeStage.needReduceShort;
    }
    return priceModel.priceStage;
  }

  String _stageText(HedgeStage stage) {
    return switch (stage) {
      HedgeStage.noExposure => '暂无策略 BTC 暴露',
      HedgeStage.aboveMidNoHedge => '价格在策略中线上方，暂不对冲',
      HedgeStage.belowMidLightHedge => '价格低于策略中线，轻度保护对冲',
      HedgeStage.nearLowerMediumHedge => '价格接近策略下限，中度保护对冲',
      HedgeStage.belowLowerStrongHedge => '价格跌破策略下限，强保护对冲',
      HedgeStage.deepBelowLowerEmergencyHedge => '深度跌破下限，应急保护对冲',
      HedgeStage.needIncreaseShort => '当前空单不足，建议增加对冲',
      HedgeStage.needReduceShort => '当前空单过多，建议 reduceOnly 平空',
      HedgeStage.skipTooSmall => '调整数量太小，暂不操作',
      HedgeStage.dryRunOnly => 'Dry Run 预览模式',
      HedgeStage.blockedByRisk => '风险检查未通过，禁止对冲',
      HedgeStage.externalPositionDetected => '检测到外部合约仓位',
      HedgeStage.syncRequired => '需要同步现货和合约状态',
      HedgeStage.error => '对冲计算异常',
    };
  }

  String _reasonText({
    required HedgeStage stage,
    required HedgeCalculationInput input,
    required Decimal exposed,
    required Decimal target,
    required Decimal diff,
    required String reason,
    required _HedgePriceModel priceModel,
  }) {
    final base =
        '当前有 $exposed BTC 属于“BUY已成交、SELL未成交”的策略暴露。'
        '当前价格 ${input.currentPrice}，策略中线 ${priceModel.midPrice}，'
        '策略下限 ${input.lowerPrice}，风险分数 ${priceModel.riskScore}，'
        '目标对冲比例 ${priceModel.ratio * Decimal.fromInt(100)}%。'
        '目标空单 $target BTC，当前空单 ${input.currentShortQty} BTC，'
        '需要调整 $diff BTC。';
    if (stage == HedgeStage.noExposure) {
      return '当前没有 BUY 已成交且 SELL 未成交的网格，因此不需要开合约空单。'
          '当前价格 ${input.currentPrice}，策略中线 ${priceModel.midPrice}，策略下限 ${input.lowerPrice}。';
    }
    if (stage == HedgeStage.aboveMidNoHedge) {
      return '$base 价格仍高于策略中间价，上涨到 SELL 的概率较高。为了减少空单磨损，目标对冲比例为 0%。';
    }
    if (stage == HedgeStage.skipTooSmall) {
      return '$base 本次跳过原因：$reason。为了减少手续费和频繁交易磨损，系统跳过本次调整。';
    }
    if (stage == HedgeStage.blockedByRisk ||
        stage == HedgeStage.externalPositionDetected) {
      return '$base 风险阻断原因：$reason。';
    }
    if (stage == HedgeStage.needIncreaseShort) {
      return '$base 目标空单数量大于当前合约空单数量，因此需要增加空单。';
    }
    if (stage == HedgeStage.needReduceShort) {
      return '$base 当前目标空单低于实际合约空单，可能是价格回到安全区域，或者 SELL 已成交导致暴露 BTC 减少。';
    }
    return '$base $reason。';
  }

  String _nextActionText(
    HedgeStage stage,
    HedgeCalculationInput input,
    HedgeActionType actionType,
  ) {
    if (input.hedgeDryRun &&
        (actionType == HedgeActionType.increaseShort ||
            actionType == HedgeActionType.reduceShort)) {
      return '当前是 Dry Run 模式，本次只显示建议，不会真实下单。确认计算正确后，可以切换到手动执行模式。';
    }
    return switch (stage) {
      HedgeStage.noExposure => '等待现货 BUY 成交后再重新计算对冲。',
      HedgeStage.aboveMidNoHedge => '如果价格跌破策略中线，将开始按价格位置逐步提高对冲比例。',
      HedgeStage.belowMidLightHedge => '如果价格继续接近下限，对冲比例会继续提高。',
      HedgeStage.nearLowerMediumHedge => '如果价格跌破下限，将进入强保护阶段，并停止新的 BUY。',
      HedgeStage.belowLowerStrongHedge => '保留已有 SELL，等待反弹成交，或由用户决定是否手动处理风险。',
      HedgeStage.deepBelowLowerEmergencyHedge => '建议人工确认是否执行更高比例对冲或暂停策略。',
      HedgeStage.needIncreaseShort => '如果开启手动执行，可以点击“执行建议开空”。',
      HedgeStage.needReduceShort => '可以使用 reduceOnly BUY 平掉多余空单，禁止开多。',
      HedgeStage.skipTooSmall => '等待价格变化或暴露 BTC 变化后再重新计算。',
      HedgeStage.dryRunOnly => '确认计算正确后，可以切换到手动执行模式。',
      HedgeStage.blockedByRisk => '请先完成 REST 对账并修复异常状态。',
      HedgeStage.externalPositionDetected => '请人工确认归属，确认前禁止自动开平空。',
      HedgeStage.syncRequired => '点击“同步现货订单”和“同步 Futures 仓位”。',
      HedgeStage.error => '查看错误信息并重新同步。',
    };
  }
}

class _HedgePriceModel {
  const _HedgePriceModel({
    required this.midPrice,
    required this.riskScore,
    required this.ratio,
    required this.priceStage,
  });

  final Decimal midPrice;
  final Decimal riskScore;
  final Decimal ratio;
  final HedgeStage priceStage;
}
