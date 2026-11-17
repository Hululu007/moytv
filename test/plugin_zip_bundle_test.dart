import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/builtin_py_sites.dart';
import 'package:moyi/plugin_manager.dart';
import 'package:moyi/zakatv_builtin.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 与 ~/workspace/moyi_jar_plugins/moyi_plugins.zip 同格式的包：
  // 平铺 1 个整包 jar + 49 个视频 py，文件名取自真实注册表。
  // 真实字节的 md5 校验由 assemble_plugin_zip.py 在组装时完成；
  // 这里验证安装路径的 zip 展开认得出这 50 个包、且名字与注册表一致。
  List<int> buildBundleZip() {
    final archive = Archive();
    final jarName = zakatvJarAsset.split('/').last;
    archive.addFile(
      ArchiveFile(jarName, 4, [0x50, 0x4B, 0x03, 0x04]),
    );
    final pyNames = <String>{
      for (final entry in BuiltinPySites.entries)
        entry.assetPath.split('/').last,
    };
    for (final name in pyNames) {
      final content = utf8.encode('# $name\n');
      archive.addFile(ArchiveFile(name, content.length, content));
    }
    return ZipEncoder().encode(archive);
  }

  test('bundle expands to the whole jar plus 49 py plugins', () {
    final entries = expandPluginZip(buildBundleZip());
    expect(entries.length, 50);
    final jars = entries.where((e) => e.isJar).toList();
    expect(jars.length, 1);
    expect(jars.single.name, 'zakatv.jar');
    final pyNames = entries.where((e) => e.isPy).map((e) => e.name).toList();
    expect(pyNames.length, 49);
    expect(pyNames.toSet().length, 49);
    // jinguo 一文件双站：注册表 50 条、文件 49 个，包里只应出现一次。
    expect(pyNames.where((n) => n == 'jinguo.py').length, 1);
    // 未注册的 4 个文件不得进包。
    for (final excluded in ['hghub.py', 'roshy.py', 'javtiful.py', 'youtube.py']) {
      expect(pyNames, isNot(contains(excluded)));
    }
  });

  test('registered py file set matches the bundle manifest count', () {
    final pyNames = <String>{
      for (final entry in BuiltinPySites.entries)
        entry.assetPath.split('/').last,
    };
    expect(pyNames.length, 49);
    expect(BuiltinPySites.entries.length, 50);
  });
}
