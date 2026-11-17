import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/html_host/html_site.dart';
import 'package:moyi/imported_site_record.dart';
import 'package:moyi/models.dart';

void main() {
  group('HtmlSiteEntry.fromFileContent', () {
    test('Route A: html file keeps its content and derives the title name', () {
      final entry = HtmlSiteEntry.fromFileContent(
        siteKey: 'html:demo',
        fileName: 'demo.html',
        bytes: utf8.encode(
          '<html><head><title> 演示站 </title></head><body>hi</body></html>',
        ),
      );
      expect(entry.route, HtmlSiteRoute.singleFile);
      expect(entry.siteName, '演示站');
      expect(entry.entryHtml, contains('<body>hi</body>'));
      expect(entry.isSingleFile, isTrue);
    });

    test('Route A: explicit site name wins over the title', () {
      final entry = HtmlSiteEntry.fromFileContent(
        siteKey: 'html:demo',
        fileName: 'demo.html',
        bytes: utf8.encode('<html><head><title>标题</title></head></html>'),
        siteName: '登记名',
      );
      expect(entry.siteName, '登记名');
    });

    test('Route A: no title falls back to the file stem', () {
      final entry = HtmlSiteEntry.fromFileContent(
        siteKey: 'html:mysite',
        fileName: 'mysite.htm',
        bytes: utf8.encode('<html><body>no title</body></html>'),
      );
      expect(entry.siteName, 'mysite');
    });

    test('Route B: json manifest with an extensions list', () {
      final entry = HtmlSiteEntry.fromFileContent(
        siteKey: 'html:enhanced',
        fileName: 'enhanced.json',
        bytes: utf8.encode(
          jsonEncode({
            'name': '增强站',
            'siteUrl': 'https://site.example.com/',
            'extensions': [
              {'id': 'ext1', 'code': 'fm.log("hi");', 'runAt': 'idle'},
              {'id': 'empty', 'name': 'no code at all'},
            ],
          }),
        ),
      );
      expect(entry.route, HtmlSiteRoute.injected);
      expect(entry.siteName, '增强站');
      expect(entry.siteUrl, 'https://site.example.com/');
      expect(entry.extensions, hasLength(1));
      expect(entry.extensions.single.id, 'ext1');
      expect(entry.extensions.single.runAt, 'idle');
    });

    test('Route B: single-extension shorthand', () {
      final entry = HtmlSiteEntry.fromFileContent(
        siteKey: 'html:short',
        fileName: 'short.json',
        bytes: utf8.encode(
          jsonEncode({
            'url': 'https://site.example.com/',
            'code': 'fm.log("hi");',
          }),
        ),
      );
      expect(entry.extensions, hasLength(1));
      expect(entry.siteName, 'short');
    });

    test('invalid contents fail with FormatException', () {
      expect(
        () => HtmlSiteEntry.fromFileContent(
          siteKey: 'html:e',
          fileName: 'e.html',
          bytes: const [],
        ),
        throwsFormatException,
      );
      expect(
        () => HtmlSiteEntry.fromFileContent(
          siteKey: 'html:e',
          fileName: 'e.json',
          bytes: utf8.encode('not json'),
        ),
        throwsFormatException,
      );
      expect(
        () => HtmlSiteEntry.fromFileContent(
          siteKey: 'html:e',
          fileName: 'e.json',
          bytes: utf8.encode(
            jsonEncode({'siteUrl': 'https://site.example.com/'}),
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => HtmlSiteEntry.fromFileContent(
          siteKey: 'html:e',
          fileName: 'e.json',
          bytes: utf8.encode(
            jsonEncode({'siteUrl': 'ftp://site.example.com/', 'code': 'x'}),
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => HtmlSiteEntry.fromFileContent(
          siteKey: 'html:e',
          fileName: 'e.html',
          bytes: [0xff, 0xfe, 0x00],
        ),
        throwsFormatException,
      );
    });
  });

  group('HtmlExtension.fromJson', () {
    test('normalizes unknown runAt to end and defaults the id', () {
      final ext = HtmlExtension.fromJson({'code': 'x', 'runAt': 'weird'});
      expect(ext.runAt, 'end');
      expect(ext.id, 'ext-0');
      expect(ext.name, 'ext-0');
      expect(ext.enabled, isTrue);
    });

    test('round-trips through toJson', () {
      const ext = HtmlExtension(
        id: 'a',
        name: 'A',
        version: '1',
        runAt: 'start',
        js: 'https://cdn.example.com/a.js',
      );
      final restored = HtmlExtension.fromJson(ext.toJson(), index: 3);
      expect(restored.id, 'a');
      expect(restored.runAt, 'start');
      expect(restored.js, 'https://cdn.example.com/a.js');
    });
  });

  group('htmlTitleName', () {
    test('strips tags and collapses whitespace, caps at 40 chars', () {
      expect(htmlTitleName('<title>A  <b>B</b>\n C</title>'), 'A B C');
      expect(htmlTitleName('<html><body>none</body></html>'), '');
      expect(htmlTitleName('<title>${'x' * 50}</title>').length, 40);
    });
  });

  group('HTML site registration', () {
    test('typeHtml records become html sites with the right description', () {
      final record = ImportedSiteRecord(
        id: 'html:demo',
        name: '演示站',
        type: ImportedSiteRecord.typeHtml,
        fileName: 'demo.html',
        contentHash: 'abc',
        importedAtMs: 1,
      );
      final site = record.asSite;
      expect(site.importType, ImportedSiteRecord.typeHtml);
      expect(site.isHtmlSite, isTrue);
      expect(site.description, 'HTML 站源导入站');
    });

    test('py records are not html sites', () {
      final record = ImportedSiteRecord(
        id: 'py:demo',
        name: '演示站',
        type: ImportedSiteRecord.typePy,
        fileName: 'demo.py',
        contentHash: 'abc',
        importedAtMs: 1,
      );
      expect(record.asSite.isHtmlSite, isFalse);
    });

    test('builtin sites are not html sites', () {
      expect(SourceSite.hongguo.isHtmlSite, isFalse);
    });
  });
}
