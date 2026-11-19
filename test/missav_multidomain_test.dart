import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_store.dart';
import 'package:moyi/zakatv_builtin.dart';

/// MissAV 多域名回落（2026-11-19）回归测试。
///
/// 钉住：jar 的 md5 常量与实际文件一致、classes.dex 含新域名串与
/// Mirror 的 tryHosts、规则包里 MissAV 为 v6 且模块带 hosts 回落表
/// 与域名记忆、bundle 版本升到 14（已装设备重新播种）。
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
      final text =
          latin1.decode(dex!.content as List<int>, allowInvalid: true);
      expect(text, contains('https://missav.fans'));
      expect(text, contains('https://www.missav06.net'));
      expect(text, contains('https://www.thisav.my'));
      expect(text, contains('tryHosts'));
    });
  });

  group('海阔规则包回落', () {
    late Map<String, dynamic> rule;

    setUpAll(() {
      final text =
          File('assets/haikuo_builtin_rules.json').readAsStringSync();
      final list = jsonDecode(text) as List<dynamic>;
      expect(list.length, 146);
      rule = list.firstWhere(
        (e) => (e as Map<String, dynamic>)['title'] == '🔞MissAV',
      ) as Map<String, dynamic>;
    });

    test('MissAV 规则 version 6 且 fixlog 记本次改动', () {
      expect(rule['version'], 6);
      final fixlog = rule['fixlog'] as String;
      expect(fixlog, contains('v6'));
      expect(fixlog, contains('missav.fans'));
    });

    test('MissAV 模块含 hosts 回落表与域名记忆', () {
      final pages = jsonDecode(rule['pages'] as String) as List<dynamic>;
      final js = (pages.first as Map<String, dynamic>)['rule'] as String;
      expect(js, contains("hosts: ['https://missav.live'"));
      expect(js, contains('https://missav.fans'));
      expect(js, contains('https://www.missav06.net'));
      expect(js, contains('https://www.thisav.my'));
      expect(js, contains('MissAV.bestHost'));
      expect(js, contains('miss.get('));
    });

    test('bundle 版本 14', () {
      expect(HaikuoStore.builtinBundleVersion, 14);
    });
  });
}
