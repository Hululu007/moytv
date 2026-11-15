// SOCKS5 代理管理页预览截图：只做测试内截图，不改业务代码。
// 假数据说明：代理条目（名称、地址、延迟、可用状态）均为测试内合成；
// 内核区为停机假状态。一测一张：调过 toImage 的测试在收尾时会挂起
// （旧预览测试同样如此，PNG 已落地），跑单测、超时杀掉只取 PNG。
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

const _previewDir = '/home/hatch/workspace/moyi_previews';

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
        'logTail': '',
      };
    }
    throw ProxyKernelFailure('unexpected method $method');
  }
}

Future<Socks5ProxyService> _previewSocks5Service() async {
  final service = Socks5ProxyService(
    store: MemorySocks5ProxyStore(),
    router: Socks5ProxyRouter(),
  );
  final fast = await service.addProxy(
    name: '示例代理·快',
    host: '10.0.0.1',
    port: 1080,
  );
  await service.updateProxy(
    fast.copyWith(lastAvailable: true, lastLatencyMs: 86),
  );
  final down = await service.addProxy(
    name: '示例代理·不通',
    host: '10.0.0.2',
    port: 1080,
  );
  await service.updateProxy(down.copyWith(lastAvailable: false));
  await service.addProxy(name: '示例代理·未测', host: '10.0.0.3', port: 1080);
  return service;
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

  testWidgets('预览 SOCKS5 代理管理页', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final socks5 = await _previewSocks5Service();
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
                    '预览·假数据：SOCKS5 代理管理页，延迟与状态均为假数据',
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
    // 把 SOCKS5 区拖到视野内：一键识别按钮可见即可截图。
    final target = find.text('一键识别');
    for (var i = 0; i < 12 && target.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    Directory(_previewDir).createSync(recursive: true);
    File('$_previewDir/socks5_proxy.png').writeAsBytesSync(bytes);
    // ignore: avoid_print
    print('preview landed: socks5_proxy');
  });
}
