import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_icon_switcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('图标清单', () {
    test('6 个选项：默认 + 5 张蚂蚁图，id 唯一、预览图都在磁盘上', () {
      expect(appIconOptions.length, 6);
      expect(appIconOptions.map((o) => o.id).toSet().length, 6);
      expect(appIconOptions.first.id, 'default');
      expect(appIconOptions.first.aliasSuffix, '');
      for (final option in appIconOptions.skip(1)) {
        expect(option.aliasSuffix, isNotEmpty);
        expect(
          File(option.previewAsset).existsSync(),
          isTrue,
          reason: '预览图缺失：${option.previewAsset}',
        );
      }
      expect(File(appIconOptions.first.previewAsset).existsSync(), isTrue);
    });

    test('AndroidManifest：5 个 activity-alias 与 Dart 侧一一对应', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect('<activity-alias'.allMatches(manifest).length, 5);
      for (final option in appIconOptions.skip(1)) {
        expect(
          manifest.contains('android:name="${option.aliasSuffix}"'),
          isTrue,
          reason: 'Manifest 缺别名：${option.aliasSuffix}',
        );
        expect(
          manifest.contains('@mipmap/ic_launcher_${option.id}'),
          isTrue,
          reason: 'Manifest 缺图标资源：${option.id}',
        );
        expect(
          manifest.contains('android:targetActivity=".MainActivity"'),
          isTrue,
        );
      }
      // 主 Activity 的启动入口还在（默认图标的根）。
      expect(manifest.contains('android.intent.category.LAUNCHER'), isTrue);
    });

    test('mipmap：5 张图标 × 5 个密度共 25 个 PNG', () {
      const densities = ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'];
      for (final option in appIconOptions.skip(1)) {
        for (final density in densities) {
          final file = File(
            'android/app/src/main/res/mipmap-$density/ic_launcher_${option.id}.png',
          );
          expect(file.existsSync(), isTrue, reason: '缺失：${file.path}');
          expect(file.lengthSync(), greaterThan(1000));
        }
      }
    });
  });

  group('切换器通道', () {
    const channel = MethodChannel('moyi/icon_switch');
    late List<MethodCall> calls;
    String current = 'default';

    setUp(() {
      calls = [];
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'currentIcon') return current;
        if (call.method == 'setIcon') {
          current = (call.arguments as Map)['id'] as String;
          return true;
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('currentIcon 读通道值，setIcon 发 id 并记存档', () async {
      current = 'ant_storm';
      final switcher = AppIconSwitcher(supportedOverride: true);
      expect(await switcher.currentIconId(), 'ant_storm');
      expect(await switcher.setIcon('ant_meadow'), isTrue);
      expect(calls.last.method, 'setIcon');
      expect((calls.last.arguments as Map)['id'], 'ant_meadow');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(appIconSelectionKey), 'ant_meadow');
    });

    test('未知 id 拒绝，不发通道', () async {
      final switcher = AppIconSwitcher(supportedOverride: true);
      expect(await switcher.setIcon('nope'), isFalse);
      expect(calls, isEmpty);
    });

    test('非安卓：setIcon 拒绝，currentIcon 回落存档', () async {
      SharedPreferences.setMockInitialValues(
        {appIconSelectionKey: 'ant_lens'},
      );
      final switcher = AppIconSwitcher(supportedOverride: false);
      expect(await switcher.setIcon('ant_flame'), isFalse);
      expect(await switcher.currentIconId(), 'ant_lens');
      expect(calls, isEmpty);
    });

    test('通道抛错时 currentIcon 回落存档', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'boom');
      });
      SharedPreferences.setMockInitialValues(
        {appIconSelectionKey: 'ant_win12'},
      );
      final switcher = AppIconSwitcher(supportedOverride: true);
      expect(await switcher.currentIconId(), 'ant_win12');
    });
  });
}
