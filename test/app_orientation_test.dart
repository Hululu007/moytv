import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_orientation.dart';
import 'package:moyi/playback_preferences.dart';

/// 全局方向决策：全屏跟视频方向（竖屏视频进竖屏、横屏进横屏），
/// 用户强制模式优先于视频方向，电视一律横屏。
void main() {
  test('fullscreen follows the video aspect ratio in auto mode', () {
    expect(
      AppOrientationController.orientations(
        television: false,
        fullscreen: true,
        aspectRatio: 9 / 16,
      ),
      const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
    );
    expect(
      AppOrientationController.orientations(
        television: false,
        fullscreen: true,
        aspectRatio: 16 / 9,
      ),
      const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    );
    // 方形按横屏算（>= 1 走横屏分支，与主播放器一致）。
    expect(
      AppOrientationController.orientations(
        television: false,
        fullscreen: true,
        aspectRatio: 1,
      ),
      const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    );
  });

  test('non-fullscreen playback does not constrain orientation', () {
    expect(
      AppOrientationController.orientations(
        television: false,
        fullscreen: false,
        aspectRatio: 9 / 16,
      ),
      DeviceOrientation.values,
    );
  });

  test('forced user mode wins over the video aspect ratio', () {
    expect(
      AppOrientationController.orientations(
        television: false,
        fullscreen: true,
        aspectRatio: 16 / 9,
        mode: PlaybackOrientationMode.portrait,
      ),
      const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
    );
    expect(
      AppOrientationController.orientations(
        television: false,
        fullscreen: true,
        aspectRatio: 9 / 16,
        mode: PlaybackOrientationMode.landscape,
      ),
      const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    );
  });

  test('television is always landscape', () {
    expect(
      AppOrientationController.orientations(
        television: true,
        fullscreen: true,
        aspectRatio: 9 / 16,
      ),
      const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    );
  });
}
