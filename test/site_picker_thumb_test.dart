// 站点列表网格卡片缩图测试：有图显示图片、无图回落站标、
// 缓存命中不再拉首页、只拉可见的卡。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/site_icon.dart';
import 'package:moyi/site_thumb_cache.dart';
import 'package:moyi/source_picker_sheet.dart';

/// 真异步链（缓存读盘、图片落盘）每一跳要一个 runAsync 窗口 +
/// 一个 pump 才能往前走：轮询直到条件成立（最多约 4 秒）。
Future<void> _settleUntil(
  WidgetTester tester,
  bool Function() done, {
  int tries = 12,
}) async {
  for (var i = 0; i < tries; i++) {
    if (done()) return;
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
  }
}

Widget _host({
  required List<SourcePickerGroup> groups,
  required String currentId,
  SiteThumbCache? thumbCache,
  SiteThumbFetcher? thumbFetcher,
  SiteIconCache? thumbImageCache,
}) => MaterialApp(
  home: Scaffold(
    body: SitePickerDialog(
      sectionName: '片库',
      currentId: currentId,
      groups: groups,
      enableZoneFlip: true,
      initialZoneIndex: 0,
      thumbCache: thumbCache,
      thumbFetcher: thumbFetcher,
      thumbImageCache: thumbImageCache,
    ),
  ),
);

void main() {
  late Directory tempDir;
  late List<int> fixtureBytes;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('site_picker_thumb_test_');
    fixtureBytes = File('test/fixtures/cover.jpg').readAsBytesSync();
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  // 测试视口按手机来（390x844），与预览图一致。
  void setPhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  SiteThumbCache cache() =>
      SiteThumbCache(directoryProvider: () async => tempDir);

  SiteIconCache imageCache() => SiteIconCache(
    directoryProvider: () async => tempDir,
    fetcher: (_) async => fixtureBytes,
  );

  testWidgets('有缩图的卡显示图片，无缩图的卡显示站标', (tester) async {
    setPhoneViewport(tester);
    final calls = <String>[];
    Future<String?> fetcher(String siteId) async {
      calls.add(siteId);
      return switch (siteId) {
        'a' => 'https://example.com/thumb-a.jpg',
        'c' => throw StateError('boom'),
        _ => null,
      };
    }

    const groups = [
      SourcePickerGroup(
        title: '视频类',
        entries: [
          SourcePickerEntry(id: 'a', name: 'A站'),
          SourcePickerEntry(id: 'b', name: 'B站'),
          SourcePickerEntry(id: 'c', name: 'C站'),
        ],
        zone: SourcePickerGroup.zoneBuiltin,
      ),
    ];
    await tester.pumpWidget(
      _host(
        groups: groups,
        currentId: 'a',
        thumbCache: cache(),
        thumbFetcher: fetcher,
        thumbImageCache: imageCache(),
      ),
    );
    await tester.pump();
    await _settleUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);

    // A 站拉到封面显示图片；B 站（回 null）与 C 站（抛错）
    // 拉不到，回落站标，不留空。
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(SiteIcon), findsNWidgets(2));
    expect(find.byKey(const ValueKey('site-picker-row-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('site-picker-row-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('site-picker-row-c')), findsOneWidget);
    expect(calls, containsAll(['a', 'b', 'c']));
  });

  testWidgets('缓存命中不再拉首页', (tester) async {
    setPhoneViewport(tester);
    final calls = <String>[];
    Future<String?> fetcher(String siteId) async {
      calls.add(siteId);
      return 'https://example.com/thumb-$siteId.jpg';
    }

    final thumbCache = cache();
    const groups = [
      SourcePickerGroup(
        title: '视频类',
        entries: [SourcePickerEntry(id: 'a', name: 'A站')],
        zone: SourcePickerGroup.zoneBuiltin,
      ),
    ];
    Widget host() => _host(
      groups: groups,
      currentId: 'a',
      thumbCache: thumbCache,
      thumbFetcher: fetcher,
      thumbImageCache: imageCache(),
    );
    await tester.pumpWidget(host());
    await tester.pump();
    await _settleUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);
    expect(find.byType(Image), findsOneWidget);
    expect(calls, ['a']);

    // 关掉重开同一缓存：地址已缓存，不再拉首页。
    await tester.pumpWidget(host());
    await tester.pump();
    await _settleUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);
    expect(find.byType(Image), findsOneWidget);
    expect(calls, ['a']);
  });

  testWidgets('只拉可见的卡，滚到底才拉后面的', (tester) async {
    setPhoneViewport(tester);
    final calls = <String>[];
    Future<String?> fetcher(String siteId) async {
      calls.add(siteId);
      return 'https://example.com/thumb-$siteId.jpg';
    }

    final groups = [
      SourcePickerGroup(
        title: '视频类',
        entries: [
          for (var i = 0; i < 30; i++)
            SourcePickerEntry(id: 's$i', name: '站$i'),
        ],
        zone: SourcePickerGroup.zoneBuiltin,
      ),
    ];
    await tester.pumpWidget(
      _host(
        groups: groups,
        currentId: 's0',
        thumbCache: cache(),
        thumbFetcher: fetcher,
        thumbImageCache: imageCache(),
      ),
    );
    await tester.pump();
    await _settleUntil(tester, () => calls.length >= 10);

    // 首屏只拉可见的卡（3 列约 4 行 + 预取边距），不到 30 个；
    // 最后一个站还没拉过。
    expect(calls.length, lessThan(30));
    expect(calls, contains('s0'));
    expect(calls, isNot(contains('s29')));

    await tester.drag(find.byType(ListView), const Offset(0, -1500));
    await tester.pump();
    await _settleUntil(tester, () => calls.contains('s29'));
    expect(calls, contains('s29'));
  });
}
