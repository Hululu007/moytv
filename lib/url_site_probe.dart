import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'content_http.dart';
import 'core_bridge.dart';
import 'nexhub_scraper/scraper/verification_detector.dart';

/// 探站失败：面向用户的中文原因。调用方直接展示 [message]，不编造结构。
class ProbeFailure implements Exception {
  const ProbeFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 探到的分类（名 + XBPQ 分类 ID + 实际链接）。
class ProbedCategory {
  const ProbedCategory({
    required this.id,
    required this.name,
    required this.url,
  });
  final String id;
  final String name;
  final String url;
}

/// 探站结果：首页识别出的站点结构，供网页爬取展示与生成蜘蛛使用。
class ProbedSite {
  const ProbedSite({
    required this.name,
    required this.base,
    required this.rule,
    required this.kind,
    required this.isMacCMS,
    required this.categories,
    required this.evidence,
  });

  /// 站名（标题/og:site_name/域名，截断至 40 字以内）。
  final String name;

  /// 站点根地址（scheme + host，不含路径/参数）。
  final String base;

  /// 生成的 XBPQ 规则 JSON；MacCMS 站为空（Go 核按 base 自动识别）。
  final String rule;

  /// 源类型：始终为空（自动识别），规则存在时 Go 核走 XBPQ。
  final String kind;

  /// 是否探到 MacCMS 采集接口。
  final bool isMacCMS;

  /// 识别出的分类（MacCMS 站为空，分类由接口在运行时给出）。
  final List<ProbedCategory> categories;

  /// 探站证据（供复核界面展示：分类数、模板、翻页/搜索探到与否等）。
  final List<String> evidence;
}

typedef ProbeFetch = Future<ContentResponse> Function(String url);

/// 输入网址探站：抓首页 → 识别站名/分类/翻页/搜索 → 输出站点结构。
///
/// 只用页面上真实存在的东西识别结构：分类模板须由两个以上同规律的分类链接
/// 归纳出来，翻页须由真实的下一页链接对齐出来；识别不到就抛 [ProbeFailure]，
/// 绝不编假结构。验证页（盾/滑块/登录墙）不绕过，直接报错说明。
class UrlSiteProbe {
  // ignore: prefer_initializing_formals (私有字段无法用具名初始化形参传入)
  UrlSiteProbe({ProbeFetch? fetchHtml}) : _fetchHtml = fetchHtml;

  final ProbeFetch? _fetchHtml;
  final ContentHttp _http = ContentHttp();

  static const _fetchTimeout = Duration(seconds: 15);

  Future<ContentResponse> _get(String url) {
    final fetch = _fetchHtml;
    if (fetch != null) return fetch(url);
    return _http.getRaw(url, timeout: _fetchTimeout);
  }

  /// 探站主入口。成功返回可复核的记录，失败抛 [ProbeFailure]。
  Future<ProbedSite> probe(String input) async {
    final startUrl = _normalize(input);
    final origin = _originOf(startUrl);
    final home = await _fetchPage(startUrl, '首页');
    final doc = html_parser.parse(home);
    final name = _extractSiteName(doc, Uri.parse(origin).host);
    final evidence = <String>[];

    // MacCMS 采集接口优先：探到则只记 base，Go 核运行时自动识别。
    if (await _isMacCMS(origin)) {
      evidence.add('探到 MacCMS 采集接口（/api.php/provide/vod/），按模板源保存');
      return ProbedSite(
        name: name,
        base: origin,
        rule: '',
        kind: '',
        isMacCMS: true,
        categories: const [],
        evidence: evidence,
      );
    }

    final categories = _extractCategories(doc, startUrl);
    final template = _detectCategoryTemplate(categories, origin);
    if (template == null) {
      throw const ProbeFailure(
        '未能从首页识别出分类结构：未找到两个以上同规律的分类链接。',
      );
    }
    evidence.add('分类 ${template.categories.length} 个');

    final withPage = await _detectPagination(template, startUrl);
    final categoryUrl = withPage.template;
    if (withPage.hasPagination) {
      evidence.add('翻页规律：已探到（{catePg}）');
    } else {
      evidence.add('翻页规律：未探到，分类只取第一页');
    }

    // 校验：按模板实际打开第一个分类页，确认模板可用。
    final first = template.categories.first;
    final checkUrl = categoryUrl
        .replaceAll('{cateId}', first.id)
        .replaceAll('{catePg}', '1');
    final checkBody = await _fetchPage(checkUrl, '分类页');
    if (!checkBody.toLowerCase().contains('<a')) {
      throw const ProbeFailure('按识别出的分类地址打开后无链接。');
    }

    final searchUrl = _detectSearch(doc, startUrl);
    if (searchUrl != null) {
      evidence.add('搜索：已探到搜索框');
    } else {
      evidence.add('搜索：未探到，可在编辑器里手工补');
    }

    final cards = _countCards(doc);
    evidence.add('首页带图链接 ${cards.count} 个（疑似作品卡）');
    for (final sample in cards.samples) {
      evidence.add('示例：$sample');
    }
    evidence.add('分类地址模板：$categoryUrl');

    final categoryField = template.categories
        .map((c) => '${_sanitizeCategoryName(c.name)}\$${c.id}')
        .join('#');
    final ruleMap = <String, String>{
      '主页url': '$origin/',
      '分类url': categoryUrl,
      '分类': categoryField,
    };
    if (searchUrl != null) ruleMap['搜索url'] = searchUrl;
    return ProbedSite(
      name: name,
      base: origin,
      rule: jsonEncode(ruleMap),
      kind: '',
      isMacCMS: false,
      categories: template.categories,
      evidence: evidence,
    );
  }

  String _normalize(String input) {
    var text = input.trim();
    if (text.isEmpty) {
      throw const ProbeFailure('请输入网址。');
    }
    if (!text.contains('://')) {
      text = 'https://$text';
    }
    final uri = Uri.tryParse(text);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        !uri.host.contains('.')) {
      throw const ProbeFailure('请输入 http 或 https 开头的完整网址。');
    }
    return text;
  }

  String _originOf(String url) {
    final uri = Uri.parse(url);
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }

  /// 抓一页并解码：验证页/非 200/空内容均抛 [ProbeFailure]（不编结构）。
  Future<String> _fetchPage(String url, String label) async {
    ContentResponse response;
    try {
      response = await _get(url);
    } on AppFailure catch (e) {
      throw ProbeFailure('抓取$label失败：${e.message}');
    } catch (e) {
      throw ProbeFailure('抓取$label失败：$e');
    }
    final body = decodeContentBytes(
      response.bodyBytes,
      contentType: response.headers['content-type'],
    );
    if (VerificationDetector.isVerificationRequired(
      statusCode: response.statusCode,
      body: body,
      headers: response.headers,
    )) {
      if (VerificationDetector.isEdgeIpRestricted(
        statusCode: response.statusCode,
        body: body,
      )) {
        throw const ProbeFailure(
          '该站拒绝了当前网络地址（边缘 IP 限制），换网络或稍后重试。',
        );
      }
      throw const ProbeFailure(
        '该站当前显示验证页（需人机验证），无法自动识别。请先在浏览器中完成验证后再试。',
      );
    }
    if (response.statusCode != 200) {
      throw ProbeFailure(
        '站点返回 HTTP ${response.statusCode}，无法识别。',
      );
    }
    if (body.trim().isEmpty) {
      throw const ProbeFailure('页面内容为空，无法识别。');
    }
    return body;
  }

  Future<bool> _isMacCMS(String origin) async {
    try {
      final response = await _get(
        '$origin/api.php/provide/vod/?ac=list&pg=1',
      );
      if (response.statusCode != 200) return false;
      final decoded = jsonDecode(
        decodeContentBytes(
          response.bodyBytes,
          contentType: response.headers['content-type'],
        ),
      );
      if (decoded is! Map) return false;
      final code = decoded['code'];
      final list = decoded['list'];
      return (code == 1 || code == '1') && list is List && list.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  String _extractSiteName(Document doc, String host) {
    var name = '';
    final og = doc.querySelector('meta[property="og:site_name"]');
    final ogName = og?.attributes['content']?.trim() ?? '';
    if (ogName.isNotEmpty) {
      name = ogName;
    } else {
      final title = doc.querySelector('title')?.text.trim() ?? '';
      name = _cleanTitle(title);
    }
    if (name.isEmpty) {
      name = host.startsWith('www.') ? host.substring(4) : host;
    }
    final runes = name.runes.toList();
    if (runes.length > 40) {
      name = String.fromCharCodes(runes.take(40));
    }
    return name;
  }

  String _cleanTitle(String title) {
    var text = title.trim();
    if (text.isEmpty) return '';
    // 常见形态「站名 - 口号」「站名_口号」「站名|口号」：取第一段。
    for (final sep in [' - ', ' | ', '_', '，', '、', '·', '—', '-', '|']) {
      final idx = text.indexOf(sep);
      if (idx >= 2) {
        final head = text.substring(0, idx).trim();
        if (head.isNotEmpty && head.length < text.length) {
          text = head;
          break;
        }
      }
    }
    return text.trim();
  }

  static const _navSelectors = [
    'nav',
    'header',
    '.nav',
    '.navbar',
    '.nav-menu',
    '.menu',
    '.header',
    '.site-nav',
    '.top-nav',
    '.navigation',
    '#nav',
    '#menu',
  ];

  static const _stoplist = {
    '登录',
    '登陆',
    '注册',
    '搜索',
    '下载',
    'app',
    'app下载',
    '客户端',
    '留言',
    '反馈',
    '收藏本站',
    '设为首页',
    '网站地图',
    '关于我们',
    '联系我们',
    '帮助中心',
    '充值',
    '会员',
    'vip',
    '签到',
    '上传',
    '投稿',
    '求片',
    '公告',
    '更多',
    '首页',
    '主页',
    '首页推荐',
  };

  static const _deadSuffixes = [
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.css',
    '.js',
    '.apk',
    '.zip',
    '.mp4',
    '.m3u8',
    '.ico',
    '.svg',
  ];

  List<ProbedCategory> _extractCategories(Document doc, String pageUrl) {
    final base = Uri.parse(pageUrl);
    final seen = <String>{};
    final navLinks = <ProbedCategory>[];
    final allLinks = <ProbedCategory>[];
    for (final anchor in doc.querySelectorAll('a[href]')) {
      final rawHref = anchor.attributes['href']?.trim() ?? '';
      if (rawHref.isEmpty) continue;
      final lower = rawHref.toLowerCase();
      if (lower.startsWith('javascript:') ||
          lower.startsWith('mailto:') ||
          lower.startsWith('tel:') ||
          lower.startsWith('#')) {
        continue;
      }
      final resolved = base.resolveUri(Uri.tryParse(rawHref) ?? Uri());
      if (resolved.scheme != 'http' && resolved.scheme != 'https') continue;
      if (resolved.host != base.host) continue;
      final path = resolved.path.toLowerCase();
      if (_deadSuffixes.any(path.endsWith)) continue;
      final text = anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty || text.length > 12) continue;
      if (RegExp(r'^\d+$').hasMatch(text)) continue;
      if (_stoplist.contains(text.toLowerCase())) continue;
      final url = resolved.toString();
      if (!seen.add(url)) continue;
      final entry = ProbedCategory(id: '', name: text, url: url);
      allLinks.add(entry);
      if (_inNav(anchor)) navLinks.add(entry);
    }
    final picked = navLinks.length >= 2 ? navLinks : allLinks;
    return picked.take(40).toList();
  }

  bool _inNav(Element element) {
    Node? node = element.parent;
    while (node != null) {
      if (node is Element) {
        for (final sel in _navSelectors) {
          if (sel.startsWith('.')) {
            if (node.classes.contains(sel.substring(1))) return true;
          } else if (sel.startsWith('#')) {
            if (node.id == sel.substring(1)) return true;
          } else if (node.localName == sel) {
            return true;
          }
        }
      }
      node = node.parent;
    }
    return false;
  }

  /// 分类模板：找两个以上同规律（同前缀+同后缀、中间段不同）的分类链接。
  _CategoryTemplate? _detectCategoryTemplate(
    List<ProbedCategory> candidates,
    String origin,
  ) {
    if (candidates.length < 2) return null;
    final groups = <String, List<_TemplateMember>>{};
    for (var i = 0; i < candidates.length; i++) {
      for (var j = i + 1; j < candidates.length; j++) {
        final a = candidates[i].url;
        final b = candidates[j].url;
        final prefix = _commonPrefix(a, b);
        if (prefix.length < origin.length) continue;
        final suffix = _commonSuffix(
          a.substring(prefix.length),
          b.substring(prefix.length),
        );
        final midA = a.substring(
          prefix.length,
          a.length - suffix.length,
        );
        final midB = b.substring(
          prefix.length,
          b.length - suffix.length,
        );
        if (midA.isEmpty || midB.isEmpty || midA == midB) continue;
        if (!_looksLikeId(midA) || !_looksLikeId(midB)) continue;
        final key = '$prefix\x00$suffix';
        final members = groups.putIfAbsent(key, () => []);
        _addMember(members, candidates[i], midA);
        _addMember(members, candidates[j], midB);
      }
    }
    _CategoryTemplate? best;
    for (final entry in groups.entries) {
      final parts = entry.key.split('\x00');
      final members = entry.value;
      if (members.length < 2) continue;
      final template = _CategoryTemplate(
        prefix: parts[0],
        suffix: parts[1],
        categories: members
            .map((m) => ProbedCategory(id: m.id, name: m.name, url: m.url))
            .toList(),
      );
      if (best == null ||
          template.categories.length > best.categories.length ||
          (template.categories.length == best.categories.length &&
              template.prefix.length > best.prefix.length)) {
        best = template;
      }
    }
    return best;
  }

  void _addMember(
    List<_TemplateMember> members,
    ProbedCategory candidate,
    String middle,
  ) {
    final id = middle.replaceAll(RegExp(r'^/+|/+$'), '');
    if (!_validXbpqId(id)) return;
    if (members.any((m) => m.id == id)) return;
    members.add(_TemplateMember(id: id, name: candidate.name, url: candidate.url));
  }

  bool _looksLikeId(String middle) {
    if (middle.isEmpty || middle.length > 80) return false;
    return RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(middle) &&
        !middle.contains('..');
  }

  bool _validXbpqId(String id) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9_/-]{0,79}$').hasMatch(id);

  String _commonPrefix(String a, String b) {
    var i = 0;
    final limit = a.length < b.length ? a.length : b.length;
    while (i < limit && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return a.substring(0, i);
  }

  String _commonSuffix(String a, String b) {
    var i = 0;
    final limit = a.length < b.length ? a.length : b.length;
    while (i < limit &&
        a.codeUnitAt(a.length - 1 - i) == b.codeUnitAt(b.length - 1 - i)) {
      i++;
    }
    return a.substring(a.length - i);
  }

  /// 翻页探测：打开第一个分类页，找“下一页/2”链接，与当前地址对齐出页码段。
  Future<_PaginationResult> _detectPagination(
    _CategoryTemplate template,
    String pageUrl,
  ) async {
    final first = template.categories.first;
    final base = Uri.parse(pageUrl);
    try {
      final body = await _fetchPage(first.url, '分类页');
      final doc = html_parser.parse(body);
      final current = first.url;
      for (final anchor in doc.querySelectorAll('a[href]')) {
        final text = anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        final isNext =
            text == '下一页' ||
            text == '下页' ||
            text == '下一頁' ||
            text.toLowerCase() == 'next' ||
            text == '>' ||
            text == '»' ||
            text == '›' ||
            text == '→' ||
            text == '2';
        if (!isNext) continue;
        final href = anchor.attributes['href']?.trim() ?? '';
        if (href.isEmpty) continue;
        final next = base.resolveUri(Uri.tryParse(href) ?? Uri()).toString();
        final paged = _alignPagination(template, current, next);
        if (paged != null) {
          return _PaginationResult(template: paged, hasPagination: true);
        }
      }
    } catch (_) {
      // 分类页抓不到/对不齐：降级为无翻页模板，不阻断探站。
    }
    return _PaginationResult(
      template: '${template.prefix}{cateId}${template.suffix}',
      hasPagination: false,
    );
  }

  /// 对齐当前分类地址与下一页地址：仅当唯一差异段是数字、且位于分类 ID 段之后
  /// 时，才认定为页码段，返回带 {cateId}/{catePg} 的模板。
  String? _alignPagination(
    _CategoryTemplate template,
    String current,
    String next,
  ) {
    if (current == next) return null;
    final prefix = _commonPrefix(current, next);
    final suffix = _commonSuffix(
      current.substring(prefix.length),
      next.substring(prefix.length),
    );
    final midCurrent = current.substring(
      prefix.length,
      current.length - suffix.length,
    );
    final midNext = next.substring(
      prefix.length,
      next.length - suffix.length,
    );
    if (midCurrent.isEmpty || midNext.isEmpty || midCurrent == midNext) {
      return null;
    }
    if (!RegExp(r'^\d+$').hasMatch(midCurrent) ||
        !RegExp(r'^\d+$').hasMatch(midNext)) {
      return null;
    }
    final first = template.categories.first;
    final idEnd = template.prefix.length + first.id.length;
    // 页码段须在分类 ID 段之后（否则差异段可能是分类 ID 本身）。
    if (prefix.length < idEnd) return null;
    final suffixOffset = prefix.length - idEnd;
    final suffixWithPage = template.suffix.replaceRange(
      suffixOffset,
      suffixOffset + midCurrent.length,
      '{catePg}',
    );
    return '${template.prefix}{cateId}$suffixWithPage';
  }

  String? _detectSearch(Document doc, String pageUrl) {
    final base = Uri.parse(pageUrl);
    const knownNames = {'wd', 'q', 'keyword', 'searchword', 'key', 's', 'kw', 'word'};
    for (final form in doc.querySelectorAll('form')) {
      final method = (form.attributes['method'] ?? 'get').toLowerCase();
      if (method != 'get') continue;
      final actionRaw = form.attributes['action']?.trim() ?? '';
      final action = base.resolveUri(
        Uri.tryParse(actionRaw.isEmpty ? pageUrl : actionRaw) ?? Uri(),
      );
      if (action.host != base.host) continue;
      final actionPath = action.path.toLowerCase();
      final actionLooksSearchful =
          actionPath.contains('search') ||
          actionPath.contains('/so') ||
          actionPath.contains('vodsearch') ||
          actionPath.contains('query');
      for (final input in form.querySelectorAll('input')) {
        final type = (input.attributes['type'] ?? 'text').toLowerCase();
        if (type != 'text' && type != 'search' && type != '') continue;
        final name = input.attributes['name']?.trim() ?? '';
        if (name.isEmpty) continue;
        if (!actionLooksSearchful && !knownNames.contains(name)) continue;
        final sep = action.query.isEmpty ? '?' : '&';
        return '${action.toString()}$sep$name={wd}';
      }
    }
    return null;
  }

  _CardEvidence _countCards(Document doc) {
    var count = 0;
    final samples = <String>[];
    final seen = <String>{};
    for (final anchor in doc.querySelectorAll('a')) {
      if (anchor.querySelector('img') == null) continue;
      count++;
      if (samples.length < 3) {
        final text = anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (text.isNotEmpty && text.length <= 20 && seen.add(text)) {
          samples.add(text);
        }
      }
    }
    return _CardEvidence(count: count, samples: samples);
  }

  String _sanitizeCategoryName(String name) =>
      name.replaceAll(RegExp(r'[\$#|]'), '').trim();
}

class _TemplateMember {
  const _TemplateMember({
    required this.id,
    required this.name,
    required this.url,
  });
  final String id;
  final String name;
  final String url;
}

class _CategoryTemplate {
  const _CategoryTemplate({
    required this.prefix,
    required this.suffix,
    required this.categories,
  });
  final String prefix;
  final String suffix;
  final List<ProbedCategory> categories;
}

class _PaginationResult {
  const _PaginationResult({required this.template, required this.hasPagination});
  final String template;
  final bool hasPagination;
}

class _CardEvidence {
  const _CardEvidence({required this.count, required this.samples});
  final int count;
  final List<String> samples;
}
