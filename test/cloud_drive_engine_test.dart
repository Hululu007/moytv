import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moyi/cloud_drive/cloud_credential_store.dart';
import 'package:moyi/cloud_drive/cloud_drive_engine.dart';
import 'package:moyi/cloud_drive/cloud_drive_types.dart';
import 'package:moyi/cloud_drive/cloud_providers.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假网盘：内存文件夹树，支持搜索开关。
class FakeProvider implements CloudDriveProvider {
  FakeProvider({this.supportsSearch = true});

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

  final bool supportsSearch;
  final Map<String, List<CloudDriveFile>> folders = {};
  var listCalls = 0;

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
    final all = folders[folderId] ?? const [];
    return CloudFolderPage(files: all, hasMore: false);
  }

  @override
  Future<List<CloudDriveFile>> search(
    http.Client client,
    CloudCredentials credentials,
    String keyword,
    String folderId,
  ) async {
    if (!supportsSearch) throw UnsupportedError('无搜索接口');
    final all = folders[folderId] ?? const [];
    return all.where((f) => f.name.contains(keyword)).toList();
  }

  @override
  Future<CloudDirectLink> directLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) async {
    return CloudDirectLink(
      url: 'https://cdn.example.com/${file.id}.mp4',
      headers: {'Cookie': 'UID=x'},
    );
  }
}

CloudDriveFile file(
  String id,
  String name, {
  CloudFileKind kind = CloudFileKind.video,
  int sizeBytes = 100 * 1024 * 1024,
  int? durationSeconds = 1800,
  String thumbnailUrl = '',
}) => CloudDriveFile(
  id: id,
  name: name,
  isFolder: false,
  kind: kind,
  sizeBytes: sizeBytes,
  durationSeconds: durationSeconds,
  thumbnailUrl: thumbnailUrl,
);

CloudDriveFile folder(String id, String name) => CloudDriveFile(
  id: id,
  name: name,
  isFolder: true,
  kind: CloudFileKind.folder,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late CloudCredentialStore credentialStore;
  late FakeProvider fake;
  late CloudDriveEngine engine;
  var showAds = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    credentialStore = CloudCredentialStore(prefs);
    await credentialStore.save(
      'pan115',
      const CloudCredentials(fields: {'cookie': 'UID=x'}, savedAtMs: 1),
    );
    fake = FakeProvider();
    fake.folders['0'] = [
      folder('f1', '剧集'),
      folder('f2', '电影'),
      file('v1', '正片.mp4', thumbnailUrl: 'https://t/cover.jpg'),
      file('v2', '无封面.mp4'),
      file('a1', '歌.mp3', kind: CloudFileKind.audio),
      file(
        'img1',
        '图.jpg',
        kind: CloudFileKind.image,
        thumbnailUrl: 'https://t/img.jpg',
      ),
      file('sub1', '字幕.srt', kind: CloudFileKind.subtitle),
      file('doc1', '说明.pdf', kind: CloudFileKind.other),
    ];
    fake.folders['f1'] = [folder('f1a', '第一季'), file('v3', '第1集.mp4')];
    fake.folders['f1a'] = [file('v4', '第1集.mp4')];
    fake.folders['f2'] = [file('v5', '电影A.mp4')];
    showAds = false;
    engine = CloudDriveEngine(
      credentialStore: credentialStore,
      httpClient: MockClient((_) async => http.Response('', 200)),
      showSuspectedAds: () => showAds,
      providers: {'pan115': fake},
    );
  });

  group('站点识别', () {
    test('isCloudSource / providerIdOf / dramaId / fileIdOf', () {
      expect(CloudDriveEngine.isCloudSource('cloud:pan115'), isTrue);
      expect(CloudDriveEngine.isCloudSource('missav'), isFalse);
      expect(CloudDriveEngine.providerIdOf('cloud:pan115'), 'pan115');
      expect(CloudDriveEngine.dramaId('pan115', 'v1'), 'pan115:v1');
      expect(CloudDriveEngine.fileIdOf('pan115:v1'), 'v1');
    });
  });

  group('catalog 根目录', () {
    test('首张是“全部”虚拟文件夹卡，其次文件夹卡在前', () async {
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      expect(page.items.first.title, '全部');
      expect(page.items.first.kind, 'folder');
      expect(page.items.first.folderId, cloudDriveAllCategory);
      expect(page.items[1].title, '剧集');
      expect(page.items[1].kind, 'folder');
      expect(page.items[2].title, '电影');
      // 文件卡在文件夹卡之后。
      expect(page.items[3].title, '正片.mp4');
    });

    test('未登录时抛 AppFailure', () async {
      await credentialStore.clear('pan115');
      expect(
        engine.catalog(
          source: 'cloud:pan115',
          page: 1,
          query: '',
          category: '',
        ),
        throwsA(isA<AppFailure>()),
      );
    });

    test('未知网盘抛 AppFailure', () async {
      expect(
        engine.catalog(source: 'cloud:nope', page: 1, query: '', category: ''),
        throwsA(isA<AppFailure>()),
      );
    });
  });

  group('多文件夹下钻', () {
    test('category=文件夹 id 时列该夹内容，不带“全部”卡', () async {
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: 'f1',
      );
      expect(page.items.map((d) => d.title), ['第一季', '第1集.mp4']);
      expect(page.items.first.kind, 'folder');
    });

    test('逐级下钻无层级上限（引擎不设上限）', () async {
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: 'f1a',
      );
      expect(page.items.map((d) => d.title), ['第1集.mp4']);
    });
  });

  group('“全部”聚合视图', () {
    test('汇总各夹视频，不含文件夹卡', () async {
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '__all__',
      );
      final titles = page.items.map((d) => d.title).toList();
      expect(titles, containsAll(['正片.mp4', '无封面.mp4', '第1集.mp4', '电影A.mp4']));
      expect(page.items.every((d) => d.kind == 'video'), isTrue);
      // 音频/图片/字幕不进聚合。
      expect(titles, isNot(contains('歌.mp3')));
    });
  });

  group('文件夹内搜索', () {
    test('有站方接口时用接口', () async {
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '正片',
        category: '',
      );
      expect(page.items.map((d) => d.title), ['正片.mp4']);
      expect(page.warning, isEmpty);
    });

    test('无站方接口时取列表按名过滤并注明', () async {
      fake = FakeProvider(supportsSearch: false);
      fake.folders['0'] = [file('v1', '正片.mp4'), file('v2', '别的.mp4')];
      engine = CloudDriveEngine(
        credentialStore: credentialStore,
        httpClient: MockClient((_) async => http.Response('', 200)),
        showSuspectedAds: () => showAds,
        providers: {'pan115': fake},
      );
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '正片',
        category: '',
      );
      expect(page.items.map((d) => d.title), ['正片.mp4']);
      expect(page.warning, contains('没有站方搜索接口'));
    });
  });

  group('封面三级兜底', () {
    test('网盘缩略图优先', () async {
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final card = page.items.firstWhere((d) => d.title == '正片.mp4');
      expect(card.cover, 'https://t/cover.jpg');
    });

    test('同名图片兜底', () async {
      fake.folders['0'] = [
        file('v9', '剧集.mp4'),
        file(
          'i9',
          '剧集.jpg',
          kind: CloudFileKind.image,
          thumbnailUrl: 'https://t/same.jpg',
        ),
      ];
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final card = page.items.firstWhere((d) => d.title == '剧集.mp4');
      expect(card.cover, 'https://t/same.jpg');
    });

    test('海报图兜底（仅视频）', () async {
      fake.folders['0'] = [
        file('v9', '剧集.mp4'),
        file('a9', '歌.mp3', kind: CloudFileKind.audio),
        file(
          'i9',
          'poster.jpg',
          kind: CloudFileKind.image,
          thumbnailUrl: 'https://t/poster.jpg',
        ),
      ];
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      expect(
        page.items.firstWhere((d) => d.title == '剧集.mp4').cover,
        'https://t/poster.jpg',
      );
      expect(page.items.firstWhere((d) => d.title == '歌.mp3').cover, '');
    });

    test('无封面时 cover 为空（走占位渲染）', () async {
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final card = page.items.firstWhere((d) => d.title == '无封面.mp4');
      expect(card.cover, '');
    });
  });

  group('疑似广告视频过滤', () {
    test('默认隐藏并在 warning 里计数', () async {
      fake.folders['0'] = [
        file(
          'ad1',
          '最新地址 www.x.com.mp4',
          sizeBytes: 20 * 1024 * 1024,
          durationSeconds: 30,
        ),
        file('v1', '正片.mp4'),
      ];
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      expect(
        page.items.map((d) => d.title),
        isNot(contains('最新地址 www.x.com.mp4')),
      );
      expect(page.warning, contains('已隐藏 1 个疑似广告视频'));
    });

    test('开关打开后显示并打“疑似广告”标签', () async {
      showAds = true;
      fake.folders['0'] = [
        file(
          'ad1',
          '最新地址 www.x.com.mp4',
          sizeBytes: 20 * 1024 * 1024,
          durationSeconds: 30,
        ),
      ];
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      expect(page.items.length, 2); // 全部卡 + 广告卡
      final card = page.items.firstWhere((d) => d.title.contains('最新地址'));
      expect(card.tags, contains('疑似广告'));
      expect(page.warning, isEmpty);
    });
  });

  group('详情', () {
    test('视频详情出一集 + 类型/封面来源标签', () async {
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final card = page.items.firstWhere((d) => d.title == '正片.mp4');
      final detail = await engine.detail(card);
      expect(detail.episodes.length, 1);
      expect(detail.episodes.first.title, '正片.mp4');
      expect(detail.tags.map((t) => t.name), contains('视频'));
      expect(detail.tags.map((t) => t.name).join(), contains('封面：'));
    });

    test('字幕/其他类型零集 + 不可播提示', () async {
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final sub = page.items.firstWhere((d) => d.title == '字幕.srt');
      final detail = await engine.detail(sub);
      expect(detail.episodes, isEmpty);
      expect(detail.warning, contains('不可播放'));
    });

    test('缓存未命中时诚实提示，不编信息', () async {
      const drama = Drama(
        id: 'pan115:ghost',
        source: 'cloud:pan115',
        title: '幽灵',
      );
      final detail = await engine.detail(drama);
      expect(detail.episodes, isEmpty);
      expect(detail.warning, contains('重新打开'));
    });

    test('文件夹详情提示下钻', () async {
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final folderCard = page.items.firstWhere((d) => d.title == '剧集');
      final detail = await engine.detail(folderCard);
      expect(detail.episodes, isEmpty);
      expect(detail.warning, contains('下钻'));
    });
  });

  group('播放', () {
    test('视频取直链进播放计划', () async {
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final card = page.items.firstWhere((d) => d.title == '正片.mp4');
      final detail = await engine.detail(card);
      final plan = await engine.resolve(card, detail.episodes.first);
      expect(plan.url, 'https://cdn.example.com/v1.mp4');
      expect(plan.headers['Cookie'], 'UID=x');
    });

    test('图片走 pics:// 计划', () async {
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final card = page.items.firstWhere((d) => d.title == '图.jpg');
      final detail = await engine.detail(card);
      final plan = await engine.resolve(card, detail.episodes.first);
      expect(plan.url, startsWith('pics://'));
      expect(plan.originalUrl, 'https://cdn.example.com/img1.mp4');
    });

    test('不可播类型抛错', () async {
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final card = page.items.firstWhere((d) => d.title == '说明.pdf');
      expect(
        engine.resolve(card, Episode({'id': 'doc1', 'title': '说明.pdf'}, 1)),
        throwsA(isA<AppFailure>()),
      );
    });

    test('缓存未命中抛错', () async {
      const drama = Drama(
        id: 'pan115:ghost',
        source: 'cloud:pan115',
        title: '幽灵',
      );
      expect(
        engine.resolve(drama, Episode({'id': 'ghost'}, 1)),
        throwsA(isA<AppFailure>()),
      );
    });
  });

  group('剧集归组（同剧名 + 集数归一）', () {
    test('两集以上归成一张剧集卡，详情按集号排序', () async {
      fake.folders['0'] = [
        file('e2', '仙剑 第2集.mp4'),
        file('e1', '仙剑 第1集.mp4'),
        file('e3', '仙剑 第3集.mp4'),
      ];
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final group = page.items.firstWhere((d) => d.title == '仙剑');
      expect(group.episodes, 3);
      expect(group.tags, contains('共3集'));
      expect(page.items.map((d) => d.title), isNot(contains('仙剑 第1集.mp4')));
      final detail = await engine.detail(group);
      expect(detail.episodes.map((e) => e.title), ['第1集', '第2集', '第3集']);
      final plan = await engine.resolve(group, detail.episodes[1]);
      expect(plan.url, 'https://cdn.example.com/e2.mp4');
    });

    test('同一集号重复不归组，各自单列', () async {
      fake.folders['0'] = [file('a1', '仙剑 第1集.mp4'), file('a2', '仙剑 第1集.mp4')];
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      expect(page.items.where((d) => d.title == '仙剑 第1集.mp4').length, 2);
    });

    test('只有一集不归组', () async {
      fake.folders['0'] = [file('a1', '仙剑 第1集.mp4')];
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      expect(page.items.map((d) => d.title), contains('仙剑 第1集.mp4'));
      expect(page.items.map((d) => d.title), isNot(contains('仙剑')));
    });

    test('不同季分开归组', () async {
      fake.folders['0'] = [
        file('s1e1', '仙剑 第1季 第1集.mp4'),
        file('s2e1', '仙剑 第2季 第1集.mp4'),
        file('s2e2', '仙剑 第2季 第2集.mp4'),
      ];
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final group = page.items.firstWhere((d) => d.title == '仙剑 第2季');
      expect(group.episodes, 2);
      expect(page.items.map((d) => d.title), contains('仙剑 第1季 第1集.mp4'));
    });
  });

  group('DVD/蓝光光盘', () {
    test('VIDEO_TS 文件夹成一张光盘卡，详情播最大 VOB', () async {
      fake.folders['0'] = [folder('vt1', 'VIDEO_TS')];
      fake.folders['vt1'] = [
        file('vob1', 'VTS_01_1.VOB', sizeBytes: 500 * 1024 * 1024),
        file('vob2', 'VTS_01_2.VOB', sizeBytes: 2 * 1024 * 1024 * 1024),
        file('ifo1', 'VIDEO_TS.IFO', kind: CloudFileKind.other),
      ];
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final disc = page.items.firstWhere((d) => d.title == 'DVD 光盘');
      expect(disc.kind, 'video');
      expect(disc.tags, contains('DVD'));
      final detail = await engine.detail(disc);
      expect(detail.episodes.length, 1);
      expect(detail.episodes.first.title, '正片');
      expect(detail.warning, contains('菜单'));
      final plan = await engine.resolve(disc, detail.episodes.first);
      expect(plan.url, 'https://cdn.example.com/vob2.mp4');
      expect(plan.forceMpv, isTrue);
    });

    test('VOB 列表归成一张“DVD 正片”，IFO/BUP 不单列', () async {
      fake.folders['0'] = [
        file('vob1', 'VTS_01_1.VOB', sizeBytes: 500 * 1024 * 1024),
        file('vob2', 'VTS_01_2.VOB', sizeBytes: 2 * 1024 * 1024 * 1024),
        file('ifo1', 'VIDEO_TS.IFO', kind: CloudFileKind.other),
        file('bup1', 'VIDEO_TS.BUP', kind: CloudFileKind.other),
      ];
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final titles = page.items.map((d) => d.title).toList();
      expect(titles, contains('DVD 正片'));
      expect(titles, isNot(contains('VIDEO_TS.IFO')));
      expect(titles, isNot(contains('VIDEO_TS.BUP')));
      final card = page.items.firstWhere((d) => d.title == 'DVD 正片');
      final detail = await engine.detail(card);
      expect(detail.episodes.length, 1);
      final plan = await engine.resolve(card, detail.episodes.first);
      expect(plan.forceMpv, isTrue);
    });

    test('无 VOB 的列表里 IFO 卡保留原样', () async {
      fake.folders['0'] = [
        file('ifo1', 'VIDEO_TS.IFO', kind: CloudFileKind.other),
        file('v1', '正片.mp4'),
      ];
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      expect(page.items.map((d) => d.title), contains('VIDEO_TS.IFO'));
    });

    test('BDMV 文件夹成一张蓝光卡，详情播最大 m2ts', () async {
      fake.folders['0'] = [folder('bd1', 'BDMV')];
      fake.folders['bd1'] = [folder('st1', 'STREAM')];
      fake.folders['st1'] = [
        file('m1', '00001.m2ts', sizeBytes: 100 * 1024 * 1024),
        file('m2', '00002.m2ts', sizeBytes: 20 * 1024 * 1024 * 1024),
      ];
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final disc = page.items.firstWhere((d) => d.title == '蓝光光盘');
      expect(disc.tags, contains('蓝光'));
      final detail = await engine.detail(disc);
      expect(detail.episodes.length, 1);
      final plan = await engine.resolve(disc, detail.episodes.first);
      expect(plan.url, 'https://cdn.example.com/m2.mp4');
      expect(plan.forceMpv, isTrue);
    });

    test('BDMV 带 AACS 时零集 + 加密提示，取流抛错', () async {
      fake.folders['0'] = [folder('bd1', 'BDMV')];
      fake.folders['bd1'] = [folder('aacs', 'AACS'), folder('st1', 'STREAM')];
      fake.folders['st1'] = [file('m1', '00001.m2ts')];
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final disc = page.items.firstWhere((d) => d.title == '蓝光光盘');
      final detail = await engine.detail(disc);
      expect(detail.episodes, isEmpty);
      expect(detail.warning, contains('AACS'));
      expect(
        engine.resolve(disc, Episode({'id': 'x', 'title': '正片'}, 1)),
        throwsA(isA<AppFailure>()),
      );
    });

    test('BDMV 无 STREAM 夹时诚实提示零集', () async {
      fake.folders['0'] = [folder('bd1', 'BDMV')];
      fake.folders['bd1'] = [folder('clip', 'CLIPINF')];
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final disc = page.items.firstWhere((d) => d.title == '蓝光光盘');
      final detail = await engine.detail(disc);
      expect(detail.episodes, isEmpty);
      expect(detail.warning, isNotEmpty);
    });
  });

  group('STRM 指针文件', () {
    CloudDriveEngine engineWithStrmBody(String body, {int status = 200}) {
      return CloudDriveEngine(
        credentialStore: credentialStore,
        httpClient: MockClient((request) async {
          if (request.url.path.contains('s1')) {
            // Response(String) 默认拉丁编码装不下 BOM，改字节构造。
            return http.Response.bytes(utf8.encode(body), status);
          }
          return http.Response('', 200);
        }),
        showSuspectedAds: () => showAds,
        providers: {'pan115': fake},
      );
    }

    test('目录里打 STRM 标签，取流展开成内层地址 + 直链头', () async {
      fake.folders['0'] = [file('s1', '直播.strm', sizeBytes: 60)];
      final strmEngine = engineWithStrmBody(
        '\uFEFF\n\nhttps://stream.example.com/live.m3u8\n',
      );
      final page = await strmEngine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final card = page.items.firstWhere((d) => d.title == '直播.strm');
      expect(card.tags, contains('STRM'));
      final detail = await strmEngine.detail(card);
      final plan = await strmEngine.resolve(card, detail.episodes.first);
      expect(plan.url, 'https://stream.example.com/live.m3u8');
      expect(plan.headers['Cookie'], 'UID=x');
    });

    test('内容不是有效地址时诚实报错', () async {
      fake.folders['0'] = [file('s1', '直播.strm', sizeBytes: 60)];
      final strmEngine = engineWithStrmBody('magnet:?xt=urn:btih:abc\n');
      final page = await strmEngine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final card = page.items.firstWhere((d) => d.title == '直播.strm');
      final detail = await strmEngine.detail(card);
      expect(
        strmEngine.resolve(card, detail.episodes.first),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'message',
            contains('不是有效的流地址'),
          ),
        ),
      );
    });

    test('STRM 内容取不到时报错读取失败', () async {
      fake.folders['0'] = [file('s1', '直播.strm', sizeBytes: 60)];
      final strmEngine = engineWithStrmBody('', status: 404);
      final page = await strmEngine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final card = page.items.firstWhere((d) => d.title == '直播.strm');
      final detail = await strmEngine.detail(card);
      expect(
        strmEngine.resolve(card, detail.episodes.first),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'message',
            contains('读取失败'),
          ),
        ),
      );
    });
  });

  group('ISO 光盘', () {
    test('目录里打 ISO 标签，取流强制 mpv', () async {
      fake.folders['0'] = [file('iso1', '电影.iso')];
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final card = page.items.firstWhere((d) => d.title == '电影.iso');
      expect(card.tags, contains('ISO 光盘'));
      final detail = await engine.detail(card);
      final plan = await engine.resolve(card, detail.episodes.first);
      expect(plan.forceMpv, isTrue);
    });

    test('普通视频不强制 mpv', () async {
      final page = await engine.catalog(
        source: 'cloud:pan115',
        page: 1,
        query: '',
        category: '',
      );
      final card = page.items.firstWhere((d) => d.title == '正片.mp4');
      final detail = await engine.detail(card);
      final plan = await engine.resolve(card, detail.episodes.first);
      expect(plan.forceMpv, isFalse);
    });
  });

  group('PlaybackPlan forceMpv 透传', () {
    test('withUrl / withHeaders / withNeedsParse / withDanmaku 都保留', () {
      const plan = PlaybackPlan(url: 'https://x/1.mp4', forceMpv: true);
      expect(plan.withUrl('https://x/2.mp4').forceMpv, isTrue);
      expect(plan.withHeaders(const {'A': 'b'}).forceMpv, isTrue);
      expect(plan.withNeedsParse(true).forceMpv, isTrue);
      expect(plan.withDanmaku('s', 'd').forceMpv, isTrue);
      const plain = PlaybackPlan(url: 'https://x/1.mp4');
      expect(plain.withUrl('https://x/2.mp4').forceMpv, isFalse);
    });
  });
}
