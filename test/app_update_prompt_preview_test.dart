// 软件更新启动弹窗预览截图（2026-11-26）：只做测试内截图，不改业务代码。
// 版本号与更新说明均为预览示意数据，不对应任何真实发布。
// 一测一张：调过 toImage 的测试收尾会挂起，跑单测、PNG 落地后超时杀掉即可。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_update.dart';
import 'package:moyi/app_update_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _previewDir = '/home/hatch/workspace/moyi_app_update_popup_20261126/preview';

const _current = AppVersion(1, 0, 13, 38);
const _latest = AppReleaseInfo(
  version: AppVersion(1, 0, 14, 39),
  tag: 'v69',
  name: '魔蚁TV v69',
  notes: '修复若干问题（预览示意）',
  htmlUrl: 'https://example.test/releases',
);

AppReleaseInfo _forcedLatest() {
  final info = AppReleaseInfo.fromGithubJson({
    'tag_name': 'v1.0.14',
    'name': '魔蚁TV v69',
    'body': '修复若干问题（预览示意）\nFORCE_AFTER: 2026-01-01\nFORCE_UNTIL: 2026-12-31\n',
    'html_url': 'https://example.test/releases',
    'assets': [
      {
        'name': 'moyi-1.0.14+39.apk',
        'browser_download_url': 'https://example.test/moyi.apk',
        'size': 100,
      },
    ],
  });
  return info!;
}

Future<void> _shoot(
  WidgetTester tester, {
  required AppReleaseInfo latest,
  required String fileName,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showAppUpdatePrompt(
                    context,
                    current: _current,
                    latest: latest,
                  ),
                  child: const Text('弹更新提示'),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.tap(find.text('弹更新提示'));
  await tester.pumpAndSettle();
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  Directory(_previewDir).createSync(recursive: true);
  File(
    '$_previewDir/$fileName',
  ).writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('预览普通更新弹窗', (tester) async {
    await _shoot(
      tester,
      latest: _latest,
      fileName: 'app_update_prompt_normal.png',
    );
  });

  testWidgets('预览强制更新弹窗', (tester) async {
    await _shoot(
      tester,
      latest: _forcedLatest(),
      fileName: 'app_update_prompt_forced.png',
    );
  });
}
