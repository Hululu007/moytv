// 预览：跨季连播倒计时提示。一测一张，收尾挂起是已知现象，PNG 落地即杀。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/hongguo_season_countdown.dart';

const _previewDir = '/home/hatch/workspace/moyi_previews';

void main() {
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

  testWidgets('预览跨季连播倒计时', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    final base = AppThemeConfig.forTheme(
      AppThemeMode.purpleNeon,
    ).toThemeData();
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
      primaryTextTheme: base.primaryTextTheme.apply(
        fontFamily: 'PreviewCJK',
      ),
      // 主题给按钮与标题指定的展示字体在预览环境没加载，钉回子集字体
      // 否则“取消”与标题显示成方框；真机上主题字体正常加载，不受影响。
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: const TextStyle(fontFamily: 'PreviewCJK'),
        ),
      ),
      appBarTheme: base.appBarTheme.copyWith(
        titleTextStyle: const TextStyle(
          fontFamily: 'PreviewCJK',
          fontSize: 20,
          color: Colors.white,
        ),
      ),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'PreviewCJK'),
            child: Scaffold(
              appBar: AppBar(title: const Text('测试剧第一季')),
              body: Column(
                children: [
                  // 播放区占位（真实画面是视频流，预览里用深色块代替）。
                  SizedBox(
                    height: 354,
                    child: Stack(
                      children: [
                        Container(
                          color: Colors.black87,
                          child: const Center(
                            child: Icon(
                              Icons.play_circle_outline,
                              size: 64,
                              color: Colors.white38,
                            ),
                          ),
                        ),
                        const Positioned(
                          left: 16,
                          right: 16,
                          bottom: 24,
                          child: Center(
                            child: SeasonAutoplayCountdownOverlay(
                              nextTitle: '测试剧第二季',
                              seasonLabel: '第 2 季',
                              remaining: 3,
                              onCancel: _noop,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Text(
                          '第 80 集 · 已播完本季最后一集\n倒计时走完自动播放下一季，点取消停住。',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    Directory(_previewDir).createSync(recursive: true);
    File('$_previewDir/autoplay_countdown.png').writeAsBytesSync(bytes);
    print('preview landed: autoplay_countdown');
  });
}

void _noop() {}
