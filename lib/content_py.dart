import 'package:flutter/services.dart' show rootBundle;

import 'content_models.dart';
import 'core_bridge.dart';
import 'import_file_store.dart';
import 'py_bridge.dart';

List<ContentChapter> parsePyPlayUrl(String playFrom, String playUrl) {
  final flags = playFrom.split(r'$$$');
  final lines = playUrl.split(r'$$$');
  if (lines.isEmpty || lines.first.trim().isEmpty) return const [];
  final flag = flags.isNotEmpty ? flags.first.trim() : '';
  final chapters = <ContentChapter>[];
  for (final part in lines.first.split('#')) {
    final sep = part.indexOf(r'$');
    if (sep <= 0) continue;
    final title = part.substring(0, sep).trim();
    final playId = part.substring(sep + 1).trim();
    if (title.isEmpty || playId.isEmpty) continue;
    chapters.add(ContentChapter(id: playId, title: title, meta: flag));
  }
  return chapters;
}

List<ContentCategory> parsePyFilterCategories(
  Map<String, dynamic> home,
  String fixedCategoryId,
  String filterKey,
) {
  final groups = home['filters']?[fixedCategoryId] as List? ?? const [];
  for (final group in groups) {
    if (group is! Map) continue;
    final map = Map<String, dynamic>.from(group);
    if ((map['key']?.toString() ?? '') != filterKey) continue;
    final values = map['value'] as List? ?? const [];
    final categories = <ContentCategory>[
      const ContentCategory(id: '', name: '全部'),
    ];
    for (final value in values) {
      if (value is! Map) continue;
      final row = Map<String, dynamic>.from(value);
      final id = row['v']?.toString() ?? '';
      final label = row['n']?.toString() ?? '';
      if (id.isEmpty) continue;
      categories.add(ContentCategory(id: id, name: label.isEmpty ? id : label));
    }
    if (categories.length > 1) return categories;
  }
  return const [];
}

class PyContentSource extends ContentSource {
  PyContentSource({
    required this.id,
    required this.name,
    this.assetPath = '',
    this.importedFileName = '',
    this.section = ContentSection.audio,
    this.fixedCategoryId = '',
    this.fixedCategoryName = '',
    this.filterKey = '',
  });

  @override
  final String id;

  @override
  final String name;

  final String assetPath;
  final String importedFileName;

  @override
  final ContentSection section;

  final String fixedCategoryId;
  final String fixedCategoryName;
  final String filterKey;

  String? _path;

  @override
  String get note => importedFileName.isNotEmpty ? '导入 py 蜘蛛' : '';

  Future<String> _spiderPath() async {
    final cached = _path;
    if (cached != null) return cached;
    if (importedFileName.isNotEmpty) {
      final path = await ImportFileStore.pathOf(importedFileName);
      _path = path;
      return path;
    }
    final bytes = await rootBundle.load(assetPath);
    final fileName = await ImportFileStore.save(
      'builtin_$id',
      'py',
      bytes.buffer.asUint8List(),
    );
    final path = await ImportFileStore.pathOf(fileName);
    _path = path;
    return path;
  }

  String _text(Object? value) => value?.toString() ?? '';

  ContentBook _bookFromRow(Map<String, dynamic> row) {
    return ContentBook(
      id: _text(row['vod_id']),
      title: _text(row['vod_name']).isEmpty
          ? _text(row['vod_id'])
          : _text(row['vod_name']),
      cover: _text(row['vod_pic']),
      author: _text(row['vod_actor']),
      remarks: _text(row['vod_remarks']),
      intro: _text(row['vod_content']),
    );
  }

  @override
  Future<List<ContentCategory>> categories() async {
    if (fixedCategoryId.isNotEmpty) {
      final fallback = [
        ContentCategory(
          id: fixedCategoryId,
          name: fixedCategoryName.isEmpty ? '听书' : fixedCategoryName,
        ),
      ];
      if (filterKey.isEmpty) return fallback;
      try {
        final path = await _spiderPath();
        final home = await PyBridge.call(path, {'action': 'categories'});
        final categories = parsePyFilterCategories(
          Map<String, dynamic>.from(home),
          fixedCategoryId,
          filterKey,
        );
        if (categories.isNotEmpty) return categories;
      } catch (_) {}
      return fallback;
    }
    final path = await _spiderPath();
    final home = await PyBridge.call(path, {'action': 'categories'});
    final rows = home['class'] as List? ?? const [];
    final categories = <ContentCategory>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final map = Map<String, dynamic>.from(row);
      final categoryId = _text(map['type_id']);
      final categoryName = _text(map['type_name']);
      if (categoryId.isEmpty) continue;
      categories.add(
        ContentCategory(
          id: categoryId,
          name: categoryName.isEmpty ? categoryId : categoryName,
        ),
      );
    }
    if (categories.isEmpty) throw AppFailure('该源暂无分类');
    return categories;
  }

  @override
  Future<ContentPage> catalog(String categoryId, int page) async {
    final path = await _spiderPath();
    final effectiveCategory = fixedCategoryId.isNotEmpty
        ? fixedCategoryId
        : categoryId;
    final request = <String, Object>{
      'action': 'catalog',
      'category': effectiveCategory,
      'page': page,
    };
    if (fixedCategoryId.isNotEmpty &&
        filterKey.isNotEmpty &&
        categoryId.isNotEmpty &&
        categoryId != fixedCategoryId) {
      request['extend'] = {filterKey: categoryId};
    }
    final result = await PyBridge.call(path, request);
    final rows = result['list'] as List? ?? const [];
    final items = <ContentBook>[];
    for (final row in rows) {
      if (row is Map) items.add(_bookFromRow(Map<String, dynamic>.from(row)));
    }
    final pageCount = result['pagecount'] is num
        ? (result['pagecount'] as num).toInt()
        : page;
    return ContentPage(
      items: items,
      hasMore: items.isNotEmpty && page < pageCount,
    );
  }

  @override
  Future<ContentPage> search(String keyword, int page) async {
    final path = await _spiderPath();
    final result = await PyBridge.call(path, {
      'action': 'search',
      'query': keyword,
      'page': page,
    });
    final rows = result['list'] as List? ?? const [];
    final items = <ContentBook>[];
    for (final row in rows) {
      if (row is Map) items.add(_bookFromRow(Map<String, dynamic>.from(row)));
    }
    return ContentPage(items: items, hasMore: false);
  }

  @override
  Future<ContentBookDetail> detail(String bookId) async {
    final path = await _spiderPath();
    final result = await PyBridge.call(path, {
      'action': 'detail',
      'vodId': bookId,
    });
    final rows = result['list'] as List? ?? const [];
    if (rows.isEmpty || rows.first is! Map) throw AppFailure('该书暂无详情');
    final vod = Map<String, dynamic>.from(rows.first as Map);
    final book = _bookFromRow(vod);
    final chapters = parsePyPlayUrl(
      _text(vod['vod_play_from']),
      _text(vod['vod_play_url']),
    );
    return ContentBookDetail(
      book: book,
      chapters: chapters,
      note: _text(vod['vod_content']),
    );
  }

  @override
  Future<ContentAudioTrack> audioTrack(
    String bookId,
    ContentChapter chapter,
  ) async {
    if (chapter.id.startsWith('http://') ||
        chapter.id.startsWith('https://')) {
      return ContentAudioTrack(url: chapter.id);
    }
    final path = await _spiderPath();
    final result = await PyBridge.call(path, {
      'action': 'resolve',
      'flag': chapter.meta,
      'playId': chapter.id,
    });
    final url = _text(result['url']).isNotEmpty
        ? _text(result['url'])
        : _text(result['playUrl']);
    if (url.isEmpty) throw AppFailure('该集暂无音频地址');
    final headers = <String, String>{};
    final rawHeaders = result['header'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        headers[key.toString()] = value.toString();
      });
    }
    return ContentAudioTrack(url: url, headers: headers);
  }
}
