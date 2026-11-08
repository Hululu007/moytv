import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'content_models.dart';
import 'core_bridge.dart';
import 'import_file_store.dart';

class LegadoJsonInfo {
  const LegadoJsonInfo({
    required this.name,
    required this.url,
    required this.type,
  });

  final String name;
  final String url;
  final int type;
}

final _loginPattern = RegExp('登录|登陆|扫码|须登陆|需登录|需登陆|要登录');

LegadoJsonInfo validateLegadoJson(String text) {
  if (text.trim().isEmpty) throw const FormatException('空文件');
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    throw const FormatException('不是合法 JSON');
  }
  if (decoded is! Map) throw const FormatException('不是书源 JSON');
  final map = Map<String, dynamic>.from(decoded);
  final url = map['bookSourceUrl']?.toString().trim() ?? '';
  if (url.isEmpty) throw const FormatException('缺少源地址');
  final searchUrl = map['searchUrl']?.toString().trim() ?? '';
  if (searchUrl.isEmpty) throw const FormatException('缺少搜索地址');
  const groups = {
    'ruleSearch': '缺少搜索规则',
    'ruleBookInfo': '缺少详情规则',
    'ruleToc': '缺少目录规则',
    'ruleContent': '缺少正文规则',
  };
  for (final entry in groups.entries) {
    final group = map[entry.key];
    if (group is! Map || group.isEmpty) throw FormatException(entry.value);
  }
  final loginUrl = map['loginUrl']?.toString().trim() ?? '';
  final name = map['bookSourceName']?.toString() ?? '';
  final comment = map['bookSourceComment']?.toString() ?? '';
  if (loginUrl.isNotEmpty ||
      _loginPattern.hasMatch(name) ||
      _loginPattern.hasMatch(comment)) {
    throw const FormatException('需要登录，暂不支持');
  }
  final typeValue = map['bookSourceType'];
  final type = typeValue is num
      ? typeValue.toInt()
      : int.tryParse(typeValue?.toString() ?? '') ?? 0;
  if (type != 0 && type != 2) {
    throw const FormatException('仅支持小说与漫画源');
  }
  return LegadoJsonInfo(name: name.isEmpty ? url : name, url: url, type: type);
}

String _text(Object? value) => value?.toString() ?? '';

List<ContentBook> legadoBooks(dynamic result) {
  if (result is! List) return const [];
  final books = <ContentBook>[];
  for (final row in result) {
    if (row is! Map) continue;
    final map = Map<String, dynamic>.from(row);
    final title = _text(map['title']);
    final url = _text(map['url']);
    if (title.isEmpty && url.isEmpty) continue;
    books.add(
      ContentBook(
        id: url,
        title: title.isEmpty ? url : title,
        cover: _text(map['cover']),
        author: _text(map['author']),
        intro: _text(map['intro']),
      ),
    );
  }
  return books;
}

List<ContentChapter> legadoChapters(dynamic result) {
  if (result is! List) return const [];
  final chapters = <ContentChapter>[];
  for (final row in result) {
    if (row is! Map) continue;
    final map = Map<String, dynamic>.from(row);
    final title = _text(map['title']);
    final url = _text(map['url']);
    if (title.isEmpty && url.isEmpty) continue;
    chapters.add(ContentChapter(id: url, title: title));
  }
  return chapters;
}

List<ContentCategory> legadoCategories(dynamic result) {
  if (result is! List) return const [];
  final categories = <ContentCategory>[];
  for (final row in result) {
    if (row is! Map) continue;
    final map = Map<String, dynamic>.from(row);
    final title = _text(map['title']);
    final url = _text(map['url']);
    if (title.isEmpty && url.isEmpty) continue;
    categories.add(
      ContentCategory(id: url, name: title.isEmpty ? url : title),
    );
  }
  return categories;
}

String legadoContentText(dynamic result) {
  if (result is! Map) throw AppFailure('该章暂无正文');
  final map = Map<String, dynamic>.from(result);
  final text = _text(map['content']);
  if (text.isEmpty) {
    final images = map['images'];
    if (images is List && images.isNotEmpty) {
      throw AppFailure('该章节为图片内容，暂不支持');
    }
    throw AppFailure('该章暂无正文');
  }
  return text;
}

String legadoNovelUrl(String title, String text) =>
    'novel://${jsonEncode({'title': title, 'content': text})}';

String legadoPicsUrl(List<String> urls) => 'pics://${urls.join('&&')}';

List<String> legadoPages(dynamic result) {
  if (result is! Map) return const [];
  final map = Map<String, dynamic>.from(result);
  final images = map['images'];
  final rows = <dynamic>[];
  if (images is String && images.isNotEmpty) {
    try {
      final decoded = jsonDecode(images);
      if (decoded is List) rows.addAll(decoded);
    } catch (_) {}
  } else if (images is List) {
    rows.addAll(images);
  }
  final urls = <String>[];
  for (final row in rows) {
    if (row is String) {
      if (row.trim().isNotEmpty) urls.add(row.trim());
    } else if (row is Map) {
      final url = Map<String, dynamic>.from(row)['url']?.toString() ?? '';
      if (url.trim().isNotEmpty) urls.add(url.trim());
    }
  }
  return urls;
}

class JsonContentSource extends ContentSource {
  JsonContentSource({
    required this.id,
    required this.name,
    this.assetPath = '',
    this.importedFileName = '',
    this.section = ContentSection.novel,
    this.sourceType = 0,
  });

  @override
  final String id;

  @override
  final String name;

  final String assetPath;
  final String importedFileName;

  @override
  final ContentSection section;

  final int sourceType;

  bool get isComic => sourceType == 2;

  @override
  String get note => importedFileName.isNotEmpty ? '导入 JSON 书源' : '';

  static final _repository = NativeRepository();

  String? _json;

  Future<String> _sourceJson() async {
    final cached = _json;
    if (cached != null) return cached;
    String text;
    if (importedFileName.isNotEmpty) {
      final path = await ImportFileStore.pathOf(importedFileName);
      try {
        text = await File(path).readAsString();
      } catch (_) {
        throw AppFailure('JSON 书源文件已丢失，请删除后重新导入');
      }
    } else {
      text = await rootBundle.loadString(assetPath);
    }
    _json = text;
    return text;
  }

  Future<dynamic> _run(String action, String input) async {
    final json = await _sourceJson();
    return _repository.legadoRun(json, action, input);
  }

  @override
  Future<List<ContentCategory>> categories() async {
    final rows = legadoCategories(await _run('exploreCategories', ''));
    if (rows.isEmpty) return const [ContentCategory(id: '', name: '全部')];
    return rows;
  }

  @override
  Future<ContentPage> catalog(String categoryId, int page) async {
    if (categoryId.isEmpty) return const ContentPage(items: []);
    final items = legadoBooks(await _run('explore', '$categoryId\x01$page'));
    return ContentPage(items: items, hasMore: items.isNotEmpty);
  }

  @override
  Future<ContentPage> search(String keyword, int page) async {
    final items = legadoBooks(await _run('search', '$keyword\x01$page'));
    return ContentPage(items: items, hasMore: false);
  }

  @override
  Future<ContentBookDetail> detail(String bookId) async {
    final chapters = legadoChapters(await _run('toc', bookId));
    return ContentBookDetail(
      book: ContentBook(id: bookId, title: ''),
      chapters: chapters,
    );
  }

  @override
  Future<String> chapterText(String bookId, ContentChapter chapter) async {
    if (isComic) throw AppFailure('漫画章节请用图片浏览');
    return legadoContentText(await _run('content', chapter.id));
  }

  @override
  Future<List<String>> chapterPages(
    String bookId,
    ContentChapter chapter,
  ) async {
    if (!isComic) throw AppFailure('该源不支持图片章节');
    final pages = legadoPages(await _run('content', chapter.id));
    if (pages.isEmpty) throw AppFailure('该章节无图片');
    return pages;
  }

  @override
  Future<ContentAudioTrack> audioTrack(
    String bookId,
    ContentChapter chapter,
  ) async {
    if (isComic) {
      final pages = await chapterPages(bookId, chapter);
      return ContentAudioTrack(url: legadoPicsUrl(pages));
    }
    final text = await chapterText(bookId, chapter);
    return ContentAudioTrack(url: legadoNovelUrl(chapter.title, text));
  }
}
