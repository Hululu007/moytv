// 115 上传界面批预览截图：账号信息位+上传入口 / 上传中进度 / 上传失败。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），逐个单跑、超时杀掉只取 PNG，不要批量跑。
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/cloud_drive/cloud_credential_store.dart';
import 'package:moyi/cloud_drive/cloud_drive_screen.dart';
import 'package:moyi/cloud_drive/cloud_providers.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _previewDir = '/home/hatch/workspace/moyi_pan115_upload_ui_20261126/preview';

late LocalStore _previewStore;

ThemeData _previewTheme(AppThemeMode mode) {
  final base = AppThemeConfig.forTheme(mode).toThemeData();
  TextStyle? cjk(TextStyle? style) => style?.copyWith(fontFamily: 'PreviewCJK');
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: cjk(base.appBarTheme.titleTextStyle),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    try {
      await tester.pump(const Duration(milliseconds: 60));
    } catch (_) {}
  }
  for (var i = 0; i < 10; i++) {
    try {
      if (tester.takeException() == null) break;
    } catch (_) {
      break;
    }
  }
}

class _PreviewPan115 extends Pan115Provider {
  _PreviewPan115({this.failUpload = false});

  final bool failUpload;

  @override
  Future<Pan115AccountInfo> accountInfo(
    http.Client client,
    CloudCredentials credentials,
  ) async {
    return const Pan115AccountInfo(
      userId: '123456',
      nickname: '测试昵称',
      vipForever: true,
    );
  }

  @override
  Future<Pan115SpaceInfo> spaceInfo(
    http.Client client,
    CloudCredentials credentials,
  ) async {
    return const Pan115SpaceInfo(
      totalBytes: 1024 * 1024 * 1024,
      usedBytes: 512 * 1024 * 1024,
      remainBytes: 512 * 1024 * 1024,
    );
  }

  @override
  Future<void> uploadLocalFile(
    http.Client client,
    CloudCredentials credentials, {
    required File file,
    String? fileName,
    required String targetFolderId,
    void Function(int sentBytes, int totalBytes)? onProgress,
  }) async {
    if (failUpload) {
      throw CloudDriveException('115 上传初始化失败：服务器没有返回上传回调');
    }
    onProgress?.call(4, 10);
    // 预览期间不完成，停在“上传中”那一帧。
    await Completer<void>().future;
  }
}

Future<void> _capture(
  WidgetTester tester, {
  required String name,
  required String label,
  required _PreviewPan115 provider,
  required bool openUpload,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _previewTheme(AppThemeMode.purpleNeon),
        home: DefaultTextStyle(
          style: const TextStyle(fontFamily: 'PreviewCJK'),
          child: Scaffold(
            body: Column(
              children: [
                Container(
                  width: double.infinity,
                  color: Colors.black87,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontFamily: 'PreviewCJK',
                    ),
                  ),
                ),
                Expanded(
                  child: CloudDriveScreen(
                    store: _previewStore,
                    providers: [provider],
                    uploadPicker: () async =>
                        (path: '/tmp/preview/a.mp4', name: 'a.mp4'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  if (openUpload) {
    await tester.ensureVisible(find.text('上传文件到根目录'));
    await tester.pump();
    await tester.tap(find.text('上传文件到根目录'));
    await _settle(tester);
  }
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = data!.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );
  Directory(_previewDir).createSync(recursive: true);
  File('$_previewDir/$name.png').writeAsBytesSync(bytes);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    _previewStore = LocalStore(prefs);
    await CloudCredentialStore(prefs).save(
      'pan115',
      const CloudCredentials(
        fields: {'cookie': 'UID=U1; CID=C1; SEID=S1'},
        savedAtMs: 1,
      ),
    );
  });

  setUpAll(() async {
    try {
      final bytes = File(
        '/home/hatch/workspace/huoyi_new/cjk_subset.ttf',
      ).readAsBytesSync();
      final loader = FontLoader('PreviewCJK')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
  });

  testWidgets('preview pan115 account card', (tester) async {
    await _capture(
      tester,
      name: 'pan115_account_card',
      label: '预览 · 网盘页 115 卡 · 账号信息位（昵称/ID/会员/容量）+ 上传入口',
      provider: _PreviewPan115(),
      openUpload: false,
    );
  });

  testWidgets('preview pan115 upload progress', (tester) async {
    await _capture(
      tester,
      name: 'pan115_upload_progress',
      label: '预览 · 115 上传弹窗 · 上传中进度（4 B / 10 B）',
      provider: _PreviewPan115(),
      openUpload: true,
    );
  });

  testWidgets('preview pan115 upload failed', (tester) async {
    await _capture(
      tester,
      name: 'pan115_upload_failed',
      label: '预览 · 115 上传弹窗 · 失败原因中文落字',
      provider: _PreviewPan115(failUpload: true),
      openUpload: true,
    );
  });
}
