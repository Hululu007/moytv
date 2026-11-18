import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 详情页背景清晰化（用户 2026-11-18 令）：播放详情页的剧照/海报
/// 背景不再模糊、清晰显示；前景文字可读性只靠渐变罩/暗色覆盖。
/// 源码级断言：背景实现函数内不得出现任何 blur 滤镜。
void main() {
  String readLib(String name) =>
      File('lib/$name').readAsStringSync();

  String functionBody(String source, String signature) {
    final start = source.indexOf(signature);
    expect(start, isNot(-1), reason: 'missing $signature');
    final end = source.indexOf('\n  Widget ', start + signature.length);
    expect(end, isNot(-1), reason: 'cannot find end of $signature');
    return source.substring(start, end);
  }

  test('player_screen.dart 全文不再含 blur 滤镜', () {
    final source = readLib('player_screen.dart');
    expect(source, isNot(contains('ImageFilter.blur')));
    expect(source, isNot(contains('ImageFiltered')));
    expect(source, isNot(contains('BackdropFilter')));
  });

  test('_videoBackdrop 直接渲染清晰封面、不包 blur', () {
    final source = readLib('player_screen.dart');
    final body = functionBody(source, 'Widget _videoBackdrop() {');
    expect(body, contains('DramaCover('));
    expect(body, isNot(contains('ImageFiltered')));
    expect(body, isNot(contains('ImageFilter')));
    expect(body, isNot(contains('BackdropFilter')));
  });

  test('竖屏合一面板仍保留渐变罩（非模糊可读性手段）', () {
    final source = readLib('player_screen.dart');
    final body = functionBody(source, 'Widget _mobilePlaybackPanel() {');
    expect(body, contains('_videoBackdrop()'));
    expect(body, contains('LinearGradient'));
    expect(body, contains('Colors.black45'));
    expect(body, contains('Colors.black87'));
  });

  test('详情页 detail_screen.dart 同样无 blur 滤镜', () {
    final source = readLib('detail_screen.dart');
    expect(source, isNot(contains('ImageFilter.blur')));
    expect(source, isNot(contains('ImageFiltered')));
    expect(source, isNot(contains('BackdropFilter')));
  });

  test('内容详情页 content_detail_screen.dart 无 blur 滤镜', () {
    final source = readLib('content_detail_screen.dart');
    expect(source, isNot(contains('ImageFilter.blur')));
    expect(source, isNot(contains('ImageFiltered')));
    expect(source, isNot(contains('BackdropFilter')));
  });
}
