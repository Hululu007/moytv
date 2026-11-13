import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'content_http.dart';
import 'core_bridge.dart';
import 'nexhub_scraper/scraper/verification_detector.dart';
import 'nexhub_scraper/scraper/web_scrape_service.dart';
import 'url_site_probe.dart';

/// 爬取失败：面向用户的中文原因，调用方直接展示 [message]，不编造数据。
class ScrapeFailure implements Exception {
  const ScrapeFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 播放链路形态：由详情页实测决定，生成蜘蛛时据此选择取流写法。
enum PlayChain {
  /// 详情页未发现可播放地址。
  none,

  /// 详情页本身含直链（video 标签或 .m3u8/.mp4 链接）。
  directMedia,

  /// 详情页含播放页链接，需再打开播放页取直链。
  viaPlayPage,
}

/// 列表项：标题、封面、链接全部来自实爬页面。
class ScrapedListItem {
  const ScrapedListItem({
    required this.title,
    required this.cover,
    required this.url,
  });
  final String title;
  final String cover;
  final String url;
}

/// 详情页示例：取自第一个列表项的真实详情页。
class ScrapedDetailSample {
  const ScrapedDetailSample({
    required this.title,
    required this.description,
    required this.cover,
    this.mediaUrls = const <String>[],
    this.playLinks = const <ScrapeLink>[],
    this.playHrefPattern,
  });
  final String title;
  final String description;
  final String cover;
  final List<String> mediaUrls;
  final List<ScrapeLink> playLinks;

  /// 播放页链接的地址规律（正则表达式源码），由实测链接归纳出来。
  final String? playHrefPattern;
}

/// 一次爬取的全部实际数据：展示与生成蜘蛛的唯一依据。
class ScrapedSiteData {
  const ScrapedSiteData({
    required this.inputUrl,
    required this.base,
    required this.siteName,
    this.pageTitle,
    this.isMacCMS = false,
    this.categories = const <ProbedCategory>[],
    this.categoryUrlTemplate,
    this.hasPagination = false,
    this.searchUrl,
    this.listItems = const <ScrapedListItem>[],
    this.detailHrefPattern,
    this.detailSample,
    this.playChain = PlayChain.none,
    this.links = const <ScrapeLink>[],
    this.evidence = const <String>[],
    this.structureError,
  });

  /// 用户输入并归一化后的地址。
  final String inputUrl;

  /// 站点根地址（scheme + host，不含路径/参数）。
  final String base;

  /// 站名（标题/og:site_name/域名）。
  final String siteName;

  /// 首页标题（通用爬取实测）。
  final String? pageTitle;

  /// 是否探到 MacCMS 采集接口。
  final bool isMacCMS;

  /// 识别出的分类（MacCMS 站为空，分类由接口在运行时给出）。
  final List<ProbedCategory> categories;

  /// 分类地址模板（含 {cateId}，有翻页时含 {catePg}）。
  final String? categoryUrlTemplate;

  /// 是否探到翻页规律。
  final bool hasPagination;

  /// 搜索地址模板（含 {wd}），未探到为 null。
  final String? searchUrl;

  /// 分类页列表项样本（标题/封面/链接）。
  final List<ScrapedListItem> listItems;

  /// 详情链接的地址规律（正则表达式源码），由列表项链接归纳出来。
  final String? detailHrefPattern;

  /// 详情页示例，未抓到为 null。
  final ScrapedDetailSample? detailSample;

  /// 播放链路形态。
  final PlayChain playChain;

  /// 通用爬取到的页面链接（展示用）。
  final List<ScrapeLink> links;

  /// 识别证据（供界面展示）。
  final List<String> evidence;

  /// 结构识别失败原因（有值时分类/列表/详情数据不完整）。
  final String? structureError;
}

/// 网址归一化：去空白、缺协议补 https，仅接受 http/https。
String normalizeScrapeUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) {
    throw const ScrapeFailure('请输入网址。');
  }
  if (!text.contains('://')) {
    text = 'https://$text';
  }
  final uri = Uri.tryParse(text);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      !uri.host.contains('.')) {
    throw const ScrapeFailure('请输入 http 或 https 开头的完整网址。');
  }
  return text;
}

typedef ScrapeFetch = Future<ContentResponse> Function(String url);

/// 网页爬取分析：抓首页 → 识别结构 → 采样列表与详情，产出 [ScrapedSiteData]。
///
/// 抓取走 [WebScrapeService]（通用模式）与 [UrlSiteProbe]（结构识别），均
/// 为真实网络请求；验证页/盾/登录墙一律抛 [ScrapeFailure]，绝不绕过。
/// 结构识别失败时不阻断：通用爬取的数据照常返回，[ScrapedSiteData.structureError]
/// 记下原因，生成蜘蛛时再按缺失项诚实报错。
class WebScrapeAnalyzer {
  WebScrapeAnalyzer({
    ScrapeFetch? fetchHtml,
    WebScrapeService? scrapeService,
    UrlSiteProbe? probe,
  })  : _fetchHtml = fetchHtml, // ignore: prefer_initializing_formals
        _service = scrapeService,
        _probe = probe; // ignore: prefer_initializing_formals

  final ScrapeFetch? _fetchHtml;
  final WebScrapeService? _service;
  final UrlSiteProbe? _probe;
  final ContentHttp _http = ContentHttp();

  static const _fetchTimeout = Duration(seconds: 15);

  WebScrapeService get _scrapeService => _service ?? WebScrapeService.instance;

  UrlSiteProbe get _siteProbe => _probe ?? UrlSiteProbe(fetchHtml: _fetchHtml);

  Future<ContentResponse> _get(String url) {
    final fetch = _fetchHtml;
    if (fetch != null) return fetch(url);
    return _http.getRaw(url, timeout: _fetchTimeout);
  }

  /// 爬取并分析 [input] 指定的站点首页。
  Future<ScrapedSiteData> analyze(String input) async {
    final startUrl = normalizeScrapeUrl(input);
    final origin = _originOf(startUrl);

    ScrapeResult scraped;
    try {
      scraped = await _scrapeService.scrape(startUrl, ScrapeMode.general);
    } on VerificationRequiredException catch (e) {
      throw ScrapeFailure(_verificationMessage(e));
    } on AppFailure catch (e) {
      throw ScrapeFailure('抓取失败：${e.message}');
    } catch (e) {
      throw ScrapeFailure('抓取失败：$e');
    }

    ProbedSite? probed;
    String? structureError;
    try {
      probed = await _siteProbe.probe(startUrl);
    } on ProbeFailure catch (e) {
      structureError = e.message;
    } catch (e) {
      structureError = '结构识别失败：$e';
    }

    if (scraped.isEmpty && probed == null) {
      throw ScrapeFailure(structureError ?? '页面未返回可用内容。');
    }

    final evidence = <String>[...?probed?.evidence];
    evidence.add('通用爬取：页面链接 ${scraped.links.length} 个');
    final name =
        probed?.name ?? _nameFromTitle(scraped.pageTitle, Uri.parse(origin).host);

    String? categoryTemplate;
    String? searchUrl;
    if (probed != null && probed.rule.isNotEmpty) {
      try {
        final rule = jsonDecode(probed.rule);
        if (rule is Map) {
          categoryTemplate = rule['分类url'] as String?;
          searchUrl = rule['搜索url'] as String?;
        }
      } catch (_) {
        // 规则解析失败：模板与搜索按未探到处理。
      }
    }

    var listItems = <ScrapedListItem>[];
    String? detailHrefPattern;
    ScrapedDetailSample? detailSample;
    var playChain = PlayChain.none;

    if (probed != null && probed.isMacCMS) {
      final mac = await _fetchMacSamples(origin);
      listItems = mac.items;
      detailSample = mac.detail;
      if (mac.hasPlayUrls) playChain = PlayChain.directMedia;
      evidence.add('采集接口列表 ${listItems.length} 个');
      if (detailSample != null) {
        evidence.add('详情示例：${detailSample.title}');
      }
    } else if (probed != null && probed.categories.isNotEmpty) {
      try {
        final firstCategory = probed.categories.first;
        final categoryHtml = await _fetchPage(firstCategory.url, '分类页');
        final doc = html_parser.parse(categoryHtml);
        listItems = _extractCards(doc, Uri.parse(firstCategory.url));
        evidence.add('分类页列表项 ${listItems.length} 个');
        detailHrefPattern = _deriveHrefPattern(
          listItems.map((e) => e.url).toList(),
          origin,
        );
        if (detailHrefPattern != null) {
          evidence.add('详情链接规律：$detailHrefPattern');
        }
        if (listItems.isNotEmpty) {
          final sampled = await _fetchDetailSample(listItems.first.url);
          detailSample = sampled.sample;
          playChain = sampled.chain;
          evidence.add('详情示例：${detailSample.title}');
          evidence.add(
            switch (playChain) {
              PlayChain.directMedia => '播放链：详情页含直链',
              PlayChain.viaPlayPage => '播放链：详情页含播放页链接',
              PlayChain.none => '播放链：详情页未发现可播放地址',
            },
          );
        }
      } on ScrapeFailure catch (e) {
        evidence.add('列表/详情采样失败：${e.message}');
      }
    }

    return ScrapedSiteData(
      inputUrl: startUrl,
      base: origin,
      siteName: name,
      pageTitle: scraped.pageTitle,
      isMacCMS: probed?.isMacCMS ?? false,
      categories: probed?.categories ?? const <ProbedCategory>[],
      categoryUrlTemplate: categoryTemplate,
      hasPagination: categoryTemplate?.contains('{catePg}') ?? false,
      searchUrl: searchUrl,
      listItems: listItems,
      detailHrefPattern: detailHrefPattern,
      detailSample: detailSample,
      playChain: playChain,
      links: scraped.links,
      evidence: evidence,
      structureError: structureError,
    );
  }

  String _verificationMessage(VerificationRequiredException e) {
    if (VerificationDetector.isEdgeIpRestricted(
      statusCode: e.statusCode,
      body: e.body,
    )) {
      return '该站拒绝了当前网络地址（边缘 IP 限制），换网络或稍后重试。';
    }
    return '该站当前显示验证页（需人机验证），无法自动爬取。'
        '请先在浏览器中完成验证后再试。';
  }

  String _originOf(String url) {
    final uri = Uri.parse(url);
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }

  String _nameFromTitle(String? title, String host) {
    var name = (title ?? '').trim();
    for (final sep in [' - ', ' | ', '_', '，', '、', '·', '—', '-', '|']) {
      final idx = name.indexOf(sep);
      if (idx >= 2) {
        final head = name.substring(0, idx).trim();
        if (head.isNotEmpty && head.length < name.length) {
          name = head;
          break;
        }
      }
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

  /// 抓一页并解码：验证页/非 200/空内容均抛 [ScrapeFailure]。
  Future<String> _fetchPage(String url, String label) async {
    ContentResponse response;
    try {
      response = await _get(url);
    } on AppFailure catch (e) {
      throw ScrapeFailure('抓取$label失败：${e.message}');
    } catch (e) {
      throw ScrapeFailure('抓取$label失败：$e');
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
      throw ScrapeFailure('抓取$label时遇到验证页（需人机验证），无法继续。');
    }
    if (response.statusCode != 200) {
      throw ScrapeFailure('抓取$label失败：站点返回 HTTP ${response.statusCode}。');
    }
    if (body.trim().isEmpty) {
      throw ScrapeFailure('抓取$label失败：页面内容为空。');
    }
    return body;
  }

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

  /// 分类页卡片：带图的同站链接，取标题/封面/地址。
  List<ScrapedListItem> _extractCards(Document doc, Uri base) {
    final seen = <String>{};
    final out = <ScrapedListItem>[];
    for (final anchor in doc.querySelectorAll('a[href]')) {
      final img = anchor.querySelector('img');
      if (img == null) continue;
      final href = anchor.attributes['href']?.trim() ?? '';
      if (href.isEmpty) continue;
      final resolved = base.resolveUri(Uri.tryParse(href) ?? Uri());
      if (resolved.scheme != 'http' && resolved.scheme != 'https') continue;
      if (resolved.host != base.host) continue;
      if (_deadSuffixes.any(resolved.path.toLowerCase().endsWith)) continue;
      final text = anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty || text.length > 60) continue;
      final url = resolved.toString();
      if (!seen.add(url)) continue;
      final src =
          img.attributes['src'] ??
          img.attributes['data-src'] ??
          img.attributes['data-original'] ??
          '';
      final cover = src.isEmpty
          ? ''
          : base.resolveUri(Uri.tryParse(src) ?? Uri()).toString();
      out.add(ScrapedListItem(title: text, cover: cover, url: url));
      if (out.length >= 12) break;
    }
    return out;
  }

  /// 由列表项地址归纳详情链接规律（路径部分的前缀 + 变化段 + 后缀）。
  String? _deriveHrefPattern(List<String> urls, String origin) {
    final infos = <_AnchorInfo>[];
    for (final url in urls) {
      if (!url.startsWith(origin)) continue;
      final uri = Uri.tryParse(url);
      if (uri == null || uri.path.isEmpty) continue;
      infos.add(_AnchorInfo(text: '', url: url, path: uri.path));
    }
    final templates = _induceTemplates(infos);
    if (templates.isEmpty) return null;
    return templates.first.pattern;
  }

  /// 详情页采样：标题/简介/封面/直链/播放页链接。
  Future<({ScrapedDetailSample sample, PlayChain chain})> _fetchDetailSample(
    String url,
  ) async {
    final html = await _fetchPage(url, '详情页');
    final doc = html_parser.parse(html);
    final base = Uri.parse(url);
    final title =
        doc.querySelector('h1')?.text.trim() ??
        doc.querySelector('title')?.text.trim() ??
        '';
    final description = _metaContent(doc, 'description') ??
        _metaContent(doc, 'og:description', property: true) ??
        _firstParagraph(doc);
    final cover = _metaContent(doc, 'og:image', property: true) ??
        _firstImage(doc, base) ??
        '';
    final mediaUrls = _extractMedia(doc, base);
    final playGroup = _derivePlayGroup(doc, base);
    final chain = mediaUrls.isNotEmpty
        ? PlayChain.directMedia
        : (playGroup != null ? PlayChain.viaPlayPage : PlayChain.none);
    return (
      sample: ScrapedDetailSample(
        title: title.replaceAll(RegExp(r'\s+'), ' ').trim(),
        description: description.replaceAll(RegExp(r'\s+'), ' ').trim(),
        cover: cover,
        mediaUrls: mediaUrls,
        playLinks: playGroup?.links ?? const <ScrapeLink>[],
        playHrefPattern: playGroup?.pattern,
      ),
      chain: chain,
    );
  }

  String? _metaContent(Document doc, String key, {bool property = false}) {
    final attr = property ? 'property' : 'name';
    final el = doc.querySelector('meta[$attr="$key"]');
    final content = el?.attributes['content']?.trim() ?? '';
    return content.isEmpty ? null : content;
  }

  String _firstParagraph(Document doc) {
    for (final p in doc.querySelectorAll('p')) {
      final text = p.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.length > 10) {
        return text.length > 200 ? text.substring(0, 200) : text;
      }
    }
    return '';
  }

  String? _firstImage(Document doc, Uri base) {
    for (final img in doc.querySelectorAll('img')) {
      final src =
          img.attributes['src'] ??
          img.attributes['data-src'] ??
          img.attributes['data-original'] ??
          '';
      if (src.isEmpty) continue;
      return base.resolveUri(Uri.tryParse(src) ?? Uri()).toString();
    }
    return null;
  }

  /// 直链：video/source 标签地址，以及带 .m3u8/.mp4 后缀的 iframe/链接地址。
  List<String> _extractMedia(Document doc, Uri base) {
    final out = <String>[];
    final seen = <String>{};
    void add(String? raw) {
      if (raw == null || raw.trim().isEmpty) return;
      final resolved =
          base.resolveUri(Uri.tryParse(raw.trim()) ?? Uri()).toString();
      if (seen.add(resolved)) out.add(resolved);
    }

    bool hasMediaSuffix(String raw) {
      final lower = raw.toLowerCase().split('?').first;
      return lower.endsWith('.m3u8') || lower.endsWith('.mp4');
    }

    for (final e in doc.querySelectorAll('video')) {
      add(e.attributes['src']);
    }
    for (final e in doc.querySelectorAll('video source')) {
      add(e.attributes['src']);
    }
    for (final e in doc.querySelectorAll('iframe')) {
      final src = e.attributes['src'] ?? '';
      if (hasMediaSuffix(src)) add(src);
    }
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'] ?? '';
      if (hasMediaSuffix(href)) add(href);
    }
    return out.take(5).toList();
  }

  static final _episodeText = RegExp(
    r'^(?:\d+|第\d+[集话期]|EP?\d+)$',
    caseSensitive: false,
  );

  /// 播放页链接组：两个以上同规律链接，且地址含 play 或文字像选集。
  _PlayGroup? _derivePlayGroup(Document doc, Uri base) {
    final infos = <_AnchorInfo>[];
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href']?.trim() ?? '';
      if (href.isEmpty) continue;
      final resolved = base.resolveUri(Uri.tryParse(href) ?? Uri());
      if (resolved.scheme != 'http' && resolved.scheme != 'https') continue;
      if (resolved.host != base.host) continue;
      if (_deadSuffixes.any(resolved.path.toLowerCase().endsWith)) continue;
      final text = a.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.length > 20) continue;
      infos.add(
        _AnchorInfo(text: text, url: resolved.toString(), path: resolved.path),
      );
    }
    for (final template in _induceTemplates(infos)) {
      final members = template.members;
      final hasPlayUrl = members.any(
        (m) => m.path.toLowerCase().contains('play'),
      );
      final episodeTexts =
          members.where((m) => _episodeText.hasMatch(m.text)).length;
      if (!hasPlayUrl && episodeTexts < 2) continue;
      return _PlayGroup(
        pattern: template.pattern,
        links: members
            .take(3)
            .map((m) => ScrapeLink(text: m.text, url: m.url))
            .toList(),
      );
    }
    return null;
  }

  /// 模板归纳：两两比对找同前缀+同后缀的链接组，按成员数/前缀长排序。
  List<_Template> _induceTemplates(List<_AnchorInfo> infos) {
    if (infos.length < 2) return const <_Template>[];
    final groups = <String, List<_AnchorInfo>>{};
    final keys = <String, (String, String)>{};
    for (var i = 0; i < infos.length; i++) {
      for (var j = i + 1; j < infos.length; j++) {
        final a = infos[i].path;
        final b = infos[j].path;
        final prefix = _commonPrefix(a, b);
        if (prefix.length < 2) continue;
        final suffix = _commonSuffix(
          a.substring(prefix.length),
          b.substring(prefix.length),
        );
        final midA = a.substring(prefix.length, a.length - suffix.length);
        final midB = b.substring(prefix.length, b.length - suffix.length);
        if (midA.isEmpty || midB.isEmpty || midA == midB) continue;
        if (!_looksLikeMiddle(midA) || !_looksLikeMiddle(midB)) continue;
        final key = '$prefix\x00$suffix';
        keys[key] = (prefix, suffix);
        final members = groups.putIfAbsent(key, () => []);
        if (!members.any((m) => m.url == infos[i].url)) {
          members.add(infos[i]);
        }
        if (!members.any((m) => m.url == infos[j].url)) {
          members.add(infos[j]);
        }
      }
    }
    final templates = <_Template>[];
    for (final entry in groups.entries) {
      if (entry.value.length < 2) continue;
      final (prefix, suffix) = keys[entry.key]!;
      templates.add(
        _Template(prefix: prefix, suffix: suffix, members: entry.value),
      );
    }
    templates.sort((a, b) {
      final bySize = b.members.length.compareTo(a.members.length);
      if (bySize != 0) return bySize;
      return b.prefix.length.compareTo(a.prefix.length);
    });
    return templates;
  }

  bool _looksLikeMiddle(String middle) {
    if (middle.isEmpty || middle.length > 80) return false;
    if (middle.contains('..') || middle.contains('"') || middle.contains('<')) {
      return false;
    }
    return !RegExp(r'\s').hasMatch(middle);
  }

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

  /// MacCMS 采样：采集接口列表 + 第一条的详情字段（展示用）。
  Future<_MacSamples> _fetchMacSamples(String origin) async {
    final items = <ScrapedListItem>[];
    ScrapedDetailSample? detail;
    var hasPlayUrls = false;
    String firstId = '';
    try {
      final listBody = await _fetchPage(
        '$origin/api.php/provide/vod/?ac=list&pg=1',
        '采集接口',
      );
      final decoded = jsonDecode(listBody);
      final list = decoded is Map ? decoded['list'] : null;
      if (list is List) {
        for (final v in list.take(12)) {
          if (v is! Map) continue;
          final name = '${v['vod_name'] ?? ''}'.trim();
          final pic = '${v['vod_pic'] ?? ''}'.trim();
          final id = '${v['vod_id'] ?? ''}'.trim();
          if (name.isEmpty) continue;
          if (firstId.isEmpty) firstId = id;
          items.add(
            ScrapedListItem(
              title: name,
              cover: pic,
              url: '$origin/api.php/provide/vod/?ac=detail&ids=$id',
            ),
          );
        }
      }
      if (firstId.isNotEmpty) {
        final detailBody = await _fetchPage(
          '$origin/api.php/provide/vod/?ac=detail&ids=$firstId',
          '采集详情',
        );
        final decodedDetail = jsonDecode(detailBody);
        final dlist = decodedDetail is Map ? decodedDetail['list'] : null;
        if (dlist is List && dlist.isNotEmpty && dlist.first is Map) {
          final v = dlist.first as Map;
          final playUrl = '${v['vod_play_url'] ?? ''}';
          final media = RegExp(r'https?://[^\s#\$]+')
              .allMatches(playUrl)
              .map((m) => m.group(0)!)
              .take(5)
              .toList();
          hasPlayUrls = media.isNotEmpty;
          detail = ScrapedDetailSample(
            title: '${v['vod_name'] ?? ''}',
            description: '${v['vod_content'] ?? ''}',
            cover: '${v['vod_pic'] ?? ''}',
            mediaUrls: media,
          );
        }
      }
    } catch (_) {
      // 采样失败不阻断：探站已验过接口，生成仍可用。
    }
    return _MacSamples(items: items, detail: detail, hasPlayUrls: hasPlayUrls);
  }
}

class _AnchorInfo {
  const _AnchorInfo({
    required this.text,
    required this.url,
    required this.path,
  });
  final String text;
  final String url;
  final String path;
}

class _Template {
  const _Template({
    required this.prefix,
    required this.suffix,
    required this.members,
  });
  final String prefix;
  final String suffix;
  final List<_AnchorInfo> members;

  /// 正则表达式源码：变化段全数字用 \d+，否则用 .+?。
  String get pattern {
    final mids = members.map(
      (m) => m.path.substring(
        prefix.length,
        m.path.length - suffix.length,
      ),
    );
    final allDigits = mids.every((m) => RegExp(r'^\d+$').hasMatch(m));
    final middle = allDigits ? r'\d+' : '.+?';
    return '${RegExp.escape(prefix)}$middle${RegExp.escape(suffix)}';
  }
}

class _PlayGroup {
  const _PlayGroup({required this.pattern, required this.links});
  final String pattern;
  final List<ScrapeLink> links;
}

class _MacSamples {
  const _MacSamples({
    required this.items,
    required this.detail,
    required this.hasPlayUrls,
  });
  final List<ScrapedListItem> items;
  final ScrapedDetailSample? detail;
  final bool hasPlayUrls;
}
