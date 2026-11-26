// 网盘番号封面刮削预览截图：只做测试内截图，不改业务代码。
// 假数据说明：列表条目按用户截图形状合成；封面是测试替身纯色
// 图，绝非真实封面（图上标签栏已注明）；图标在测试环境渲染为
// 方块。一测一张：调过 toImage 的测试在收尾时会挂起（旧预览
// 测试同样如此，PNG 已落地），跑单测、超时杀掉只取 PNG。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/multimedia_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir = '/home/hatch/workspace/moyi_pan_scrape_20261126/preview';

const _standInColors = <Color>[
  Color(0xFF7C4DFF),
  Color(0xFF00BFA5),
  Color(0xFFFF6E40),
  Color(0xFF2979FF),
  Color(0xFFFF4081),
  Color(0xFF76FF03),
];

/// 生成替身封面 PNG 文件，返回 {封面地址: 本地路径}。
/// 纯 Dart 编码实色 PNG（不用 dart:ui 的 toImage 播种）。
Map<String, String> _makeStandInCovers(List<String> urls) {
  final dir = Directory('${Directory.systemTemp.path}/pan_scrape_preview');
  dir.createSync(recursive: true);
  final map = <String, String>{};
  for (var i = 0; i < urls.length; i++) {
    final path = '${dir.path}/cover_$i.png';
    File(
      path,
    ).writeAsBytesSync(_solidPng(_standInColors[i % _standInColors.length]));
    map[urls[i]] = path;
  }
  return map;
}

Uint8List _solidPng(Color color, {int width = 300, int height = 450}) {
  final r = (color.r * 255).round();
  final g = (color.g * 255).round();
  final b = (color.b * 255).round();
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0);
    for (var x = 0; x < width; x++) {
      raw.add([r, g, b]);
    }
  }
  final compressed = ZLibEncoder().convert(raw.toBytes());
  final out = BytesBuilder();
  out.add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final typeBytes = type.codeUnits;
    final length = ByteData(4)..setUint32(0, data.length);
    out.add(length.buffer.asUint8List());
    out.add(typeBytes);
    out.add(data);
    final crc = _crc32([...typeBytes, ...data]);
    final crcBytes = ByteData(4)..setUint32(0, crc);
    out.add(crcBytes.buffer.asUint8List());
  }

  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 2)
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  chunk('IHDR', ihdr.buffer.asUint8List());
  chunk('IDAT', compressed);
  chunk('IEND', const []);
  return out.toBytes();
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}

const _pan115 = SourceSite('cloud:pan115', '115网盘', '');

Drama _video(String id, String title) =>
    Drama(id: id, source: 'cloud:pan115', title: title, kind: 'video');

Drama _folder(String id, String title, String folderId) => Drama(
  id: id,
  source: 'cloud:pan115',
  title: title,
  kind: 'folder',
  folderId: folderId,
);

/// 预览仓库：目录页按用户截图形状合成；封面走替身 PNG 本地路径。
class _PreviewRepository extends FixtureRepository {
  Map<String, String> coverByUrl = {};

  @override
  Future<String> cover(Drama drama, {bool force = false}) async =>
      coverByUrl[drama.cover] ?? '';

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    if (query.isNotEmpty) return CatalogPage([]);
    return CatalogPage([
      _folder('pan115:fd1', 'HRSM-032', 'fd1'),
      _folder('pan115:fd2', 'HODV-21775', 'fd2'),
      _video('pan115:v1', 'DV-390(53dv390).mp4'),
      _video('pan115:v2', 'DV-405(53dv405).mkv'),
      _video('pan115:v3', 'HJMO-652.mkv'),
      _video('pan115:v4', '普通电影.mp4'),
    ]);
  }
}

ThemeData _previewTheme() {
  final base = ThemeData.dark();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
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

Future<void> _capture(
  WidgetTester tester, {
  required String name,
  required String label,
  required PanCoverFetcher coverFetcher,
  required Map<String, String> coverByUrl,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  final repository = _PreviewRepository()..coverByUrl = coverByUrl;
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
                  child: MultimediaScreen(
                    repository: repository,
                    store: store,
                    driveSites: const [_pan115],
                    onOpenDrama: (_) {},
                    metadataFetcher:
                        ({
                          required String title,
                          String? year,
                          String? typeHint,
                        }) async => null,
                    coverFetcher: coverFetcher,
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
  // 本地替身图的读取+解码是真异步 I/O，假时钟 pump 等不到：
  // 放进 runAsync 给真实时间落地，再 pump 让解码完的图上屏。
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 800)),
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
  File('$_previewDir/$name.png').writeAsBytesSync(bytes);
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
    } catch (_) {}
  });

  testWidgets('preview pan list before scrape', (tester) async {
    await _capture(
      tester,
      name: 'pan_scrape_before',
      label: '渲染预览 · 假数据 · 网盘列表刮削前：番号文件/文件夹全是占位图',
      coverFetcher: (_) async => '',
      coverByUrl: const {},
    );
  });

  testWidgets('preview pan list after scrape', (tester) async {
    const codes = ['HRSM-032', 'HODV-21775', 'DV-390', 'DV-405', 'HJMO-652'];
    final urls = [for (final code in codes) 'https://img/$code.jpg'];
    await _capture(
      tester,
      name: 'pan_scrape_after',
      label:
          '渲染预览 · 假数据 · 网盘列表刮削后：带番号的已在数据层补上封面地址（挂件测试逐条断言）；本机测试环境解不出本地图文件（与女优库预览同限制），此处仍显示占位框，真机出真图',
      coverFetcher: (code) async =>
          codes.contains(code) ? 'https://img/$code.jpg' : '',
      coverByUrl: _makeStandInCovers(urls),
    );
  });
}
