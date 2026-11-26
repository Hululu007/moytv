import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/playback_preferences.dart';

void main() {
  group('无缝播放偏好', () {
    test('默认关，JSON 往返保持', () {
      const prefs = PlaybackPreferences();
      expect(prefs.seamless, isFalse);
      expect(prefs.preload, isTrue);
      final restored = PlaybackPreferences.fromJson(prefs.toJson());
      expect(restored.seamless, isFalse);
      final on = PlaybackPreferences.fromJson(
        prefs.withSeamless(true).toJson(),
      );
      expect(on.seamless, isTrue);
      expect(on.preload, isTrue);
    });

    test('开无缝自动开预加载', () {
      const prefs = PlaybackPreferences(preload: false);
      final next = prefs.withSeamless(true);
      expect(next.seamless, isTrue);
      expect(next.preload, isTrue);
    });

    test('关无缝不动预加载', () {
      const prefs = PlaybackPreferences(seamless: true);
      final next = prefs.withSeamless(false);
      expect(next.seamless, isFalse);
      expect(next.preload, isTrue);
    });

    test('关预加载连带关无缝', () {
      const prefs = PlaybackPreferences(seamless: true);
      final next = prefs.withPreload(false);
      expect(next.preload, isFalse);
      expect(next.seamless, isFalse);
    });

    test('开预加载不动无缝', () {
      const prefs = PlaybackPreferences(preload: false);
      final next = prefs.withPreload(true);
      expect(next.preload, isTrue);
      expect(next.seamless, isFalse);
    });

    test('存量矛盾数据（无缝开、预加载关）读入时归一化为无缝关', () {
      final restored = PlaybackPreferences.fromJson({
        'seamless': true,
        'preload': false,
      });
      expect(restored.preload, isFalse);
      expect(restored.seamless, isFalse);
      final consistent = PlaybackPreferences.fromJson({
        'seamless': true,
        'preload': true,
      });
      expect(consistent.seamless, isTrue);
    });

    test('老数据没有 seamless 字段时默认关', () {
      final restored = PlaybackPreferences.fromJson({'preload': true});
      expect(restored.seamless, isFalse);
    });
  });
}
