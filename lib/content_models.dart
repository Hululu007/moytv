import 'core_bridge.dart';

enum ContentSection { audio, novel }

extension ContentSectionLabel on ContentSection {
  String get title => switch (this) {
    ContentSection.audio => '听书',
    ContentSection.novel => '阅读',
  };
}

class ContentCategory {
  const ContentCategory({required this.id, required this.name});

  final String id;
  final String name;
}

class ContentBook {
  const ContentBook({
    required this.id,
    required this.title,
    this.cover = '',
    this.author = '',
    this.remarks = '',
    this.intro = '',
    this.kind = 'item',
    this.folderId = '',
  });

  final String id;
  final String title;
  final String cover;
  final String author;
  final String remarks;
  final String intro;

  /// item=内容卡（点击进详情）；folder=文件夹卡（点击以 [folderId] 作为
  /// 分类参数再次请求列表下钻，与影视区文件夹通道同一口径）。
  final String kind;
  final String folderId;
  bool get isFolder => kind == 'folder';
  String get drillId => folderId.isNotEmpty ? folderId : id;
}

class ContentChapter {
  const ContentChapter({required this.id, required this.title, this.meta = ''});

  final String id;
  final String title;
  final String meta;
}

class ContentBookDetail {
  const ContentBookDetail({
    required this.book,
    required this.chapters,
    this.note = '',
  });

  final ContentBook book;
  final List<ContentChapter> chapters;
  final String note;
}

class ContentPage {
  const ContentPage({
    required this.items,
    this.hasMore = false,
    this.total = 0,
  });

  final List<ContentBook> items;
  final bool hasMore;
  final int total;
}

class ContentAudioTrack {
  const ContentAudioTrack({required this.url, this.headers = const {}});

  final String url;
  final Map<String, String> headers;
}

abstract class ContentSource {
  String get id;
  String get name;
  ContentSection get section;
  String get note => '';

  Future<List<ContentCategory>> categories();
  Future<ContentPage> catalog(String categoryId, int page);
  Future<ContentPage> search(String keyword, int page);
  Future<ContentBookDetail> detail(String bookId);

  Future<String> chapterText(String bookId, ContentChapter chapter) =>
      throw AppFailure('该源不支持正文读取');

  Future<List<String>> chapterPages(String bookId, ContentChapter chapter) =>
      throw AppFailure('该源不支持图片章节');

  Map<String, String> get pageHeaders => const {};

  Future<ContentAudioTrack> audioTrack(String bookId, ContentChapter chapter) =>
      throw AppFailure('该源不支持音频播放');
}
