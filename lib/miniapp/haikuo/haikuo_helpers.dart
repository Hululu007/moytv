/// 海阔运行时的纯函数帮手：不依赖 Flutter/平台，可单测。
///
/// 这里只放共用的确定性逻辑：备份数据库行转规则、代理里的
/// Cookie 罐、嗅探到的资源地址筛选、摘要/HMAC 计算。WebView
/// 与本地服务的接线仍在 runner/store 里。
library;

import 'dart:convert';
import 'dart:io';

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

/// 页面沉浸与播放器全屏取“或”：任一为真就藏状态栏
/// （SystemUiMode.immersiveSticky），否则 edgeToEdge。
bool haikuoImmersiveUi({
  required bool pageImmersive,
  required bool inlineFullscreen,
}) =>
    pageImmersive || inlineFullscreen;

/// 下载中心/分享落盘用的安全文件名：只取 basename，禁路径穿越。
/// 名字为空、`.`、`..` 时返回 null（调用方拒绝该请求）。
String? haikuoSafeFileName(String name) {
  final base = name.replaceAll('\\', '/').split('/').last.trim();
  if (base.isEmpty || base == '.' || base == '..') return null;
  return base;
}

/// `share://` 的目标是否指向规则本地文件（`hiker://files/…`）。
bool haikuoIsHikerFilesTarget(String target) =>
    target.startsWith('hiker://files/');

/// `hiker://files/…` 目标的文件键：去掉前缀与查询串/片段并解码。
/// 非 files 目标返回空串。
String haikuoShareFileKey(String target) {
  if (!haikuoIsHikerFilesTarget(target)) return '';
  var rest = target.substring('hiker://files/'.length);
  final cut = rest.indexOf(RegExp('[?#]'));
  if (cut >= 0) rest = rest.substring(0, cut);
  try {
    return Uri.decodeComponent(rest);
  } catch (_) {
    return rest;
  }
}

/// 下载条目排序：mtime 新的在前，同时间按名字升序。返回新列表。
List<Map<String, dynamic>> sortHaikuoDownloadEntries(
  List<Map<String, dynamic>> entries,
) {
  final sorted = [...entries];
  sorted.sort((a, b) {
    final aTime = (a['mtime'] as num?)?.toInt() ?? 0;
    final bTime = (b['mtime'] as num?)?.toInt() ?? 0;
    if (aTime != bTime) return bTime.compareTo(aTime);
    return '${a['name'] ?? ''}'.compareTo('${b['name'] ?? ''}');
  });
  return sorted;
}

/// E33 会话变量表：putVar/getVar/clearVar 的 Dart 侧进程内存储。
/// 随进程生死，重启即失（指南语义），绝不写盘。运行页持有一个
/// 静态实例供全部规则页共享；JS 侧镜像经 `/__vars` 同步。
class HaikuoSessionVars {
  final Map<String, String> _vars = {};

  /// 整表快照（新 Map，调用方改不动原表）。
  Map<String, String> snapshot() => Map<String, String>.from(_vars);

  /// 应用一条写操作：`set`（key/value）、`clear`（key）、
  /// `clearAll`。未知 op 忽略，不抛错。
  void apply(Map<String, dynamic> payload) {
    final op = '${payload['op'] ?? ''}';
    if (op == 'set') {
      _vars['${payload['key'] ?? ''}'] = '${payload['value'] ?? ''}';
    } else if (op == 'clear') {
      _vars.remove('${payload['key'] ?? ''}');
    } else if (op == 'clearAll') {
      _vars.clear();
    }
  }
}

/// GZIP 压缩（`/__crypto` 的 `gzip` op 用，Java GZIPOutputStream 走它）。
/// SDK 的 gzip 在 dart:io（GZipCodec），dart:convert 里没有。
List<int> haikuoGzipBytes(List<int> bytes) => GZipCodec().encode(bytes);

/// GZIP 解压（`/__crypto` 的 `gunzip` op 用，Java GZIPInputStream 走它）。
/// 输入不是合法 gzip 时抛 FormatException，调用方转为空结果。
List<int> haikuoGunzipBytes(List<int> bytes) => GZipCodec().decode(bytes);

/// Raw deflate 解压（`/__crypto` 的 `inflate` op 用，Java
/// InflaterInputStream 走它）。输入不是合法 raw deflate 流时抛
/// FormatException，调用方转为空结果。
List<int> haikuoInflateBytes(List<int> bytes) =>
    ZLibDecoder(raw: true).convert(bytes);

/// E111-F1：从请求头里拆出 User-Agent（大小写不敏感，只取第一个
/// 非空值）。WebView 的 `loadRequest` headers 改不了 UA，须走
/// `setUserAgent`，拆出的头不再进 `loadRequest`（避免重复）。
({String userAgent, Map<String, String> headers}) haikuoSplitUserAgent(
  Map<String, String> headers,
) {
  var ua = '';
  final rest = <String, String>{};
  headers.forEach((key, value) {
    if (key.toLowerCase() == 'user-agent') {
      if (ua.isEmpty) ua = value;
    } else {
      rest[key] = value;
    }
  });
  return (userAgent: ua, headers: rest);
}

/// E111-F3：checkJs 通过哨兵。checkJs 求值结果为 null/undefined/
/// false/"" 时回空串，其余一律回此哨兵（不再 `String(__r)`，空数组
/// 之类的边角不再误判为不通过）。
const haikuoCheckJsPassSentinel = '__HK_PASS__';

/// E111-F2：嗅探与 WebView 取码共用的网页桥垫片（同一构造，两处
/// 不得各写一份）。注入后页面里有：`window._getUrls()`（资源地址
/// 数组）、`window.fy_bridge_app`/`window.fba`（`getUrls` 数组形态、
/// `log` 空实现、`getCookie` 回注入时的 Cookie 串——值滞后至多一拍、
/// `writeFile` 推入 `__hkWriteFiles` 待 Dart 侧收走、`getUa` 回
/// `navigator.userAgent`、`setWebTitle` 空实现）。
/// `__hkWriteFiles` 用 `||[]` 保留已攒的条目，重复注入不丢。
String haikuoBridgePadScript(String pageCookies) {
  final cookiesJson = jsonEncode(pageCookies);
  return 'window.__hkPageCookies=$cookiesJson;'
      'window.__hkWriteFiles=window.__hkWriteFiles||[];'
      'window._getUrls=function(){try{return performance.getEntriesByType('
      '"resource").map(function(e){return e.name;});}catch(e){return [];}};'
      'window.fy_bridge_app={getUrls:window._getUrls,'
      'log:function(){},'
      'getCookie:function(){return window.__hkPageCookies||"";},'
      'writeFile:function(p,c){window.__hkWriteFiles.push({path:String(p||""),'
      'content:String(c==null?"":c)});},'
      'getUa:function(){return navigator.userAgent;},'
      'setWebTitle:function(){}};'
      'window.fba=window.fy_bridge_app;';
}

/// G11：x5 单行网页的 Dart 侧布局换算，照搬运行时 `parseX5Desc` 的
/// 分段语义（`&&` 切段、去空白，`list` 忽略、`float`/`top` 置模式位、
/// `auto`→240、`video`→宽 9/16 高、`screen`→视口高、`100%`→视口高、
/// `screen-N`→视口高减 N、纯数字→像素、`N%`→视口高占比；后出现的
/// 高度段覆盖前者，与 JS 循环一致）。
/// `viewportHeight` 是规则 WebView 区的可用高（屏高减内容顶偏移），
/// `viewportWidth` 是区宽，`topOffset` 是实测顶栏高（top 模式无显式
/// 高度时，行高 = 可用高减顶栏高，即贴着顶栏下方铺到底，与旧 CSS
/// `top:120px;bottom:0` 同形、偏移改实测）。高度夹在 0 与可用高之间。
/// `auto` 保持 240（0 条规则用真自适应，指南算法无定义，不猜）。
({double height, bool floatMode, bool topMode, bool videoMode})
haikuoX5RowLayout({
  required String desc,
  required double viewportHeight,
  required double viewportWidth,
  required double topOffset,
}) {
  // 负尺寸输入一律按 0 计（调用方已夹取，此处再兜一层，防负高进布局）。
  final vh = viewportHeight < 0 ? 0.0 : viewportHeight;
  final vw = viewportWidth < 0 ? 0.0 : viewportWidth;
  final top = topOffset < 0 ? 0.0 : topOffset;
  var floatMode = false;
  var topMode = false;
  var videoMode = false;
  double? heightPx;
  for (final rawPart in desc.split('&&')) {
    final p = rawPart.trim();
    if (p.isEmpty || p == 'list') continue;
    if (p == 'float') {
      floatMode = true;
      continue;
    }
    if (p == 'top') {
      topMode = true;
      floatMode = true;
      continue;
    }
    if (p == 'auto') {
      heightPx = 240;
      continue;
    }
    if (p == 'video') {
      videoMode = true;
      heightPx = null;
      continue;
    }
    if (p == 'screen' || p == '100%') {
      heightPx = vh;
      continue;
    }
    final screenMinus = RegExp(r'^screen-(\d+)$').firstMatch(p);
    if (screenMinus != null) {
      heightPx =
          vh - (double.tryParse(screenMinus.group(1)!) ?? 0);
      continue;
    }
    if (RegExp(r'^\d+$').hasMatch(p)) {
      heightPx = double.parse(p);
      continue;
    }
    if (RegExp(r'^\d+%$').hasMatch(p)) {
      heightPx =
          vh * (double.parse(p.substring(0, p.length - 1)) / 100);
      continue;
    }
  }
  double height;
  if (videoMode) {
    height = vw * 9 / 16;
  } else if (heightPx != null) {
    height = heightPx;
  } else if (topMode) {
    height = vh - top;
  } else {
    height = 240;
  }
  if (height < 0) height = 0;
  if (height > vh) height = vh;
  return (
    height: height,
    floatMode: floatMode,
    topMode: topMode,
    videoMode: videoMode,
  );
}

/// G11：`window.__haikuoUrlInterceptor` 回值的决策解析。规则求值回
/// 的 JSON 串只能是 `{d:"allow"}`、`{d:"block"}`、
/// `{d:"exec",code:"…"}` 三种；解析失败、未知 d 值、exec 带空代码
/// 一律按放行处理（fail-open，导航不受壳子解析故障牵连）。
/// 入参须是已剥掉 Android 侧 JSON 引号的正文（见 `_sniffResultText`）。
({String action, String code}) haikuoParseX5Intercept(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map) return (action: 'allow', code: '');
    final action = '${decoded['d'] ?? ''}';
    if (action == 'block') return (action: 'block', code: '');
    if (action == 'exec') {
      final code = '${decoded['code'] ?? ''}';
      if (code.isEmpty) return (action: 'allow', code: '');
      return (action: 'exec', code: code);
    }
    return (action: 'allow', code: '');
  } catch (_) {
    return (action: 'allow', code: '');
  }
}

/// G11/R6§14：原生 x5 行的页内桥脚本（紧跟 [haikuoBridgePadScript]
/// 之后注入同一页面，垫片每次重建 `fy_bridge_app` 对象，桥方法须
/// 每次都重新挂上去，故两者永远拼成一次注入）。
///
/// 内容：`HaikuoX5Bridge` 通道投递（JSON `{method,args,id}`，仅异步）、
/// `$$$` 页内序列化器（镜像规则侧链式构造器，只产字符串，不访问
/// `lazyMap`——`lazyRule` 产 `url@lazyRule=IIFE` 串供规则侧求值）、
/// `fy_bridge_app`/`fba` 上的通道方法（`open`/`playVideo`/
/// `parseLazyRule`/`parseLazyRuleAsync`/只写四方法/`setWebUa`/
/// `hideLoading`/`refreshPage`/`back`/`toast`/`fetch`）与
/// `base64Encode`（与规则侧同义的 UTF-8 安全版）。
///
/// 故意不提供的 4 个方法（R6 UNFILLABLE，不伪造）：`getHeaderUrl`
/// （无契约）、`getVar`（同步读无异步通道可满足）、`getInternalJs`
/// （语义未知）、`openThirdApp`（无启动路径，规则均有 `&&` 守卫）。
/// `fetch` 回 Promise（异步通道无同步返回值可给），60 秒无回传则
/// 按空串兑现。脚本内只用双引号字符串（供 Node 抽取测试按
/// `r'…'` 段拼回原文），不得引入单引号。
String haikuoX5BridgeScript() {
  return r'window.__hkX5Seq=window.__hkX5Seq||0;'
      r'window.__hkX5Fetches=window.__hkX5Fetches||{};'
      r'window.__hkX5Post=function(m,a,id){try{window.HaikuoX5Bridge.postMessage(JSON.stringify({method:m,args:a||[],id:(id===undefined?0:id)}));}catch(e){}};'
      r'window.__hkX5ResolveFetch=function(id,res){try{var r=window.__hkX5Fetches[id];delete window.__hkX5Fetches[id];if(r)r(res);}catch(e){}};'
      r'window.__hkX5Base64Encode=function(t){try{return btoa(unescape(encodeURIComponent(String(t==null?"":t))));}catch(e){return "";}};'
      r'if(typeof window.base64Encode!=="function"){window.base64Encode=window.__hkX5Base64Encode;}'
      r'window.$$$=function(sel,headers,titleArg){'
      r'var url=(typeof sel==="string")?sel:"";'
      r'var selectOptions=null;var selectCol;var selectTitle;'
      r'if(Array.isArray(sel)){selectOptions=sel.map(function(v){return String(v);});if(typeof headers==="number")selectCol=headers;if(typeof titleArg==="string")selectTitle=titleArg;}'
      r'function fnSrc(fn){return (typeof fn==="function")?String(fn):String(fn==null?"":fn);}'
      r'function serArg(a){if(typeof a==="function")return fnSrc(a);if(a===undefined)return "undefined";try{var s=JSON.stringify(a);return (s===undefined)?JSON.stringify(String(a)):s;}catch(e){return JSON.stringify(String(a));}}'
      r'function toStr(fn){var a=[];for(var i=1;i<arguments.length;i++)a.push(serArg(arguments[i]));return "("+fnSrc(fn)+")("+a.join(",")+")";}'
      r'var chained={};'
      r'chained.rule=function(fn){return url+"@rule=.js:("+fnSrc(fn)+")()";};'
      r'chained.lazyRule=function(fn){var a=[];for(var i=1;i<arguments.length;i++)a.push(arguments[i]);if(!a.length)a.push(url);else if(a[0]===undefined)a[0]=url;return url+"@lazyRule="+toStr.apply(null,[fn].concat(a));};'
      r'chained.image=function(fn,s1,s2){var a=[];if(s1!==undefined)a.push(serArg(s1));if(s2!==undefined)a.push(serArg(s2));if(!a.length)a.push("input");return url+"@headers="+JSON.stringify(headers||{})+"@js=("+fnSrc(fn)+")("+a.join(",")+")";};'
      r'chained.x5Rule=function(fn){return "javascript:("+fnSrc(fn)+")()";};'
      r'chained.input=function(fn){return "input://"+JSON.stringify({value:url,js:"("+fnSrc(fn)+")(input)"});};'
      r'chained.confirm=function(fn){return "confirm://"+url+".js:("+fnSrc(fn)+")()";};'
      r'chained.select=function(fn){var a=[];for(var i=1;i<arguments.length;i++)a.push(arguments[i]);var cfg={options:(selectOptions?selectOptions.slice():[url]),js:toStr.apply(null,[fn].concat(a))};if(selectTitle!==undefined)cfg.title=selectTitle;if(typeof selectCol==="number")cfg.col=selectCol;return "select://"+JSON.stringify(cfg);};'
      r'chained.b64=function(){return chained;};'
      r'return chained;};'
      r'(function(){var b=window.fy_bridge_app||{};window.fy_bridge_app=b;window.fba=b;'
      r'b.base64Encode=window.__hkX5Base64Encode;'
      r'b.open=function(arg){var s=(typeof arg==="string")?arg:JSON.stringify(arg||{});window.__hkX5Post("open",[s]);};'
      r'b.playVideo=function(u){window.__hkX5Post("playVideo",[String(u||"")]);};'
      r'b.parseLazyRule=function(s){window.__hkX5Post("parseLazyRule",[String(s==null?"":s)]);};'
      r'b.parseLazyRuleAsync=function(s){window.__hkX5Post("parseLazyRuleAsync",[String(s==null?"":s)]);};'
      r'b.putVar=function(k,v){window.__hkX5Post("putVar",[String(k==null?"":k),String(v==null?"":v)]);};'
      r'b.clearVar=function(k){window.__hkX5Post("clearVar",[(k===undefined||k===null)?null:String(k)]);};'
      r'b.putMyVar=function(k,v){window.__hkX5Post("putMyVar",[String(k==null?"":k),String(v==null?"":v)]);};'
      r'b.clearMyVar=function(k){window.__hkX5Post("clearMyVar",[(k===undefined||k===null)?null:String(k)]);};'
      r'b.setWebUa=function(ua){window.__hkX5Post("setWebUa",[String(ua||"")]);};'
      r'b.hideLoading=function(){window.__hkX5Post("hideLoading",[]);};'
      r'b.refreshPage=function(){window.__hkX5Post("refreshPage",[]);};'
      r'b.back=function(){window.__hkX5Post("back",[]);};'
      r'b.toast=function(m){window.__hkX5Post("toast",[String(m==null?"":m)]);};'
      r'b.fetch=function(u,o){return new Promise(function(resolve){var id=++window.__hkX5Seq;window.__hkX5Fetches[id]=resolve;window.__hkX5Post("fetch",[String(u||""),o||null],id);setTimeout(function(){if(window.__hkX5Fetches[id]){delete window.__hkX5Fetches[id];resolve("");}},60000);});};'
      r'})();';
}


/// W6 floatVideo：嗅探资源枚举脚本——与 `_sniffTick` video 形态同一
/// 串抽成共享常量，两路不得各写一份（枚举口径一致，改一处即两处）。
/// 回 `performance` 资源记录的地址数组；页内无 performance 时回空数组。
const haikuoResourceEntriesScript =
    '(function(){try{return performance.getEntriesByType("resource")'
    '.map(function(e){return e.name;});}catch(e){return [];}})()';

/// W6 floatVideo：暂停页内全部 `<video>` 元素的脚本——与 `_hideX5Row`
/// 同一串抽成共享常量；求值失败静默（try/catch 在串内）。
const haikuoPausePageVideosScript =
    'try{document.querySelectorAll("video").forEach(function(v){v.pause();});}catch(e){}';

/// W6 floatVideo 门控：只有严格的 `true` 才开（对应规则侧
/// `extra.floatVideo === true`；`1`、`'true'`、缺失一律不开）。
bool haikuoFloatVideoGate(Object? value) => value == true;

/// W6 floatVideo：连续求值失败达此次数即停轮询，静默回落只显示网页
/// （单拍失败跳过即可，页未加载完是常态；持续失败才停，避免空转）。
const haikuoFloatVideoMaxFailures = 10;

/// W6 floatVideo：是否应继续轮询。门控/可见/未检出/未关闭/
/// 失败未超上限五项全满足才轮询；任一项不满足即停（静默回落）。
bool haikuoFloatVideoShouldPoll({
  required bool floatVideo,
  required bool visible,
  required bool hasVideo,
  required bool dismissed,
  required int consecutiveFailures,
}) =>
    floatVideo &&
    visible &&
    !hasVideo &&
    !dismissed &&
    consecutiveFailures < haikuoFloatVideoMaxFailures;

/// W6 floatVideo：从资源地址里挑可播地址。复用嗅探现成件
/// [pickSniffedVideoUrl]（不另写嗅探器）：无 include 规则（x5 行
/// extra 无 videoRules），`blockRules` 作排除规则（广告地址不进浮层）。
String haikuoFloatVideoPick(List<String> entries, List<String> blockRules) =>
    pickSniffedVideoUrl(entries, excludeRules: blockRules);
