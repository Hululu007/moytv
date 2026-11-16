import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/content_legado.dart';
import 'package:moyi/content_models.dart';
import 'package:moyi/content_registry.dart';
import 'package:moyi/novel_source_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('内置 JSON 书源清单', () {
    test('共 52 个，id 唯一，全部在阅读区', () {
      final builtins = ContentRegistry.novelJsonBuiltins;
      expect(builtins, hasLength(52));
      final ids = builtins.map((s) => s.id).toList();
      expect(ids.toSet(), hasLength(52));
      for (final source in builtins) {
        expect(source.section, ContentSection.novel);
        expect(source.name.trim(), isNotEmpty);
        expect(source, isA<JsonContentSource>());
        final jsonSource = source as JsonContentSource;
        expect(
          jsonSource.assetPath,
          startsWith('assets/legado_sources/legado_'),
        );
        expect(jsonSource.importedFileName, isEmpty);
        expect(jsonSource.note, '内置书源');
      }
    });

    test('漫画分流：只有 5 个 type=2 的源是漫画', () {
      final comics = ContentRegistry.novelJsonBuiltins
          .whereType<JsonContentSource>()
          .where((s) => s.isComic);
      expect(comics.map((s) => s.id).toSet(), {
        'legado_8079_0',
        'legado_8042_0',
        'legado_7987_0',
        'legado_7978_0',
        'legado_7621_0',
      });
    });

    test('异常 type 的 11 个源按小说处理', () {
      const remapped = {
        'legado_8044_0',
        'legado_8057_0',
        'legado_8066_0',
        'legado_8100_0',
        'legado_7968_0',
        'legado_8056_0',
        'legado_8089_0',
        'legado_7985_0',
        'legado_8099_0',
        'legado_8008_0',
        'legado_8010_0',
      };
      for (final source in ContentRegistry.novelJsonBuiltins) {
        final jsonSource = source as JsonContentSource;
        if (remapped.contains(source.id)) {
          expect(jsonSource.sourceType, 0, reason: source.id);
          expect(jsonSource.isComic, isFalse, reason: source.id);
        }
      }
    });

    test('阅读区默认列出内置源，原有内置 py 源顺序不动，导入源排最后', () {
      addTearDown(() {
        ContentRegistry.setNovelImports([]);
        ContentRegistry.setNovelJsonVisibility();
      });
      final ids = ContentRegistry.sourcesFor(
        ContentSection.novel,
      ).map((s) => s.id).toList();
      expect(ids.first, 'aabook');
      expect(ids.sublist(0, 10), [
        'aabook',
        'ylxs',
        'cheniyo',
        'hwg4',
        'buliang',
        'yinse',
        'mhbl',
        'ho5ho',
        'modu18',
        'h528',
      ]);
      expect(
        ids,
        containsAll(ContentRegistry.novelJsonBuiltins.map((s) => s.id)),
      );
    });
  });

  group('内置书源资源文件', () {
    test('每个资源都是单个书源对象，名字与注册名一致', () async {
      for (final source in ContentRegistry.novelJsonBuiltins) {
        final jsonSource = source as JsonContentSource;
        final text = await rootBundle.loadString(jsonSource.assetPath);
        final decoded = jsonDecode(text);
        expect(decoded, isA<Map>(), reason: jsonSource.assetPath);
        final map = Map<String, dynamic>.from(decoded as Map);
        expect(map['bookSourceName'], source.name);
        expect(
          map['bookSourceUrl']?.toString().trim(),
          isNotEmpty,
          reason: source.id,
        );
      }
    });

    test('资源文件不含旗标词', () async {
      final flags = RegExp('萝莉|幼女|未成年|初中生|小学生|loli', caseSensitive: false);
      for (final source in ContentRegistry.novelJsonBuiltins) {
        final jsonSource = source as JsonContentSource;
        final text = await rootBundle.loadString(jsonSource.assetPath);
        expect(flags.hasMatch(text), isFalse, reason: source.id);
        expect(flags.hasMatch(source.name), isFalse, reason: source.id);
      }
    });
  });

  group('内置书源开关与删除态', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      ContentRegistry.setNovelImports([]);
      ContentRegistry.setNovelJsonVisibility();
    });

    tearDown(() {
      ContentRegistry.setNovelImports([]);
      ContentRegistry.setNovelJsonVisibility();
    });

    test('关掉的源不进阅读区列表，再打开回来', () async {
      const id = 'legado_8117_0';
      await NovelSourceStore.setBuiltinHidden(id, true);
      await NovelSourceStore.applyToRegistry();
      expect(
        ContentRegistry.sourcesFor(ContentSection.novel).map((s) => s.id),
        isNot(contains(id)),
      );
      expect(await NovelSourceStore.builtinHiddenIds(), {id});

      await NovelSourceStore.setBuiltinHidden(id, false);
      await NovelSourceStore.applyToRegistry();
      expect(
        ContentRegistry.sourcesFor(ContentSection.novel).map((s) => s.id),
        contains(id),
      );
      expect(await NovelSourceStore.builtinHiddenIds(), isEmpty);
    });

    test('删掉的源记删除态，重新载入也不复活', () async {
      const id = 'legado_8117_0';
      await NovelSourceStore.removeBuiltin(id);
      await NovelSourceStore.applyToRegistry();
      expect(
        ContentRegistry.sourcesFor(ContentSection.novel).map((s) => s.id),
        isNot(contains(id)),
      );
      expect(await NovelSourceStore.builtinRemovedIds(), {id});

      // 模拟下次启动重新载入：删除态仍在，不复活。
      await NovelSourceStore.applyToRegistry();
      expect(
        ContentRegistry.sourcesFor(ContentSection.novel).map((s) => s.id),
        isNot(contains(id)),
      );
    });

    test('恢复已删除的源后重新出现', () async {
      const id = 'legado_8117_0';
      await NovelSourceStore.removeBuiltin(id);
      await NovelSourceStore.restoreRemovedBuiltins();
      await NovelSourceStore.applyToRegistry();
      expect(
        ContentRegistry.sourcesFor(ContentSection.novel).map((s) => s.id),
        contains(id),
      );
      expect(await NovelSourceStore.builtinRemovedIds(), isEmpty);
    });

    test('非内置 id 的开关与删除请求被忽略', () async {
      await NovelSourceStore.setBuiltinHidden('not-a-builtin', true);
      await NovelSourceStore.removeBuiltin('not-a-builtin');
      expect(await NovelSourceStore.builtinHiddenIds(), isEmpty);
      expect(await NovelSourceStore.builtinRemovedIds(), isEmpty);
    });

    test('导入源与内置源互不干扰', () async {
      await NovelSourceStore.setBuiltinHidden('legado_8117_0', true);
      await NovelSourceStore.applyToRegistry();
      final before = ContentRegistry.sourcesFor(
        ContentSection.novel,
      ).map((s) => s.id).toList();
      expect(before, isNot(contains('legado_8117_0')));
      expect(before, contains('legado_8116_0'));
    });
  });
}
