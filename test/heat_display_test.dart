import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// cover 回空串：FixtureRepository.cover 对合成剧集抛错，详情页
/// 封面重试会把异常抛到测试框架（与 heat 显示无关）。
class _NoCoverRepository extends FixtureRepository {
  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('heatDisplayText', () {
    test('文件大小形状标“大小”', () {
      expect(heatDisplayText('1.4MB'), '大小 1.4MB');
      expect(heatDisplayText('1024 KB'), '大小 1024 KB');
      expect(heatDisplayText('2GB'), '大小 2GB');
      expect(heatDisplayText('512B'), '大小 512B');
      expect(heatDisplayText(' 1.4mb '), '大小  1.4mb ');
    });

    test('非文件大小形状仍标“热度”', () {
      expect(heatDisplayText('1.2万'), '热度 1.2万');
      expect(heatDisplayText('5集'), '热度 5集');
      expect(heatDisplayText('1.4MB/s'), '热度 1.4MB/s');
      expect(heatDisplayText('高'), '热度 高');
    });

    test('heatLooksLikeFileSize 判定', () {
      expect(heatLooksLikeFileSize('1.4MB'), isTrue);
      expect(heatLooksLikeFileSize('1.2万'), isFalse);
      expect(heatLooksLikeFileSize(''), isFalse);
    });
  });

  group('详情页 heat 显示', () {
    const frameChannel = MethodChannel('moyi/frame_extractor');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    setUp(() {
      messenger.setMockMethodCallHandler(frameChannel, (_) async => null);
    });
    tearDown(() {
      messenger.setMockMethodCallHandler(frameChannel, null);
    });

    Future<void> pumpDetail(WidgetTester tester, Drama drama) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = LocalStore(await SharedPreferences.getInstance());
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: DetailScreen(
            drama: drama,
            repository: _NoCoverRepository(),
            store: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('heat 是文件大小时显示“大小”不显示“热度”', (tester) async {
      await pumpDetail(
        tester,
        const Drama(
          id: 'tg:1',
          source: 'hongguo',
          title: 'TG 测试片',
          episodes: 1,
          heat: '1.4MB',
        ),
      );
      expect(find.textContaining('大小 1.4MB'), findsOneWidget);
      expect(find.textContaining('热度'), findsNothing);
    });

    testWidgets('heat 是热度值时显示“热度”', (tester) async {
      await pumpDetail(
        tester,
        const Drama(
          id: 'tg:2',
          source: 'hongguo',
          title: 'TG 测试片',
          episodes: 1,
          heat: '1.2万',
        ),
      );
      expect(find.textContaining('热度 1.2万'), findsOneWidget);
    });
  });
}
