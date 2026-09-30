import 'package:get/get.dart';

class LiveTradingGateService extends GetxService {
  final liveTradingEnabled = false.obs;
  final warningConfirmed = false.obs;
  final disableReason = ''.obs;
  final activeScope = 'global'.obs;
  final RxSet<String> _enabledScopes = <String>{}.obs;

  void resetForAppStart() {
    _enabledScopes.clear();
    setActiveScope('global');
    disable(reason: 'app start');
  }

  void setActiveScope(String scope) {
    final normalized = normalizeScope(scope);
    activeScope.value = normalized;
    liveTradingEnabled.value = _enabledScopes.contains(normalized);
  }

  bool isEnabledForScope(String scope) {
    return _enabledScopes.contains(normalizeScope(scope));
  }

  void disable({String reason = '', String? scope}) {
    final normalized = normalizeScope(scope ?? activeScope.value);
    _enabledScopes.remove(normalized);
    if (activeScope.value == normalized) {
      liveTradingEnabled.value = false;
    }
    warningConfirmed.value = false;
    disableReason.value = reason;
  }

  void setEnabled(bool value, {String? scope}) {
    final normalized = normalizeScope(scope ?? activeScope.value);
    if (!value) {
      disable(scope: normalized);
    } else {
      _enabledScopes.add(normalized);
      if (activeScope.value == normalized) {
        liveTradingEnabled.value = true;
      }
      warningConfirmed.value = true;
      disableReason.value = '';
      markActivity();
    }
  }

  void setWarningConfirmed(bool value) {
    warningConfirmed.value = value;
  }

  void markActivity() {
    if (!liveTradingEnabled.value) {
      return;
    }
    disableReason.value = '';
  }

  static String scopeFor({required String symbol, String? keyProfileId}) {
    final normalizedSymbol = symbol.toUpperCase();
    final profile =
        keyProfileId == null || keyProfileId.trim().isEmpty
            ? 'legacy'
            : keyProfileId.trim();
    return '$normalizedSymbol.$profile';
  }

  static String normalizeScope(String scope) {
    final value = scope.trim();
    return value.isEmpty ? 'global' : value;
  }
}
