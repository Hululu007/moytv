import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/site_icon.dart';
import 'package:moyi/source_picker_sheet.dart';

void main() {
  group('siteIconCandidates', () {
    test('普通地址派生 origin + 三个站标路径', () {
      expect(
        siteIconCandidates('https://example.com/foo/bar?x=1'),
        [
          'https://example.com/apple-touch-icon.png',
          'https://example.com/favicon.png',
          'https://example.com/favicon.ico',
        ],
      );
    });

    test('带端口的 origin 保留端口', () {
      expect(
        siteIconCandidates('http://example.com:8080/a'),
        [
          'http://example.com:8080/apple-touch-icon.png',
          'http://example.com:8080/favicon.png',
          'http://example.com:8080/favicon.ico',
        ],
      );
    });

    test('地址本身是图片时放第一位', () {
      final candidates = siteIconCandidates(
        'https://cdn.example.com/logo.png',
      );
      expect(candidates.first, 'https://cdn.example.com/logo.png');
      expect(candidates.length, 4);
    });

    test('空地址与非 http(s) 地址返回空', () {
      expect(siteIconCandidates(''), isEmpty);
      expect(siteIconCandidates('not a url'), isEmpty);
      expect(siteIconCandidates('ftp://example.com/x'), isEmpty);
    });
  });

  group('jarSiteIconCandidates', () {
    test('ext 里有公开 host 时派生候选', () {
      expect(
        jarSiteIconCandidates('jar:zakatv:ZakaSe8'),
        [
          'https://8se.me/apple-touch-icon.png',
          'https://8se.me/favicon.png',
          'https://8se.me/favicon.ico',
        ],
      );
    });

    test('ext 为空、无此 key、非 jar id 时返回空', () {
      expect(jarSiteIconCandidates('jar:zakatv:ZakaMjv011'), isEmpty);
      expect(jarSiteIconCandidates('jar:zakatv:NoSuchKey'), isEmpty);
      expect(jarSiteIconCandidates('plain-id'), isEmpty);
      expect(jarSiteIconCandidates(''), isEmpty);
    });
  });

  group('siteIconGlyph', () {
    test('跳过开头的 🔞 取第一个字母或数字', () {
      expect(siteIconGlyph('🔞河马AV'), '河');
      expect(siteIconGlyph('MissAV'), 'M');
      expect(siteIconGlyph('91短视频'), '9');
    });

    test('空名回落“站”', () {
      expect(siteIconGlyph(''), '站');
      expect(siteIconGlyph('   '), '站');
    });
  });

  test('siteIconColor 同一站名永远同一色', () {
    expect(siteIconColor('黄果'), siteIconColor('黄果'));
    expect(siteIconColor(''), isNotNull);
  });

  testWidgets('无候选地址时显示首字彩色块，不联网不崩溃', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SiteIcon(siteId: 'plain', siteName: '🔞河马AV'),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(find.text('河'), findsOneWidget);
  });

  testWidgets('站标取不到时回落字块，不崩溃', (tester) async {
    final temp = Directory.systemTemp.createTempSync('site_icon_test');
    addTearDown(() => temp.deleteSync(recursive: true));
    final cache = SiteIconCache(
      directoryProvider: () async => temp,
      fetcher: (_) async => null,
    );
    // 真实文件 IO 在 testWidgets 的假时钟下不会自行完成，须包在
    // runAsync 里跑真异步，否则用例会挂起（已实测）。先给真 IO 留
    // 一段真实时间，等 _load 走完失败回落链再断言。
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SiteIcon(
              siteId: 'plain',
              siteName: '测试站',
              iconUrls: const ['http://127.0.0.1:9/no.png'],
              cache: cache,
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    });
    expect(find.text('测'), findsOneWidget);
  });

  testWidgets('站标取到时显示图片并写入磁盘缓存', (tester) async {
    const png = <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ];
    final temp = Directory.systemTemp.createTempSync('site_icon_test');
    addTearDown(() => temp.deleteSync(recursive: true));
    final cache = SiteIconCache(
      directoryProvider: () async => temp,
      fetcher: (_) async => png,
    );
    // 真实文件 IO + 图片解码须在真异步下完成，见上一个用例的注释。
    // pumpAndSettle 察觉不到未完成的真 IO，必须等到缓存文件落盘
    // （即 _load 已走完）再渲染断言，否则会在 glyph 初始态误判。
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SiteIcon(
              siteId: 'plain',
              siteName: '测试站',
              iconUrls: const ['https://example.com/icon.png'],
              cache: cache,
            ),
          ),
        ),
      );
      for (var i = 0; i < 50 && temp.listSync().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
    });
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('测'), findsNothing);
    expect(temp.listSync().whereType<File>().length, 1);
  });

  testWidgets('站点选择弹窗普通样式渲染图标宫格', (tester) async {
    const groups = [
      SourcePickerGroup(
        title: '内置影视',
        entries: [
          SourcePickerEntry(id: 'a', name: 'A站'),
          SourcePickerEntry(id: 'b', name: 'B站'),
          SourcePickerEntry(id: 'c', name: 'C站'),
        ],
      ),
    ];
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SitePickerDialog(
            sectionName: '片库',
            currentId: 'b',
            groups: groups,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 10));
    // 每站一块图标（无地址时为首字块），站名只出现一次，选中站打勾。
    expect(find.byType(SiteIcon), findsNWidgets(3));
    expect(find.text('A站'), findsOneWidget);
    expect(find.text('B站'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byType(GridView), findsOneWidget);
  });

  testWidgets('编辑模式宫格里删除按钮与图标共存', (tester) async {
    const groups = [
      SourcePickerGroup(
        title: '内置影视',
        entries: [SourcePickerEntry(id: 'a', name: 'A站')],
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SitePickerDialog(
            sectionName: '片库',
            currentId: 'a',
            groups: groups,
            initialEditMode: true,
            onDeleteSite: (_) async => false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(find.byType(SiteIcon), findsOneWidget);
    expect(
      find.byKey(const ValueKey('site-picker-delete-a')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.check), findsNothing);
  });
}
