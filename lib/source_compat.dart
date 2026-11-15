import 'dart:convert';

/// 订阅配置 / 站点接口兼容层（纯解析，不碰网络与存储）。
///
/// 形态证据：
/// - jar 类名 api：jar_site_config.dart 的 _classNameOfApi 早已把带点
///   的非 csp_ api 当类名；zakatv_builtin.dart 全是
///   com.github.catvod.spider.* 全类名。
/// - 远程 JS 蜘蛛：drpy-node 解包样本 spider/catvod/alist.js 注释里的
///   配置示例即 {"type":3,"api":"http://xxx.com/alist.js"}。
/// - 解析 type 1：drpy-node 解包样本 config/parses.conf 注明
///   “0 普通解析、1 json 解析、2 并发多 json 解析、3 聚合解析”，
///   spider/php/config.json 里的 type:1 条目带 header 对象。
/// - drpy 声明式规则：drpy-node 解包样本 spider/js_todo/*.js 的
///   var rule = {title, host, url, 一级, 二级, 搜索} 形态。
/// - CatPaw：树内与样本中除 drpy-node README 里一条“DS 源适配猫影视”
///   的仓库链接外，无任何独立的 type/api 形态证据；本文件不为它
///   单独立一种解析（见回报里的 CatPaw 证据结论）。

/// 站点 api 的形态分类。
enum SiteApiKind {
  /// csp_ 前缀：jar 蜘蛛。
  jarCsp,

  /// 全类名：com.github.catvod.spider.Xxx 等 jar 蜘蛛。
  jarClass,

  /// http(s) 的 .py 文件：远程 py 蜘蛛。
  remotePy,

  /// http(s) 的 .js 文件：远程 JS 蜘蛛。
  remoteJs,

  /// TVBox type:4（或 type:"t4"）的 http 聚合接口。
  t4,

  /// 普通 http(s) 接口（MacCMS/XBPQ/自定义源通道）。
  httpApi,

  /// 认不出的形态。
  unsupported,
}

class SiteApiShape {
  const SiteApiShape(this.kind, [this.reason = '']);

  final SiteApiKind kind;

  /// unsupported 时的跳过原因；其余形态为空。
  final String reason;
}

final _classNamePattern = RegExp(r'^[A-Za-z_][\w]*(\.[A-Za-z_][\w]*)+$');

/// 站点 api 形态分类。typeValue 取站点条目的 type 字段（int 或字符串）。
SiteApiShape classifySiteApi({required String api, Object? typeValue}) {
  final trimmed = api.trim();
  if (trimmed.isEmpty) {
    return const SiteApiShape(
      SiteApiKind.unsupported,
      '缺少 api',
    );
  }
  if (trimmed.startsWith('csp_')) {
    return const SiteApiShape(SiteApiKind.jarCsp);
  }
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    final path = trimmed.split('?').first.split('#').first.toLowerCase();
    if (path.endsWith('.py')) {
      return const SiteApiShape(SiteApiKind.remotePy);
    }
    if (path.endsWith('.js')) {
      return const SiteApiShape(SiteApiKind.remoteJs);
    }
    final typeText = typeValue?.toString().trim().toLowerCase() ?? '';
    if (typeText == '4' || typeText == 't4') {
      return const SiteApiShape(SiteApiKind.t4);
    }
    return const SiteApiShape(SiteApiKind.httpApi);
  }
  // 带点、无斜杠的类名形态：com.github.catvod.spider.Xxx。裸域名
  // （两段全小写，如 example.com）不算——那不是合法的 api 写法。
  if (!trimmed.contains('/') &&
      !trimmed.contains('?') &&
      !trimmed.contains(':') &&
      _classNamePattern.hasMatch(trimmed)) {
    final segments = trimmed.split('.');
    final last = segments.last;
    final upperLast =
        last.isNotEmpty && last[0] == last[0].toUpperCase() && last[0] != last[0].toLowerCase();
    if (segments.length >= 3 ||
        trimmed.contains('.spider.') ||
        upperLast) {
      return const SiteApiShape(SiteApiKind.jarClass);
    }
  }
  return SiteApiShape(
    SiteApiKind.unsupported,
    'api 类型不支持（$trimmed）',
  );
}

/// spider/jar 引用：地址 + 可选 md5。
typedef SpiderRefValue = ({String url, String md5});

final _md5Pattern = RegExp(r'^[0-9a-fA-F]{32}$');

/// spider/jar 引用解析，认三种形态：字符串 "url;md5"、对象
/// {url, md5}、数组 [url, md5]。
SpiderRefValue parseSpiderRefValue(Object? raw) {
  if (raw is Map) {
    final map = Map<String, dynamic>.from(raw);
    final url =
        (map['url'] ?? map['address'] ?? map['href'] ?? '').toString().trim();
    final md5 = (map['md5'] ?? map['hash'] ?? '').toString().trim();
    return (url: url, md5: _md5Pattern.hasMatch(md5) ? md5.toLowerCase() : '');
  }
  if (raw is List) {
    var url = '';
    var md5 = '';
    for (final part in raw) {
      final text = part.toString().trim();
      if (text.isEmpty) continue;
      if (_md5Pattern.hasMatch(text)) {
        md5 = text.toLowerCase();
      } else if (url.isEmpty) {
        url = text;
      }
    }
    return (url: url, md5: md5);
  }
  final text = raw?.toString() ?? '';
  var url = '';
  var md5 = '';
  for (final part in text.split(';')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    if (_md5Pattern.hasMatch(trimmed)) {
      md5 = trimmed.toLowerCase();
    } else if (url.isEmpty) {
      url = trimmed;
    }
  }
  return (url: url, md5: md5);
}

/// base64 包裹的配置：整段是 base64、解出来是以 { 开头、含
/// sites/lives/parses 的 JSON 时返回解码后的文本，否则返回 null。
/// 只在普通 JSON 解析失败后尝试，不改变正常配置的解析路径。
String? tryDecodeBase64Config(String text) {
  final compact = text.trim().replaceAll(RegExp(r'\s+'), '');
  if (compact.length < 20 || compact.length % 4 == 1) return null;
  if (!RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(compact)) return null;
  // 排除普通 JSON 文本（不会全是 base64 字符集且以 { 开头）。
  if (compact.startsWith('{')) return null;
  final normalized = compact.replaceAll('-', '+').replaceAll('_', '/');
  final padded = normalized.padRight(
    (normalized.length + 3) ~/ 4 * 4,
    '=',
  );
  try {
    final decoded = utf8.decode(base64Decode(padded));
    final trimmed = decoded.trim();
    if (!trimmed.startsWith('{')) return null;
    if (!trimmed.contains('"sites"') &&
        !trimmed.contains('"lives"') &&
        !trimmed.contains('"parses"') &&
        !trimmed.contains("'sites'")) {
      return null;
    }
    // 必须是合法 JSON 对象才算，避免把随机 base64 当配置。
    final parsed = jsonDecode(trimmed);
    if (parsed is! Map) return null;
    return trimmed;
  } catch (_) {
    return null;
  }
}

/// XBPQ 规则键：与 Go 核 customSourceRuleKeys 对齐（命中 2 个即认）。
const List<String> xbpqRuleKeys = [
  '主页url',
  '首页url',
  '分类url',
  '分类Header',
  '数组',
  '播放数组',
  '搜索url',
  '线路数组',
  '请求',
  '分类',
];

/// ext 文本是否为 XBPQ 规则 JSON（命中 2 个规则键即认）。
bool looksLikeXbpqRuleJson(String ext) {
  if (ext.isEmpty) return false;
  try {
    final decoded = jsonDecode(ext);
    if (decoded is! Map) return false;
    final map = Map<String, dynamic>.from(decoded);
    var hits = 0;
    for (final key in xbpqRuleKeys) {
      if (map.containsKey(key)) hits++;
    }
    return hits >= 2;
  } catch (_) {
    return false;
  }
}

/// JS 蜘蛛脚本的形态分类（只用于导入时识别与报错，不决定执行）。
enum JsSourceShape {
  /// 函数形态蜘蛛（全局函数 / rule 对象方法 / Spider 类）。
  functionSpider,

  /// CatVod cat 形态：@header(lang:'cat') + 短函数名。
  catScript,

  /// Node 模块形态：module.exports / exports.* / export default。
  moduleExports,

  /// 含 spider/rule 标记但无蜘蛛函数的对象（旧口径下可导入）。
  ruleObject,

  /// drpy 声明式规则：rule 对象 + 一级/二级规则串，无蜘蛛函数，
  /// JS 引擎跑不了，需走 drpy-node 小程序或 drpyS 服务。
  drpyRule,

  /// 无任何可识别标记。
  unknown,
}

final _spiderFunctionMarkers = [
  'homeContent',
  'categoryContent',
  'detailContent',
  'searchContent',
  'playerContent',
  'homeVod',
  'function home(',
  'function category(',
  'function detail(',
  'function search(',
  'function play(',
];

/// JS 脚本形态分类。
JsSourceShape classifyJsSource(String source) {
  final text = source;
  final hasSpiderFunction = _spiderFunctionMarkers.any(text.contains) ||
      text.contains('module.exports') ||
      text.contains('exports.') ||
      text.contains('export default');
  final hasRuleObject =
      RegExp(r'\b(var|let|const)\s+rule\s*=').hasMatch(text) ||
      text.contains('rule = {');
  final hasDrpyFields =
      (text.contains('一级') || text.contains('二级')) &&
      text.contains('host');
  if (hasRuleObject && hasDrpyFields && !hasSpiderFunction) {
    return JsSourceShape.drpyRule;
  }
  if (text.contains('@header') &&
      RegExp("['\"]?lang['\"]?\\s*:\\s*['\"]cat['\"]").hasMatch(text)) {
    return JsSourceShape.catScript;
  }
  if (text.contains('module.exports') ||
      text.contains('exports.') ||
      text.contains('export default')) {
    return JsSourceShape.moduleExports;
  }
  if (hasSpiderFunction) return JsSourceShape.functionSpider;
  if (text.contains('spider') || text.contains('rule')) {
    return JsSourceShape.ruleObject;
  }
  return JsSourceShape.unknown;
}

/// 解析接口条目：type 0 普通（网页模板）、1 JSON 接口；2/3（并发
/// 多 JSON / 聚合）现有管线不支持，调用方据此跳过并注明。
class ParseEntryShape {
  const ParseEntryShape({
    required this.name,
    required this.url,
    required this.typeValue,
    required this.headers,
  });

  final String name;
  final String url;
  final int typeValue;
  final Map<String, String> headers;

  bool get isJson => typeValue == 1;
}

/// 解析接口条目解析：url 认 url/api 键，header 认 header/headers
///（对象或 JSON 字符串），type 认 int 与数字字符串，缺省 0。
ParseEntryShape parseEntryShape(Map<String, dynamic> entry, int index) {
  final name = (entry['name'] ?? entry['title'] ?? '解析 $index').toString();
  final url = (entry['url'] ?? entry['api'] ?? '').toString().trim();
  final rawType = entry['type'];
  var typeValue = 0;
  if (rawType is num) {
    typeValue = rawType.toInt();
  } else if (rawType != null) {
    typeValue = int.tryParse(rawType.toString().trim()) ?? 0;
  }
  final headers = <String, String>{};
  final rawHeaders = entry['header'] ?? entry['headers'];
  if (rawHeaders is Map) {
    rawHeaders.forEach((key, value) {
      if (value != null) headers[key.toString()] = value.toString();
    });
  } else if (rawHeaders is String) {
    final trimmed = rawHeaders.trim();
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value != null) headers[key.toString()] = value.toString();
          });
        }
      } catch (_) {}
    }
  }
  return ParseEntryShape(
    name: name,
    url: url,
    typeValue: typeValue,
    headers: headers,
  );
}

/// 直播条目：url 认字符串，数组时取第一个 http(s) 地址；epg/group
/// 有则透传到直播源。
class LiveEntryShape {
  const LiveEntryShape({
    required this.name,
    required this.url,
    required this.epg,
    required this.group,
  });

  final String name;
  final String url;
  final String epg;
  final String group;
}

LiveEntryShape parseLiveEntry(Map<String, dynamic> entry, int index) {
  final name = (entry['name'] ?? '直播 $index').toString();
  var url = '';
  final rawUrl = entry['url'];
  if (rawUrl is String) {
    url = rawUrl.trim();
  } else if (rawUrl is List) {
    for (final item in rawUrl) {
      final text = item.toString().trim();
      if (text.startsWith('http://') || text.startsWith('https://')) {
        url = text;
        break;
      }
    }
  }
  return LiveEntryShape(
    name: name,
    url: url,
    epg: (entry['epg'] ?? '').toString().trim(),
    group: (entry['group'] ?? '').toString().trim(),
  );
}
