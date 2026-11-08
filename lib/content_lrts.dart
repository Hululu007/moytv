import 'content_http.dart';
import 'content_models.dart';
import 'core_bridge.dart';

const _ajax = 'https://m.lrts.me/ajax/';
const _categoryPageSize = 20;
const _episodePageSize = 50;

class LrtsCategories {
  static const values = <ContentCategory>[
    ContentCategory(id: '11', name: '玄幻奇幻'),
    ContentCategory(id: '8', name: '都市传说'),
    ContentCategory(id: '3109', name: '穿越架空'),
    ContentCategory(id: '14', name: '武侠仙侠'),
    ContentCategory(id: '3106', name: '青春校园'),
    ContentCategory(id: '12', name: '历史幻想'),
    ContentCategory(id: '3021', name: '科幻空间'),
    ContentCategory(id: '9042', name: '网游竞技'),
    ContentCategory(id: '9041', name: '热血军事'),
    ContentCategory(id: '44', name: '官场商战'),
    ContentCategory(id: '9045', name: '心理百科'),
    ContentCategory(id: '9046', name: '科学科普'),
    ContentCategory(id: '17', name: '人物传记'),
    ContentCategory(id: '3063', name: '纪实传奇'),
    ContentCategory(id: '1026', name: '哲学宗教'),
    ContentCategory(id: '9044', name: '文艺文化'),
    ContentCategory(id: '109', name: '公开课'),
    ContentCategory(id: '3059', name: '投资理财'),
    ContentCategory(id: '3058', name: '股市'),
    ContentCategory(id: '3057', name: '商业智慧'),
    ContentCategory(id: '16', name: '管理营销'),
    ContentCategory(id: '9048', name: '创业'),
    ContentCategory(id: '63', name: '益智故事'),
    ContentCategory(id: '3027', name: '儿童文学'),
    ContentCategory(id: '9031', name: '国学启蒙'),
    ContentCategory(id: '9029', name: '卡通动画'),
    ContentCategory(id: '9245', name: '少儿名著'),
    ContentCategory(id: '64', name: '少儿科普'),
    ContentCategory(id: '68', name: '少儿英语'),
    ContentCategory(id: '9060', name: '戏曲名家'),
    ContentCategory(id: '95', name: '豫剧'),
    ContentCategory(id: '89', name: '京剧'),
    ContentCategory(id: '93', name: '黄梅戏'),
    ContentCategory(id: '90', name: '越剧'),
    ContentCategory(id: '67', name: '鼓书琴书'),
  ];
}

class LrtsSource extends ContentSource {
  LrtsSource(this._http);

  final ContentHttp _http;
  final Map<String, List<String>> _categoryBookIds = {};

  @override
  String get id => 'lrts';

  @override
  String get name => '懒人听书';

  @override
  ContentSection get section => ContentSection.audio;

  @override
  String get note =>
      '分类/详情/播放已实拉；只列免费章节，付费章节需登录不在本源内；播放地址带时效签名，每次现取不缓存；搜索需登录，本源不登录故搜索不可用';

  ContentBook _bookFromRow(Map row) {
    var cover = '${row['cover'] ?? ''}';
    if (cover.isNotEmpty && !cover.contains('180')) {
      final dot = cover.lastIndexOf('.');
      if (dot > 0) {
        cover = '${cover.substring(0, dot)}_180x254${cover.substring(dot)}';
      }
    }
    var title = '${row['name'] ?? ''}'.trim();
    final tags = '${row['tags'] ?? ''}';
    if (tags.contains('VIP')) {
      title = '[VIP] $title';
    } else if (tags.contains('精品')) {
      title = '[精品] $title';
    }
    final finished = int.tryParse('${row['state'] ?? ''}') == 2;
    final sections = int.tryParse('${row['sections'] ?? ''}') ?? 0;
    var intro = '${row['recReason'] ?? ''}';
    if (intro.isEmpty || intro == 'null') intro = '${row['desc'] ?? ''}';
    return ContentBook(
      id: '${row['id'] ?? ''}',
      title: title,
      cover: cover,
      author: '${row['author'] ?? ''}'.trim(),
      intro: intro.trim(),
      remarks:
          '${finished ? '完本' : '连载'}${sections > 0 ? ' · $sections 集' : ''}',
    );
  }

  @override
  Future<List<ContentCategory>> categories() async => LrtsCategories.values;

  @override
  Future<ContentPage> catalog(String categoryId, int page) async {
    if (page <= 1) {
      final root = contentJsonObject(
        await _http.get(
          '${_ajax}getResourceList?dsize=$_categoryPageSize'
          '&entityId=$categoryId&entityType=1&pageNum=1&showFilters=1',
        ),
      );
      final useAlbums = (int.tryParse('${root['albumCount'] ?? ''}') ?? 0) > 0;
      final rows = (root[useAlbums ? 'albums' : 'books'] as List?) ?? const [];
      final ids = (root[useAlbums ? 'albumIds' : 'bookIds'] as List?)
              ?.map((e) => '$e')
              .toList() ??
          const [];
      _categoryBookIds[categoryId] = ids;
      final items = <ContentBook>[];
      for (final row in rows) {
        if (row is! Map) continue;
        final book = _bookFromRow(row);
        if (book.id.isEmpty || book.title.isEmpty) continue;
        items.add(book);
      }
      return ContentPage(
        items: items,
        hasMore: ids.length > _categoryPageSize,
      );
    }
    final ids = _categoryBookIds[categoryId] ?? const [];
    final from = (page - 1) * _categoryPageSize;
    if (from >= ids.length) {
      return const ContentPage(items: []);
    }
    final slice = ids.skip(from).take(_categoryPageSize).toList();
    final root = contentJsonObject(
      await _http.get(
        '${_ajax}getResourceList?dsize=$_categoryPageSize'
        '&entityId=$categoryId&entityType=0&pageNum=0&showFilters=0'
        '&page=$page&bookIds=[${slice.join(',')}]',
      ),
    );
    final useAlbums = (int.tryParse('${root['albumCount'] ?? ''}') ?? 0) > 0;
    final rows = (root[useAlbums ? 'albums' : 'books'] as List?) ?? const [];
    final items = <ContentBook>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final book = _bookFromRow(row);
      if (book.id.isEmpty || book.title.isEmpty) continue;
      items.add(book);
    }
    return ContentPage(
      items: items,
      hasMore: from + _categoryPageSize < ids.length,
    );
  }

  @override
  Future<ContentPage> search(String keyword, int page) async {
    final root = contentJsonObject(
      await _http.get(
        '${_ajax}search?keyWord=${Uri.encodeQueryComponent(keyword)}'
        '&pageSize=40&pageNum=$page&searchOption=1',
      ),
    );
    final status = int.tryParse('${root['status'] ?? ''}');
    final result = (root['data'] as Map?) ?? const {};
    final bookResult = (result['bookResult'] as Map?) ?? const {};
    final rows = (bookResult['list'] as List?) ?? const [];
    if (rows.isEmpty && (status == 485 || '${root['msg'] ?? ''}'.contains('登录'))) {
      throw AppFailure('懒人听书搜索需登录，本源不登录，暂不支持搜索');
    }
    final items = <ContentBook>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final book = _bookFromRow(row);
      if (book.id.isEmpty || book.title.isEmpty) continue;
      items.add(book);
    }
    final count = int.tryParse('${bookResult['count'] ?? ''}') ?? 0;
    final totalPage = count > 0 ? (count + 39) ~/ 40 : page;
    return ContentPage(
      items: items,
      hasMore: page < totalPage && items.isNotEmpty,
      total: totalPage,
    );
  }

  @override
  Future<ContentBookDetail> detail(String bookId) async {
    final chapters = <ContentChapter>[];
    var totalSections = 0;
    var skipped = 0;
    var page = 1;
    while (true) {
      final menu = contentJsonObject(
        await _http.get(
          '${_ajax}getBookMenu?bookId=$bookId'
          '&pageNum=$page&pageSize=$_episodePageSize&sortType=0',
        ),
      );
      final rows = (menu['list'] as List?) ?? const [];
      if (page == 1) {
        totalSections = int.tryParse('${menu['sections'] ?? ''}') ?? 0;
      }
      for (final row in rows) {
        if (row is! Map) continue;
        final free = int.tryParse('${row['payType'] ?? ''}') == 0;
        final title = '${row['name'] ?? ''}'.trim();
        if (!free) {
          skipped++;
          continue;
        }
        if (title.isEmpty) continue;
        chapters.add(
          ContentChapter(
            id: '${_ajax}getPlayPath?entityId=$bookId&entityType=3&opType=1'
                '&sections=[${row['section']}]&type=0',
            title: title,
          ),
        );
      }
      if (rows.length < _episodePageSize) break;
      page++;
      if (totalSections > 0 &&
          chapters.length + skipped >= totalSections) {
        break;
      }
    }
    final info = contentJsonObject(
      await _http.get('${_ajax}getBookInfo?id=$bookId'),
    );
    final extra = (info['extraInfos'] as List?) ?? const [];
    var intro = '';
    if (extra.isNotEmpty && extra.first is Map) {
      intro = '${(extra.first as Map)['content'] ?? ''}'.trim();
    }
    if (intro.isEmpty) intro = '${info['desc'] ?? ''}'.trim();
    final book = ContentBook(
      id: bookId,
      title: '${info['name'] ?? ''}'.trim(),
      cover: '${info['bestCover'] ?? ''}',
      author: '${info['author'] ?? ''}'.trim(),
      intro: intro,
      remarks: totalSections > 0 ? '共 $totalSections 集' : '',
    );
    return ContentBookDetail(
      book: book,
      chapters: chapters,
      note: skipped > 0 && totalSections > 0
          ? '全 $totalSections 集，本源只列免费的 ${chapters.length} 集'
          : '',
    );
  }

  @override
  Future<ContentAudioTrack> audioTrack(
    String bookId,
    ContentChapter chapter,
  ) async {
    if (!chapter.id.startsWith(_ajax)) {
      throw AppFailure('懒人听书免费章节缺少播放接口地址');
    }
    final root = contentJsonObject(await _http.get(chapter.id));
    final rows = (root['list'] as List?) ?? const [];
    if (rows.isEmpty || rows.first is! Map) {
      throw AppFailure('${root['msg'] ?? '无法获取音频地址'}');
    }
    final path = '${(rows.first as Map)['path'] ?? ''}'.trim();
    if (path.isEmpty) {
      throw AppFailure('${root['msg'] ?? '无法获取音频地址'}');
    }
    return ContentAudioTrack(
      url: path,
      headers: const {'User-Agent': contentUserAgent},
    );
  }
}
