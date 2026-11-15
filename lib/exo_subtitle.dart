import 'dart:math' as math;

import 'package:flutter/material.dart';

// Exo 字幕 Dart 层：Kotlin 侧 TvboxPlayerView 把 onCues(CueGroup) 经
// MethodChannel 原样转发到这里，原生 PlayerView 内的 SubtitleView 已隐藏，
// 字幕只由 ExoSubtitleOverlay 画一遍，避免两层叠画。
//
// 重叠根因（实查）：一条内嵌 ASS 轨道里同时出现的多个 Dialogue 事件，
// Exo 解成同一个 CueGroup 里的多条 Cue；CueGroup 文档明说 cue 框可能
// 重叠、只分 z 轴先后，不替调用方错开。SsaDecoder 对无 \pos 的对话
// 不给不同的行位置，SubtitleView 便把几条都画在同一个默认底框里，
// 文字压在一起。本层把同组 cue 归一成自上而下的行文本，一次画完，
// 结构上不再重叠；cue 自带的 line（0 顶部 → 1 底部）只用来保序，
// 不作绝对定位——\pos 像素定位与内嵌字体仍走 MPV/libass 那条路。
//
// 同步：CueGroup 自带 presentationTimeUs，与播放位置同一条时间轴，
// 偏移量为 0 时即自动对齐。树里没有现成的字幕偏移设置项，不虚构新
// 设置；offsetMs 只留在逻辑层（正值 = 字幕延后），入口待拍板。

/// 单条 Exo cue。[line]/[position] 是 Cue 的分数位置，未设置时为 null
///（Kotlin 侧已把 DIMEN_UNSET 滤掉，不往 Dart 发哨兵值）。
class ExoSubtitleCue {
  const ExoSubtitleCue({required this.text, this.line, this.position});

  final String text;

  /// 垂直位置分数：0 为顶部，1 为底部；只在 [0, 1] 内才参与排序。
  final double? line;
  final double? position;

  @override
  bool operator ==(Object other) =>
      other is ExoSubtitleCue &&
      other.text == text &&
      other.line == line &&
      other.position == position;

  @override
  int get hashCode => Object.hash(text, line, position);
}

/// 一组同时生效的 cue，[presentationTimeUs] 是该组生效的时刻（微秒）。
class ExoSubtitleGroup {
  const ExoSubtitleGroup({
    required this.presentationTimeUs,
    required this.cues,
  });

  final int presentationTimeUs;
  final List<ExoSubtitleCue> cues;

  /// 解析 Kotlin 侧 onCues 转发的 map：
  /// `{presentationTimeUs: int, cues: [{text, line?, position?}]}`。
  /// 形状不对返回 null；单条 cue 形状不对只跳过该条，不整组丢弃。
  static ExoSubtitleGroup? fromChannelMap(Object? value) {
    if (value is! Map) return null;
    final time = value['presentationTimeUs'];
    if (time is! num) return null;
    final rawCues = value['cues'];
    if (rawCues is! List) return null;
    final cues = <ExoSubtitleCue>[];
    for (final raw in rawCues) {
      if (raw is! Map) continue;
      final text = raw['text'];
      if (text is! String) continue;
      final line = raw['line'];
      final position = raw['position'];
      cues.add(
        ExoSubtitleCue(
          text: text,
          line: line is num ? line.toDouble() : null,
          position: position is num ? position.toDouble() : null,
        ),
      );
    }
    return ExoSubtitleGroup(
      presentationTimeUs: time.toInt(),
      cues: cues,
    );
  }
}

/// 归一单条 cue 文本：ASS 换行 `\N` / `\n` 转真换行，`\h` 转空格，
/// 行内覆盖块 `{...}`（如 `\pos`、`\an`、`\c`）去掉，空行丢弃。
/// Exo 的 SsaDecoder 已做过大部分剥离，这里是兜底归一，
/// 保证换行与去标签在任何解码形态下都成立。
String normalizeExoSubtitleText(String raw) {
  var text = raw
      .replaceAll(r'\N', '\n')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\h', ' ');
  final override = RegExp(r'\{[^{}]*\}');
  while (override.hasMatch(text)) {
    text = text.replaceAll(override, '');
  }
  final lines = <String>[];
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) lines.add(trimmed);
  }
  return lines.join('\n');
}

/// 把同组 cue 排成不重叠的行：归一、去空、去重后按 line 自上而下
/// 排序（无 line 或 line 不在 [0, 1] 内时按解码顺序沉底），返回的
/// 每项是一条 cue 的完整文本（内部可含换行），调用方拼成一个 Text。
List<String> layoutExoSubtitleLines(List<ExoSubtitleCue> cues) {
  final seen = <String>{};
  final ordered = <_OrderedCue>[];
  for (var i = 0; i < cues.length; i++) {
    final normalized = normalizeExoSubtitleText(cues[i].text);
    if (normalized.isEmpty || !seen.add(normalized)) continue;
    final line = cues[i].line;
    ordered.add(
      _OrderedCue(
        order: i,
        line: line != null && line >= 0 && line <= 1 ? line : 1.0,
        text: normalized,
      ),
    );
  }
  ordered.sort((a, b) {
    final byLine = a.line.compareTo(b.line);
    return byLine != 0 ? byLine : a.order.compareTo(b.order);
  });
  return ordered.map((cue) => cue.text).toList();
}

class _OrderedCue {
  const _OrderedCue({
    required this.order,
    required this.line,
    required this.text,
  });

  final int order;
  final double line;
  final String text;
}

/// 按时间轴回放 CueGroup 的小缓冲：onCues 只在 cue 变化时到，位置
///  tick 每 500ms 到；两者拼起来才能在偏移与 seek 后都取到正确的组。
/// 只认单媒体时间轴（TvboxPlayerView 每次 open 只放一个 MediaItem）。
class ExoSubtitleBuffer {
  static const _maxGroups = 32;

  final List<ExoSubtitleGroup> _groups = [];

  void push(ExoSubtitleGroup group) {
    var index = _groups.length;
    while (index > 0 &&
        _groups[index - 1].presentationTimeUs > group.presentationTimeUs) {
      index--;
    }
    if (index < _groups.length &&
        _groups[index].presentationTimeUs == group.presentationTimeUs) {
      _groups[index] = group;
    } else {
      _groups.insert(index, group);
    }
    while (_groups.length > _maxGroups) {
      _groups.removeAt(0);
    }
  }

  /// 取 [positionMs] 时刻应显示的 cue。[offsetMs] 为正表示字幕延后
  /// 那么多毫秒（显示更早时刻的组），为负表示提前；默认 0 自动对齐。
  List<ExoSubtitleCue> activeCuesAt(int positionMs, {int offsetMs = 0}) {
    final targetUs = (positionMs - offsetMs) * 1000;
    ExoSubtitleGroup? active;
    for (final group in _groups) {
      if (group.presentationTimeUs <= targetUs) {
        active = group;
      } else {
        break;
      }
    }
    return active?.cues ?? const [];
  }

  void clear() => _groups.clear();
}

/// Exo 字幕叠加层：与 media_kit SubtitleView 同款画法——多行拼成
/// 一个居中 Text、半透明黑底、字号按画面积缩放，天然不重叠。
/// [bottomPadding] 须盖过 TvboxVideoPane 底部控制条（约 68px）。
class ExoSubtitleOverlay extends StatelessWidget {
  const ExoSubtitleOverlay({
    super.key,
    required this.lines,
    this.bottomPadding = 72,
  });

  final List<String> lines;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final visible = lines.where((line) => line.trim().isNotEmpty).toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final area = constraints.maxWidth * constraints.maxHeight;
          const reference = 1920.0 * 1080.0;
          final scale = area.isFinite && area > 0
              ? math.sqrt((area / reference).clamp(0.0, 1.0))
              : 1.0;
          return Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, bottomPadding),
              child: Text(
                visible.join('\n'),
                textAlign: TextAlign.center,
                textScaler: TextScaler.linear(scale),
                style: const TextStyle(
                  height: 1.4,
                  fontSize: 32.0,
                  color: Color(0xffffffff),
                  backgroundColor: Color(0xaa000000),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
