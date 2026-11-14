import 'package:moyi/content_models.dart';
import 'package:moyi/content_registry.dart';
import 'package:moyi/global_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 全局搜索服务层回归：注册表全量收录、去重、并行聚合、单站失败隔离。
///
/// 对照修仙版 global_search_test.dart 按魔蚁注册表改写：魔蚁没有境界
/// 门禁（成人源也在列）、没有核心阅读站（阅读侧就是 ContentRegistry
/// 两区）、阅读侧 id 与视频侧不撞名（红果听书是 hongguo_audio），
/// 故无门禁谓词、无 readingCore 标记。
class _FakeSource implements ContentSource {
  _FakeSource({
    required this.id,
    required this.name,
    required this.section,
    this.items = const [],
    this.error,
    this.delay = Duration.zero,
  });

  @override
  final String id;
  @override
  final String name;
  @override
  final ContentSection section;
  final List<ContentBook> items;
  final Object? error;
  final Duration delay;

  @override
  String get note => '';

  @override
  Future<List<ContentCategory>> categories() async => const [];

  @override
  Future<ContentPage> catalog(String categoryId, int page) async =>
      throw UnimplementedError();

  @override
  Future<ContentPage> search(String keyword, int page) async {
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (error != null) throw error!;
    return ContentPage(items: items);
  }

  @override
  Future<ContentBookDetail> detail(String bookId) async =>
      throw UnimplementedError();

  @override
  Future<String> chapterText(String bookId, ContentChapter chapter) =>
      throw UnimplementedError();

  @override
  Future<List<String>> chapterPages(String bookId, ContentChapter chapter) =>
      throw UnimplementedError();

  @override
  Map<String, String> get pageHeaders => const {};

  @override
  Future<ContentAudioTrack> audioTrack(
    String bookId,
    ContentChapter chapter,
  ) async => throw UnimplementedError();
}

ContentBook _book(String id, String title) => ContentBook(id: id, title: title);

void main() {
  test('收齐两区：听书 9 个 + 阅读 19 个，id 唯一，成人源也在列', () {
    addTearDown(() => ContentRegistry.setNovelImports([]));
    ContentRegistry.setNovelImports([]);
    final targets = globalSearchBookTargets(
      audioSources: ContentRegistry.sourcesFor(ContentSection.audio),
      novelSources: ContentRegistry.sourcesFor(ContentSection.novel),
    );
    final audio = targets
        .where((t) => t.section == ContentSection.audio)
        .map((t) => t.source.id)
        .toList();
    final novel = targets
        .where((t) => t.section == ContentSection.novel)
        .map((t) => t.source.id)
        .toList();
    expect(audio, [
      'tingshuwang',
      'ximalaya',
      'hongguo_audio',
      'lrts',
      'hsvoice31',
      'tingyou',
      'hysxs',
      'asmrmoon',
      'jar_tingshu',
    ]);
    expect(novel.length, 19);
    expect(
      novel,
      containsAll(['aabook', 'buliang', 'mhbl', 'ho5ho', 'kxmanhua']),
    );
    // 无门禁：成人源 id 都在列；全表 id 不重复。
    expect(targets.map((t) => t.source.id).toSet().length, 28);
  });

  test('去重：同 id 两区都出现只留一个，听书优先', () {
    final targets = globalSearchBookTargets(
      audioSources: [
        _FakeSource(id: 'dup', name: '听书版', section: ContentSection.audio),
      ],
      novelSources: [
        _FakeSource(id: 'dup', name: '阅读版', section: ContentSection.novel),
        _FakeSource(id: 'only', name: '唯阅读', section: ContentSection.novel),
      ],
    );
    expect(targets.map((t) => t.source.id), ['dup', 'only']);
    expect(targets.first.section, ContentSection.audio);
    expect(targets.first.source.name, '听书版');
  });

  test('漫画挂在阅读区：漫画源目标 section 均为 novel', () {
    addTearDown(() => ContentRegistry.setNovelImports([]));
    ContentRegistry.setNovelImports([]);
    final targets = globalSearchBookTargets(
      audioSources: const [],
      novelSources: ContentRegistry.sourcesFor(ContentSection.novel),
    );
    final comics = targets.where(
      (t) => {
        'mhbl',
        'ho5ho',
        'nnhanman',
        '55comics',
        'kmh001',
        'csmanhua',
        'kxmanhua',
      }.contains(t.source.id),
    );
    expect(comics.length, 7);
    expect(comics.every((t) => t.section == ContentSection.novel), isTrue);
  });

  test('hongguo 不撞名：阅读侧只有 hongguo_audio，没有裸 hongguo', () {
    final targets = globalSearchBookTargets(
      audioSources: ContentRegistry.sourcesFor(ContentSection.audio),
      novelSources: ContentRegistry.sourcesFor(ContentSection.novel),
    );
    final ids = targets.map((t) => t.source.id).toSet();
    expect(ids, contains('hongguo_audio'));
    expect(ids, isNot(contains('hongguo')));
  });

  test('导入源进表：setNovelImports 后新源被收录', () {
    addTearDown(() => ContentRegistry.setNovelImports([]));
    ContentRegistry.setNovelImports([
      _FakeSource(id: 'import1', name: '导入源', section: ContentSection.novel),
    ]);
    final targets = globalSearchBookTargets(
      audioSources: const [],
      novelSources: ContentRegistry.sourcesFor(ContentSection.novel),
    );
    expect(targets.map((t) => t.source.id), contains('import1'));
  });

  test('聚合：三家假源都出结果 → 三组，区 / 源 / 条目正确', () async {
    final targets = [
      GlobalSearchBookTarget(
        source: _FakeSource(
          id: 'a1',
          name: '听书站',
          section: ContentSection.audio,
          items: [_book('1', '神瞳·听书')],
        ),
        section: ContentSection.audio,
      ),
      GlobalSearchBookTarget(
        source: _FakeSource(
          id: 'n1',
          name: '小说站',
          section: ContentSection.novel,
          items: [_book('2', '神瞳·小说')],
        ),
        section: ContentSection.novel,
      ),
      GlobalSearchBookTarget(
        source: _FakeSource(
          id: 'n2',
          name: '漫画站',
          section: ContentSection.novel,
          items: [_book('3', '神瞳·漫画')],
        ),
        section: ContentSection.novel,
      ),
    ];
    final groups = await searchReadingTargets('神瞳', targets);
    expect(groups.map((g) => g.source.id), ['a1', 'n1', 'n2']);
    expect(groups[0].section, ContentSection.audio);
    expect(groups[1].items.single.title, '神瞳·小说');
    expect(groups[2].source.name, '漫画站');
  });

  test('单站失败不拖垮整次搜索：抛错 / 超时 / 空结果都只回空组', () async {
    final targets = [
      GlobalSearchBookTarget(
        source: _FakeSource(
          id: 'good',
          name: '好站',
          section: ContentSection.audio,
          items: [_book('1', '神瞳')],
        ),
        section: ContentSection.audio,
      ),
      GlobalSearchBookTarget(
        source: _FakeSource(
          id: 'boom',
          name: '抛错站',
          section: ContentSection.audio,
          error: StateError('boom'),
        ),
        section: ContentSection.audio,
      ),
      GlobalSearchBookTarget(
        source: _FakeSource(
          id: 'slow',
          name: '超时站',
          section: ContentSection.novel,
          delay: const Duration(seconds: 5),
          items: [_book('2', '神瞳·慢')],
        ),
        section: ContentSection.novel,
      ),
      GlobalSearchBookTarget(
        source: _FakeSource(
          id: 'empty',
          name: '空结果站',
          section: ContentSection.novel,
        ),
        section: ContentSection.novel,
      ),
    ];
    final groups = await searchReadingTargets(
      '神瞳',
      targets,
      perSiteTimeout: const Duration(milliseconds: 100),
    );
    expect(groups.map((g) => g.source.id), ['good']);
    expect(groups.single.items.single.title, '神瞳');
  });

  test('空查询直接回空，不调源', () async {
    final targets = [
      GlobalSearchBookTarget(
        source: _FakeSource(
          id: 'v1',
          name: '站',
          section: ContentSection.audio,
          error: StateError('must not search'),
        ),
        section: ContentSection.audio,
      ),
    ];
    expect(await searchReadingTargets('   ', targets), isEmpty);
    expect(await searchReadingTargets('神瞳', const []), isEmpty);
  });
}
