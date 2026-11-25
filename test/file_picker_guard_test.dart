// 选文件同款毛病回归（与主树统一导入入口 9395cf3 同款修法）：
// 三处选文件入口——导入中心、插件市场、idj 插件 tab 的
// installFromFile——选择器调用必须进 try：用户取消静默返回，
// 选择器本身抛错给明确提示，异常不许漏出（漏出会让本文件用例
// 以未捕获异步异常失败，这正是回归信号）。
import 'dart:io';

// file_picker 的平台接口是传递依赖，测试装假平台必须直接引它。
// ignore: depend_on_referenced_packages
import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/idj_plugin_store.dart';
import 'package:moyi/import_center_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/miniapp/idj_plugin_tab.dart';
import 'package:moyi/plugin_market_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 假文件选择器平台：error 非空时所有选择调用抛错；
/// 否则模拟用户取消（pickFile 回 null、pickFiles 回空列表）。
class FakeFilePickerPlatform extends FilePickerPlatform {
  FakeFilePickerPlatform({this.error});

  final Object? error;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    final e = error;
    if (e != null) throw e;
    return const [];
  }

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    final e = error;
    if (e != null) throw e;
    return null;
  }
}

Future<Map<String, dynamic>> _probeStub({
  required String pluginId,
  required String script,
  required Map<String, dynamic> manifest,
}) async => {};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FilePickerPlatform originalPlatform;
  late Directory tempDir;
  late IdjPluginStore idjStore;

  setUpAll(() {
    originalPlatform = FilePickerPlatform.instance;
    tempDir = Directory.systemTemp.createTempSync('picker_guard_test');
  });

  tearDownAll(() {
    FilePickerPlatform.instance = originalPlatform;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    idjStore = IdjPluginStore(
      preferences: prefs,
      rootOverride: tempDir,
      probe: _probeStub,
    );
  });

  group('idj 插件 installFromFile', () {
    // 抛错路径里 installFromFile 会先等错误弹窗关掉才返回，
    // 所以返回值装箱、由用例在关弹窗后再读。
    Future<List<bool?>> pumpEntry(WidgetTester tester) async {
      final box = <bool?>[null];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  box[0] = await IdjPluginActions.installFromFile(
                    context,
                    idjStore,
                  );
                },
                child: const Text('从文件安装'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('从文件安装'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return box;
    }

    testWidgets('选择器抛错：不崩、回 false、弹明确提示', (tester) async {
      FilePickerPlatform.instance = FakeFilePickerPlatform(
        error: StateError('选择器打不开'),
      );
      final box = await pumpEntry(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('打开文件选择器失败'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(box[0], isFalse);
    });

    testWidgets('用户取消：静默回 false、无弹窗', (tester) async {
      FilePickerPlatform.instance = FakeFilePickerPlatform();
      final box = await pumpEntry(tester);
      expect(box[0], isFalse);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('导入中心选文件', () {
    Future<void> pumpPage(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      await tester.pumpWidget(
        MaterialApp(
          home: ImportCenterScreen(
            repository: FixtureRepository(),
            store: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('import-center-file')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('选择器抛错：不崩、SnackBar 给明确提示', (tester) async {
      FilePickerPlatform.instance = FakeFilePickerPlatform(
        error: StateError('选择器打不开'),
      );
      await pumpPage(tester);
      expect(find.textContaining('打开文件选择器失败'), findsOneWidget);
    });

    testWidgets('用户取消：静默、无提示', (tester) async {
      FilePickerPlatform.instance = FakeFilePickerPlatform();
      await pumpPage(tester);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.textContaining('打开文件选择器失败'), findsNothing);
    });
  });

  group('插件市场选文件', () {
    Future<void> pumpPage(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      await tester.pumpWidget(
        MaterialApp(
          home: PluginMarketScreen(
            repository: FixtureRepository(),
            store: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('plugin-install-from-file')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('选择器抛错：不崩、SnackBar 给明确提示', (tester) async {
      FilePickerPlatform.instance = FakeFilePickerPlatform(
        error: StateError('选择器打不开'),
      );
      await pumpPage(tester);
      expect(find.textContaining('打开文件选择器失败'), findsOneWidget);
    });

    testWidgets('用户取消：静默、无提示', (tester) async {
      FilePickerPlatform.instance = FakeFilePickerPlatform();
      await pumpPage(tester);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.textContaining('打开文件选择器失败'), findsNothing);
    });
  });
}
