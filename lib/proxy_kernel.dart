import 'dart:convert';
import 'dart:math';

const String proxyKernelDefaultVersion = 'v1.19.32';
const String proxyKernelBuiltinVersion = 'v1.19.32';
const String proxyKernelBuiltinAsset = 'assets/proxy_kernel/mihomo';
const String proxyKernelAssetName = 'mihomo-android-arm64-v8-v1.19.32.gz';
const String proxyKernelReleaseBase =
    'https://github.com/MetaCubeX/mihomo/releases/download';
const int proxyKernelDefaultMixedPort = 7890;
const int proxyKernelDefaultControllerPort = 9090;
const String proxyKernelSelectGroup = 'PROXY';

String proxyKernelDownloadUrl({String version = proxyKernelDefaultVersion}) {
  final tag = version.startsWith('v') ? version : 'v$version';
  final asset = proxyKernelAssetName.replaceFirst('v1.19.32', tag);
  return '$proxyKernelReleaseBase/$tag/$asset';
}

class ProxyKernelFailure implements Exception {
  ProxyKernelFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class ProxyKernelNode {
  const ProxyKernelNode({required this.name, required this.fields});

  final String name;
  final Map<String, String> fields;

  Map<String, dynamic> toJson() => {'name': name, 'fields': fields};

  factory ProxyKernelNode.fromJson(Map<String, dynamic> json) {
    final fields = <String, String>{};
    final raw = json['fields'];
    if (raw is Map) {
      raw.forEach((key, value) => fields['$key'] = '$value');
    }
    return ProxyKernelNode(name: '${json['name'] ?? ''}', fields: fields);
  }
}

class ProxyKernelState {
  const ProxyKernelState({
    this.supported = true,
    this.installed = false,
    this.builtinAvailable = false,
    this.hasExternal = false,
    this.version = '',
    this.builtinVersion = '',
    this.externalVersion = '',
    this.activeBinary = '',
    this.running = false,
    this.mixedPort = 0,
    this.controllerPort = 0,
    this.selectedNode = '',
    this.logTail = '',
  });

  final bool supported;
  final bool installed;
  final bool builtinAvailable;
  final bool hasExternal;
  final String version;
  final String builtinVersion;
  final String externalVersion;
  final String activeBinary;
  final bool running;
  final int mixedPort;
  final int controllerPort;
  final String selectedNode;
  final String logTail;

  String get displayBuiltinVersion =>
      builtinVersion.isEmpty ? proxyKernelBuiltinVersion : builtinVersion;

  String get displayVersion =>
      activeBinary == 'external' && externalVersion.isNotEmpty
      ? externalVersion
      : displayBuiltinVersion;

  factory ProxyKernelState.fromJson(Map<String, dynamic> json) =>
      ProxyKernelState(
        supported: json['supported'] != false,
        installed: json['installed'] == true,
        builtinAvailable: json['builtinAvailable'] == true,
        hasExternal: json['hasExternal'] == true,
        version: '${json['version'] ?? ''}',
        builtinVersion: '${json['builtinVersion'] ?? ''}',
        externalVersion: '${json['externalVersion'] ?? ''}',
        activeBinary: '${json['activeBinary'] ?? ''}',
        running: json['running'] == true,
        mixedPort: (json['mixedPort'] as num?)?.toInt() ?? 0,
        controllerPort: (json['controllerPort'] as num?)?.toInt() ?? 0,
        selectedNode: '${json['selectedNode'] ?? ''}',
        logTail: '${json['logTail'] ?? ''}',
      );

  factory ProxyKernelState.unsupported() =>
      const ProxyKernelState(supported: false);

  Map<String, dynamic> toJson() => {
    'supported': supported,
    'installed': installed,
    'builtinAvailable': builtinAvailable,
    'hasExternal': hasExternal,
    'version': version,
    'builtinVersion': builtinVersion,
    'externalVersion': externalVersion,
    'activeBinary': activeBinary,
    'running': running,
    'mixedPort': mixedPort,
    'controllerPort': controllerPort,
    'selectedNode': selectedNode,
    'logTail': logTail,
  };
}

class ProxyControllerEntry {
  const ProxyControllerEntry({
    required this.name,
    required this.type,
    this.current = '',
    this.all = const [],
  });

  final String name;
  final String type;
  final String current;
  final List<String> all;

  factory ProxyControllerEntry.fromJson(
    String name,
    Map<String, dynamic> json,
  ) => ProxyControllerEntry(
    name: name,
    type: '${json['type'] ?? ''}',
    current: '${json['now'] ?? ''}',
    all: [for (final item in (json['all'] as List? ?? const [])) '$item'],
  );
}

class ProxyControllerState {
  const ProxyControllerState({this.entries = const []});

  final List<ProxyControllerEntry> entries;

  factory ProxyControllerState.fromJson(Map<String, dynamic> json) {
    final raw = json['proxies'];
    final entries = <ProxyControllerEntry>[];
    if (raw is Map) {
      raw.forEach((key, value) {
        if (value is Map) {
          entries.add(
            ProxyControllerEntry.fromJson(
              '$key',
              Map<String, dynamic>.from(value),
            ),
          );
        }
      });
    }
    return ProxyControllerState(entries: entries);
  }

  ProxyControllerEntry? get selectGroup {
    for (final entry in entries) {
      if (entry.name == proxyKernelSelectGroup) return entry;
    }
    return null;
  }

  List<ProxyControllerEntry> get nodes => [
    for (final entry in entries)
      if (entry.type != 'Selector' &&
          entry.type != 'URLTest' &&
          entry.type != 'Fallback' &&
          entry.type != 'LoadBalance' &&
          entry.name != 'DIRECT' &&
          entry.name != 'REJECT')
        entry,
  ];
}

String proxyKernelRandomSecret() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

int proxyKernelNextFreePort(int candidate, Set<int> taken) {
  var port = candidate;
  while (taken.contains(port) && port < 65535) {
    port++;
  }
  return port;
}

String _decodeSubscriptionText(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    throw ProxyKernelFailure('订阅内容为空');
  }
  if (text.contains('proxies:')) return text;
  final compact = text.replaceAll(RegExp(r'\s+'), '');
  try {
    final decoded = utf8.decode(base64.decode(compact));
    if (decoded.contains('proxies:')) return decoded;
  } on ProxyKernelFailure {
    rethrow;
  } catch (_) {}
  throw ProxyKernelFailure(
    '订阅内容不是 Clash YAML（proxies 列表），且 base64 解码后也不是；'
    '请确认订阅地址返回的是 Clash 格式',
  );
}

List<String> _splitYamlLines(String text) =>
    text.split('\n').map((line) => line.replaceAll('\r', '')).toList();

int _indentOf(String line) {
  var count = 0;
  while (count < line.length && line[count] == ' ') {
    count++;
  }
  return count;
}

String _stripYamlComment(String value) {
  var inSingle = false;
  var inDouble = false;
  for (var i = 0; i < value.length; i++) {
    final char = value[i];
    if (char == "'" && !inDouble) inSingle = !inSingle;
    if (char == '"' && !inSingle) inDouble = !inDouble;
    if (char == '#' && !inSingle && !inDouble) {
      if (i == 0 || value[i - 1] == ' ') return value.substring(0, i).trim();
    }
  }
  return value.trim();
}

String _unquoteYamlScalar(String value) {
  final text = value.trim();
  if (text.length >= 2 &&
      ((text.startsWith('"') && text.endsWith('"')) ||
          (text.startsWith("'") && text.endsWith("'")))) {
    final inner = text.substring(1, text.length - 1);
    if (text.startsWith('"')) {
      return inner
          .replaceAll(r'\"', '"')
          .replaceAll(r'\\', r'\')
          .replaceAll(r'\n', '\n');
    }
    return inner.replaceAll("''", "'");
  }
  return text;
}

List<ProxyKernelNode> parseProxySubscription(String raw) {
  final text = _decodeSubscriptionText(raw);
  final lines = _splitYamlLines(text);
  var proxiesIndent = -1;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty || line.trim().startsWith('#')) continue;
    if (line.trim() == 'proxies:' || line.trim().startsWith('proxies: ')) {
      proxiesIndent = _indentOf(line);
      if (line.trim().startsWith('proxies: [')) {
        throw ProxyKernelFailure('proxies 行内流式列表暂不支持，请用标准多行列表');
      }
      break;
    }
  }
  if (proxiesIndent < 0) {
    throw ProxyKernelFailure('订阅中没有找到顶层 proxies 列表');
  }
  final nodes = <ProxyKernelNode>[];
  var listItemIndent = -1;
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trim();
    if (line.isEmpty || trimmed.startsWith('#')) {
      i++;
      continue;
    }
    final indent = _indentOf(line);
    if (indent <= proxiesIndent && !trimmed.startsWith('- ')) {
      if (nodes.isNotEmpty) break;
      i++;
      continue;
    }
    if (listItemIndent < 0 &&
        indent > proxiesIndent &&
        trimmed.startsWith('- ')) {
      listItemIndent = indent;
    }
    if (indent == listItemIndent && trimmed.startsWith('- ')) {
      final fields = <String, String>{};
      var first = trimmed.substring(2).trim();
      if (first.isNotEmpty) {
        final colon = first.indexOf(':');
        if (colon > 0) {
          fields[first.substring(0, colon).trim()] = _unquoteYamlScalar(
            _stripYamlComment(first.substring(colon + 1)),
          );
        }
      }
      final itemIndent = indent;
      i++;
      final stack = <({int indent, String key})>[];
      while (i < lines.length) {
        final next = lines[i];
        final nextTrimmed = next.trim();
        if (nextTrimmed.isEmpty || nextTrimmed.startsWith('#')) {
          i++;
          continue;
        }
        final nextIndent = _indentOf(next);
        if (nextIndent <= itemIndent) break;
        if (nextTrimmed.startsWith('- ')) break;
        while (stack.isNotEmpty && stack.last.indent >= nextIndent) {
          stack.removeLast();
        }
        final colon = nextTrimmed.indexOf(':');
        if (colon <= 0) {
          i++;
          continue;
        }
        final key = nextTrimmed.substring(0, colon).trim();
        final value = _stripYamlComment(nextTrimmed.substring(colon + 1));
        if (value.isEmpty) {
          stack.add((indent: nextIndent, key: key));
        } else {
          final fullKey = [for (final entry in stack) entry.key, key].join('.');
          fields[fullKey] = _unquoteYamlScalar(value);
        }
        i++;
      }
      final name = fields['name'] ?? '';
      if (name.isEmpty) {
        throw ProxyKernelFailure('订阅里有节点缺少 name，无法生成配置');
      }
      nodes.add(ProxyKernelNode(name: name, fields: fields));
      continue;
    }
    i++;
  }
  if (nodes.isEmpty) {
    throw ProxyKernelFailure('订阅 proxies 列表为空，没有可用节点');
  }
  final seen = <String>{};
  for (final node in nodes) {
    if (!seen.add(node.name)) {
      throw ProxyKernelFailure('订阅里节点名重复：${node.name}');
    }
  }
  return nodes;
}

String _yamlQuote(String value) {
  if (value.isEmpty) return "''";
  if (RegExp(r'^[A-Za-z0-9_.\-/]+$').hasMatch(value)) return value;
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n');
  return '"$escaped"';
}

String _yamlScalar(String value) {
  if (value == 'true' ||
      value == 'false' ||
      value == 'null' ||
      value == '~' ||
      RegExp(r'^-?\d+(\.\d+)?$').hasMatch(value)) {
    return _yamlQuote(value);
  }
  return _yamlQuote(value);
}

void _emitYamlTree(
  StringBuffer buffer,
  Map<String, Object> tree,
  String prefix,
  bool firstLine,
) {
  var first = firstLine;
  tree.forEach((key, value) {
    final lead = first ? '- ' : prefix;
    first = false;
    if (value is Map<String, Object>) {
      buffer.writeln('$lead$key:');
      _emitYamlTree(buffer, value, '$prefix  ', false);
    } else {
      buffer.writeln('$lead$key: ${_yamlScalar(value as String)}');
    }
  });
}

String _emitProxyFields(Map<String, String> fields) {
  final tree = <String, Object>{};
  fields.forEach((key, value) {
    final parts = key.split('.');
    var cursor = tree;
    for (var index = 0; index < parts.length - 1; index++) {
      cursor =
          cursor.putIfAbsent(parts[index], () => <String, Object>{})
              as Map<String, Object>;
    }
    cursor[parts.last] = value;
  });
  final buffer = StringBuffer();
  _emitYamlTree(buffer, tree, '  ', true);
  return buffer.toString();
}

/// 内置最小分流规则：回环与内网地址直连，其余全部走 PROXY 组。
/// 包里没有 GEOIP/GEOSITE 数据库，也不下发规则集文件，所以这里不写
/// 任何地理规则——写了内核也跑不起来。订阅自带可用规则时优先用订阅的
///（见 [extractSubscriptionRules]），没有时才用这套。
const List<String> proxyKernelMinimalRules = [
  'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve',
  'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
  'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve',
  'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve',
  'IP-CIDR,::1/128,DIRECT,no-resolve',
  'IP-CIDR,fc00::/8,DIRECT,no-resolve',
  'IP-CIDR,fe80::/10,DIRECT,no-resolve',
  'MATCH,$proxyKernelSelectGroup',
];

/// 订阅规则里允许直接沿用的简单类型。复合类型（AND/OR/NOT）、规则集
///（RULE-SET）、地理类型（GEOIP/GEOSITE）与脚本类型一律丢掉：它们要么
/// 需要包里没有的数据文件，要么嵌套结构无法按行过滤，写进配置只会让
/// 内核启动失败；丢掉的部分由末尾的 MATCH 兜底走 PROXY，不会断流。
const Set<String> _subscriptionRuleAllowedTypes = {
  'DOMAIN',
  'DOMAIN-SUFFIX',
  'DOMAIN-KEYWORD',
  'DOMAIN-REGEX',
  'IP-CIDR',
  'IP-CIDR6',
  'IP-ASN',
  'SRC-IP-CIDR',
  'SRC-PORT',
  'DST-PORT',
  'PROCESS-NAME',
  'PROCESS-PATH',
  'NETWORK',
  'MATCH',
};

/// 从订阅文本里提取可用的 `rules:` 规则（纯函数，可单测）。
/// 只保留目标是 DIRECT/REJECT/REJECT-DROP/PROXY 组/已知节点名的规则；
/// 指向不存在的策略组的规则丢掉（本应用生成的配置只有一个 PROXY 组）。
/// 订阅无 rules 段、内容非法、或一条都留不下时返回空列表，
/// 调用方随后用 [proxyKernelMinimalRules] 兜底。
List<String> extractSubscriptionRules(String raw, Set<String> nodeNames) {
  String text;
  try {
    text = _decodeSubscriptionText(raw);
  } catch (_) {
    return const [];
  }
  final lines = _splitYamlLines(text);
  var rulesIndent = -1;
  var start = -1;
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    if (trimmed == 'rules:' || trimmed.startsWith('rules: ')) {
      if (trimmed.startsWith('rules: [')) return const [];
      rulesIndent = _indentOf(lines[i]);
      start = i + 1;
      break;
    }
  }
  if (start < 0) return const [];
  final kept = <String>[];
  for (var i = start; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final indent = _indentOf(line);
    if (indent <= rulesIndent && !trimmed.startsWith('- ')) break;
    if (!trimmed.startsWith('- ')) continue;
    final rule = trimmed.substring(2).trim();
    if (rule.isEmpty) continue;
    final usable = _filterSubscriptionRule(rule, nodeNames);
    if (usable != null) kept.add(usable);
  }
  return kept;
}

String? _filterSubscriptionRule(String rule, Set<String> nodeNames) {
  final parts = rule.split(',');
  if (parts.length < 2) return null;
  final type = parts[0].trim().toUpperCase();
  if (!_subscriptionRuleAllowedTypes.contains(type)) return null;
  var targetIndex = parts.length - 1;
  if (parts[targetIndex].trim().toLowerCase() == 'no-resolve') {
    targetIndex--;
    if (targetIndex < 1) return null;
  }
  final target = parts[targetIndex].trim();
  final upper = target.toUpperCase();
  if (upper == 'DIRECT' || upper == 'REJECT' || upper == 'REJECT-DROP') {
    return rule;
  }
  if (target == proxyKernelSelectGroup || nodeNames.contains(target)) {
    return rule;
  }
  return null;
}

String buildProxyKernelConfig({
  required List<ProxyKernelNode> nodes,
  required int mixedPort,
  required int controllerPort,
  required String secret,
  List<String>? rules,
}) {
  if (nodes.isEmpty) {
    throw ProxyKernelFailure('没有节点，无法生成代理内核配置');
  }
  if (mixedPort <= 0 || mixedPort > 65535) {
    throw ProxyKernelFailure('本地代理端口无效：$mixedPort');
  }
  if (controllerPort <= 0 || controllerPort > 65535) {
    throw ProxyKernelFailure('控制端口无效：$controllerPort');
  }
  if (mixedPort == controllerPort) {
    throw ProxyKernelFailure('代理端口与控制端口不能相同');
  }
  final buffer = StringBuffer();
  buffer.writeln('mixed-port: $mixedPort');
  buffer.writeln('allow-lan: false');
  buffer.writeln('mode: rule');
  buffer.writeln('log-level: info');
  buffer.writeln('ipv6: false');
  buffer.writeln('external-controller: 127.0.0.1:$controllerPort');
  buffer.writeln('secret: ${_yamlScalar(secret)}');
  buffer.writeln('proxies:');
  for (final node in nodes) {
    buffer.write(_emitProxyFields(node.fields));
  }
  buffer.writeln('proxy-groups:');
  buffer.writeln('  - name: $proxyKernelSelectGroup');
  buffer.writeln('    type: select');
  buffer.writeln('    proxies:');
  for (final node in nodes) {
    buffer.writeln('      - ${_yamlQuote(node.name)}');
  }
  buffer.writeln('      - DIRECT');
  buffer.writeln('rules:');
  // 订阅规则优先；没有或为空时用内置最小规则。订阅规则里若没有 MATCH
  // 兜底，补一条 MATCH,PROXY，保证所有流量都有去处。
  final effectiveRules = (rules == null || rules.isEmpty)
      ? proxyKernelMinimalRules
      : rules;
  for (final rule in effectiveRules) {
    buffer.writeln('  - $rule');
  }
  final hasMatch = effectiveRules.any(
    (rule) => rule.trim().toUpperCase().startsWith('MATCH,'),
  );
  if (!hasMatch) {
    buffer.writeln('  - MATCH,$proxyKernelSelectGroup');
  }
  return buffer.toString();
}

final RegExp _ipv4Pattern = RegExp(
  r'\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}'
  r'(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b',
);

List<String> extractIpv4Addresses(String text) {
  final found = <String>[];
  final seen = <String>{};
  for (final match in _ipv4Pattern.allMatches(text)) {
    final ip = match.group(0)!;
    final octets = ip.split('.').map(int.parse);
    if (octets.any((value) => value > 255)) continue;
    if (seen.add(ip)) found.add(ip);
  }
  return found;
}
