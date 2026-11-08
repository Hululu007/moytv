import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';

enum NonVideoKind { novel, pics }

class NonVideoContent {
  const NonVideoContent.novel({required this.title, required this.text})
    : kind = NonVideoKind.novel,
      urls = const [],
      headers = const {};
  const NonVideoContent.pics({
    required this.title,
    required this.urls,
    this.headers = const {},
  }) : kind = NonVideoKind.pics,
       text = '';
  final NonVideoKind kind;
  final String title;
  final String text;
  final List<String> urls;
  final Map<String, String> headers;
  bool get isNovel => kind == NonVideoKind.novel;
  bool get isPics => kind == NonVideoKind.pics;
}

String? _findPayload(String value, String scheme) {
  final start = value.indexOf(scheme);
  if (start < 0) return null;
  return value.substring(start);
}

NonVideoContent? parseNonVideoUrl(
  String raw, {
  Map<String, String> headers = const {},
}) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final novel = _findPayload(value, 'novel://');
  if (novel != null) {
    final jsonText = novel.substring('novel://'.length).trim();
    if (!jsonText.startsWith('{')) {
      return null;
    }
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is Map) {
        final title = decoded['title']?.toString() ?? '';
        final text = decoded['content']?.toString() ?? '';
        if (text.isNotEmpty) {
          return NonVideoContent.novel(title: title, text: text);
        }
      }
    } catch (_) {}
    return null;
  }
  final pics = _findPayload(value, 'pics://');
  if (pics != null) {
    final payload = pics.substring('pics://'.length);
    final urls = [
      for (final part in payload.split('&&'))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    if (urls.isEmpty) return null;
    return NonVideoContent.pics(title: '', urls: urls, headers: headers);
  }
  return null;
}

NonVideoContent? nonVideoFromEpisode(Episode episode) {
  final candidates = <String>[];
  for (final key in const ['videoUrl', 'episodeId', 'id', 'url']) {
    final value = episode.raw[key];
    if (value is String && value.isNotEmpty) candidates.add(value);
  }
  if (episode.id.isNotEmpty) candidates.add(episode.id);
  for (final candidate in candidates) {
    final parsed = parseNonVideoUrl(candidate);
    if (parsed != null) return parsed;
  }
  return null;
}

bool isNonVideoEpisode(Episode episode) => nonVideoFromEpisode(episode) != null;

NonVideoKind? nonVideoKindOfEpisode(Episode episode) {
  final candidates = <String>[];
  for (final key in const ['videoUrl', 'episodeId', 'id', 'url']) {
    final value = episode.raw[key];
    if (value is String && value.isNotEmpty) candidates.add(value);
  }
  if (episode.id.isNotEmpty) candidates.add(episode.id);
  for (final candidate in candidates) {
    if (_findPayload(candidate, 'novel://') != null) return NonVideoKind.novel;
    if (_findPayload(candidate, 'pics://') != null) return NonVideoKind.pics;
  }
  return null;
}

Map<String, String> _imageHeaders(
  String url,
  Map<String, String> sourceHeaders,
) {
  if (url.startsWith('http://127.0.0.1') ||
      url.startsWith('http://localhost')) {
    return const {};
  }
  final userAgent =
      sourceHeaders['User-Agent'] ?? sourceHeaders['user-agent'];
  final referer = sourceHeaders['Referer'] ?? sourceHeaders['referer'];
  return {
    'User-Agent':
        userAgent ??
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer':
        referer != null && referer.isNotEmpty
            ? referer
            : 'https://mjv011.com/',
  };
}

class NovelReaderView extends StatefulWidget {
  const NovelReaderView({
    super.key,
    required this.content,
    required this.title,
    this.onCenterTap,
    this.initialPage = 0,
    this.onPageChanged,
  });
  final NonVideoContent content;
  final String title;
  final VoidCallback? onCenterTap;
  final int initialPage;
  final ValueChanged<int>? onPageChanged;
  @override
  State<NovelReaderView> createState() => _NovelReaderViewState();
}

class _FoldClipper extends CustomClipper<Path> {
  const _FoldClipper({
    required this.forward,
    required this.foldX,
    required this.bulge,
  });

  final bool forward;
  final double foldX;
  final double bulge;

  @override
  Path getClip(Size size) {
    final path = Path();
    if (forward) {
      path.moveTo(0, 0);
      path.lineTo(foldX, 0);
      path.quadraticBezierTo(
        foldX + bulge,
        size.height / 2,
        foldX,
        size.height,
      );
      path.lineTo(0, size.height);
    } else {
      path.moveTo(size.width, 0);
      path.lineTo(foldX, 0);
      path.quadraticBezierTo(
        foldX - bulge,
        size.height / 2,
        foldX,
        size.height,
      );
      path.lineTo(size.width, size.height);
    }
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant _FoldClipper oldClipper) {
    return oldClipper.forward != forward ||
        oldClipper.foldX != foldX ||
        oldClipper.bulge != bulge;
  }
}

class _NovelReaderViewState extends State<NovelReaderView>
    with SingleTickerProviderStateMixin {
  double _fontSize = 17;
  late final AnimationController _turnController;
  int _page = 0;
  List<String> _pages = const [];
  double _pageWidth = 0;
  double _pageHeight = 0;
  double _pageFont = 0;
  String _pageText = '';
  int _turnDirection = 0;
  int? _turnTarget;
  double _dragDistance = 0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _turnController = AnimationController(vsync: this);
    _page = widget.initialPage;
  }

  @override
  void dispose() {
    _turnController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant NovelReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content.text != widget.content.text) {
      _pages = const [];
      _page = 0;
      _turnDirection = 0;
      _turnTarget = null;
      _dragDistance = 0;
      _dragging = false;
      _turnController.stop();
    }
  }

  List<String> _paginate(double width, double height) {
    final text = widget.content.text;
    final style = TextStyle(fontSize: _fontSize, height: 1.7);
    final lines = <String>[];
    for (final para in text.split('\n')) {
      final trimmed = para.trim();
      if (trimmed.isEmpty) {
        lines.add('');
        continue;
      }
      final painter = TextPainter(
        text: TextSpan(text: trimmed, style: style),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      final metrics = painter.computeLineMetrics();
      var start = 0;
      for (var i = 0; i < metrics.length; i++) {
        final boundary = painter.getLineBoundary(
          TextPosition(offset: start),
        );
        lines.add(trimmed.substring(boundary.start, boundary.end));
        start = boundary.end;
        if (start >= trimmed.length) break;
      }
    }
    final lineHeight = _fontSize * 1.7;
    final perPage = (height / lineHeight).floor().clamp(1, 1000);
    final pages = <String>[];
    for (var i = 0; i < lines.length; i += perPage) {
      final end = (i + perPage).clamp(0, lines.length);
      pages.add(lines.sublist(i, end).join('\n'));
    }
    return pages.isEmpty ? const [''] : pages;
  }

  void _clearTurn() {
    _turnDirection = 0;
    _turnTarget = null;
    _dragDistance = 0;
    _dragging = false;
  }

  void _startTurn(int direction) {
    if (_pages.isEmpty || _turnController.isAnimating) return;
    final target = _page + direction;
    if (target < 0 || target >= _pages.length) return;
    setState(() {
      _turnDirection = direction;
      _turnTarget = target;
      _dragDistance = 0;
    });
    _turnController.duration = const Duration(milliseconds: 560);
    _turnController.forward(from: 0).then((_) {
      if (!mounted) return;
      setState(() {
        _page = target;
        _clearTurn();
      });
      widget.onPageChanged?.call(target);
      _turnController.reset();
    }, onError: (_) {});
  }

  void _onDragStart(double width) {
    if (_pages.isEmpty) return;
    _turnController.stop();
    _dragging = true;
    if (_turnDirection == 1) {
      _dragDistance = -_turnController.value * width;
    } else if (_turnDirection == -1) {
      _dragDistance = _turnController.value * width;
    } else {
      _dragDistance = 0;
    }
  }

  void _onDragUpdate(DragUpdateDetails details, double width) {
    if (_pages.isEmpty || !_dragging) return;
    _dragDistance += details.delta.dx;
    final direction = _dragDistance < 0
        ? 1
        : _dragDistance > 0
        ? -1
        : 0;
    if (direction == 0) {
      setState(() {
        _turnDirection = 0;
        _turnTarget = null;
        _turnController.value = 0;
      });
      return;
    }
    final target = _page + direction;
    setState(() {
      _turnDirection = direction;
      if (target < 0 || target >= _pages.length) {
        _turnTarget = null;
        _turnController.value = (_dragDistance.abs() / width * 0.25).clamp(
          0.0,
          0.3,
        );
      } else {
        _turnTarget = target;
        _turnController.value = (_dragDistance.abs() / width).clamp(0.0, 1.0);
      }
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    final progress = _turnController.value;
    if (progress <= 0.001) {
      setState(_clearTurn);
      return;
    }
    final velocity = details.velocity.pixelsPerSecond.dx;
    final target = _turnTarget;
    final fling =
        (velocity < -500 && _turnDirection == 1) ||
        (velocity > 500 && _turnDirection == -1);
    if (target != null && (fling || progress >= 0.28)) {
      _turnController.duration = const Duration(milliseconds: 480);
      _turnController.forward().then((_) {
        if (!mounted) return;
        setState(() {
          _page = target;
          _clearTurn();
        });
        widget.onPageChanged?.call(target);
        _turnController.reset();
      }, onError: (_) {});
    } else {
      _turnController.duration = const Duration(milliseconds: 280);
      _turnController.reverse().then((_) {
        if (!mounted) return;
        setState(_clearTurn);
      }, onError: (_) {});
    }
  }

  void _onTapUp(TapUpDetails details, double width) {
    if (_turnController.isAnimating || _dragging) return;
    final dx = details.localPosition.dx;
    if (dx < width * 0.35) {
      _startTurn(-1);
    } else if (dx > width * 0.65) {
      _startTurn(1);
    } else {
      widget.onCenterTap?.call();
    }
  }

  Widget _pageBody(int index) {
    return Container(
      color: const Color(0xFFF7F1E3),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
        child: Text(
          _pages[index],
          style: TextStyle(
            fontSize: _fontSize,
            height: 1.7,
            color: Colors.black87,
          ),
        ),
      ),
    );
  }

  Widget _turnStack(double width) {
    final progress = _turnDirection == 0 ? 0.0 : _turnController.value;
    final target = _turnTarget;
    final turning = _turnDirection != 0 && progress > 0.001;
    final displayedPage = turning && progress > 0.5 && target != null
        ? target
        : _page;
    final curl = math.sin(math.pi * progress.clamp(0.0, 1.0));
    final children = <Widget>[];
    if (turning && target != null) {
      final forward = _turnDirection == 1;
      final foldX = forward ? width * (1 - progress) : width * progress;
      final bulge = 26 * curl;
      final curlWidth = 72 * curl;
      children.add(_pageBody(target));
      children.add(
        Positioned(
          left: forward ? foldX : foldX - 56,
          width: 56,
          top: 0,
          bottom: 0,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: forward ? Alignment.centerLeft : Alignment.centerRight,
                end: forward ? Alignment.centerRight : Alignment.centerLeft,
                colors: [
                  Colors.black.withValues(alpha: 0.22),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      );
      children.add(
        ClipPath(
          clipper: _FoldClipper(
            forward: forward,
            foldX: foldX,
            bulge: bulge,
          ),
          child: _pageBody(_page),
        ),
      );
      children.add(
        Positioned(
          left: forward ? foldX - 40 : foldX,
          width: 40,
          top: 0,
          bottom: 0,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: forward ? Alignment.centerLeft : Alignment.centerRight,
                end: forward ? Alignment.centerRight : Alignment.centerLeft,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.18),
                ],
              ),
            ),
          ),
        ),
      );
      if (curlWidth > 1) {
        children.add(
          Positioned(
            left: forward ? foldX : foldX - curlWidth,
            width: curlWidth,
            top: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: forward ? Alignment.centerLeft : Alignment.centerRight,
                  end: forward ? Alignment.centerRight : Alignment.centerLeft,
                  colors: const [Color(0xFFCFC3A5), Color(0xFFEDE4CC)],
                ),
              ),
            ),
          ),
        );
        children.add(
          Positioned(
            left: foldX - 0.75,
            width: 1.5,
            top: 0,
            bottom: 0,
            child: Container(color: Colors.black26),
          ),
        );
      }
    } else if (turning) {
      children.add(
        Transform.translate(
          offset: Offset(-_turnDirection * progress * width * 0.5, 0),
          child: _pageBody(_page),
        ),
      );
      children.add(
        Positioned(
          left: _turnDirection == 1 ? width - 24 : 0,
          width: 24,
          top: 0,
          bottom: 0,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: _turnDirection == 1
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                end: _turnDirection == 1
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                colors: [
                  Colors.black.withValues(alpha: 0.18),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      );
    } else {
      children.add(_pageBody(_page));
    }
    children.add(
      Positioned(
        left: 18,
        right: 18,
        bottom: 6,
        child: Row(
          children: [
            Expanded(
              child: LinearProgressIndicator(
                value: _pages.isEmpty ? 0 : (displayedPage + 1) / _pages.length,
                backgroundColor: Colors.black12,
                color: Colors.brown,
                minHeight: 2,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${displayedPage + 1} / ${_pages.length}',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => _onDragStart(width),
      onHorizontalDragUpdate: (details) => _onDragUpdate(details, width),
      onHorizontalDragEnd: _onDragEnd,
      onTapUp: (details) => _onTapUp(details, width),
      child: Stack(fit: StackFit.expand, children: children),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.content.title.isNotEmpty
        ? widget.content.title
        : widget.title;
    return Container(
      color: const Color(0xFFF7F1E3),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '减小字号',
                  onPressed: _fontSize > 13
                      ? () => setState(() => _fontSize -= 1)
                      : null,
                  icon: const Icon(Icons.text_decrease),
                ),
                Text(
                  '${_fontSize.toInt()}',
                  style: const TextStyle(color: Colors.black54),
                ),
                IconButton(
                  tooltip: '增大字号',
                  onPressed: _fontSize < 26
                      ? () => setState(() => _fontSize += 1)
                      : null,
                  icon: const Icon(Icons.text_increase),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth - 36;
                final height = constraints.maxHeight - 48;
                if (_pages.isEmpty ||
                    _pageWidth != width ||
                    _pageHeight != height ||
                    _pageFont != _fontSize ||
                    _pageText != widget.content.text) {
                  _pages = _paginate(width, height);
                  _pageWidth = width;
                  _pageHeight = height;
                  _pageFont = _fontSize;
                  _pageText = widget.content.text;
                  if (_page >= _pages.length) _page = _pages.length - 1;
                }
                return AnimatedBuilder(
                  animation: _turnController,
                  builder: (context, _) =>
                      _turnStack(constraints.maxWidth),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class PicsViewerView extends StatefulWidget {
  const PicsViewerView({
    super.key,
    required this.content,
    required this.title,
    this.initialIndex = 0,
    this.onIndexChanged,
  });
  final NonVideoContent content;
  final String title;
  final int initialIndex;
  final ValueChanged<int>? onIndexChanged;
  @override
  State<PicsViewerView> createState() => _PicsViewerViewState();
}

class _PicsViewerViewState extends State<PicsViewerView> {
  late final PageController _controller;
  int _index = 0;
  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.initialIndex);
    _index = widget.initialIndex;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PicsViewerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content.urls != widget.content.urls) {
      _index = 0;
      _controller.jumpToPage(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final urls = widget.content.urls;
    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: urls.length,
            onPageChanged: (value) {
              setState(() => _index = value);
              widget.onIndexChanged?.call(value);
              for (final next in [value - 1, value + 1]) {
                if (next >= 0 && next < urls.length) {
                  precacheImage(
                    NetworkImage(
                      urls[next],
                      headers: _imageHeaders(urls[next], widget.content.headers),
                    ),
                    context,
                  );
                }
              }
            },
            itemBuilder: (context, i) {
              return InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Center(
                  child: Image.network(
                    urls[i],
                    headers: _imageHeaders(urls[i], widget.content.headers),
                    fit: BoxFit.contain,
                    errorBuilder: (context, _, _) => Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        '图片加载失败\n${urls[i]}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: '上一张',
                  onPressed: _index > 0
                      ? () => _controller.previousPage(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                        )
                      : null,
                  icon: const Icon(Icons.chevron_left, color: Colors.white),
                ),
                Text(
                  '${_index + 1} / ${urls.length}',
                  style: const TextStyle(color: Colors.white),
                ),
                IconButton(
                  tooltip: '下一张',
                  onPressed: _index + 1 < urls.length
                      ? () => _controller.nextPage(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                        )
                      : null,
                  icon: const Icon(Icons.chevron_right, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
