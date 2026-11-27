// 问题 6（2026-11-27）：网盘文件夹秒开——引擎目录页两级缓存
// （内存文件页 + 落盘条目页）+ 命中后台刷新 + 子文件夹预取 +
// 聚合并行遍历。此前片库站入口零缓存、每次点文件夹都现拉网
// 络；聚合“全部”逐个文件夹串行拉满才出画，弱网下点完长时
// 间没动静（用户报“文件夹点了没反应”）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moyi/cloud_drive/cloud_credential_store.dart';
import 'package:moyi/cloud_drive/cloud_drive_engine.dart';
import 'package:moyi/cloud_drive/cloud_drive_types.dart';
import 'package:moyi/cloud_drive/cloud_providers.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeProvider implements CloudDriveProvider {
  @override
  String get id => 'pan115';
  @override
  String get displayName => '115网盘';
  @override
  String get appName => '115 App';
  @override
  String get rootFolderId => '0';
  @override
  void Function(String, CloudCredentials)? onCredentialsRefreshed;
  @override
  void Function(String, String)? onSessionExpired;

  final Map<String, List<CloudDriveFile>> folders = {};
  var listCalls = 0;
  var failAll = false;

  @override
  Future<QrLoginSession> startQrLogin(http.Client client) =>
      throw UnimplementedError();
  @override
  Future<QrPollResult> pollQrLogin(
    http.Client client,
    QrLoginSession session,
  ) => throw UnimplementedError();

  @override
  Future<CloudFolderPage> listFolder(
    http.Client client,
    CloudCredentials credentials,
    String folderId,
    int page,
  ) async {
    listCalls++;
    if (failAll) throw CloudDriveException('网络断开（测试注入）');
    return CloudFolderPage(
      files: folders[folderId] ?? const [],
      hasMore: false,
    );
  }

  @override
  Future<List<CloudDriveFile>> search(
    http.Client client,
    CloudCredentials credentials,
    String keyword,
    String folderId,
  ) async => const [];

  @override
  Future<CloudDirectLink> directLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) async => CloudDirectLink(url: 'https://cdn.example.com/${file.id}.mp4');
}

CloudDriveFile _file(String id, String name) => CloudDriveFile(
  id: id,
  name: name,
  isFolder: false,
  kind: CloudFileKind.video,
  sizeBytes: 1024,
  durationSeconds: 1800,
);

CloudDriveFile _folder(String id, String name) =>
    CloudDriveFile(id: id, name: name, isFolder: true, kind: CloudFileKind.folder);

Future<CloudDriveEngine> _engine(
  _FakeProvider fake, {
  Future<Directory> Function()? cacheDir,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = CloudCredentialStore(prefs);
  await store.save(
    'pan115',
    const CloudCredentials(fields: {'cookie': 'UID=x'}, savedAtMs: 1),
  );
  return CloudDriveEngine(
    credentialStore: store,
    httpClient: MockClient((_) async => http.Response('', 200)),
    showSuspectedAds: () => false,
    providers: {'pan115': fake},
    catalogCacheDir: cacheDir,
  );
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 80));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('引擎目录页缓存（问题 6）', () {
    test('同一文件夹第二开走内存缓存：断网也出画，后台刷新失败静默', () async {
      final fake = _FakeProvider();
      fake.folders['0'] = [_file('v1', '正片.mp4')];
      final engine = await _engine(fake);
      final first = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      expect(first.items.map((d) => d.title), contains('正片.mp4'));
      final callsAfterFirst = fake.listCalls;

      fake.failAll = true; // 断网：刷新与现拉都会失败
      final second = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      expect(second.items.map((d) => d.title), contains('正片.mp4'));
      await _settle();
      expect(fake.listCalls, greaterThan(callsAfterFirst)); // 后台刷新试过
    });

    test('子文件夹预取：根目录出来后子夹第一页已进缓存', () async {
      final fake = _FakeProvider();
      fake.folders['0'] = [_folder('f1', '剧集'), _folder('f2', '电影')];
      fake.folders['f1'] = [_folder('f1a', '第一季'), _file('v3', '第1集.mp4')];
      fake.folders['f1a'] = [_file('v4', '第1集.mp4')];
      fake.folders['f2'] = [_file('v5', '电影A.mp4')];
      final engine = await _engine(fake);
      await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      await _settle();
      // 根 1 次 + 预取 f1/f2 各 1 次（f1a 是预取的预取，不级联）。
      expect(fake.listCalls, 3);

      fake.failAll = true;
      final sub = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: 'f1',
      );
      expect(sub.items.map((d) => d.title), contains('第1集.mp4'));
      // 多层下钻：第三层也靠预取（f1 出画时预取了 f1a）——先恢复
      // 网络让 f1 的命中刷新带出 f1a 预取，再断网验第三层。
      fake.failAll = false;
      await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: 'f1',
      );
      await _settle();
      fake.failAll = true;
      final deep = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: 'f1a',
      );
      expect(deep.items.map((d) => d.title), contains('第1集.mp4'));
    });

    test('聚合“全部”第二开走缓存：断网也出齐视频', () async {
      final fake = _FakeProvider();
      fake.folders['0'] = [_folder('f1', '剧集'), _file('v1', '根目录.mp4')];
      fake.folders['f1'] = [_file('v3', '剧集第1集.mp4')];
      final engine = await _engine(fake);
      final first = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: cloudDriveAllCategory,
      );
      expect(first.items.length, 2);
      fake.failAll = true;
      final second = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: cloudDriveAllCategory,
      );
      expect(second.items.length, 2);
    });

    test('落盘缓存：新引擎（模拟重启）断网也能先出画', () async {
      final dir = await Directory.systemTemp.createTemp('cloud_cache_test');
      addTearDown(() => dir.delete(recursive: true));
      Future<Directory> cacheDir() async => dir;

      final fake1 = _FakeProvider();
      fake1.folders['0'] = [_file('v1', '正片.mp4')];
      final engine1 = await _engine(fake1, cacheDir: cacheDir);
      await engine1.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      // 落盘是防抖写（400ms），等它落下去。
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final cacheFile = File('${dir.path}/cloud_catalog_pages.json');
      expect(await cacheFile.exists(), isTrue);
      final raw = await cacheFile.readAsString();
      // 落盘只许展示字段：不许出现凭证字样。
      expect(raw, isNot(contains('UID')));
      expect(raw, isNot(contains('cookie')));

      final fake2 = _FakeProvider()..failAll = true;
      final engine2 = await _engine(fake2, cacheDir: cacheDir);
      final page = await engine2.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      expect(page.items.map((d) => d.title), contains('正片.mp4'));
    });
  });

  group('Drama.merge 文件夹性粘住（问题 6）', () {
    const folderDrama = Drama(
      id: 'pan115:f1',
      source: 'cloud:pan115',
      title: '剧集',
      kind: 'folder',
      folderId: 'f1',
    );

    test('被 kind 为空的更新合并后仍是文件夹', () {
      const update = Drama(
        id: 'pan115:f1',
        source: 'cloud:pan115',
        title: '剧集',
        cover: 'https://t/new.jpg',
      );
      final merged = folderDrama.merge(update);
      expect(merged.isFolder, isTrue);
      expect(merged.folderId, 'f1');
      expect(merged.cover, 'https://t/new.jpg'); // 其他字段照常取新
    });

    test('普通条目合并普通更新，kind 按新值/旧值回退不变', () {
      const video = Drama(
        id: 'pan115:v1',
        source: 'cloud:pan115',
        title: '正片.mp4',
        kind: 'video',
      );
      const update = Drama(
        id: 'pan115:v1',
        source: 'cloud:pan115',
        title: '正片.mp4',
      );
      expect(video.merge(update).kind, 'video');
      expect(video.merge(update).isFolder, isFalse);
    });
  });
}
