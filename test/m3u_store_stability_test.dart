import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/m3u_subscriptions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('moyi_m3u_store_test');
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

  test('save 后 readText 读回同样内容，不留临时文件', () async {
    final fileName = await M3uFileStore.save('sub1', [65, 66, 67]);
    expect(fileName, 'sub1.m3u');
    expect(await M3uFileStore.readText(fileName), 'ABC');
    final dir = Directory('${tempDir.path}/m3u_subscriptions');
    final leftovers = dir
        .listSync()
        .where((e) => e.path.contains('.tmp'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('重复保存覆盖旧内容', () async {
    final first = await M3uFileStore.save('sub2', [49]);
    await M3uFileStore.save('sub2', [50, 51]);
    expect(await M3uFileStore.readText(first), '23');
  });

  test('非法 id 字符被转义，不产生路径穿越', () async {
    final fileName = await M3uFileStore.save('../evil', [65]);
    expect(fileName, contains('evil'));
    expect(fileName.contains('/'), isFalse);
    expect(
      File('${tempDir.path}/m3u_subscriptions/$fileName').existsSync(),
      isTrue,
    );
    expect(File('${tempDir.path}/evil.m3u').existsSync(), isFalse);
  });

  test('读不存在的副本报 AppFailure', () async {
    await expectLater(
      M3uFileStore.readText('nope.m3u'),
      throwsA(isA<Exception>()),
    );
  });
}
