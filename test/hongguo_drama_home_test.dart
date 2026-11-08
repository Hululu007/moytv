import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/hongguo_drama_home.dart';

void main() {
  test('hongguo drama group detection', () {
    expect(isHongguoDramaGroup('hongguo'), isTrue);
    expect(isHongguoDramaGroup('dsd'), isFalse);
    expect(isHongguoDramaGroup(''), isFalse);
    expect(isHongguoDramaGroup('hongguo2'), isFalse);
  });
}
