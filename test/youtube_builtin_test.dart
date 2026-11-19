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

  test('go_tingshu site exists in the builtin list as an audio-only Listen-Read site', () {
    final site =
        zakatvBuiltinSites.singleWhere((site) => site.key == 'go_tingshu');
    expect(site.name, '飞卢听书');
    expect(site.className, 'com.github.catvod.spider.TingShu');
    expect(site.audioOnly, isTrue);
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
