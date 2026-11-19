import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/live_models.dart';
import 'package:moyi/live_repository.dart';
import 'package:moyi/live_sources.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/m3u_subscriptions.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 回归：两份各 34447 条的 m3u（贴近用户 9 份女优合集的真实规模）。
/// 旧版快照把频道全塞进 SharedPreferences 单键：单份全量约 21MB，
/// 两份约 43MB，commit 必抛“本地记录超过保存上限”；新版只存元数据。
String _bigM3u(String tag, {int entries = 34447, int groups = 40}) {
  final buffer = StringBuffer('#EXTM3U\n');
  for (var i = 0; i < entries; i++) {
    final group = '女优${(i % groups) + 1}';
    buffer
      ..write(
        '#EXTINF:-1 tvg-logo="https://v.hersav.me/images/av/$tag$i.jpg" '
        'group-title="$group",',
      )
      ..write('JUBE-${10000 + i} 标题$tag$i\n')
      ..write('https://v.hersav.me/$tag$i/$tag$i.m3u8\n');
  }
  return buffer.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('moyi_m3u_limit_test');
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
    loadImportedLiveChannels = null;
  });

  test('导入两份 34447 条 m3u：提交不超上限、频道按需可取', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = LocalStore(prefs);
    addTearDown(store.dispose);

    final textA = _bigM3u('a');
    final first = await M3uSubscriptionService.build(
      name: '女优合集1',
      kind: M3uSubscription.kindFile,
      text: textA,
      rawBytes: utf8.encode(textA),
    );
    expect(first.channelCount, 34447);
    final textB = _bigM3u('b');
    final second = await M3uSubscriptionService.build(
      name: '女优合集2',
      kind: M3uSubscription.kindFile,
      text: textB,
      rawBytes: utf8.encode(textB),
    );
    expect(second.channelCount, 34447);

    // 旧版这里会抛 StateError（本地记录超过保存上限）。
    await store.syncM3uSubscriptions([first, second]);
    expect(store.m3uSubscriptions.length, 2);
    expect(
      store.m3uSubscriptions.map((sub) => sub.channelCount),
      [34447, 34447],
    );

    // 快照只剩元数据：两份加起来远不到 16MB。
    final raw = prefs.getString('localSnapshot.v1');
    expect(raw, isNotNull);
    expect(utf8.encode(raw!).length, lessThan(1024 * 1024));

    // 频道按需加载：点开合集1取全量。
    final repository = LiveRepository();
    final firstChannels = await repository.channels(
      LiveSource.byId(first.sourceId)!,
      const LivePlatform(id: 'all', name: '全部频道'),
    );
    expect(firstChannels.length, 34447);
    expect(store.m3uSubscriptions.first.channels.length, 34447);

    // 再点合集2：合集1 的内存频道被丢掉，只留当前这份。
    final secondChannels = await repository.channels(
      LiveSource.byId(second.sourceId)!,
      const LivePlatform(id: 'all', name: '全部频道'),
    );
    expect(secondChannels.length, 34447);
    expect(store.m3uSubscriptions.first.channels, isEmpty);
    expect(store.m3uSubscriptions.last.channels.length, 34447);

    // 丢掉的订阅仍能按需再取回来。
    final firstAgain = await repository.channels(
      LiveSource.byId(first.sourceId)!,
      const LivePlatform(id: 'all', name: '全部频道'),
    );
    expect(firstAgain.length, 34447);
  });

  test('老快照瘦身：带 channels 的旧订阅下次启动自动重写为元数据版', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final text = _bigM3u('c', entries: 6000, groups: 10);
    final built = await M3uSubscriptionService.build(
      name: '老订阅',
      kind: M3uSubscription.kindFile,
      text: text,
      rawBytes: utf8.encode(text),
    );
    // 模拟旧版快照：手动把 channels 写回去。
    final legacyJson = {
      'id': built.id,
      'name': built.name,
      'kind': built.kind,
      'url': '',
      'fileName': built.fileName,
      'groupCount': built.groupCount,
      'updatedAtMs': built.updatedAtMs,
      'channels': [
        for (final channel in built.channels) channel.toFavourite(),
      ],
    };
    final first = LocalStore(prefs);
    await first.syncM3uSubscriptions([built]);
    // 把快照里的 m3uSubscriptions 换成旧格式（含 channels）。
    final raw = prefs.getString('localSnapshot.v1')!;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    (decoded['values'] as Map<String, dynamic>)['m3uSubscriptions'] =
        jsonEncode([legacyJson]);
    await prefs.setString('localSnapshot.v1', jsonEncode(decoded));
    // 显式 dispose 一次（下面不再 addTearDown，避免重复 dispose）。
    first.dispose();

    LiveSource.importedSources.clear();
    importedLiveChannels.clear();
    final second = LocalStore(prefs);
    addTearDown(second.dispose);
    // 启动时自动瘦身：等写队列跑完，快照里不再有 channels。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final slimmed = prefs.getString('localSnapshot.v1')!;
    expect(slimmed.contains('"channels"'), isFalse);
    expect(second.m3uSubscriptions.single.channelCount, 6000);
  });
}
