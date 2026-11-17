import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../danmaku_models.dart';
import '../../danmaku_overlay.dart';

/// 海阔播放器的轻量弹幕层（方案乙）：只读播放 JSON 透传来的 danmuUrl。
///
/// 不碰主播放器与西瓜共用的 [DanmakuController]（它只认 AppRepository
/// 分页接口，海阔播放器没有 PlaybackPlan，接上也恒为“不支持”）。
/// 数据契约只认静态实证的那一种：JSON 数组，元素 `{text, time秒}`
/// （红果 dm 代理的 danmakuMore 拼法）；`web://` 弹幕无渲染契约，
/// 这里不取数、不渲染，调用方原样透传、如实标注不支持。
/// 排布复用主播放器同一套 [planDanmaku]（分道、8 秒飞行、上限），
/// 位置由播放进度驱动，暂停/ seek 时弹幕停在正确位置。

/// 弹幕取数函数形态：供播放器视图注入假取数做测试，默认走 HTTP。
typedef HaikuoDanmuFetcher =
    Future<List<DanmakuItem>> Function(String url, Map<String, String> headers);

/// 只有 http(s) 地址才能取数；`web://` 与空串一律不取。
bool haikuoDanmuUrlIsFetchable(String url) {
  final trimmed = url.trim();
  return trimmed.startsWith('http://') || trimmed.startsWith('https://');
}

/// 解析 dm 响应体：JSON 数组，元素 `{text, time秒}`。
///
/// 容错：非数组/解析失败回空列表（不抛错）；缺 text、缺时间、
/// 时间为负的行跳过；`timeMs`（毫秒）形态也认，作 `time` 的备选；
/// 超过 [maxItems] 只留时间最早的那些。绝不猜测其它信封形态。
List<DanmakuItem> parseHaikuoDanmuBody(String body, {int maxItems = 2000}) {
  dynamic decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return const [];
  }
  if (decoded is! List) return const [];
  final items = <DanmakuItem>[];
  for (final row in decoded) {
    if (row is! Map) continue;
    final rawText = row['text'];
    if (rawText is! String) continue;
    final cleaned = rawText
        .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]'), ' ')
        .trim();
    if (cleaned.isEmpty) continue;
    int? timeMs;
    final time = row['time'];
    if (time is num) {
      timeMs = (time * 1000).round();
    } else {
      final timeMsRaw = row['timeMs'];
      if (timeMsRaw is num) timeMs = timeMsRaw.toInt();
    }
    if (timeMs == null || timeMs < 0) continue;
    items.add(
      DanmakuItem(
        id: 'dm:${items.length}',
        text: trimDanmakuText(cleaned, 181),
        timeMs: timeMs,
      ),
    );
  }
  items.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  if (items.length <= maxItems) return List.unmodifiable(items);
  return List.unmodifiable(items.take(maxItems));
}

/// 取一条 dm URL 的弹幕：GET + 该条播放线路的头（默认 UA 打底，
/// 线路头覆盖），15 秒超时；非 200 抛错，调用方据此显示重试。
Future<List<DanmakuItem>> fetchHaikuoDanmu(
  String url,
  Map<String, String> headers, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    throw const FormatException('弹幕地址不是 http(s) 地址');
  }
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient
        .get(uri, headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
          'Accept': 'application/json, text/plain, */*',
          ...headers,
        })
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw Exception('弹幕加载失败：HTTP ${response.statusCode}');
    }
    return parseHaikuoDanmuBody(response.body);
  } on TimeoutException {
    throw Exception('弹幕加载超时');
  } finally {
    if (owned) httpClient.close();
  }
}

/// 只读 danmuUrl 的小控制器：取数 + 解析 + 按播放位置过滤。
///
/// 切集/切线路时调用方先 [reset] 再 [load]；取数失败置 [failed]，
/// 开关切到重试形态；同一地址+同一头重复 load 不重复取数。
class HaikuoDanmuController extends ChangeNotifier {
  List<DanmakuItem> _items = const [];
  bool _enabled = true;
  bool _loading = false;
  bool _failed = false;
  bool _loaded = false;
  String _url = '';
  String _headersKey = '';
  int _token = 0;
  int _lastNotifiedMs = -1;
  bool _lastNotifiedPlaying = false;

  /// 弹幕条目（按时间升序）。
  List<DanmakuItem> get items => _items;

  bool get enabled => _enabled;

  bool get loading => _loading;

  bool get failed => _failed;

  bool get loaded => _loaded;

  /// 数据版本号：取数/重置时 +1，排布缓存据此失效。
  int dataRevision = 0;

  int positionMs = 0;
  int durationMs = 0;
  bool playing = false;
  double rate = 1;

  /// 是否该显示弹幕层：开关开着、且有数据。时长不作条件
  /// （直播流时长可能为 0，位置窗口过滤本身已足够）。
  bool get visible => _enabled && _items.isNotEmpty;

  /// 开关旁的状态文案（PlayerControls 的 danmakuStatus 用）。
  String get status {
    if (!_enabled) return '弹幕已关闭';
    if (_loading) return '正在加载弹幕';
    if (_failed) return '弹幕加载失败，可重试';
    if (_loaded) {
      return _items.isEmpty ? '这段暂无弹幕' : '已载入 ${_items.length} 条弹幕';
    }
    return '等待播放';
  }

  /// 取数并装载。地址不可取（空串/`web://`）时直接重置、不取数。
  Future<void> load(
    String url,
    Map<String, String> headers, {
    HaikuoDanmuFetcher? fetcher,
  }) async {
    final trimmed = url.trim();
    if (!haikuoDanmuUrlIsFetchable(trimmed)) {
      reset();
      return;
    }
    final headersKey = _headersKeyOf(headers);
    if (_loaded &&
        !_failed &&
        _url == trimmed &&
        _headersKey == headersKey) {
      return;
    }
    final token = ++_token;
    _url = trimmed;
    _headersKey = headersKey;
    _loading = true;
    _failed = false;
    notifyListeners();
    try {
      final fetched = await (fetcher ?? fetchHaikuoDanmu)(trimmed, headers);
      if (token != _token) return;
      _items = fetched;
      _loaded = true;
      _loading = false;
      dataRevision++;
    } catch (_) {
      if (token != _token) return;
      _items = const [];
      _loaded = false;
      _loading = false;
      _failed = true;
      dataRevision++;
    }
    notifyListeners();
  }

  /// 清空数据与状态（切集/切线路/无弹幕时调）。
  void reset() {
    _token++;
    _url = '';
    _headersKey = '';
    _items = const [];
    _loading = false;
    _failed = false;
    _loaded = false;
    positionMs = 0;
    durationMs = 0;
    dataRevision++;
    notifyListeners();
  }

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
  }

  /// 播放位置同步：位置变化满 250ms 或播/停翻转时才通知，
  /// 避免每帧重建弹幕层。
  void update({
    required Duration position,
    required Duration duration,
    required bool playing,
    required double rate,
  }) {
    positionMs = position.inMilliseconds.clamp(0, danmakuMaxDurationMs);
    durationMs = duration.inMilliseconds;
    this.playing = playing;
    this.rate = rate.isFinite && rate > 0 ? rate : 1;
    final positionJumped =
        (positionMs - _lastNotifiedMs).abs() >= 250 || positionMs == 0;
    final playingFlipped = playing != _lastNotifiedPlaying;
    if (positionJumped || playingFlipped) {
      _lastNotifiedMs = positionMs;
      _lastNotifiedPlaying = playing;
      notifyListeners();
    }
  }

  String _headersKeyOf(Map<String, String> headers) {
    final keys = headers.keys.toList()..sort();
    return keys.map((key) => '$key=${headers[key]}').join('\n');
  }

  @override
  void dispose() {
    _token++;
    super.dispose();
  }
}

/// 海阔弹幕渲染层：排布复用 [planDanmaku]，位置由播放进度驱动
/// （弹幕左缘 = 飞行进度 ×（宽 + 文宽），暂停时静止、seek 后即正）。
class HaikuoDanmuOverlay extends StatefulWidget {
  const HaikuoDanmuOverlay({
    super.key,
    required this.controller,
    required this.aspectRatio,
  });

  final HaikuoDanmuController controller;
  final double aspectRatio;

  @override
  State<HaikuoDanmuOverlay> createState() => _HaikuoDanmuOverlayState();
}

class _HaikuoDanmuOverlayState extends State<HaikuoDanmuOverlay> {
  Object? _layout;
  List<DanmakuFlight> _schedule = const [];

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (!constraints.hasBoundedWidth ||
              !constraints.hasBoundedHeight ||
              constraints.maxWidth <= 0 ||
              constraints.maxHeight <= 0) {
            return const SizedBox.shrink();
          }
          final aspect = widget.aspectRatio.isFinite && widget.aspectRatio > 0
              ? widget.aspectRatio
              : 16 / 9;
          final width = math.min(
            constraints.maxWidth,
            constraints.maxHeight * aspect,
          );
          final height = math.min(
            constraints.maxHeight,
            constraints.maxWidth / aspect,
          );
          const fontSize = 12.0;
          final scaler = MediaQuery.textScalerOf(context);
          final rowHeight = scaler.scale(fontSize) * 1.5;
          final rows = ((height * .55 - 8) / rowHeight).floor().clamp(0, 4);
          const style = TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.white,
            height: 1.2,
            shadows: [
              Shadow(color: Colors.black, blurRadius: 3, offset: Offset(1, 1)),
            ],
          );
          return Center(
            child: SizedBox(
              width: width,
              height: height,
              child: ClipRect(
                child: AnimatedBuilder(
                  animation: widget.controller,
                  builder: (context, _) {
                    final controller = widget.controller;
                    if (!controller.visible || rows == 0) {
                      return const SizedBox.shrink();
                    }
                    final layout = (
                      controller.dataRevision,
                      width,
                      rows,
                      fontSize,
                      scaler,
                    );
                    if (_layout != layout) {
                      _layout = layout;
                      _schedule = planDanmaku(
                        controller.items,
                        width: width,
                        rows: rows,
                        measure: (text) {
                          final painter = TextPainter(
                            text: TextSpan(text: text, style: style),
                            textDirection: TextDirection.ltr,
                            textScaler: scaler,
                            maxLines: 1,
                          )..layout();
                          final measured = painter.width;
                          painter.dispose();
                          return measured;
                        },
                      );
                    }
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (final flight in _schedule)
                          if (controller.positionMs >= flight.item.timeMs &&
                              controller.positionMs <
                                  flight.item.timeMs + danmakuLifetimeMs)
                            Positioned(
                              key: ValueKey('haikuo-danmaku-${flight.item.id}'),
                              left:
                                  width -
                                  (width + flight.width) *
                                      (controller.positionMs -
                                              flight.item.timeMs) /
                                      danmakuLifetimeMs,
                              top: 8 + flight.lane * rowHeight,
                              width: flight.width,
                              height: rowHeight,
                              child: Text(
                                flight.text,
                                style: style,
                                textScaler: scaler,
                                textDirection: TextDirection.ltr,
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                      ],
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}
