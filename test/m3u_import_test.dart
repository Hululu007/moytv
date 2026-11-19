import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:moyi/live_models.dart';
import 'package:moyi/live_repository.dart';
import 'package:moyi/live_sources.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/m3u_subscriptions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sampleM3u = '''
#EXTM3U url-tvg="https://epg.test/xml"
#EXTINF:-1 tvg-id="cctv1" tvg-logo="https://logo.test/cctv1.png" group-title="央视",CCTV-1 综合
https://live.test/cctv1.m3u8
#EXTINF:-1 tvg-id="hn" tvg-logo="https://logo.test/hn.png" group-title="卫视",湖南卫视
https://live.test/hn.m3u8
#EXTINF:-1 group-title="卫视",坏频道
not-a-url
#EXTINF:-1,无分组频道
https://live.test/plain.m3u8
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // M3uSubscriptionService.build 要把原文件存进应用目录，测前
  // 把 path_provider 指到临时目录。
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('moyi_m3u_import_test');
    const provider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(provider, (call) async => tempDir.path);
  });

  tearDownAll(() async {
    const provider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(provider, null);
    await tempDir.delete(recursive: true);
  });

  tearDown(() {
    LiveSource.importedSources.clear();
    importedLiveChannels.clear();
  });

  group('m3u 解析', () {
    test('group-title 作分类、tvg-logo 作台标、坏行计数', () {
      final report = analyzeM3u(_sampleM3u, source: 'm3u:test');
      expect(report.channelCount, 3);
      expect(report.totalEntries, 4);
      expect(report.badEntries, 1);
      final groups = {for (final group in report.groups) group.name: group};
      expect(groups.keys, containsAll(['央视', '卫视', '其他']));
      final cctv = groups['央视']!.channels.single;
      expect(cctv.name, 'CCTV-1 综合');
      expect(cctv.logo, 'https://logo.test/cctv1.png');
      expect(cctv.group, '央视');
      expect(cctv.url, 'https://live.test/cctv1.m3u8');
    });

    test('缺 #EXTM3U 头也能解析', () {
      final report = analyzeM3u(
        '#EXTINF:-1 group-title="卫视",湖南卫视\nhttps://live.test/hn.m3u8\n',
        source: 'm3u:test',
      );
      expect(report.channelCount, 1);
    });

    test('空文件明确报错', () {
      expect(
        () => analyzeM3u('   \n', source: 'm3u:test'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('文件为空'),
          ),
        ),
      );
    });

    test('无可用频道明确报错并带计数', () {
      expect(
        () => analyzeM3u(
          '#EXTM3U\n#EXTINF:-1,坏频道\nnot-a-url\n',
          source: 'm3u:test',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('未解析到任何频道'),
          ),
        ),
      );
    });
  });

  group('订阅持久化与直播注册', () {
    test('订阅 JSON 只存元数据与频道数，不存频道', () {
      final report = analyzeM3u(_sampleM3u, source: 'm3u:abc');
      final sub = M3uSubscription(
        id: 'abc',
        name: '测试订阅',
        kind: M3uSubscription.kindUrl,
        url: 'https://sub.test/list.m3u',
        groupCount: report.groups.length,
        updatedAtMs: 123,
        channels: report.channels,
      );
      final json = sub.toJson();
      expect(json.containsKey('channels'), isFalse);
      expect(json['channelCount'], 3);
      final restored = M3uSubscription.fromJson(json);
      expect(restored.name, '测试订阅');
      expect(restored.channelCount, 3);
      expect(restored.channels, isEmpty);
      expect(restored.sourceId, 'm3u:abc');
    });

    test('老快照的 channels 字段仍能读出', () {
      final legacy = <String, dynamic>{
        'id': 'old',
        'name': '老订阅',
        'kind': M3uSubscription.kindFile,
        'url': '',
        'fileName': '',
        'groupCount': 2,
        'updatedAtMs': 0,
        'channels': [
          {
            'key': 'm3u:old\x00卫视\x00湖南卫视',
            'name': '湖南卫视',
            'group': '卫视',
            'source': 'm3u:old',
            'url': 'https://live.test/hn.m3u8',
            'urls': ['https://live.test/hn.m3u8'],
            'headers': <String, String>{},
            'logo': '',
            'number': '001',
            'token': '',
            'subtitle': '',
          },
        ],
      };
      final restored = M3uSubscription.fromJson(legacy);
      expect(restored.channelCount, 1);
      expect(restored.channels.single.name, '湖南卫视');
    });

    test('LocalStore 同步后进入直播区且仓库可直接取频道', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      final report = analyzeM3u(_sampleM3u, source: 'm3u:sub1');
      final sub = M3uSubscription(
        id: 'sub1',
        name: '我的订阅',
        kind: M3uSubscription.kindFile,
        groupCount: report.groups.length,
        channels: report.channels,
      );
      await store.syncM3uSubscriptions([sub]);
      expect(store.m3uSubscriptions.single.name, '我的订阅');
      final source = LiveSource.byId('m3u:sub1');
      expect(source, isNotNull);
      expect(source!.builtin, isFalse);
      expect(
        LiveSource.visible(false).any((item) => item.id == 'm3u:sub1'),
        isTrue,
      );
      final repository = LiveRepository();
      final channels = await repository.channels(
        source,
        const LivePlatform(id: 'all', name: '全部频道'),
      );
      expect(channels.length, 3);
      expect(channels.first.name, 'CCTV-1 综合');
      final playback = await repository.playback(source, channels.first);
      expect(playback.url, 'https://live.test/cctv1.m3u8');
      await store.syncM3uSubscriptions(const []);
      expect(LiveSource.byId('m3u:sub1'), isNull);
      expect(importedLiveChannels.containsKey('m3u:sub1'), isFalse);
    });

    test('重启后从存档恢复订阅，频道按需从副本加载', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final first = LocalStore(prefs);
      final record = await M3uSubscriptionService.build(
        name: '保留订阅',
        kind: M3uSubscription.kindUrl,
        text: _sampleM3u,
        rawBytes: utf8.encode(_sampleM3u),
        url: 'https://sub.test/a.m3u',
      );
      await first.syncM3uSubscriptions([record]);
      first.dispose();
      LiveSource.importedSources.clear();
      importedLiveChannels.clear();
      final second = LocalStore(prefs);
      addTearDown(second.dispose);
      expect(second.m3uSubscriptions.single.name, '保留订阅');
      expect(second.m3uSubscriptions.single.channelCount, 3);
      expect(LiveSource.byId(record.sourceId), isNotNull);
      // 重启后频道不常驻内存，点开该源时才从副本加载。
      expect(importedLiveChannels.containsKey(record.sourceId), isFalse);
      final repository = LiveRepository();
      final channels = await repository.channels(
        LiveSource.byId(record.sourceId)!,
        const LivePlatform(id: 'all', name: '全部频道'),
      );
      expect(channels.length, 3);
      expect(channels.first.name, 'CCTV-1 综合');
      final playback = await repository.playback(
        LiveSource.byId(record.sourceId)!,
        channels.first,
      );
      expect(playback.url, 'https://live.test/cctv1.m3u8');
    });
  });
}
