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

/// 正文清洗：有的书源返回带 <p>/<br>/&nbsp; 的 HTML，直接喂给分页和
/// 朗读会把标签念出来、也会把分页算乱。
String cleanNovelText(String text) {
  var value = text
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</(p|div|h\d)\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  const entities = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&ldquo;': '“',
    '&rdquo;': '”',
  };
  entities.forEach((key, val) => value = value.replaceAll(key, val));
  value = value.replaceAll(RegExp(r'[ \t\u3000]+'), ' ');
  value = value.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return value.trim();
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
        final text = cleanNovelText(decoded['content']?.toString() ?? '');
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
    this.onEndReached,
    this.onStartReached,
  });
  final NonVideoContent content;
  final String title;
  final VoidCallback? onCenterTap;
  final int initialPage;
  final ValueChanged<int>? onPageChanged;

  /// 已到本章最后一页还往后翻：去看下一章（不让人卡在最后一页）。
  final VoidCallback? onEndReached;

  /// 已到本章第一页还往前翻。
  final VoidCallback? onStartReached;
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
      if (metrics.isEmpty) {
        lines.add(trimmed);
        continue;
      }
      var start = 0;
      var guard = 0;
      while (start < trimmed.length) {
        if (guard++ > 20000) break;
        TextRange boundary;
        try {
          boundary = painter.getLineBoundary(TextPosition(offset: start));
        } catch (_) {
          lines.add(trimmed.substring(start));
          break;
        }
        if (boundary.end <= start) {
          // 边界没往前走就手动推一格，否则死循环把界面卡死（点了没反应）。
          lines.add(trimmed.substring(start, start + 1));
          start += 1;
          continue;
        }
        final end = boundary.end.clamp(0, trimmed.length);
        lines.add(trimmed.substring(start, end));
        start = end;
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
    if (_turnController.isAnimating) return;
    if (_pages.isEmpty) {
      // 正文还没分好 / 本章为空：也让人能翻到下一章，不能点了毫无反应。
      if (direction > 0) {
        widget.onEndReached?.call();
      } else {
        widget.onStartReached?.call();
      }
      return;
    }
    final target = _page + direction;
    if (target >= _pages.length) {
      widget.onEndReached?.call();
      return;
    }
    if (target < 0) {
      widget.onStartReached?.call();
      return;
    }
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
    if (target == null && (fling || progress >= 0.28)) {
      setState(_clearTurn);
      (details.velocity.pixelsPerSecond.dx < 0
          ? widget.onEndReached
          : widget.onStartReached)
          ?.call();
      return;
    }
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
    this.verticalScroll = false,
    this.onEndReached,
  });
  final NonVideoContent content;
  final String title;
  final int initialIndex;
  final ValueChanged<int>? onIndexChanged;

  /// 最后一屏/最后一张还往后翻：去看下一章。
  final VoidCallback? onEndReached;

  /// 纵向连续滚动：整章图上下排成一列（漫画阅读）；默认横向逐张翻页。
  final bool verticalScroll;
  @override
  State<PicsViewerView> createState() => _PicsViewerViewState();
}

class _PicsViewerViewState extends State<PicsViewerView> {
  late final PageController _controller;
  late final ScrollController _scrollController;
  int _index = 0;
  bool _restored = false;
  int _restoreAttempts = 0;
  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.initialIndex);
    _scrollController = ScrollController()..addListener(_onVerticalScroll);
    _index = widget.initialIndex;
    if (widget.verticalScroll) _scheduleRestore();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PicsViewerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content.urls != widget.content.urls) {
      _index = 0;
      _restored = true;
      _controller.jumpToPage(0);
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    }
  }

  /// 纵向模式按滚动比例估算当前图序号（恢复书签用同一口径，来回一致）。
  int _indexFromOffset() {
    final urls = widget.content.urls;
    if (urls.length <= 1 || !_scrollController.hasClients) return 0;
    final max = _scrollController.position.maxScrollExtent;
    if (max <= 0) return 0;
    final fraction = (_scrollController.offset / max).clamp(0.0, 1.0);
    return (fraction * (urls.length - 1)).round().clamp(0, urls.length - 1);
  }

  bool _endReported = false;

  void _onVerticalScroll() {
    if (!widget.verticalScroll) return;
    if (_scrollController.hasClients) {
      final pos = _scrollController.position;
      if (pos.maxScrollExtent > 0 &&
          pos.pixels >= pos.maxScrollExtent - 4) {
        if (!_endReported) {
          _endReported = true;
          widget.onEndReached?.call();
        }
      } else if (pos.pixels < pos.maxScrollExtent - 40) {
        _endReported = false;
      }
    }
    final next = _indexFromOffset();
    if (next != _index) {
      setState(() => _index = next);
      widget.onIndexChanged?.call(next);
    }
  }

  /// 续读恢复：按 initialIndex 的比例跳到对应滚动位置。图未加载完时
  /// maxScrollExtent 为 0，帧后回调链式复查（图一到、下一帧就跳），
  /// 30 帧仍为 0 就停在顶部。
  void _scheduleRestore() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_restored || !widget.verticalScroll || !mounted) return;
      final urls = widget.content.urls;
      if (urls.length <= 1 || widget.initialIndex <= 0) {
        _restored = true;
        return;
      }
      if (!_scrollController.hasClients ||
          _scrollController.position.maxScrollExtent <= 0) {
        if (_restoreAttempts < 30) {
          _restoreAttempts++;
          _scheduleRestore();
        }
        return;
      }
      _restored = true;
      final max = _scrollController.position.maxScrollExtent;
      final target =
          (widget.initialIndex.clamp(0, urls.length - 1) / (urls.length - 1)) *
          max;
      if (target > 0) _scrollController.jumpTo(target);
    });
  }

  void _scrollByViewport(double direction) {
    if (!_scrollController.hasClients) return;
    final viewport = _scrollController.position.viewportDimension;
    final target = (_scrollController.offset + direction * viewport * 0.85)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  Widget _imageItem(String url) {
    return Image.network(
      url,
      headers: _imageHeaders(url, widget.content.headers),
      fit: BoxFit.contain,
      errorBuilder: (context, _, _) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '图片加载失败\n$url',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final urls = widget.content.urls;
    if (urls.isEmpty) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '本章没有取到图片',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 8),
              const Text(
                '可能是源站临时抽风，点下面重试或换一章',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: widget.onEndReached,
                child: const Text('看下一章'),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          if (widget.verticalScroll)
            ListView.builder(
              controller: _scrollController,
              itemCount: urls.length,
              itemBuilder: (context, i) {
                return Image.network(
                  urls[i],
                  headers: _imageHeaders(urls[i], widget.content.headers),
                  width: double.infinity,
                  fit: BoxFit.fitWidth,
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 48),
                      child: Center(
                        child: SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  },
                  errorBuilder: (context, _, _) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '图片加载失败\n${urls[i]}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                );
              },
            )
          else
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
                  child: Center(child: _imageItem(urls[i])),
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
                  tooltip: widget.verticalScroll ? '上一屏' : '上一张',
                  onPressed: widget.verticalScroll
                      ? (_index > 0 ? () => _scrollByViewport(-1) : null)
                      : _index > 0
                      ? () => _controller.previousPage(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                        )
                      : null,
                  icon: Icon(
                    widget.verticalScroll
                        ? Icons.keyboard_arrow_up
                        : Icons.chevron_left,
                    color: Colors.white,
                  ),
                ),
                Text(
                  '${_index + 1} / ${urls.length}',
                  style: const TextStyle(color: Colors.white),
                ),
                IconButton(
                  tooltip: widget.verticalScroll ? '下一屏' : '下一张',
                  onPressed: widget.verticalScroll
                      ? (_index + 1 < urls.length
                            ? () => _scrollByViewport(1)
                            : (widget.onEndReached ?? () => _scrollByViewport(1)))
                      : _index + 1 < urls.length
                      ? () => _controller.nextPage(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                        )
                      : null,
                  icon: Icon(
                    widget.verticalScroll
                        ? Icons.keyboard_arrow_down
                        : Icons.chevron_right,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
