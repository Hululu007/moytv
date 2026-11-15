// 在看卡片源徽标预览截图：只做测试内截图，不改业务代码。
// 全部假数据；调过 toImage 的测试在收尾时会挂起（旧现象，PNG 已落地），
// 跑单测、超时杀掉只取 PNG。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/follow_state.dart';
import 'package:moyi/jar_bridge.dart';
import 'package:moyi/local_profiles.dart';
import 'package:moyi/local_snapshot.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/saved_library.dart';
import 'package:moyi/ui_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir = '/home/hatch/workspace/moyi_previews';

ThemeData _previewTheme() {
  final base = AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    try {
      await tester.pump(const Duration(milliseconds: 100));
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

void main() {
  testWidgets('preview watching source badge', (tester) async {
    const jarId = 'jar:zakatv:previewbadge';
    const pyId = 'py:previewbadge';
    const plainId = 'import:previewbadge';
    SourceSite.importedSites[jarId] = const SourceSite(
      jarId,
      '假 jar 站',
      '合成数据',
      section: SourceSite.sectionVideo,
    );
    JarBridge.register(
      const JarSiteSpec(
        siteId: jarId,
        configId: 'zakatv',
        name: '假 jar 站',
        className: 'Fake',
        jarUrl: '',
        jarMd5: '',
        ext: '',
      ),
    );
    SourceSite.importedSites[pyId] = const SourceSite(
      pyId,
      '假 py 站',
      '合成数据',
      section: SourceSite.sectionVideo,
    );
    SourceSite.importedPyFiles[pyId] = 'previewbadge.py';
    SourceSite.importedSites[plainId] = const SourceSite(
      plainId,
      '假纯文字站',
      '合成数据',
      section: SourceSite.sectionVideo,
    );
    addTearDown(() {
      JarBridge.unregister(jarId);
      SourceSite.importedSites.remove(jarId);
      SourceSite.importedSites.remove(pyId);
      SourceSite.importedPyFiles.remove(pyId);
      SourceSite.importedSites.remove(plainId);
    });

    const dramas = [
      Drama(
        id: 'hongguo:preview-1',
        source: 'hongguo',
        title: '假数据·红果剧',
        episodes: 24,
        category: '合成数据',
      ),
      Drama(
        id: '$pyId:1',
        source: pyId,
        title: '假数据·爬虫站剧',
        episodes: 36,
        category: '合成数据',
      ),
      Drama(
        id: '$jarId:1',
        source: jarId,
        title: '假数据·咖啡杯站剧',
        episodes: 12,
        category: '合成数据',
      ),
      Drama(
        id: '$plainId:1',
        source: plainId,
        title: '假数据·纯文字站剧',
        episodes: 8,
        category: '合成数据',
      ),
      Drama(
        id: 'hongguo:preview-vip',
        source: 'hongguo',
        title: '假数据·会员剧',
        episodes: 48,
        category: '合成数据',
        vip: true,
      ),
    ];
    // 追剧数据直接预置进偏好快照、由 LocalStore 构造时同步读入：
    // setFollowStatus 这类写路径在本测试环境下永不返回（二分定位：
    // 卡在写路径的 AppDatabase 同步上，与徽标无关的旧坑），预览里
    // 不走写路径。
    const profile = LocalProfile(id: 'default', name: '管理员', admin: true);
    SharedPreferences.setMockInitialValues({
      LocalSnapshot.storageKey: jsonEncode({
        'version': 1,
        'values': <String, Object>{
          'profiles': jsonEncode([profile.toJson()]),
          'activeProfile': 'default',
          'favorites': jsonEncode([for (final drama in dramas) drama.toJson()]),
          'followStates': jsonEncode({
            for (final drama in dramas)
              drama.id: const FollowState(
                status: FollowStatus.watching,
                knownEpisodes: 48,
                readEpisodes: 48,
              ).toJson(),
          }),
        },
      }),
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final previousMode = appThemeNotifier.value;
    appThemeNotifier.value = AppThemeMode.purpleNeon;
    addTearDown(() => appThemeNotifier.value = previousMode);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _previewTheme(),
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
                    child: const Text(
                      '预览·假数据 — 在看卡片右上角源徽标：名称 + 图标'
                      '（jar 咖啡杯 / py 爬虫 / 无图标纯文字）',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontFamily: 'PreviewCJK',
                      ),
                    ),
                  ),
                  Expanded(
                    child: SavedLibrary(
                      repository: FixtureRepository(),
                      store: store,
                      history: false,
                      onOpen: (_) {},
                      onContinue: (_) {},
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
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    Directory(_previewDir).createSync(recursive: true);
    File('$_previewDir/watching_source_badge.png').writeAsBytesSync(bytes);
    print('preview landed: watching_source_badge');
  });
}
