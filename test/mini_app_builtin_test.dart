import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moyi/miniapp/mini_app_builtin.dart';
import 'package:moyi/miniapp/mini_app_manifest.dart';
import 'package:moyi/miniapp/mini_app_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('miniapp_builtin_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  List<int> zipWithManifest(String appId, String name) {
    final manifest = utf8.encode(jsonEncode({
      'appId': appId,
      'name': name,
      'version': '1.0.0',
      'versionCode': 1,
      'entry': 'index.html',
      'permissions': ['ui'],
    }));
    final archive = Archive()
      ..addFile(ArchiveFile('manifest.json', manifest.length, manifest))
      ..addFile(ArchiveFile('index.html', 4, [60, 104, 62, 10]));
    return ZipEncoder().encode(archive);
  }

  String manifestOnlyJson(String appId, String name) => jsonEncode({
    'appId': appId,
    'name': name,
    'version': '1.0.0',
    'versionCode': 1,
    'entry': 'https://example.com/',
    'permissions': ['ui'],
  });

  group('内置小程序播种', () {
    test('首次播种装 zip 包与 manifest-only 包，二次调用全部跳过', () async {
      final zipBytes = zipWithManifest('com.example.demo', '示例');
      final market = jsonEncode({
        'apps': [
          {
            'appId': 'com.example.demo',
            'name': '示例',
            'version': '1.0.0',
            'versionCode': 1,
            'url': 'https://example.com/demo.zip',
            'md5': md5.convert(zipBytes).toString(),
            'size': zipBytes.length,
          },
          {
            'appId': 'com.example.site',
            'name': '在线站点',
            'version': '1.0.0',
            'versionCode': 1,
            'url': 'https://example.com/site/manifest.json',
          },
        ],
      });
      Future<ByteData> load(String asset) async {
        final bytes = switch (asset) {
          'assets/miniapps/builtin/market.json' => utf8.encode(market),
          'assets/miniapps/builtin/com.example.demo.zip' => zipBytes,
          'assets/miniapps/builtin/com.example.site.manifest.json' =>
            utf8.encode(manifestOnlyJson('com.example.site', '在线站点')),
          _ => throw StateError('unexpected asset $asset'),
        };
        return ByteData.view(Uint8List.fromList(bytes).buffer);
      }

      final store = MiniAppStore(rootOverride: temp);
      final first = await MiniAppBuiltin.ensureSeeded(store, loadAsset: load);
      expect(first.installed, ['com.example.demo', 'com.example.site']);
      expect(first.failed, isEmpty);
      expect(first.unavailable, isEmpty);
      final installed = await store.listInstalled();
      expect(installed.map((m) => m.appId), containsAll([
        'com.example.demo',
        'com.example.site',
      ]));

      final second = await MiniAppBuiltin.ensureSeeded(store, loadAsset: load);
      expect(second.installed, isEmpty);
      expect(second.skipped, ['com.example.demo', 'com.example.site']);
    });

    test('已装过的应用跳过播种（不覆盖用户装的版本）', () async {
      final zipBytes = zipWithManifest('com.example.demo', '示例');
      final store = MiniAppStore(rootOverride: temp);
      await store.installFromZipBytes(zipBytes);
      final market = jsonEncode({
        'apps': [
          {
            'appId': 'com.example.demo',
            'name': '示例',
            'version': '1.0.0',
            'versionCode': 1,
            'url': 'https://example.com/demo.zip',
            'md5': md5.convert(zipBytes).toString(),
            'size': zipBytes.length,
          },
        ],
      });
      Future<ByteData> load(String asset) async {
        final bytes = asset.endsWith('market.json')
            ? utf8.encode(market)
            : zipBytes;
        return ByteData.view(Uint8List.fromList(bytes).buffer);
      }
      final result = await MiniAppBuiltin.ensureSeeded(store, loadAsset: load);
      expect(result.installed, isEmpty);
      expect(result.skipped, ['com.example.demo']);
    });

    test('md5 不一致记为失败且不写播种标记，下次还能重试', () async {
      final zipBytes = zipWithManifest('com.example.demo', '示例');
      final market = jsonEncode({
        'apps': [
          {
            'appId': 'com.example.demo',
            'name': '示例',
            'version': '1.0.0',
            'versionCode': 1,
            'url': 'https://example.com/demo.zip',
            'md5': '0' * 32,
            'size': zipBytes.length,
          },
        ],
      });
      Future<ByteData> load(String asset) async {
        final bytes = asset.endsWith('market.json')
            ? utf8.encode(market)
            : zipBytes;
        return ByteData.view(Uint8List.fromList(bytes).buffer);
      }
      final store = MiniAppStore(rootOverride: temp);
      final result = await MiniAppBuiltin.ensureSeeded(store, loadAsset: load);
      expect(result.failed.map((f) => f.appId), ['com.example.demo']);
      expect(result.installed, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(MiniAppBuiltin.seededKey), isNot(true));
      expect(await store.listInstalled(), isEmpty);
    });

    test('缺失的内置包记为 unavailable，不崩', () async {
      final market = jsonEncode({
        'apps': [
          {
            'appId': 'com.example.gone',
            'name': '不存在',
            'version': '1.0.0',
            'versionCode': 1,
            'url': 'https://example.com/gone.zip',
          },
        ],
      });
      Future<ByteData> load(String asset) async {
        if (asset.endsWith('market.json')) {
          final bytes = utf8.encode(market);
          return ByteData.view(Uint8List.fromList(bytes).buffer);
        }
        throw StateError('asset missing');
      }
      final store = MiniAppStore(rootOverride: temp);
      final result = await MiniAppBuiltin.ensureSeeded(store, loadAsset: load);
      expect(result.unavailable, ['com.example.gone']);
      expect(result.failed, isEmpty);
    });
  });

  group('内置包资产完整性（磁盘实测）', () {
    test('market.json 清单里的每个应用都有对应资产文件且大小一致', () {
      final marketFile = File('assets/miniapps/builtin/market.json');
      expect(marketFile.existsSync(), isTrue);
      final items = parseMiniAppMarketJson(marketFile.readAsStringSync());
      expect(items, hasLength(17));
      for (final item in items) {
        final fileName = item.url.endsWith('.json')
            ? '${item.appId}.manifest.json'
            : '${item.appId}.zip';
        final file = File('assets/miniapps/builtin/$fileName');
        expect(file.existsSync(), isTrue, reason: '缺资产：$fileName');
        if (item.size != null) {
          expect(
            file.lengthSync(),
            item.size,
            reason: '大小不一致：$fileName',
          );
        }
        // 大包（drpy_node）只验大小，md5 由播种时 installFromZipBytes 验；
        // 其余小包在这里就把 md5 对上。
        if (item.md5 != null && file.lengthSync() < 10 * 1024 * 1024) {
          expect(
            md5.convert(file.readAsBytesSync()).toString(),
            item.md5,
            reason: 'md5 不一致：$fileName',
          );
        }
      }
      // 影视库（桥接播放的入口）必须在清单里。
      expect(items.map((i) => i.appId), contains('com.ant.emby'));
    });
  });
}
