import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/playback_preferences.dart';

void main() {
  group('无缝播放偏好', () {
    test('默认开，JSON 往返保持', () {
      const prefs = PlaybackPreferences();
      expect(prefs.seamless, isTrue);
      expect(prefs.preload, isTrue);
      final restored = PlaybackPreferences.fromJson(prefs.toJson());
      expect(restored.seamless, isTrue);
      final off = PlaybackPreferences.fromJson(
        prefs.withSeamless(false).toJson(),
      );
      expect(off.seamless, isFalse, reason: '用户手动关过的按存量值走');
      expect(off.preload, isTrue);
    });

    test('开无缝自动开预加载', () {
      const prefs = PlaybackPreferences(preload: false, seamless: false);
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
      const prefs = PlaybackPreferences(preload: false, seamless: false);
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

    test('老数据没有 seamless 字段时默认开', () {
      final restored = PlaybackPreferences.fromJson({'preload': true});
      expect(restored.seamless, isTrue);
      final noPreload = PlaybackPreferences.fromJson({'preload': false});
      expect(noPreload.seamless, isFalse, reason: '预加载关着仍归一化为无缝关');
    });
  });
}
