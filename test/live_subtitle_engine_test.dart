import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/live_subtitle_engine.dart';
import 'package:whisper_cpp_flutter_plus/whisper_cpp_flutter_plus.dart';

void main() {
  test('Linux 上平台守卫：modelState 报 unknown，loadModel 抛错', () async {
    final engine = PluginLiveSubtitleEngine();
    expect(await engine.modelState('tiny'), LiveSubtitleModelState.unknown);
    await expectLater(
      engine.loadModel('tiny'),
      throwsA(isA<LiveSubtitleEngineException>()),
    );
    await engine.dispose();
  });

  test('插件模型管理器：校验码不对的缓存文件抛 FormatException', () async {
    final dir = await Directory.systemTemp.createTemp('whisper_mgr_bad_');
    try {
      final file = File('${dir.path}/ggml-tiny.bin');
      await file.writeAsBytes([1, 2, 3, 4]);
      final manager = WhisperModelManager(storageDirectory: dir);
      await expectLater(
        manager.findCatalogModel(WhisperModelCatalog.tiny),
        throwsA(isA<FormatException>()),
      );
      manager.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('插件模型管理器：校验码对上的文件能被找到', () async {
    final probe = File(
      '${Platform.environment['HOME']}/workspace/.subtitle_probe/ggml-tiny.bin',
    );
    if (!await probe.exists()) {
      markTestSkipped('探针模型文件不在，跳过（需先跑过模型下载）');
      return;
    }
    final dir = await Directory.systemTemp.createTemp('whisper_mgr_ok_');
    try {
      await probe.copy('${dir.path}/ggml-tiny.bin');
      final manager = WhisperModelManager(storageDirectory: dir);
      final found = await manager.findCatalogModel(WhisperModelCatalog.tiny);
      expect(found, isNotNull);
      expect(await found!.length(), 77691713);
      manager.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test(
    '插件真下载 tiny 模型：走 downloadCatalogModel，落盘后校验码对得上',
    () async {
      final dir = await Directory.systemTemp.createTemp('whisper_mgr_dl_');
      try {
        final manager = WhisperModelManager(storageDirectory: dir);
        var sawProgress = false;
        await for (final _ in manager.downloadCatalogModel(
          WhisperModelCatalog.tiny,
        )) {
          sawProgress = true;
        }
        manager.close();
        final file = File('${dir.path}/ggml-tiny.bin');
        expect(await file.exists(), isTrue);
        expect(await file.length(), 77691713);
        // 再走一遍发现路径：校验码对上才算下载成功。
        final manager2 = WhisperModelManager(storageDirectory: dir);
        expect(
          await manager2.findCatalogModel(WhisperModelCatalog.tiny),
          isNotNull,
        );
        manager2.close();
        expect(sawProgress, isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    '镜像下载：本地 HTTP 服务当镜像，落盘后校验码对得上',
    () async {
      final probe = File(
        '${Platform.environment['HOME']}/workspace/.subtitle_probe/ggml-tiny.bin',
      );
      if (!await probe.exists()) {
        markTestSkipped('探针模型文件不在，跳过（需先跑过模型下载）');
        return;
      }
      final bytes = await probe.readAsBytes();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.uri.path == '/ggml-tiny.bin') {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.binary
            ..headers.contentLength = bytes.length
            ..add(bytes);
          await request.response.close();
        } else {
          request.response.statusCode = 404;
          await request.response.close();
        }
      });
      final dir = await Directory.systemTemp.createTemp('whisper_mirror_');
      try {
        // 引擎层在 Linux 上拒跑（平台守卫），这里直接测插件的
        // manager.download 镜像分支：服务层只负责把地址传进来。
        final manager = WhisperModelManager(storageDirectory: dir);
        var sawProgress = false;
        await for (final _ in manager.download(
          Uri.parse('http://127.0.0.1:${server.port}/ggml-tiny.bin'),
          'ggml-tiny.bin',
          sha256Hex: WhisperModelCatalog.tiny.sha256,
          allowInsecureHttp: true,
        )) {
          sawProgress = true;
        }
        manager.close();
        final file = File('${dir.path}/ggml-tiny.bin');
        expect(await file.exists(), isTrue);
        expect(await file.length(), 77691713);
        final manager2 = WhisperModelManager(storageDirectory: dir);
        expect(
          await manager2.findCatalogModel(WhisperModelCatalog.tiny),
          isNotNull,
        );
        manager2.close();
        expect(sawProgress, isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
