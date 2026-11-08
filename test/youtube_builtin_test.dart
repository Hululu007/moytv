import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:moyi/zakatv_builtin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('deleted YouTube site is gone from the builtin list', () {
    expect(
      zakatvBuiltinSites.any((site) => site.key == 'ZakaYouTube'),
      isFalse,
    );
  });

  test('go_tingshu builtin is audio-only', () {
    final tingshu = zakatvBuiltinSites.singleWhere(
      (site) => site.key == 'go_tingshu',
    );
    expect(tingshu.audioOnly, isTrue);
  });

  test('merged zakatv jar md5 matches the asset on disk', () {
    final bytes = File('assets/jars/zakatv.jar').readAsBytesSync();
    expect(md5.convert(bytes).toString(), zakatvJarMd5);
  });

  test('standalone youtube jar md5 matches the asset on disk', () {
    final bytes = File('assets/jars/youtube.jar').readAsBytesSync();
    expect(md5.convert(bytes).toString(), youtubeJarMd5);
  });
}
