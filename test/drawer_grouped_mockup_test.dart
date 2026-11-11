import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:moyi/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _mockupItem({
  required IconData icon,
  required String label,
  bool selected = false,
}) {
  return ListTile(
    leading: Icon(icon),
    title: Text(label),
    selected: selected,
    onTap: () {},
  );
}

Widget _mockupGroup({required String title, required List<Widget> children}) {
  return ExpansionTile(
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    initiallyExpanded: true,
    children: children,
  );
}

class MockupGroupedDrawer extends StatelessWidget {
  const MockupGroupedDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(color: colors.primaryContainer),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  '魔蚁box',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 4),
                Text('当前版本 1.0.0'),
              ],
            ),
          ),
          _mockupGroup(
            title: '影视区',
            children: [
              _mockupItem(
                icon: Icons.movie_rounded,
                label: '短剧',
                selected: true,
              ),
              _mockupItem(icon: Icons.video_library_rounded, label: '点播'),
              _mockupItem(icon: Icons.live_tv_rounded, label: '直播'),
              _mockupItem(icon: Icons.group_rounded, label: '一起看房间'),
            ],
          ),
          _mockupGroup(
            title: '阅读',
            children: [
              _mockupItem(icon: Icons.headphones_rounded, label: '听书'),
            ],
          ),
          const Divider(),
          _mockupItem(icon: Icons.list_rounded, label: '站点区'),
          _mockupItem(icon: Icons.source_rounded, label: '内容源管理'),
          _mockupItem(icon: Icons.settings_outlined, label: '设置'),
        ],
      ),
    );
  }
}

void main() {
  setUpAll(() async {
    try {
      final bytes = File(
        '/home/hatch/workspace/huoyi_new/cjk_subset.ttf',
      ).readAsBytesSync();
      final loader = FontLoader('PreviewCJK')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      final fallback = FontLoader('Roboto')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await fallback.load();
    } catch (_) {}
  });

  testWidgets('mockup drawer grouped', (tester) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scaffoldKey = GlobalKey<ScaffoldState>();
    final boundaryKey = GlobalKey();
    final base = AppTheme.platformLight;
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
      listTileTheme: base.listTileTheme.copyWith(
        titleTextStyle: base.listTileTheme.titleTextStyle?.copyWith(
          fontFamily: 'PreviewCJK',
        ),
        subtitleTextStyle: base.listTileTheme.subtitleTextStyle?.copyWith(
          fontFamily: 'PreviewCJK',
        ),
      ),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'PreviewCJK'),
            child: Scaffold(
              key: scaffoldKey,
              drawer: const MockupGroupedDrawer(),
              body: const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    scaffoldKey.currentState!.openDrawer();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final boundary =
        boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    const outDir = '/home/hatch/workspace/huoyi_new/previews';
    Directory(outDir).createSync(recursive: true);
    File('$outDir/preview_drawer_grouped.png').writeAsBytesSync(bytes);
    print('mockup landed: preview_drawer_grouped');
  });
}
