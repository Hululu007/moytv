/// 海阔运行时的纯函数帮手：不依赖 Flutter/平台，可单测。
///
/// 这里只放共用的确定性逻辑：备份数据库行转规则、代理里的
/// Cookie 罐、嗅探到的资源地址筛选、摘要/HMAC 计算。WebView
/// 与本地服务的接线仍在 runner/store 里。
library;

import 'package:crypto/crypto.dart';

/// SQLite 文件魔数：`SQLite format 3\0`。
bool isSqliteBytes(List<int> bytes) {
  const magic = <int>[
    0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, 0x6F, 0x72, 0x6D, 0x61,
    0x74, 0x20, 0x33, 0x00,
  ];
  if (bytes.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }
  return true;
}

/// 备份数据库 `articlelistrule` 一行转海阔规则 Map。
///
/// 列名换成规则 JSON 的键名（`searchfind`→`searchFind`、
/// `firstheader`→`firstHeader`、`group_lpcolumn`→`group`）；值里
/// 的字符串 `'None'`（数据库导出时的空值写法）一律当空；`version`
/// 数字转字符串；`pages` 保持原样（JSON 字符串或数组都由运行时再解）。
/// 标题为空的行返回 null（调用方跳过）。
Map<String, dynamic>? haikuoDbRowToRule(Map<String, dynamic> row) {
  final title = _dbText(row['title']);
  if (title.isEmpty) return null;
  String text(Object? value) => _dbText(value);
  final rule = <String, dynamic>{
    'title': title,
    'url': text(row['url']),
    'find_rule': text(row['find_rule']),
    'detail_find_rule': text(row['detail_find_rule']),
    'sdetail_find_rule': text(row['sdetail_find_rule']),
    'searchFind': text(row['searchfind']),
    'search_url': text(row['search_url']),
    'prerule': text(row['prerule']),
    'storage': text(row['storage']),
    'last_chapter_rule': text(row['last_chapter_rule']),
    'chapter_find': text(row['chapter_find']),
    'movie_find': text(row['movie_find']),
    'col_type': text(row['col_type']),
    'detail_col_type': text(row['detail_col_type']),
    'sdetail_col_type': text(row['sdetail_col_type']),
    'class_name': text(row['class_name']),
    'class_url': text(row['class_url']),
    'area_name': text(row['area_name']),
    'area_url': text(row['area_url']),
    'sort_name': text(row['sort_name']),
    'sort_url': text(row['sort_url']),
    'year_name': text(row['year_name']),
    'year_url': text(row['year_url']),
    'firstHeader': text(row['firstheader']),
    'group': text(row['group_lpcolumn']),
    'type': text(row['type']),
    'ua': text(row['ua']),
    'proxy': text(row['proxy']),
    'author': text(row['author']),
    'icon': text(row['icon']),
    'version': _dbVersion(row['version']),
  };
  final pages = row['pages'];
  if (pages is String) {
    rule['pages'] = pages;
  } else if (pages is List) {
    rule['pages'] = pages;
  } else {
    rule['pages'] = '[]';
  }
  return rule;
}

String _dbText(Object? value) {
  if (value == null) return '';
  final text = '$value'.trim();
  if (text == 'None' || text == 'null') return '';
  return text;
}

String _dbVersion(Object? value) {
  if (value == null) return '';
  final text = '$value'.trim();
  if (text == 'None' || text == 'null') return '';
  return text;
}

/// 规则 `proxy` 字段归一：空、`false`、`0`、`none`（不分大小写）
/// 都表示不走代理；否则当代理地址，没有 scheme 时补 `http://`。
/// 返回 null 表示不设代理。
///
/// 含 `=>` 的改写行不是 HTTP 代理地址，一律返回 null（改写由
/// JS 侧 `rawHttpEx` 按 [parseHaikuoProxyRewrites] 处理）；以前
/// 这里把整字段当代理地址是误读，改写行会被当成代理主机。
String? parseHaikuoProxy(String? raw) {
  final value = (raw ?? '').trim();
  if (value.isEmpty) return null;
  if (value.contains('=>')) return null;
  final lower = value.toLowerCase();
  if (lower == 'false' || lower == '0' || lower == 'none' ||
      lower == 'no' || lower == 'off') {
    return null;
  }
  if (lower.contains('://')) return value;
  return 'http://$value';
}

/// PBKDF2 密钥派生（RFC 2898）：[password]/[salt] 为原始字节，
/// [iterations] 轮次（调用方封顶），[keyBytes] 派生字节数，
/// [hash] 为 `sha1`/`sha256`/`sha512`（默认 sha1，CryptoJS 默认一致）。
/// 供 CryptoJS.PBKDF2 经 /__crypto 单次请求完成全部轮次。
List<int> haikuoPbkdf2({
  required List<int> password,
  required List<int> salt,
  required int iterations,
  required int keyBytes,
  String hash = 'sha1',
}) {
  final Hash digest;
  switch (hash.toLowerCase()) {
    case 'sha256':
      digest = sha256;
    case 'sha512':
      digest = sha512;
    default:
      digest = sha1;
  }
  final hmac = Hmac(digest, password);
  final hashLen = digest.convert(const []).bytes.length;
  final blocks = (keyBytes + hashLen - 1) ~/ hashLen;
  final out = <int>[];
  for (var block = 1; block <= blocks; block++) {
    final blockInput = <int>[
      ...salt,
      (block >> 24) & 0xFF,
      (block >> 16) & 0xFF,
      (block >> 8) & 0xFF,
      block & 0xFF,
    ];
    var u = hmac.convert(blockInput).bytes;
    final t = List<int>.from(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    out.addAll(t);
  }
  return out.sublist(0, keyBytes.clamp(0, out.length));
}

/// 通配包含匹配：[pattern] 里的 `*` 匹配任意字符，命中 URL 的任意
/// 一部分即算命中（官方嗅探规则语义）。供嗅探 blockRules 的导航拦截用。
bool wildcardContains(String url, String pattern) {
  if (pattern.isEmpty) return false;
  final regex = RegExp(
    RegExp.escape(pattern).replaceAll(r'\*', '.*'),
  );
  return regex.hasMatch(url);
}
/// 每行在第一个 `=>` 处拆成一对；无 `=>` 的行忽略。
/// 返回空列表表示该字段没有改写行。
List<(String, String)> parseHaikuoProxyRewrites(String? raw) {
  final out = <(String, String)>[];
  final value = raw ?? '';
  if (!value.contains('=>')) return out;
  for (final line in value.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final idx = trimmed.indexOf('=>');
    if (idx <= 0) continue;
    final from = trimmed.substring(0, idx).trim();
    final to = trimmed.substring(idx + 2).trim();
    if (from.isEmpty || to.isEmpty) continue;
    out.add((from, to));
  }
  return out;
}

/// 对 [url] 应用改写行：默认包含匹配，命中第一条就把命中的那段
/// 换成新地址；都不命中原样返回。
String applyHaikuoProxyRewrites(String url, List<(String, String)> rewrites) {
  for (final (from, to) in rewrites) {
    final idx = url.indexOf(from);
    if (idx >= 0) {
      return url.substring(0, idx) + to + url.substring(idx + from.length);
    }
  }
  return url;
}

/// 按主机存 Cookie 的内存罐（仅当次运行页会话内有效）。
///
/// 只存 `name=value`，忽略过期时间等属性（会话级嗅探/取数够用）；
/// 同名后来居上；`Set-Cookie` 多行逐行解析。
class HaikuoCookieJar {
  final Map<String, Map<String, String>> _byHost = {};

  /// 把一组 `Set-Cookie` 响应头存进 [host] 的罐子里。
  void store(String host, Iterable<String> setCookieHeaders) {
    if (host.isEmpty) return;
    final jar = _byHost.putIfAbsent(host, () => <String, String>{});
    for (final header in setCookieHeaders) {
      final first = header.split(';').first.trim();
      final eq = first.indexOf('=');
      if (eq <= 0) continue;
      final name = first.substring(0, eq).trim();
      final value = first.substring(eq + 1).trim();
      if (name.isEmpty) continue;
      jar[name] = value;
    }
  }

  /// 直接写一条 `name=value`（或 `a=b; c=d`）进 [host] 的罐子。
  void setCookie(String host, String cookie) {
    if (host.isEmpty || cookie.trim().isEmpty) return;
    store(host, cookie.split(';').map((part) => part.trim()));
  }

  /// 取 [host] 的 `Cookie` 请求头值；没有存过返回空串。
  String headerFor(String host) {
    final jar = _byHost[host];
    if (jar == null || jar.isEmpty) return '';
    return jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  bool get isEmpty => _byHost.values.every((jar) => jar.isEmpty);
}

/// 十六进制字符串转字节：非法字符先剔除，末尾落单的半个字节丢弃。
List<int> haikuoHexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp('[^0-9a-fA-F]'), '');
  final bytes = <int>[];
  for (var i = 0; i + 1 < clean.length; i += 2) {
    bytes.add(int.parse(clean.substring(i, i + 2), radix: 16));
  }
  return bytes;
}

/// 摘要计算（供运行时 `/__crypto` 与 CryptoJS 子集用）。
///
/// [op] 为 `md5`/`sha1`/`sha256`/`sha512` 之一；未知 op 返回空串，
/// 调用方不编结果。
String haikuoHashHex(String op, List<int> bytes) {
  final digest = switch (op) {
    'md5' => md5.convert(bytes),
    'sha1' => sha1.convert(bytes),
    'sha256' => sha256.convert(bytes),
    'sha512' => sha512.convert(bytes),
    _ => null,
  };
  return digest?.toString() ?? '';
}

/// HMAC 计算：[op] 为 `md5`/`sha1`/`sha256`/`sha512` 之一，
/// 未知 op 返回空串。
String haikuoHmacHex(String op, List<int> key, List<int> message) {
  final hash = switch (op) {
    'md5' => md5,
    'sha1' => sha1,
    'sha256' => sha256,
    'sha512' => sha512,
    _ => null,
  };
  if (hash == null) return '';
  return Hmac(hash, key).convert(message).toString();
}

/// 规则标题归一：去 🔞 前缀、花体/全角字母数字折成 ASCII、去首尾
/// 空白、转小写。供跨规则 `?rule=` 匹配与预置模块映射用：规则标题
/// 里常见的花体写法（如 `𝟕𝐌𝐌𝐓𝐕`）与普通写法（`7MMTV`）须能对上。
/// JS 侧用 `String.normalize('NFKC')` 做同一件事，两边结果须一致。
String normalizeRuleTitle(String title) {
  final buffer = StringBuffer();
  for (final rune in title.runes) {
    if (rune == 0x1F51E) continue; // 🔞
    final folded = _foldMathAlphanumeric(rune);
    if (folded != null) {
      buffer.write(folded);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString().trim().toLowerCase();
}

/// 数学字母数字区（U+1D400–U+1D7FF）与全角区折成 ASCII；不在表里的
/// 返回 null（调用方原样保留）。只覆盖连续排布的样式块（粗体、斜体、
/// 粗斜体、双线、等宽、无衬线各式）与数字块；带缺口的手写体只认首字，
/// 其余缺口位命中概率极低，精确匹配已先行兜底。
String? _foldMathAlphanumeric(int rune) {
  // 全角：Ａ-Ｚ ａ-ｚ ０-９。
  if (rune >= 0xFF21 && rune <= 0xFF3A) {
    return String.fromCharCode(0x41 + rune - 0xFF21);
  }
  if (rune >= 0xFF41 && rune <= 0xFF5A) {
    return String.fromCharCode(0x61 + rune - 0xFF41);
  }
  if (rune >= 0xFF10 && rune <= 0xFF19) {
    return String.fromCharCode(0x30 + rune - 0xFF10);
  }
  // 数学区数字块：每块 10 个，起址分别为粗体/双线/无衬线/无衬线粗体/等宽。
  const digitBases = [0x1D7CE, 0x1D7D8, 0x1D7E2, 0x1D7EC, 0x1D7F6];
  for (final base in digitBases) {
    if (rune >= base && rune < base + 10) {
      return String.fromCharCode(0x30 + rune - base);
    }
  }
  // 数学区字母块：每种样式大写 26 + 小写 26 连续排布。
  const letterBases = [
    (0x1D400, 0x1D41A), // 粗体
    (0x1D434, 0x1D44E), // 斜体
    (0x1D468, 0x1D482), // 粗斜体
    (0x1D504, 0x1D51E), // 花体
    (0x1D538, 0x1D552), // 双线
    (0x1D5A0, 0x1D5BA), // 无衬线
    (0x1D5D4, 0x1D5EE), // 无衬线粗体
    (0x1D608, 0x1D622), // 无衬线斜体
    (0x1D63C, 0x1D656), // 无衬线粗斜体
    (0x1D670, 0x1D68A), // 等宽
    (0x1D4D0, 0x1D4EA), // 粗手写体
  ];
  for (final (upperBase, lowerBase) in letterBases) {
    if (rune >= upperBase && rune < upperBase + 26) {
      return String.fromCharCode(0x41 + rune - upperBase);
    }
    if (rune >= lowerBase && rune < lowerBase + 26) {
      return String.fromCharCode(0x61 + rune - lowerBase);
    }
  }
  if (rune == 0x1D49C) return 'A'; // 手写体 𝒜（该区唯一无缺口首字）
  return null;
}

/// 在 [titles] 里找与 [query] 同一规则的标题：精确相等优先，其次
/// 去 🔞、其次归一化相等。找不到返回 null（调用方报明确错误）。
String? matchRuleTitle(String query, Iterable<String> titles) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return null;
  for (final title in titles) {
    if (title == trimmed) return title;
  }
  final stripped = trimmed.replaceAll('🔞', '').trim();
  for (final title in titles) {
    if (title.replaceAll('🔞', '').trim() == stripped) return title;
  }
  final wanted = normalizeRuleTitle(trimmed);
  for (final title in titles) {
    if (normalizeRuleTitle(title) == wanted) return title;
  }
  return null;
}

/// 预置模块解析（`/__files/` 回落的第 2–5 步；第 1 步会话文件由调用方先查）。
///
/// [requestBasename] 是请求的文件基名（如 `Apollo.js`、`𝟕𝐌𝐌𝐓𝐕.js`）；
/// [ruleTitle] 是当前规则标题；[manifest] 是
/// `assets/haikuo_modules_manifest.json` 的 `rules` 映射（标题 → 文件名列表）。
/// 返回命中的清单文件名，命中不了返回 null（调用方报数据缺口，不伪造文件）。
/// 顺序：(2) 当前规则映射（请求基名 == 规则标题 + `.js` 时取含 `Apollo` 的
/// 文件）；(3) 清单文件名 `__` 之后的部分 == 请求基名；(4) 精确文件名；
/// (5) 归一化（去 🔞 + 花体折叠 + 小写）相等。
String? resolvePresetModule({
  required String requestBasename,
  required String ruleTitle,
  required Map<String, List<String>> manifest,
}) {
  final base = requestBasename.trim();
  if (base.isEmpty) return null;
  String? manifestKeyFor(String title) {
    for (final key in manifest.keys) {
      if (key == title) return key;
    }
    return matchRuleTitle(title, manifest.keys);
  }

  // (2) 当前规则映射：动态 `MY_RULE.title + '.js'` 取 Apollo 引擎。
  final ruleKey = manifestKeyFor(ruleTitle);
  if (ruleKey != null) {
    final wanted = '${normalizeRuleTitle(ruleTitle)}.js';
    if (normalizeRuleTitle(base) == wanted) {
      for (final file in manifest[ruleKey]!) {
        if (file.contains('Apollo')) return file;
      }
    }
  }
  // (3) `__` 后缀匹配。
  for (final files in manifest.values) {
    for (final file in files) {
      final sep = file.indexOf('__');
      final suffix = sep >= 0 ? file.substring(sep + 2) : file;
      if (suffix == base) return file;
    }
  }
  // (4) 精确文件名。
  for (final files in manifest.values) {
    for (final file in files) {
      if (file == base) return file;
    }
  }
  // (5) 归一化匹配。
  final wantedNorm = normalizeRuleTitle(base);
  for (final files in manifest.values) {
    for (final file in files) {
      if (normalizeRuleTitle(file) == wantedNorm) return file;
    }
  }
  return null;
}

/// `startProxyServer` 代理地址的路径解析：`/__proxyserver/<id>/...`
/// 取出 `<id>`；形态不对返回 null。
String? parseProxyServerId(String path) {
  const prefix = '/__proxyserver/';
  if (!path.startsWith(prefix)) return null;
  final rest = path.substring(prefix.length);
  if (rest.isEmpty) return null;
  final id = rest.split('/').first;
  return id.isEmpty ? null : id;
}

/// 从嗅探到的资源地址里挑一个可播地址。
///
/// [entries] 按加载顺序；[includeRules] 为空表示不限制，`*` 通配
/// 任意字符；[excludeRules] 命中的一律跳过。只认常见媒体后缀与
/// m3u8/mp4 特征串。找不到返回空串。
String pickSniffedVideoUrl(
  List<String> entries, {
  List<String> includeRules = const [],
  List<String> excludeRules = const [],
}) {
  // 官方语义是包含匹配（`video*m3u*.ts` 命中整条 URL 的一部分），
  // 不是整串锚定：规则写短模式是常态，锚定会漏掉带前后缀的地址。
  bool matches(String url, String pattern) {
    final regex = RegExp(
      RegExp.escape(pattern).replaceAll(r'\*', '.*'),
    );
    return regex.hasMatch(url);
  }

  bool isMedia(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') ||
        lower.contains('.mp4') ||
        lower.contains('.flv') ||
        lower.contains('.mkv') ||
        lower.contains('.ts') ||
        lower.contains('.m4a') ||
        lower.contains('.mp3') ||
        lower.contains('.webm') ||
        lower.contains('.mov');
  }

  for (final entry in entries) {
    final url = entry.trim();
    if (url.isEmpty || !url.startsWith('http')) continue;
    if (!isMedia(url)) continue;
    if (excludeRules.any((rule) => matches(url, rule))) continue;
    if (includeRules.isNotEmpty &&
        !includeRules.any((rule) => matches(url, rule))) {
      continue;
    }
    return url;
  }
  return '';
}
