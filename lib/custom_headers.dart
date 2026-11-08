import 'dart:convert';

class CustomHeaderRule {
  const CustomHeaderRule({
    required this.host,
    required this.name,
    required this.value,
  });

  final String host;
  final String name;
  final String value;

  Map<String, dynamic> toJson() => {
        'host': host,
        'name': name,
        'value': value,
      };

  static CustomHeaderRule? fromJson(dynamic input) {
    if (input is! Map) return null;
    final host = input['host'];
    final name = input['name'];
    final value = input['value'];
    if (host is! String || name is! String || value is! String) return null;
    if (host.trim().isEmpty || name.trim().isEmpty) return null;
    return CustomHeaderRule(host: host, name: name, value: value);
  }

  bool matches(String url) {
    final pattern = host.trim().toLowerCase();
    if (pattern.isEmpty) return false;
    final lowerUrl = url.toLowerCase();
    if (pattern.contains('://') || pattern.contains('/')) {
      return lowerUrl.contains(pattern);
    }
    final uri = Uri.tryParse(url);
    final urlHost = (uri?.host ?? '').toLowerCase();
    if (urlHost.isEmpty) return lowerUrl.contains(pattern);
    if (pattern.contains('*')) {
      final regex = RegExp(
        '^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$',
      );
      return regex.hasMatch(urlHost);
    }
    return urlHost == pattern || urlHost.endsWith('.$pattern');
  }
}

Map<String, String> applyCustomHeaders(
  String url,
  Map<String, String> base, {
  required bool enabled,
  required List<CustomHeaderRule> rules,
}) {
  if (!enabled || rules.isEmpty) return base;
  final result = Map<String, String>.from(base);
  final present = <String>{
    for (final key in base.keys) key.toLowerCase(),
  };
  for (final rule in rules) {
    if (!rule.matches(url)) continue;
    final name = rule.name.trim();
    if (name.isEmpty || rule.value.isEmpty) continue;
    final lowerName = name.toLowerCase();
    if (present.contains(lowerName)) continue;
    result[name] = rule.value;
    present.add(lowerName);
  }
  return result;
}

List<CustomHeaderRule> parseCustomHeaderRules(String raw) {
  try {
    if (raw.trim().isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final rules = <CustomHeaderRule>[];
    for (final item in decoded) {
      final rule = CustomHeaderRule.fromJson(item);
      if (rule != null) rules.add(rule);
    }
    return rules;
  } catch (_) {
    return const [];
  }
}
