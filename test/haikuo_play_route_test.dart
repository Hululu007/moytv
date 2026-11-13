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
}
