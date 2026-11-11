import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'haikuo_codec.dart';
import 'haikuo_program.dart';
import 'haikuo_runtime_html.dart';

/// 海阔小程序运行页。
///
/// 脚本放在本地 HTTP 服务里跑（和内置小程序容器同一套思路）：
/// 页面同源，脚本里的同步 `fetch()` 才能打到 `/__fetch` 由 Dart 侧代理，
/// 绕开 WebView 的跨域限制；点条目时用通道回到原生，媒体地址直接进播放器。
class HaikuoRunnerPage extends StatefulWidget {
  const HaikuoRunnerPage({super.key, required this.program});

  final HaikuoProgram program;

  @override
  State<HaikuoRunnerPage> createState() => _HaikuoRunnerPageState();
}

class _HaikuoRunnerPageState extends State<HaikuoRunnerPage> {
  HttpServer? _server;
  WebViewController? _controller;
  String? _error;
  bool _loading = true;
  // 规则去广告后存下的本地 m3u8（saveFile 发来的内容），由 /__files/<名> 提供给播放器。
  final Map<String, String> _savedFiles = {};

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    final server = _server;
    _server = null;
    unawaited(server?.close(force: true));
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      server.listen(_handleRequest);
      if (!mounted) return;
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFF120B20))
        ..addJavaScriptChannel(
          'HaikuoNative',
          onMessageReceived: _onNativeMessage,
        )
        ..loadRequest(Uri.parse('http://127.0.0.1:${server.port}/'));
      setState(() {
        _controller = controller;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  void _onNativeMessage(JavaScriptMessage message) {
    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map) return;
      payload = {
        for (final entry in decoded.entries) '${entry.key}': entry.value,
      };
    } catch (_) {
      return;
    }
    switch ('${payload['type']}') {
      case 'toast':
        _snack('${payload['text'] ?? ''}');
      case 'saveFile':
        final name = '${payload['name'] ?? ''}';
        if (name.isNotEmpty) {
          _savedFiles[name] = '${payload['content'] ?? ''}';
        }
      case 'play':
        final url = '${payload['url'] ?? ''}';
        if (url.isEmpty) return;
        _openPlayer(url, '${payload['title'] ?? widget.program.name}');
      case 'open':
        final url = '${payload['url'] ?? ''}';
        if (url.isEmpty) return;
        _openLink(url, '${payload['title'] ?? ''}');
    }
  }

  void _snack(String text) {
    if (!mounted || text.isEmpty) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _openPlayer(String url, String title) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => HaikuoPlayPage(url: url, title: title),
      ),
    );
  }

  Future<void> _openLink(String url, String title) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _HaikuoWebPage(url: url, title: title),
      ),
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.uri.path == '/') {
        final payload = _programPayload();
        final encoded = base64Encode(utf8.encode(jsonEncode(payload)));
        final html = haikuoRuntimeHtml
            .replaceAll('__PROGRAM_B64__', encoded)
            .replaceAll(
              '__TITLE__',
              const HtmlEscape().convert(widget.program.name),
            );
        request.response.headers.contentType = ContentType.html;
        request.response.write(html);
        await request.response.close();
        return;
      }
      if (request.uri.path == '/__fetch') {
        await _proxy(request);
        return;
      }
      if (request.uri.path.startsWith('/__files/')) {
        final name = Uri.decodeComponent(
          request.uri.path.substring('/__files/'.length),
        );
        final content = _savedFiles[name];
        if (content == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
            charset: 'utf-8',
          );
          request.response.write(content);
        }
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {
        // 连接已经断了，忽略
      }
    }
  }

  Map<String, dynamic> _programPayload() {
    final program = widget.program;
    Map<String, dynamic> rule = const {};
    if (program.rawJson.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(program.rawJson);
        if (decoded is Map) {
          rule = {
            for (final entry in decoded.entries) '${entry.key}': entry.value,
          };
        }
      } catch (_) {
        rule = const {};
      }
    }
    return {
      'name': program.name,
      'script': program.script,
      'url': program.url,
      'kind': program.kind.name,
      'rule': rule,
    };
  }

  Future<void> _proxy(HttpRequest request) async {
    final params = request.uri.queryParameters;
    final target = params['u'] ?? '';
    final method = (params['m'] ?? 'GET').toUpperCase();
    final body = params['b'] ?? '';
    Map<String, String> headers = const {};
    final rawHeaders = params['h'];
    if (rawHeaders != null && rawHeaders.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawHeaders);
        if (decoded is Map) {
          headers = {
            for (final entry in decoded.entries)
              '${entry.key}': '${entry.value}',
          };
        }
      } catch (_) {
        headers = const {};
      }
    }
    final response = request.response;
    response.headers.contentType = ContentType.json;
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      response.write(jsonEncode({'code': 0, 'body': ''}));
      await response.close();
      return;
    }
    final merged = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
      ...headers,
    };
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20)
        ..idleTimeout = const Duration(seconds: 5)
        ..userAgent = merged['User-Agent'];
      final uri = Uri.parse(target);
      final req = await client.openUrl(method, uri).timeout(
        const Duration(seconds: 25),
      );
      merged.forEach((key, value) {
        if (value.isEmpty) return;
        if (key.toLowerCase() == 'content-length') return;
        try {
          req.headers.set(key, value);
        } catch (_) {
          // 个别头 WebView 设置不进去，跳过
        }
      });
      if (method != 'GET' && method != 'HEAD' && body.isNotEmpty) {
        req.add(utf8.encode(body));
      }
      final resp = await req.close().timeout(const Duration(seconds: 30));
      final bytes = await resp.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
      client.close(force: true);
      response.write(
        jsonEncode({
          'code': resp.statusCode,
          'body': HaikuoCodec.decodeText(bytes.takeBytes()),
        }),
      );
      await response.close();
    } catch (error) {
      response.write(jsonEncode({'code': 0, 'body': '', 'error': '$error'}));
      await response.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF120B20),
      appBar: AppBar(
        title: Text(widget.program.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _controller?.reload(),
          ),
        ],
      ),
      body: _error != null
          ? _RunnerError(message: _error!)
          : _loading || _controller == null
          ? const Center(child: CircularProgressIndicator())
          : WebViewWidget(controller: _controller!),
    );
  }
}

class _RunnerError extends StatelessWidget {
  const _RunnerError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 42),
            const SizedBox(height: 12),
            Text('小程序没能启动：$message', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// 外部链接页：脚本里 `open(url)` 打开普通网页时用。
class _HaikuoWebPage extends StatefulWidget {
  const _HaikuoWebPage({required this.url, required this.title});

  final String url;
  final String title;

  @override
  State<_HaikuoWebPage> createState() => _HaikuoWebPageState();
}

class _HaikuoWebPageState extends State<_HaikuoWebPage> {
  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..loadRequest(Uri.parse(widget.url));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.title.isEmpty ? widget.url : widget.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    body: WebViewWidget(controller: _controller),
  );
}

/// 媒体播放页：海阔小程序返回直链（m3u8 / mp4）时用它播。
class HaikuoPlayPage extends StatefulWidget {
  const HaikuoPlayPage({super.key, required this.url, required this.title});

  final String url;
  final String title;

  @override
  State<HaikuoPlayPage> createState() => _HaikuoPlayPageState();
}

class _HaikuoPlayPageState extends State<HaikuoPlayPage> {
  late final Player _player = Player();
  late final VideoController _video = VideoController(_player);
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      await _player.open(Media(widget.url));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  @override
  void dispose() {
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          widget.title.isEmpty ? '播放' : widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Center(
        child: _error == null
            ? AspectRatio(
                aspectRatio: 16 / 9,
                child: Video(controller: _video),
              )
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '播放失败：$_error\n\n地址：${widget.url}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
      ),
    );
  }
}
