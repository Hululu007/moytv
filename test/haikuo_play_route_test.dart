import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runner_page.dart';

/// play 消息去向决策：播放器已打开时递送（切集），详情页发起时内嵌，
/// 其余（列表页发起）推一个新播放页。
void main() {
  test('active player always wins (episode delivery)', () {
    expect(
      resolvePlayRoute(fromDetail: true, playerActive: true),
      HaikuoPlayRoute.deliver,
    );
    expect(
      resolvePlayRoute(fromDetail: false, playerActive: true),
      HaikuoPlayRoute.deliver,
    );
  });

  test('detail play with no active player goes inline', () {
    expect(
      resolvePlayRoute(fromDetail: true, playerActive: false),
      HaikuoPlayRoute.inline,
    );
  });

  test('list play with no active player pushes a page', () {
    expect(
      resolvePlayRoute(fromDetail: false, playerActive: false),
      HaikuoPlayRoute.push,
    );
  });

  test('slot height follows the video aspect ratio', () {
    // 横屏 16:9：旧槽位高度不变。
    expect(
      haikuoSlotHeight(aspectRatio: 16 / 9, maxWidth: 390, maxHeight: 844),
      closeTo(390 * 9 / 16, 0.01),
    );
    // 方形：宽即高，未超上限。
    expect(
      haikuoSlotHeight(aspectRatio: 1, maxWidth: 390, maxHeight: 844),
      closeTo(390, 0.01),
    );
  });

  test('portrait slot grows but stays under the 56% cap', () {
    // 竖屏 9:16：按比例要 693.33，被 56% 上限压到 472.64，
    // 仍比 16:9 槽位（219.375）高一倍多，下方详情仍可见。
    expect(
      haikuoSlotHeight(aspectRatio: 9 / 16, maxWidth: 390, maxHeight: 844),
      closeTo(844 * 0.56, 0.01),
    );
  });

  test('slot height falls back to 16:9 for invalid ratios', () {
    for (final ratio in [0.0, -1.0, double.nan, double.infinity]) {
      expect(
        haikuoSlotHeight(aspectRatio: ratio, maxWidth: 390, maxHeight: 844),
        closeTo(390 * 9 / 16, 0.01),
      );
    }
  });
}
