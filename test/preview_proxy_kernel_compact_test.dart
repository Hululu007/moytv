// 代理内核页紧凑版预览截图：只做测试内截图，不改业务代码。
// 假数据说明：内核停机状态、代理条目均为测试内合成。一测一张：
// 调过 toImage 的测试在收尾时可能挂起（旧现象，PNG 已落地），
// 跑单测、超时杀掉只取 PNG。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/proxy_kernel.dart';
import 'package:moyi/proxy_kernel_screen.dart';
import 'package:moyi/proxy_kernel_service.dart';
import 'package:moyi/socks5_proxy.dart';

class _PreviewKernelController implements ProxyKernelController {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (method == 'status') {
      return {
        'supported': true,
        'installed': true,
        'builtinAvailable': true,
        'hasExternal': false,
        'builtinVersion': proxyKernelBuiltinVersion,
        'externalVersion': '',
        'activeBinary': '',
        'running': false,
        'mixedPort': 0,
        'controllerPort': 0,
        'selectedNode': '',
        'logTail': 'time="2026-11-15" level=info msg="假日志行"',
      };
    }
    throw ProxyKernelFailure('unexpected method $method');
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
    } catch (_) {}
  });

  testWidgets('预览 代理内核页紧凑版', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final socks5 = Socks5ProxyService(
      store: MemorySocks5ProxyStore(),
      router: Socks5ProxyRouter(),
    );
    final fast = await socks5.addProxy(
      name: '示例代理·快',
      host: '10.0.0.1',
      port: 1080,
    );
    await socks5.updateProxy(
      fast.copyWith(lastAvailable: true, lastLatencyMs: 86),
    );
    final kernel = ProxyKernelService(
      controller: _PreviewKernelController(),
      store: MemoryProxyKernelStore(),
    );
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: 'PreviewCJK'),
          home: Scaffold(
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
                    '预览 · 假数据 · 代理内核页紧凑版：按钮/间距缩小一档',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontFamily: 'PreviewCJK',
                    ),
                  ),
                ),
                Expanded(
                  child: ProxyKernelScreen(
                    service: kernel,
                    socks5Service: socks5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    const dir = '/home/hatch/workspace/moyi_previews';
    Directory(dir).createSync(recursive: true);
    File('$dir/proxy_kernel_compact.png').writeAsBytesSync(bytes);
  });
}
