import 'dart:convert';

import 'package:crypto/crypto.dart';

class BinanceSignatureService {
  const BinanceSignatureService();

  String canonicalQuery(Map<String, Object?> params) {
    final entries = _sortedEntries(params);
    return entries
        .map((entry) {
          final value = entry.value;
          final encodedKey = Uri.encodeQueryComponent(entry.key);
          final encodedValue = Uri.encodeQueryComponent(value.toString());
          return '$encodedKey=$encodedValue';
        })
        .join('&');
  }

  String hmacSha256({required String secretKey, required String payload}) {
    final key = utf8.encode(secretKey);
    final bytes = utf8.encode(payload);
    return Hmac(sha256, key).convert(bytes).toString();
  }

  Map<String, Object?> sign({
    required String secretKey,
    required Map<String, Object?> params,
  }) {
    final entries = _sortedEntries(params);
    final ordered = <String, Object?>{};
    for (final entry in entries) {
      ordered[entry.key] = entry.value;
    }
    final payload = canonicalQuery(ordered);
    ordered['signature'] = hmacSha256(secretKey: secretKey, payload: payload);
    return ordered;
  }

  List<MapEntry<String, Object?>> _sortedEntries(Map<String, Object?> params) {
    return params.entries.where((entry) => entry.value != null).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
  }
}
