class ReconciliationDifferenceModel {
  const ReconciliationDifferenceModel({
    required this.severity,
    required this.accountType,
    required this.type,
    this.localValue,
    this.exchangeValue,
    this.suggestion,
  });

  final String severity;
  final String accountType;
  final String type;
  final String? localValue;
  final String? exchangeValue;
  final String? suggestion;
}

class ReconciliationResult {
  const ReconciliationResult({
    required this.runId,
    required this.differences,
  });

  final String runId;
  final List<ReconciliationDifferenceModel> differences;
}
