import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class MediaSniffer {
  static final RegExp mediaUrlPattern = RegExp(
    r'''https?://[^\s"'<>\\]+?\.(?:m3u8|mpd|mp4|m4v|mov|flv|m4s|webm|m4a|aac|mp3|wav|ogg)(?:\?[^\s"'<>\\]*)?''',
    caseSensitive: false,
  );

  static final RegExp _hlsAssignmentPattern = RegExp(
    r'''(?:hlsUrl|source|videoUrl|playUrl|url)\s*[:=]\s*["'](https?://[^"']+)["']''',
    caseSensitive: false,
  );

  static final RegExp auxUrlPattern = RegExp(
    r'''https?://[^\s"'<>\\]+?\.(?:vtt|ass|srt)(?:\?[^\s"'<>\\]*)?''',
    caseSensitive: false,
  );

  static bool isMediaUrl(String url) => mediaUrlPattern.hasMatch(url);

  static bool isAuxUrl(String url) => auxUrlPattern.hasMatch(url);

  static List<String> extractAuxFromText(String text) {
    final found = <String>{};
    for (final match in auxUrlPattern.allMatches(text)) {
      found.add(match.group(0)!);
    }
    return found.toList();
  }

  static List<String> extractFromText(String text) {
    final found = <String>{};
    for (final match in mediaUrlPattern.allMatches(text)) {
      found.add(match.group(0)!);
    }
    for (final match in _hlsAssignmentPattern.allMatches(text)) {
      final candidate = match.group(1);
      if (candidate != null && isMediaUrl(candidate)) found.add(candidate);
    }
    return found.toList();
  }

  static const String probeScript = r'''
(function () {
  if (window.__snifferInstalled) return;
  window.__snifferInstalled = true;
  window.__sniffedMedia = [];
  window.__sniffedAux = [];
  var pattern = /\.(m3u8|mpd|mp4|m4v|mov|flv|m4s|webm|m4a|aac|mp3|wav|ogg)(\?|#|$)/i;
  var auxPattern = /\.(vtt|ass|srt)(\?|#|$)/i;
  var textPattern = /https?:\/\/[^\s"'<>\\]+?\.(?:m3u8|mpd|mp4|m4v|mov|flv|m4s|webm|m4a|aac|mp3|wav|ogg)(?:\?[^\s"'<>\\]*)?/gi;
  var auxTextPattern = /https?:\/\/[^\s"'<>\\]+?\.(?:vtt|ass|srt)(?:\?[^\s"'<>\\]*)?/gi;
  function report(url) {
    if (typeof url !== 'string' || !pattern.test(url)) return;
    if (window.__sniffedMedia.indexOf(url) < 0) window.__sniffedMedia.push(url);
  }
  function reportAux(url) {
    if (typeof url !== 'string' || !auxPattern.test(url)) return;
    if (window.__sniffedAux.indexOf(url) < 0) window.__sniffedAux.push(url);
  }
  function reportText(text) {
    if (typeof text !== 'string') return;
    var found = text.match(textPattern);
    if (found) found.forEach(report);
    var auxFound = text.match(auxTextPattern);
    if (auxFound) auxFound.forEach(reportAux);
  }
  var open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    report(url);
    reportAux(url);
    return open.apply(this, arguments);
  };
  var xhrSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function () {
    var xhr = this;
    try {
      xhr.addEventListener('load', function () {
        try { reportText(xhr.responseText); } catch (e) {}
      });
    } catch (e) {}
    return xhrSend.apply(this, arguments);
  };
  var fetchOriginal = window.fetch;
  if (fetchOriginal) {
    window.fetch = function (input) {
      report(typeof input === 'string' ? input : input && input.url);
      reportAux(typeof input === 'string' ? input : input && input.url);
      var result = fetchOriginal.apply(this, arguments);
      try {
        result.then(function (response) {
          try {
            response.clone().text().then(reportText).catch(function () {});
          } catch (e) {}
          return response;
        });
      } catch (e) {}
      return result;
    };
  }
  var wsOriginal = window.WebSocket;
  if (wsOriginal) {
    window.WebSocket = function (url, protocols) {
      var ws = protocols ? new wsOriginal(url, protocols) : new wsOriginal(url);
      try {
        ws.addEventListener('message', function (event) {
          try { reportText(typeof event.data === 'string' ? event.data : ''); } catch (e) {}
        });
      } catch (e) {}
      return ws;
    };
    window.WebSocket.prototype = wsOriginal.prototype;
  }
  function scanDom() {
    document.querySelectorAll('video, audio, source, embed, object').forEach(function (node) {
      report(node.currentSrc || node.src || node.data);
    });
    document.querySelectorAll('track, link[rel="stylesheet"]').forEach(function (node) {
      reportAux(node.src || node.href);
    });
    document.querySelectorAll('iframe').forEach(function (node) {
      report(node.src);
      try {
        var inner = node.contentDocument;
        if (inner) {
          inner.querySelectorAll('video, audio, source').forEach(function (n) {
            report(n.currentSrc || n.src);
          });
          reportText(inner.documentElement ? inner.documentElement.innerHTML : '');
        }
      } catch (e) {}
    });
    document.querySelectorAll('script').forEach(function (node) {
      reportText(node.textContent);
    });
    reportText(document.documentElement ? document.documentElement.innerHTML : '');
    if (window.performance && performance.getEntriesByType) {
      performance.getEntriesByType('resource').forEach(function (entry) {
        report(entry.name);
      });
    }
  }
  new MutationObserver(scanDom).observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['src'],
  });
  scanDom();
})();
''';
}

class SnifferService {
  SnifferService({List<String> initialCandidates = const []}) {
    addAll(initialCandidates);
  }

  final _candidates = <String>[];
  final _auxiliary = <String>[];

  List<String> get candidates => List.unmodifiable(_candidates);

  List<String> get auxiliary => List.unmodifiable(_auxiliary);

  bool add(String url) {
    final trimmed = url.trim();
    if (!MediaSniffer.isMediaUrl(trimmed) || _candidates.contains(trimmed)) {
      return false;
    }
    _candidates.add(trimmed);
    return true;
  }

  bool addAux(String url) {
    final trimmed = url.trim();
    if (!MediaSniffer.isAuxUrl(trimmed) || _auxiliary.contains(trimmed)) {
      return false;
    }
    _auxiliary.add(trimmed);
    return true;
  }

  void addAll(Iterable<String> urls) {
    for (final url in urls) {
      add(url);
    }
  }

  static int _score(String url) {
    final path = url.toLowerCase().split('?').first.split('#').first;
    if (path.endsWith('.m3u8')) return 0;
    if (path.endsWith('.mpd')) return 1;
    if (path.endsWith('.mp4')) return 2;
    if (path.endsWith('.m4v') ||
        path.endsWith('.mov') ||
        path.endsWith('.webm')) {
      return 3;
    }
    if (path.endsWith('.m4a') ||
        path.endsWith('.aac') ||
        path.endsWith('.mp3') ||
        path.endsWith('.wav') ||
        path.endsWith('.ogg')) {
      return 4;
    }
    return 5;
  }

  String? get preferred {
    if (_candidates.isEmpty) return null;
    final ordered = [..._candidates]
      ..sort((a, b) => _score(a).compareTo(_score(b)));
    return ordered.first;
  }

  static List<String> parseSniffedResult(Object? result) {
    if (result is List) return result.whereType<String>().toList();
    if (result is String) {
      try {
        final decoded = jsonDecode(result);
        if (decoded is List) return decoded.whereType<String>().toList();
      } catch (_) {}
    }
    return const [];
  }
}

class SniffWebViewPage extends StatefulWidget {
  const SniffWebViewPage({
    super.key,
    required this.pageUrl,
    required this.onMediaFound,
    this.headers = const {},
    this.initialCandidates = const [],
    this.autoPlay = false,
    this.embedded = false,
  });

  final String pageUrl;
  final Map<String, String> headers;
  final List<String> initialCandidates;
  final ValueChanged<String> onMediaFound;
  final bool autoPlay;
  final bool embedded;

  @override
  State<SniffWebViewPage> createState() => _SniffWebViewPageState();
}

class _SniffWebViewPageState extends State<SniffWebViewPage> {
  late final SnifferService _service;
  WebViewController? _controller;
  Timer? _timer;
  bool _polling = false;
  bool _autoPlayed = false;

  bool get _supported => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _service = SnifferService(initialCandidates: widget.initialCandidates);
    if (!_supported) return;
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => unawaited(_injectAndPoll()),
          onNavigationRequest: (request) {
            if (MediaSniffer.isMediaUrl(request.url)) {
              final added = _service.add(request.url);
              if (added && mounted) setState(() {});
              _maybeAutoPlay();
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );
    _controller = controller;
    unawaited(
      controller.loadRequest(
        Uri.parse(widget.pageUrl),
        headers: widget.headers,
      ),
    );
    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_poll()),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _injectAndPoll() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.runJavaScript(MediaSniffer.probeScript);
    } catch (_) {}
    await _poll();
  }

  Future<void> _poll() async {
    final controller = _controller;
    if (controller == null || _polling) return;
    _polling = true;
    try {
      final result = await controller.runJavaScriptReturningResult(
        'JSON.stringify(window.__sniffedMedia || [])',
      );
      final found = SnifferService.parseSniffedResult(result);
      var changed = false;
      for (final url in found) {
        if (_service.add(url)) changed = true;
      }
      try {
        final auxResult = await controller.runJavaScriptReturningResult(
          'JSON.stringify(window.__sniffedAux || [])',
        );
        for (final url in SnifferService.parseSniffedResult(auxResult)) {
          if (_service.addAux(url)) changed = true;
        }
      } catch (_) {}
      if (changed && mounted) setState(() {});
      _maybeAutoPlay();
    } catch (_) {
    } finally {
      _polling = false;
    }
  }

  void _maybeAutoPlay() {
    if ((!widget.autoPlay && !widget.embedded) || _autoPlayed) return;
    final preferred = _service.preferred;
    if (preferred == null) return;
    _autoPlayed = true;
    widget.onMediaFound(preferred);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final candidates = _service.candidates;
    final preferred = _service.preferred;
    if (widget.embedded) {
      if (_controller == null) {
        return Center(
          child: Text(
            '当前平台不支持网页内嵌播放',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        );
      }
      return WebViewWidget(controller: _controller!);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('网页嗅探')),
      body: Column(
        children: [
          if (_controller != null)
            Expanded(child: WebViewWidget(controller: _controller!))
          else
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Icon(Icons.radar_rounded, size: 40, color: colors.primary),
                  const SizedBox(height: 12),
                  Text(
                    '当前平台不支持 WebView 嗅探',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '目标播放页：\n${widget.pageUrl}',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          if (preferred != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: FilledButton.icon(
                onPressed: () => widget.onMediaFound(preferred),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('播放推荐地址'),
              ),
            ),
          if (candidates.isNotEmpty)
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    '已提取的候选媒体地址',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  for (final candidate in candidates)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.play_circle_outline_rounded),
                      title: Text(
                        candidate,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => widget.onMediaFound(candidate),
                    ),
                  if (_service.auxiliary.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      '字幕及其他捕获（点一下复制地址）',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    for (final aux in _service.auxiliary)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.subtitles_outlined),
                        title: Text(
                          aux,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () async {
                          await Clipboard.setData(ClipboardData(text: aux));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已复制字幕地址')),
                            );
                          }
                        },
                      ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
