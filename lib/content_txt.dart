import 'dart:convert';
import 'dart:io';

import 'package:enough_convert/gbk.dart';

import 'content_models.dart';
import 'core_bridge.dart';
import 'import_file_store.dart';

String decodeTxtBytes(List<int> bytes) {
  var body = bytes;
  if (body.length >= 3 &&
      body[0] == 0xEF &&
      body[1] == 0xBB &&
      body[2] == 0xBF) {
    body = body.sublist(3);
  }
  try {
    return utf8.decode(body);
  } on FormatException {
    return gbk.decode(body);
  }
}

class TxtChapter {
  const TxtChapter({required this.title, required this.body});

  final String title;
  final String body;
}

final _numberedHeading = RegExp(
  r'^第\s*[0-9一二三四五六七八九十百千两零〇○壹贰叁肆伍陆柒捌玖拾佰仟]+\s*[章节卷回集篇]',
);
final _namedHeading = RegExp(
  r'^(序章|楔子|引子|前言|后记|番外|尾声|终章|序言|引言|跋)([ :：·、\-].*)?$',
);

bool _isHeading(String line) {
  final text = line.trim();
  if (text.isEmpty || text.length > 40) return false;
  return _numberedHeading.hasMatch(text) || _namedHeading.hasMatch(text);
}

List<TxtChapter> splitTxtChapters(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = normalized.split('\n');
  final titles = <String>[];
  final bodies = <StringBuffer>[];
  var preface = StringBuffer();
  for (final line in lines) {
    if (_isHeading(line)) {
      titles.add(line.trim());
      bodies.add(StringBuffer());
    } else if (titles.isEmpty) {
      preface.writeln(line);
    } else {
      bodies.last.writeln(line);
    }
  }
  if (titles.isEmpty) {
    return [TxtChapter(title: '全文', body: text.trim())];
  }
  final chapters = <TxtChapter>[];
  for (var i = 0; i < titles.length; i++) {
    var body = bodies[i].toString().trim();
    if (i == 0) {
      final head = preface.toString().trim();
      if (head.isNotEmpty) {
        body = body.isEmpty ? head : '$head\n\n$body';
      }
    }
    if (body.isEmpty) continue;
    chapters.add(TxtChapter(title: titles[i], body: body));
  }
  if (chapters.isEmpty) {
    return [TxtChapter(title: '全文', body: text.trim())];
  }
  return chapters;
}

class TxtContentSource extends ContentSource {
  TxtContentSource({
    required this.id,
    required this.name,
    required this.importedFileName,
    this.section = ContentSection.novel,
  });

  @override
  final String id;

  @override
  final String name;

  @override
  final ContentSection section;

  final String importedFileName;

  @override
  String get note => '导入 txt';

  List<TxtChapter>? _chapters;

  Future<List<TxtChapter>> _loadChapters() async {
    final cached = _chapters;
    if (cached != null) return cached;
    final path = await ImportFileStore.pathOf(importedFileName);
    final bytes = await File(path).readAsBytes();
    final chapters = splitTxtChapters(decodeTxtBytes(bytes));
    _chapters = chapters;
    return chapters;
  }

  Future<TxtChapter> _chapter(ContentChapter chapter) async {
    final chapters = await _loadChapters();
    final index = int.tryParse(chapter.id);
    if (index == null || index < 0 || index >= chapters.length) {
      throw AppFailure('章节不存在');
    }
    return chapters[index];
  }

  ContentBook _book(int chapterCount) => ContentBook(
    id: id,
    title: name,
    remarks: '共$chapterCount章',
  );

  @override
  Future<List<ContentCategory>> categories() async =>
      const [ContentCategory(id: 'all', name: '全部')];

  @override
  Future<ContentPage> catalog(String categoryId, int page) async {
    if (page != 1) return const ContentPage(items: []);
    final chapters = await _loadChapters();
    return ContentPage(items: [_book(chapters.length)], total: 1);
  }

  @override
  Future<ContentPage> search(String keyword, int page) async {
    if (page != 1 || keyword.isEmpty) {
      return catalog('', page);
    }
    if (!name.contains(keyword)) return const ContentPage(items: []);
    final chapters = await _loadChapters();
    return ContentPage(items: [_book(chapters.length)], total: 1);
  }

  @override
  Future<ContentBookDetail> detail(String bookId) async {
    final chapters = await _loadChapters();
    return ContentBookDetail(
      book: _book(chapters.length),
      chapters: [
        for (var i = 0; i < chapters.length; i++)
          ContentChapter(id: '$i', title: chapters[i].title),
      ],
    );
  }

  @override
  Future<String> chapterText(String bookId, ContentChapter chapter) async {
    return (await _chapter(chapter)).body;
  }

  @override
  Future<ContentAudioTrack> audioTrack(
    String bookId,
    ContentChapter chapter,
  ) async {
    final item = await _chapter(chapter);
    return ContentAudioTrack(
      url:
          'novel://${jsonEncode({'title': item.title, 'content': item.body})}',
    );
  }
}
