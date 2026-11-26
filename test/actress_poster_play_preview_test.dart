// 女优库海报透明播放键预览截图（2026-11-25）：只做测试内截图，不改业务代码。
// 假数据说明：人物、作品均为测试内合成；卡片图是测试替身纯色图，
// 绝非真实封面（图上标签栏已注明）；图标在测试环境渲染为方块。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把两张放进同一个测试体。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_av_style.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_detail_page.dart';
import 'package:moyi/actress/actress_film_library.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_neon.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir =
    '/home/hatch/workspace/moyi_actress_diag_20261125/preview';

/// 替身封面色板：每张卡一个纯色，与真实封面无关。
const _standInColors = <Color>[
  Color(0xFF7C4DFF),
  Color(0xFF00BFA5),
  Color(0xFFFF6E40),
  Color(0xFF2979FF),
  Color(0xFFFF4081),
  Color(0xFF76FF03),
];

/// 生成替身封面 PNG 文件，返回 {封面地址: 本地路径}。
/// 纯 Dart 编码实色 PNG（不用 dart:ui 的 toImage：播种在挂件前跑，
/// 那时还没有帧推进，toImage 永远等不到光栅器、会挂死）。
Future<Map<String, String>> _makeStandInCovers(List<String> urls) async {
  final dir = Directory('${Directory.systemTemp.path}/actress_poster_preview');
  // 同步建目录：widget 测试里异步文件 I/O 要等 runAsync/pump 才会
  // 完成，await 会直接挂死（见 AGENTS.md 的 FakeAsync 教训）。
  dir.createSync(recursive: true);
  final map = <String, String>{};
  for (var i = 0; i < urls.length; i++) {
    final path = '${dir.path}/cover_$i.png';
    File(path).writeAsBytesSync(
      _solidPng(_standInColors[i % _standInColors.length]),
    );
    map[urls[i]] = path;
  }
  return map;
}

/// 实色 PNG 编码（IHDR + IDAT + IEND，zlib 压缩、CRC32 校验）：
/// 测试替身图专用，与真实封面无关。
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

/// 预览仓库：封面走替身 PNG 本地路径，搜索返回空。
class _PosterPreviewRepository extends FixtureRepository {
  Map<String, String> coverByUrl = {};

  @override
  Future<String> cover(Drama drama, {bool force = false}) async =>
      coverByUrl[drama.cover] ?? '';

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
      CatalogPage([]);
}

/// 预览主题：全文统一用测试 CJK 字体（只在 MaterialApp 内层才生效，
/// 外层 DefaultTextStyle 会被主题的默认文本样式盖掉）。
ThemeData _previewTheme() {
  final base = ThemeData.dark();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
    ),
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
  required Size size,
  required Widget Function() buildPage,
  Future<void> Function(_PosterPreviewRepository repository)? prewarm,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final repository = _PosterPreviewRepository();
  if (prewarm != null) await prewarm(repository);
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
                Expanded(child: buildPage()),
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

  testWidgets('preview film detail poster play key', (tester) async {
    // 影视库详情页大海报：封面为空走占位底，中央应有 72 透明播放键；
    // 下面“播放线路 / 正片”行照常在。不点播，只截图。
    final db = MemoryActressDatabase();
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final repository = _PosterPreviewRepository();
    final service = FilmLibraryService(database: db);
    const entry = FilmLibraryEntry(
      vodId: 'SSIS-001',
      title: '测试作品标题',
      coverUrl: '',
      playUrl: 'https://example.com/video.m3u8',
      actress: '测试女优',
      code: 'SSIS-001',
      category: '日本AV',
      site: 'whos',
      date: '2024-01-01',
      remarks: '高清',
      content: '简介测试文本。',
    );
    await _capture(
      tester,
      name: 'film_detail_poster_play',
      label: '预览 · 假数据 · 影视库详情页大海报 + 中央透明播放键（封面为空=占位底）',
      size: const Size(390, 1250),
      buildPage: () => FilmDetailPage(
        entry: entry,
        database: db,
        repository: repository,
        store: store,
        service: service,
      ),
    );
    // 海报上有且仅有一个居中透明播放键。
    expect(find.byType(ActressPosterPlayKey), findsOneWidget);
  });

  testWidgets('preview actress detail works grid play keys', (tester) async {
    // 女优详情页作品卡片墙：6 张替身封面卡，每张海报中央应有
    // 48 透明播放键。只截图，不点播。
    var personId = 0;
    final db = MemoryActressDatabase();
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final repository = _PosterPreviewRepository();
    final urls = [for (var i = 1; i <= 6; i++) 'https://cover/work$i.jpg'];
    repository.coverByUrl = await _makeStandInCovers(urls);
    final person = (await db.upsertRosterPerson(
      const RosterPerson(
        source: ActressRosterSourceId.missav,
        sourceId: '/dm16/cn/actresses/x',
        name: '测试女优',
        sex: 'female',
      ),
    ))!;
    personId = person.localId;
    await db.upsertWorks(person.localId, [
      for (var i = 1; i <= 6; i++)
        RosterFilm(
          code: 'SSIS-00${100 + i}',
          coverUrl: urls[i - 1],
          detailUrl: '/dm16/cn/work$i',
        ),
    ], coverSource: 'jar:missav30:ZakaMissav');
    await _capture(
      tester,
      name: 'actress_detail_works_play_keys',
      label: '预览 · 假数据 · 女优详情作品卡片墙 · 2026-11-26 照 AvPlay 截图换 AvWorkCard（无中央播放键） · 测试替身封面，非真实封面',
      size: const Size(390, 1250),
      buildPage: () => ActressDetailPage(
        localId: personId,
        repository: repository,
        store: store,
        database: db,
      ),
      prewarm: (_) async {
        // 预热替身封面进图片缓存：widget 测试的 FakeAsync 区里文件
        // 读取完成不了（要等 runAsync），先在真异步区里把图解出来
        // 放进缓存，卡片挂载时 Image.file 直接命中缓存出图。
        await tester.runAsync(() async {
          for (final path in repository.coverByUrl.values.toSet()) {
            final provider = ResizeImage.resizeIfNeeded(
              440,
              null,
              FileImage(File(path)),
            );
            final stream = provider.resolve(ImageConfiguration.empty);
            final done = Completer<void>();
            late final ImageStreamListener listener;
            listener = ImageStreamListener(
              (image, synchronousCall) {
                stream.removeListener(listener);
                if (!done.isCompleted) done.complete();
              },
              onError: (error, stackTrace) {
                stream.removeListener(listener);
                if (!done.isCompleted) done.completeError(error, stackTrace);
              },
            );
            stream.addListener(listener);
            await done.future;
          }
        });
      },
    );
    // 2026-11-26 改版式：作品墙是 AvWorkCard、照截图无播放键。
    expect(find.byType(AvWorkCard), findsNWidgets(6));
    expect(find.byType(ActressPosterPlayKey), findsNothing);
  });
}
