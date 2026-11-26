import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_update.dart';
import 'package:moyi/app_update_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _current = AppVersion(1, 0, 6, 31);
const _latest = AppReleaseInfo(
  version: AppVersion(1, 0, 7, 32),
  tag: 'v62',
  name: '魔蚁TV v62',
  notes: '修复若干问题',
  htmlUrl: 'https://example.test/releases',
);

/// 强制更新版：发布说明里带 FORCE 窗口，且当前时间落在窗口内。
AppReleaseInfo forcedLatest() {
  final info = AppReleaseInfo.fromGithubJson({
    'tag_name': 'v1.0.7',
    'name': '魔蚁TV v62',
    'body': '修复若干问题\nFORCE_AFTER: 2026-01-01\nFORCE_UNTIL: 2026-12-31\n',
    'html_url': 'https://example.test/releases',
    'assets': [
      {
        'name': 'moyi-1.0.7+32-v7a-v8a.apk',
        'browser_download_url': 'https://example.test/moyi.apk',
        'size': 100,
      },
    ],
  });
  expect(info, isNotNull);
  return info!;
}

Future<void> pumpPrompt(
  WidgetTester tester, {
  AppReleaseInfo latest = _latest,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          return ElevatedButton(
            onPressed: () => showAppUpdatePrompt(
              context,
              current: _current,
              latest: latest,
            ),
            child: const Text('弹更新提示'),
          );
        },
      ),
    ),
  );
  await tester.tap(find.text('弹更新提示'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('更新提示框', () {
    testWidgets('弹出后显示新版本号与更新说明', (tester) async {
      await pumpPrompt(tester);
      expect(find.text('发现新版本 1.0.7'), findsOneWidget);
      expect(find.textContaining('当前版本 1.0.6 → 最新版本 1.0.7'), findsOneWidget);
      expect(find.textContaining('修复若干问题'), findsOneWidget);
      expect(find.text('稍后再说'), findsOneWidget);
      // 测试跑在宿主上（非安卓），应显示“打开发布页”而不是下载按钮。
      expect(find.text('打开发布页'), findsOneWidget);
      expect(find.text('下载并安装'), findsNothing);
    });

    testWidgets('点“稍后再说”关框并记下这版不再弹', (tester) async {
      await pumpPrompt(tester);
      await tester.tap(find.text('稍后再说'));
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 1.0.7'), findsNothing);
      expect(
        await AppUpdateChecker.isUpdateDismissed(_latest.version),
        isTrue,
      );
      // 另一版没被记下，照样会弹。
      expect(
        await AppUpdateChecker.isUpdateDismissed(
          const AppVersion(1, 0, 8, 33),
        ),
        isFalse,
      );
    });

    testWidgets('强制更新没有“稍后再说”', (tester) async {
      await pumpPrompt(tester, latest: forcedLatest());
      expect(find.text('发现新版本 1.0.7'), findsOneWidget);
      expect(find.textContaining('强制更新'), findsOneWidget);
      expect(find.text('稍后再说'), findsNothing);
    });
  });

  group('dismissUpdate / isUpdateDismissed', () {
    test('记下的版本才算已忽略', () async {
      const version = AppVersion(1, 0, 7, 32);
      expect(await AppUpdateChecker.isUpdateDismissed(version), isFalse);
      await AppUpdateChecker.dismissUpdate(version);
      expect(await AppUpdateChecker.isUpdateDismissed(version), isTrue);
    });
  });
}
