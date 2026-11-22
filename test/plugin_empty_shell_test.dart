import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/build_variant.dart';
import 'package:moyi/plugin_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 本文件两种变体都要跑：默认跑正常版，
  // flutter test --dart-define=MOYI_EMPTY_SHELL=true 跑空壳版。
  // 每次运行打印变体值，日志里能看出跑的是哪一版。
  test('report build variant', () {
    // ignore: avoid_print
    print('emptyShellBuild=$emptyShellBuild');
  });

  test('builtinPlugins follows the build variant', () {
    final plugins = PluginManager.builtinPlugins();
    if (emptyShellBuild) {
      expect(plugins, isEmpty);
    } else {
      // 2 个 jar 插件（zakatv + 一点播独立 jar；MissAV v30 独立 jar 已于
      // 2026-11-22 摘除）+ 124 个 py 插件（含新内置 MissAV）。
      expect(plugins.length, 126);
      expect(plugins.first.id, PluginManager.jarPluginId);
    }
  });

  test('ensureBuiltinPlugins never throws in either variant', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await PluginManager.ensureBuiltinPlugins(preferences);
    // 空壳版直接返回；正常版在测试环境逐条吞错。都不抛错。
  });

  test('installBuiltinPlugin refuses in the empty shell', () async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    if (emptyShellBuild) {
      expect(
        await PluginManager.installBuiltinPlugin(PluginManager.jarPluginId),
        isFalse,
      );
    }
  });
}
