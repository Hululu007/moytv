import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/builtin_legado_sources.dart';
import 'package:moyi/builtin_py_sites.dart';
import 'package:moyi/models.dart';
import 'package:moyi/site_builtin_icons.dart';
import 'package:moyi/site_icon.dart';
import 'package:moyi/zakatv_builtin.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  (int, int) pngSize(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    return (data.getUint32(16), data.getUint32(20));
  }

  test('内置图标文件都在、是方形 PNG、边长不超过 192', () {
    for (final entry in builtinSiteIcons.entries) {
      final file = File(entry.value);
      expect(
        file.existsSync(),
        isTrue,
        reason: '${entry.key} 的 ${entry.value} 不存在',
      );
      final bytes = file.readAsBytesSync();
      expect(bytes.sublist(0, 8), [
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ], reason: '${entry.value} 不是 PNG');
      final (w, h) = pngSize(bytes);
      expect(w, h, reason: '${entry.value} 不是方形：$w x $h');
      expect(w, lessThanOrEqualTo(192), reason: '${entry.value} 边长 $w 超过 192');
    }
    expect(builtinSiteIcons.length, 27);
    expect(builtinSiteIcons.values.toSet().length, 19);
  });

  test('映射键全是已注册的站 id，图标不造幽灵站点', () {
    final known = <String>{
      for (final e in BuiltinPySites.entries) e.siteId,
      for (final s in SourceSite.allValues) s.id,
      for (final c in zakatvBuiltinSites) c.key,
      for (final s in builtinLegadoSources) s.id,
      for (final f in Directory('assets/novel_spiders').listSync())
        if (f.path.endsWith('.py'))
          f.path.split('/').last.replaceAll('.py', ''),
    };
    for (final key in builtinSiteIcons.keys) {
      expect(known, contains(key), reason: '图标映射 $key 不在任何注册表里');
    }
    // 注册表计数不变：图标只配站，不加站。
    expect(BuiltinPySites.entries.length, 121);
    expect(zakatvBuiltinSites.length, 140);
    expect(builtinLegadoSources.length, 52);
  });

  test('查表：jar 形态 id 取 key 段，未映射回空', () {
    expect(
      builtinSiteIconAsset('jar:zakatv:ZakaAv91'),
      'assets/site_icons/ic_app_91av.png',
    );
    expect(builtinSiteIconAsset('aijav'), 'assets/site_icons/ic_app_aijav.png');
    expect(builtinSiteIconAsset('hmav'), isNull);
    expect(builtinSiteIconAsset(''), isNull);
  });

  testWidgets('已映射站离线亮内置图标，不走网络', (tester) async {
    var fetches = 0;
    final temp = Directory.systemTemp.createTempSync('site_builtin_test');
    addTearDown(() => temp.deleteSync(recursive: true));
    final cache = SiteIconCache(
      directoryProvider: () async => temp,
      fetcher: (_) async {
        fetches++;
        return null;
      },
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SiteIcon(siteId: 'aijav', siteName: '🔞AiJav', cache: cache),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    });
    expect(fetches, 0);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(Icon), findsNothing);
  });

  testWidgets('未映射站仍走 favicon/图案标，不取内置图标', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SiteIcon(siteId: 'no-such-site', siteName: '无名站'),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(find.byType(Image), findsNothing);
    expect(find.byType(Icon), findsOneWidget);
    expect(find.byType(Text), findsNothing);
  });
}
