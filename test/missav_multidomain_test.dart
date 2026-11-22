import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_store.dart';
import 'package:moyi/zakatv_builtin.dart';

/// MissAV 多域名回落（2026-11-19）与取流验盾 v7（2026-11-19）回归测试。
/// 2026-11-22 用户令删 MissAV 全部旧站：海阔 🔞MissAV 规则已撤包
/// （146 → 145 条，bundle 版本升到 16，已装设备重新播种时清掉旧副本）。
/// 钉住：jar 的 md5 常量与实际文件一致、classes.dex 含新域名串与
/// Mirror 的 tryHosts。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('jar 回落', () {
    test('zakatvJarMd5 与实际 jar 文件一致', () {
      final bytes = File('assets/jars/zakatv.jar').readAsBytesSync();
      expect(md5.convert(bytes).toString(), zakatvJarMd5);
    });

    test('classes.dex 含新域名串与 tryHosts', () {
      final bytes = File('assets/jars/zakatv.jar').readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);
      final dex = archive.findFile('classes.dex');
      expect(dex, isNotNull);
      final text = latin1.decode(dex!.content as List<int>, allowInvalid: true);
      expect(text, contains('https://missav.fans'));
      expect(text, contains('https://www.missav06.net'));
      expect(text, contains('https://www.thisav.my'));
      expect(text, contains('tryHosts'));
    });
  });

  group('海阔规则包：MissAV 规则已撤包', () {
    test('🔞MissAV 不在规则包里，条数 145', () {
      final text = File('assets/haikuo_builtin_rules.json').readAsStringSync();
      final list = jsonDecode(text) as List<dynamic>;
      expect(list.length, 145);
      final titles = [
        for (final e in list) (e as Map<String, dynamic>)['title'],
      ];
      expect(titles, isNot(contains('🔞MissAV')));
    });

    test('bundle 版本 16', () {
      expect(HaikuoStore.builtinBundleVersion, 16);
    });
  });
}
