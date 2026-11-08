import 'content_crypto.dart';
import 'content_http.dart';
import 'content_models.dart';
import 'core_bridge.dart';

const tingshuwangHost = 'https://m.tingshuwang.cc';

List<ContentCategory> parseTingshuwangCategories(String html) {
  final categories = <ContentCategory>[];
  final seen = <String>{};
  final pattern = RegExp(
    r'href="/book/([a-z]+)/"[^>]*data-cid="\d+"[^>]*title="([^"]+)"',
  );
  for (final match in pattern.allMatches(html)) {
    final slug = match.group(1)!;
    final name = match.group(2)!.trim();
    if (name.isEmpty || !seen.add(slug)) continue;
    categories.add(ContentCategory(id: slug, name: name));
  }
  return categories;
}

String _stripTingshuwangTags(String s) => htmlUnescape(
  s.replaceAll(RegExp(r'<[^>]+>'), ' '),
).replaceAll(RegExp(r'\s+'), ' ').trim();

List<ContentBook> parseTingshuwangCards(String html) {
  final books = <ContentBook>[];
  final seen = <String>{};
  for (final block in html.split('<li>')) {
    final link = RegExp(
      r'href="/book/([A-Za-z0-9]+)/" class="full-link" title="([^"]+)"',
    ).firstMatch(block);
    if (link == null) continue;
    final cover = RegExp(r'<img src="([^"]+)"').firstMatch(block);
    if (cover == null || !cover.group(1)!.contains('d/file/cover')) continue;
    final slug = link.group(1)!;
    if (!seen.add(slug)) continue;
    final title = link.group(2)!.trim();
    if (title.isEmpty) continue;
    final latest =
        RegExp(
          r'<em>([^<]*第\d+集[^<]*)</em>',
        ).firstMatch(block)?.group(1)?.trim() ??
        '';
    final status =
        RegExp(
          r'<em class="(?:finished|serial)">([^<]+)</em>',
        ).firstMatch(block)?.group(1)?.trim() ??
        '';
    final author =
        RegExp(
          r'class="author">.*?<a[^>]*>([^<]+)</a>',
          dotAll: true,
        ).firstMatch(block)?.group(1)?.trim() ??
        '';
    final intro = RegExp(
      r'<p class="intro">(.*?)</p>',
      dotAll: true,
    ).firstMatch(block)?.group(1);
    books.add(
      ContentBook(
        id: slug,
        title: title,
        cover: cover.group(1)!,
        author: author,
        remarks: [latest, status].where((x) => x.isNotEmpty).join(' · '),
        intro: intro == null ? '' : _stripTingshuwangTags(intro),
      ),
    );
  }
  return books;
}

ContentPage parseTingshuwangCatalog(String html, int page) {
  final items = parseTingshuwangCards(html);
  return ContentPage(
    items: items,
    hasMore: items.isNotEmpty && html.contains('index_${page + 1}.html'),
    total: items.length,
  );
}

ContentPage parseTingshuwangSearch(String html) {
  final items = parseTingshuwangCards(html);
  return ContentPage(items: items, hasMore: false, total: items.length);
}

ContentBookDetail parseTingshuwangDetail(String html, String slug) {
  final title =
      RegExp(r'<title>([^<]+)有声小说').firstMatch(html)?.group(1)?.trim() ?? '';
  final author =
      RegExp(r'作者：([^-<]+)').firstMatch(html)?.group(1)?.trim() ?? '';
  final cover =
      RegExp(
        r'<img src="([^"]*d/file/cover[^"]*)"',
      ).firstMatch(html)?.group(1) ??
      '';
  final intro = RegExp(
    r'<div class="book-intr[^"]*">(.*?)</div>',
    dotAll: true,
  ).firstMatch(html)?.group(1);
  final chapters = <ContentChapter>[];
  final seen = <String>{};
  final pattern = RegExp(
    r'<a href="/book/[A-Za-z0-9]+/(\d+)\.html"[^>]*>([^<]+)</a>',
  );
  for (final match in pattern.allMatches(html)) {
    final num = match.group(1)!;
    final chapterTitle = match.group(2)!.trim();
    final url = '$tingshuwangHost/book/$slug/$num.html';
    if (chapterTitle.isEmpty || !seen.add(url)) continue;
    chapters.add(ContentChapter(id: url, title: chapterTitle));
  }
  return ContentBookDetail(
    book: ContentBook(
      id: slug,
      title: title,
      cover: cover,
      author: author,
      intro: intro == null ? '' : _stripTingshuwangTags(intro),
    ),
    chapters: chapters.reversed.toList(),
  );
}

String parseTingshuwangAudioUrl(String html) {
  final match = RegExp(r"videourl:'([^']+)'").firstMatch(html);
  final url = match?.group(1)?.trim() ?? '';
  if (url.isEmpty) throw AppFailure('该章节未找到音频地址');
  if (url.startsWith('http')) return url;
  if (url.startsWith('//')) return 'https:$url';
  return 'https://www.tingshuwang.cc$url';
}

class TingshuwangSource extends ContentSource {
  TingshuwangSource(this._http);

  final ContentHttp _http;

  @override
  String get id => 'tingshuwang';

  @override
  String get name => '听书网';

  @override
  ContentSection get section => ContentSection.audio;

  @override
  Future<List<ContentCategory>> categories() async {
    final html = await _http.get('$tingshuwangHost/book/');
    final categories = parseTingshuwangCategories(html);
    if (categories.isEmpty) throw AppFailure('听书网未返回分类');
    return categories;
  }

  @override
  Future<ContentPage> catalog(String categoryId, int page) async {
    final url = page <= 1
        ? '$tingshuwangHost/book/$categoryId/'
        : '$tingshuwangHost/book/$categoryId/index_$page.html';
    final html = await _http.get(url);
    return parseTingshuwangCatalog(html, page);
  }

  @override
  Future<ContentPage> search(String keyword, int page) async {
    if (page > 1) return const ContentPage(items: []);
    final encoded = Uri.encodeComponent(keyword);
    final html = await _http.get('$tingshuwangHost/so/$encoded/');
    return parseTingshuwangSearch(html);
  }

  @override
  Future<ContentBookDetail> detail(String bookId) async {
    final html = await _http.get('$tingshuwangHost/book/$bookId/');
    final parsed = parseTingshuwangDetail(html, bookId);
    if (parsed.chapters.isEmpty) throw AppFailure('该书暂无章节');
    return parsed;
  }

  @override
  Future<ContentAudioTrack> audioTrack(
    String bookId,
    ContentChapter chapter,
  ) async {
    final html = await _http.get(chapter.id);
    return ContentAudioTrack(url: parseTingshuwangAudioUrl(html));
  }
}
