import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/content_py.dart';
import 'package:moyi/core_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late int docsCalls;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('moyi_content_py_test');
    const provider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(provider, (call) async {
      docsCalls++;
      return tempDir.path;
    });
    final dir = Directory('${tempDir.path}/imported_spiders');
    await dir.create(recursive: true);
    await File('${dir.path}/x.py').writeAsString('class Spider:\n pass\n');
  });

  tearDownAll(() async {
    const provider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(provider, null);
    await tempDir.delete(recursive: true);
  });

  setUp(() {
    docsCalls = 0;
  });

  PyContentSource source() => PyContentSource(
    id: 'x1',
    name: '测试站',
    importedFileName: 'x.py',
  );

  test('并发目录调用只解析一次蜘蛛路径', () async {
    final s = source();
    // 测试宿主没有 Python 桥，三路都会在取路径后报“运行时未就绪”；
    // 关键是取路径（走 path_provider 通道）只发生一次。
    final results = await Future.wait([
      s.catalog('', 1).then<Object>((_) => 'ok', onError: (e) => e),
      s.catalog('', 1).then<Object>((_) => 'ok', onError: (e) => e),
      s.catalog('', 1).then<Object>((_) => 'ok', onError: (e) => e),
    ]);
    expect(results.every((e) => e is AppFailure), isTrue);
    expect(docsCalls, 1);
  });

  test('路径解析成功后不再重复解析', () async {
    final s = source();
    await expectLater(s.catalog('', 1), throwsA(isA<AppFailure>()));
    final afterFirst = docsCalls;
    expect(afterFirst, 1);
    await expectLater(s.catalog('', 1), throwsA(isA<AppFailure>()));
    expect(docsCalls, afterFirst);
  });
}
