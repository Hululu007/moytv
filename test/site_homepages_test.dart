import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/builtin_legado_sources.dart';
import 'package:moyi/builtin_py_sites.dart';
import 'package:moyi/content_legado.dart';
import 'package:moyi/site_homepages.dart';
import 'package:moyi/site_icon.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String originOf(String url) {
    final uri = Uri.parse(url);
    return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
  }

  test('py 映射：值确是 origin、主机名确在对应蜘蛛文件里', () {
    final checked = <String>{};
    // 视频 py：注册表里的 siteId 与 assetPath 一一对应。
    for (final entry in BuiltinPySites.entries) {
      final url = pySiteHomepages[entry.siteId];
      expect(url, isNotNull, reason: '${entry.siteId} 无主页映射');
      expect(url, originOf(url!), reason: '$url 不是 origin');
      final text = File(entry.assetPath).readAsStringSync();
      expect(
        text,
        contains(Uri.parse(url).host),
        reason:
            '${entry.siteId} 的主机 ${Uri.parse(url).host} 不在 ${entry.assetPath} 里',
      );
      checked.add(entry.siteId);
    }
    // 阅读 py：文件名即站 id。
    for (final file in Directory('assets/novel_spiders').listSync()) {
      if (!file.path.endsWith('.py')) continue;
      final id = file.path.split('/').last.replaceAll('.py', '');
      final url = pySiteHomepages[id];
      expect(url, isNotNull, reason: '阅读蜘蛛 $id 无主页映射');
      expect(url, originOf(url!), reason: '$url 不是 origin');
      final text = File(file.path).readAsStringSync();
      expect(
        text,
        contains(Uri.parse(url).host),
        reason: '$id 的主机 ${Uri.parse(url).host} 不在 ${file.path} 里',
      );
      checked.add(id);
    }
    // 表里不许有多余条目（防编造/漂移）。
    expect(pySiteHomepages.keys.toSet(), checked);
    expect(pySiteHomepages.length, 148);
  });

  test('Go 映射：值确是 origin、主机名确在 Go 核源码里', () {
    final goText = Directory('native/core/seku')
        .listSync()
        .where((f) => f.path.endsWith('.go'))
        .map((f) => File(f.path).readAsStringSync())
        .join('\n');
    for (final entry in goSiteHomepages.entries) {
      expect(
        entry.value,
        originOf(entry.value),
        reason: '${entry.value} 不是 origin',
      );
      expect(
        goText,
        contains(Uri.parse(entry.value).host),
        reason: '${entry.key} 的主机 ${Uri.parse(entry.value).host} 不在 Go 核源码里',
      );
    }
    expect(goSiteHomepages.length, 59);
  });

  test('阅读 JSON 映射：值确与源文件 bookSourceUrl 同 origin', () {
    for (final source in builtinLegadoSources) {
      final jsonSource = source as JsonContentSource;
      final data =
          jsonDecode(File(jsonSource.assetPath).readAsStringSync())
              as Map<String, dynamic>;
      final bookUrl = data['bookSourceUrl'] as String;
      final mapped = legadoSiteHomepages[source.id];
      if (!bookUrl.startsWith('http')) {
        // 自定义协议源（如 moyue://）永远取不到站标，不许进表。
        expect(mapped, isNull, reason: '${source.id} 的 $bookUrl 不应进映射表');
        continue;
      }
      expect(mapped, isNotNull, reason: '${source.id} 无主页映射');
      expect(mapped, originOf(bookUrl), reason: '${source.id} 映射值与源文件不一致');
    }
    expect(legadoSiteHomepages.length, 93);
  });

  test('桥接查表：三种 id 形态都解析，查不到回空', () {
    final hmav = siteHomepageCandidates('hmav');
    expect(hmav, isNotEmpty);
    expect(hmav.first, startsWith('https://5.hmav7911.cc:8888/'));
    expect(siteHomepageCandidates('jar:zakatv:hmav'), hmav);
    expect(siteHomepageCandidates('v_javdb'), isNotEmpty);
    expect(siteHomepageCandidates('legado_8059_0'), isNotEmpty);
    expect(siteHomepageCandidates('chaoliu'), isNotEmpty);
    expect(siteHomepageCandidates('chaoliu').first, startsWith('https://mjv011.com/'));
    expect(siteHomepageCandidates('no-such-site'), isEmpty);
    expect(siteHomepageCandidates(''), isEmpty);
  });

  testWidgets('桥接站标：不传 iconUrls 也按主页取图标', (tester) async {
    const png = <int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x48,
      0x44,
      0x52,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x08,
      0x06,
      0x00,
      0x00,
      0x00,
      0x1F,
      0x15,
      0xC4,
      0x89,
      0x00,
      0x00,
      0x00,
      0x0A,
      0x49,
      0x44,
      0x41,
      0x54,
      0x78,
      0x9C,
      0x63,
      0x00,
      0x01,
      0x00,
      0x00,
      0x05,
      0x00,
      0x01,
      0x0D,
      0x0A,
      0x2D,
      0xB4,
      0x00,
      0x00,
      0x00,
      0x00,
      0x49,
      0x45,
      0x4E,
      0x44,
      0xAE,
      0x42,
      0x60,
      0x82,
    ];
    final requested = <String>[];
    final temp = Directory.systemTemp.createTempSync('site_homepages_test');
    addTearDown(() => temp.deleteSync(recursive: true));
    final cache = SiteIconCache(
      directoryProvider: () async => temp,
      fetcher: (url) async {
        requested.add(url);
        return png;
      },
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SiteIcon(siteId: 'hmav', siteName: '🔞河马AV', cache: cache),
          ),
        ),
      );
      for (var i = 0; i < 50 && temp.listSync().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
    });
    expect(requested, isNotEmpty);
    expect(requested.first, startsWith('https://5.hmav7911.cc:8888/'));
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('河'), findsNothing);
  });

  testWidgets('桥接站标取不到时回落图案标', (tester) async {
    final temp = Directory.systemTemp.createTempSync('site_homepages_test');
    addTearDown(() => temp.deleteSync(recursive: true));
    final cache = SiteIconCache(
      directoryProvider: () async => temp,
      fetcher: (_) async => null,
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SiteIcon(siteId: 'hmav', siteName: '🔞河马AV', cache: cache),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    });
    expect(find.byType(Icon), findsOneWidget);
    expect(find.text('河'), findsNothing);
  });

  test('站标缓存：第二次解析不重复下载', () async {
    final temp = Directory.systemTemp.createTempSync('site_homepages_test');
    addTearDown(() => temp.deleteSync(recursive: true));
    var fetches = 0;
    final cache = SiteIconCache(
      directoryProvider: () async => temp,
      fetcher: (_) async {
        fetches++;
        return const <int>[
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
          0x00,
          0x00,
          0x00,
          0x0D,
          0x49,
          0x48,
          0x44,
          0x52,
          0x00,
          0x00,
          0x00,
          0x01,
          0x00,
          0x00,
          0x00,
          0x01,
          0x08,
          0x06,
          0x00,
          0x00,
          0x00,
          0x1F,
          0x15,
          0xC4,
          0x89,
          0x00,
          0x00,
          0x00,
          0x0A,
          0x49,
          0x44,
          0x41,
          0x54,
          0x78,
          0x9C,
          0x63,
          0x00,
          0x01,
          0x00,
          0x00,
          0x05,
          0x00,
          0x01,
          0x0D,
          0x0A,
          0x2D,
          0xB4,
          0x00,
          0x00,
          0x00,
          0x00,
          0x49,
          0x45,
          0x4E,
          0x44,
          0xAE,
          0x42,
          0x60,
          0x82,
        ];
      },
    );
    const url = 'https://example.com/favicon.png';
    final first = await cache.resolve(url);
    final second = await cache.resolve(url);
    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(first!.path, second!.path);
    expect(fetches, 1);
  });
}
