// 移植自 NexHub（https://github.com/nexhub-app/NexHub，提交 37ddbdd，Apache-2.0）。
// 原始路径：lib/core/scraper/web_scrape_service.dart。
// 移植状态：改编——HttpFetcher（dio）未随本批移植，抓取改走魔蚁现有 ContentHttp
// 的 getRaw（同代理/超时链路）+ decodeContentBytes 解码；验证页判定改走随本批移植
// 的 VerificationDetector，命中时同样抛 VerificationRequiredException，契约不变。
// 抽取逻辑（ScrapeMode/ScrapeResult/ScrapeLink 与各模式分支）与原文一致。
// 另加可注入的 fetchHtml 供测试使用（默认走真实网络）。
// 2026-11-14 补万象同款两处行为：空页面抛错、视频模式原文直链兜底
// （见 scrape 内注释）；类型与字段不改，videoUrls 仍为 List<String>。
/// 网页爬取服务。
///
/// 基于魔蚁 [ContentHttp] 拉取 HTML，再用 [HtmlUtils] 按模式抽取内容。
/// 设计目标：把「抓取 + 解析」与 UI 隔离，UI 只负责展示。
library;

import '../../content_http.dart';
import '../utils/html_utils.dart';
import 'verification_detector.dart';

/// 爬取模式：影响抽取策略与结果展示形态。
enum ScrapeMode {
  general,
  novel,
  comic,
  video,
  article;
}

/// 通用链接条目（供 general 模式展示）。
class ScrapeLink {
  final String text;
  final String url;
  const ScrapeLink({required this.text, required this.url});
}

/// 爬取结果：按模式填充不同字段，UI 按需渲染。
class ScrapeResult {
  final String url;
  final String? pageTitle;
  final List<String> paragraphs;
  final List<String> imageUrls;
  final List<String> videoUrls;
  final List<ScrapeLink> links;

  const ScrapeResult({
    required this.url,
    this.pageTitle,
    this.paragraphs = const <String>[],
    this.imageUrls = const <String>[],
    this.videoUrls = const <String>[],
    this.links = const <ScrapeLink>[],
  });

  bool get isEmpty =>
      pageTitle == null &&
      paragraphs.isEmpty &&
      imageUrls.isEmpty &&
      videoUrls.isEmpty &&
      links.isEmpty;
}

/// 网页爬取服务——全应用单例。
class WebScrapeService {
  WebScrapeService._({Future<ContentResponse> Function(String url)? fetchHtml})
      // ignore: prefer_initializing_formals
      : _fetchHtml = fetchHtml;

  static final WebScrapeService instance = WebScrapeService._();

  /// 测试用构造：注入假抓取，替代真实网络。
  factory WebScrapeService.forTest(
    Future<ContentResponse> Function(String url) fetchHtml,
  ) => WebScrapeService._(fetchHtml: fetchHtml);

  final Future<ContentResponse> Function(String url)? _fetchHtml;
  final ContentHttp _http = ContentHttp();

  /// 抓取 [url] 并按 [mode] 抽取内容。
  ///
  /// 相对地址会自动基于 [url] 解析为绝对地址。命中验证特征时抛出
  /// [VerificationRequiredException]（由调用方决定重试或跳转验证页）。
  Future<ScrapeResult> scrape(String url, ScrapeMode mode) async {
    final fetch = _fetchHtml;
    final response = fetch != null
        ? await fetch(url)
        : await _http.getRaw(url);
    final html = decodeContentBytes(
      response.bodyBytes,
      contentType: response.headers['content-type'],
    );
    // 空页面不是「无结果」：HTTP 成功却返回空正文，说明响应被截断或
    // 站点根本没吐内容，必须当错误报出来，否则用户看到的只是空态，
    // 无法区分「网没通」与「页上真没东西」。
    if (html.trim().isEmpty) {
      throw Exception('服务器返回了空页面，无内容可爬：$url');
    }
    if (VerificationDetector.isVerificationRequired(
      statusCode: response.statusCode,
      body: html,
      headers: response.headers,
    )) {
      throw VerificationRequiredException(
        url: url,
        statusCode: response.statusCode,
        body: html,
      );
    }
    final base = Uri.tryParse(url);
    String? absolutize(String? raw) {
      if (raw == null || raw.isEmpty) return null;
      final uri = Uri.tryParse(raw);
      if (uri == null) return null;
      final resolved = base != null ? base.resolveUri(uri) : uri;
      return resolved.toString();
    }

    final pageTitle = HtmlUtils.query(html, 'title');

    switch (mode) {
      case ScrapeMode.general:
        final links = HtmlUtils.elements(html, 'a')
            .map(
              (e) => ScrapeLink(
                text: e.text.trim(),
                url: absolutize(e.attributes['href']) ?? '',
              ),
            )
            .where((l) => l.url.isNotEmpty)
            .toList();
        return ScrapeResult(url: url, pageTitle: pageTitle, links: links);

      case ScrapeMode.novel:
      case ScrapeMode.article:
        final paragraphs = HtmlUtils.queryAll(html, 'p')
            .where((s) => s.trim().length > 1)
            .toList();
        final imageUrls = mode == ScrapeMode.article
            ? _extractImages(html)
                .map((s) => absolutize(s))
                .where((s) => s != null)
                .cast<String>()
                .toList()
            : const <String>[];
        return ScrapeResult(
          url: url,
          pageTitle: pageTitle,
          paragraphs: paragraphs,
          imageUrls: imageUrls,
        );

      case ScrapeMode.comic:
        final imageUrls = _extractImages(html)
            .map((s) => absolutize(s))
            .where((s) => s != null)
            .cast<String>()
            .toList();
        return ScrapeResult(url: url, pageTitle: pageTitle, imageUrls: imageUrls);

      case ScrapeMode.video:
        final videoUrls = _extractVideos(html)
            .map((s) => absolutize(s))
            .where((s) => s != null)
            .cast<String>()
            .toList();
        return ScrapeResult(url: url, pageTitle: pageTitle, videoUrls: videoUrls);
    }
  }

  List<String> _extractImages(String html) => HtmlUtils.elements(html, 'img')
      .map(
        (e) =>
            e.attributes['src'] ??
            e.attributes['data-src'] ??
            e.attributes['data-original'] ??
            '',
      )
      .where((s) => s.isNotEmpty)
      .toList();

  List<String> _extractVideos(String html) {
    final list = <String>[];
    for (final e in HtmlUtils.elements(html, 'video')) {
      final src = e.attributes['src'];
      if (src != null && src.isNotEmpty) list.add(src);
    }
    for (final e in HtmlUtils.elements(html, 'video source')) {
      final src = e.attributes['src'];
      if (src != null && src.isNotEmpty) list.add(src);
    }
    for (final e in HtmlUtils.elements(html, 'iframe')) {
      final src = e.attributes['src'];
      if (src != null && src.isNotEmpty) list.add(src);
    }
    // 兜底：多数视频站把流地址藏在 <script>/JSON 里，页面上根本没有
    // <video> 标签。直接在原文里扫流媒体直链（m3u8/mp4 等），否则
    // 视频模式对这类站永远是空结果。只认绝对地址与 // 协议相对地址，
    // 去重、上限 100 条，避免把页面噪音全捞进来。
    final seen = list.toSet();
    final streamPattern = RegExp(
      r'''(?:https?:)?//[^\s"'<>\\]+\.(?:m3u8|mp4|m4v|mov|flv|mkv|avi|webm)(?:\?[^\s"'<>\\]*)?''',
      caseSensitive: false,
    );
    for (final m in streamPattern.allMatches(html)) {
      if (list.length >= 100) break;
      final candidate = m.group(0)!;
      if (seen.add(candidate)) {
        list.add(candidate);
      }
    }
    return list;
  }
}
