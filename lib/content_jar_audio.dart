import 'content_models.dart';
import 'core_bridge.dart';
import 'jar_bridge.dart';
import 'models.dart';
import 'zakatv_builtin.dart';

class JarAudioContentSource extends ContentSource {
  @override
  String get id => 'jar_tingshu';

  @override
  String get name => '飞卢听书';

  @override
  ContentSection get section => ContentSection.audio;

  JarSiteSpec get _spec {
    final spec = JarBridge.specFor(
      JarSiteSpec.siteIdFor(zakatvJarId, 'go_tingshu'),
    );
    if (spec == null) throw AppFailure('飞卢听书源未就绪');
    return spec;
  }

  @override
  Future<List<ContentCategory>> categories() async {
    final spec = _spec;
    try {
      final result = await JarBridge.categories(spec);
      return [
        for (final category in result)
          ContentCategory(id: category.id, name: category.name),
      ];
    } on JarBridgeFailure catch (e) {
      throw AppFailure(e.message);
    }
  }

  @override
  Future<ContentPage> catalog(String categoryId, int page) async {
    final spec = _spec;
    try {
      final result = await JarBridge.catalog(
        spec,
        category: categoryId,
        page: page,
      );
      return _toPage(result);
    } on JarBridgeFailure catch (e) {
      throw AppFailure(e.message);
    }
  }

  @override
  Future<ContentPage> search(String keyword, int page) async {
    final spec = _spec;
    try {
      final result = await JarBridge.catalog(
        spec,
        query: keyword,
        page: page,
      );
      return _toPage(result);
    } on JarBridgeFailure catch (e) {
      throw AppFailure(e.message);
    }
  }

  ContentPage _toPage(CatalogPage page) => ContentPage(
    items: [
      for (final drama in page.items)
        ContentBook(
          id: drama.id,
          title: drama.title,
          cover: drama.cover,
          intro: drama.description,
          remarks: drama.heat.isNotEmpty ? drama.heat : drama.views,
          kind: drama.kind == 'folder' ? 'folder' : 'item',
          folderId: drama.folderId,
        ),
    ],
    hasMore: page.hasMore,
  );

  @override
  Future<ContentBookDetail> detail(String bookId) async {
    final spec = _spec;
    try {
      final result = await JarBridge.detail(
        spec,
        Drama(id: bookId, source: spec.siteId, title: bookId),
      );
      return ContentBookDetail(
        book: ContentBook(
          id: result.drama.id,
          title: result.drama.title,
          cover: result.drama.cover,
          intro: result.drama.description,
        ),
        chapters: [
          for (final episode in result.episodes)
            ContentChapter(
              id: episode.id,
              title: episode.title,
              meta: episode.raw['flag']?.toString() ?? '',
            ),
        ],
      );
    } on JarBridgeFailure catch (e) {
      throw AppFailure(e.message);
    }
  }

  @override
  Future<ContentAudioTrack> audioTrack(
    String bookId,
    ContentChapter chapter,
  ) async {
    final spec = _spec;
    try {
      final plan = await JarBridge.resolve(
        spec,
        Drama(id: bookId, source: spec.siteId, title: bookId),
        Episode({
          'id': chapter.id,
          'title': chapter.title,
          'flag': chapter.meta,
          'playId': chapter.id,
          'currentEpisode': 0,
        }, 0),
      );
      if (plan.needsParse) throw AppFailure('该集需要解析播放，听书区暂不支持');
      return ContentAudioTrack(url: plan.url, headers: plan.headers);
    } on JarBridgeFailure catch (e) {
      throw AppFailure(e.message);
    }
  }
}
