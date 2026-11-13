import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'haikuo_codec.dart';
import 'haikuo_program.dart';

/// 剪贴板里扫出来的一个可导入候选。
///
/// [text] 是交给现有导入链（`HaikuoStore.importText`）的原始口令文本；
/// [label] 是弹窗里显示的名字：能离线解析出规则名就用规则名，
/// 解析不出就用口令前半截。
class HaikuoClipboardCandidate {
  const HaikuoClipboardCandidate({required this.text, required this.label});

  final String text;
  final String label;
}

/// 已处理过的剪贴板摘要存取：同一内容只弹一次，重启后也不重弹。
abstract class HaikuoClipboardSeenStore {
  Future<String?> readDigest();
  Future<void> writeDigest(String digest);
}

/// 默认实现：SharedPreferences。读写失败一律吞掉（退回仅内存去重），
/// 绝不拖垮页面。
class SharedPrefsHaikuoClipboardSeenStore
    implements HaikuoClipboardSeenStore {
  static const key = 'haikuo_clipboard_seen_digest';

  @override
  Future<String?> readDigest() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeDigest(String digest) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, digest);
    } catch (_) {}
  }
}

/// 内存版：测试用。
class InMemoryHaikuoClipboardSeenStore implements HaikuoClipboardSeenStore {
  String? _digest;

  @override
  Future<String?> readDigest() async => _digest;

  @override
  Future<void> writeDigest(String digest) async {
    _digest = digest;
  }
}

/// 纯函数：从剪贴板文本里提取可导入口令候选（去重、按出现顺序）。
///
/// 只认现有导入链已支持的形态（见 `HaikuoCodec` / `HaikuoStore.importText`）：
/// 官方 ￥ 口令、`rule://`、`base64://@`、海阔深链、云口令短码、JSON。
/// 其中云口令只有云 6 能联网取回（其他云编号导入时由现有链路报明原因）；
/// 检测本身不联网、不导入，只做形态识别与名字提取。
/// 裸 http(s) 链接故意不认：剪贴板里任何链接都弹窗太骚扰，
/// 链接导入仍走手动“从链接导入”。
abstract final class HaikuoClipboardScan {
  static final _yenCodePattern = RegExp(r'[^\s]*￥[^\s]*￥[^\s]*');
  static final _ruleLinkPattern = RegExp(
    r'rule://[^\s，。、]+',
    caseSensitive: false,
  );
  static final _base64LinkPattern = RegExp(
    r'base64://[^\s，。、]+',
    caseSensitive: false,
  );
  static final _deepLinkPattern = RegExp(
    r'''(?:hiker|haikuo|haik|海阔)://[^\s，。、"',<>（）]+''',
    caseSensitive: false,
  );

  static const _trailingJunk = '，。、；：！？,.!?:;」』】)）';
  static const _maxCandidates = 50;

  static List<HaikuoClipboardCandidate> extract(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return const [];

    // 整段就是一份 JSON：只当一个候选，不再拆行找口令。
    if (HaikuoCodec.looksLikeJson(text)) {
      final programs = _tryParseJson(text);
      if (programs != null) {
        return [
          HaikuoClipboardCandidate(text: text, label: _namesLabel(programs)),
        ];
      }
    }

    final spans = <_Span>[];
    void addSpan(
      int start,
      int end,
      String value, {
      List<HaikuoProgram>? programs,
    }) {
      final cleaned = _cleanSpan(value);
      if (cleaned.isEmpty) return;
      spans.add(_Span(start, end, cleaned, programs));
    }

    for (final match in _yenCodePattern.allMatches(text)) {
      addSpan(match.start, match.end, match.group(0) ?? '');
    }
    for (final match in _ruleLinkPattern.allMatches(text)) {
      addSpan(match.start, match.end, match.group(0) ?? '');
    }
    for (final match in _base64LinkPattern.allMatches(text)) {
      addSpan(match.start, match.end, match.group(0) ?? '');
    }
    for (final match in _deepLinkPattern.allMatches(text)) {
      addSpan(match.start, match.end, match.group(0) ?? '');
    }
    for (final match in HaikuoCodec.cloudCodeMatches(text)) {
      addSpan(match.start, match.end, match.group(0) ?? '');
    }
    for (final jsonSpan in _findJsonSpans(text)) {
      spans.add(jsonSpan);
    }

    // 落在已解析 JSON 段内部的口令形态不重复算（规则 JSON 里
    // 出现 ￥/链接只是正文，不是另一条口令）；更短的 JSON 行
    // 被更长的 JSON 切片盖住时也只留切片。
    final jsonSpans = spans.where((span) => span.programs != null).toList();
    for (final json in jsonSpans) {
      spans.removeWhere(
        (span) =>
            !identical(span, json) &&
            span.start >= json.start &&
            span.end <= json.end &&
            (json.end - json.start) > (span.end - span.start),
      );
    }
    spans.sort((a, b) => a.start.compareTo(b.start));

    final seen = <String>{};
    final out = <HaikuoClipboardCandidate>[];
    for (final span in spans) {
      final value = span.text;
      if (!_looksImportable(value)) continue;
      if (!seen.add(value)) continue;
      out.add(
        HaikuoClipboardCandidate(
          text: value,
          label: span.programs != null
              ? _namesLabel(span.programs!)
              : _labelFor(value),
        ),
      );
      if (out.length >= _maxCandidates) break;
    }
    return out;
  }

  /// 剪贴板内容的摘要（去首尾空白后算 sha1，与 `HaikuoProgram.makeId`
  /// 同一算法）：同一内容只弹一次的比对依据。
  static String digestOf(String? raw) {
    final text = raw?.trim() ?? '';
    return sha1.convert(utf8.encode(text)).toString();
  }

  static bool _looksImportable(String value) {
    if (value.contains('￥')) {
      final segments = value.split('￥');
      return segments.length >= 3 && segments[2].trim().length >= 8;
    }
    final lower = value.toLowerCase();
    if (lower.startsWith('rule://')) {
      return value.length > 'rule://'.length + 8;
    }
    if (lower.contains('base64://')) return value.length >= 24;
    if (_deepLinkPattern.hasMatch(value)) return value.length >= 12;
    if (HaikuoCodec.cloudCodeMatches(value).isNotEmpty) return true;
    // JSON 段在收集时已验证过解析，这里再认一次保持口径一致。
    if (HaikuoCodec.looksLikeJson(value)) return _tryParseJson(value) != null;
    return false;
  }

  /// 名字提取：离线试解析（不联网），取规则名；解析不出就显示口令前半截。
  static String _labelFor(String span) {
    for (final candidate in HaikuoCodec.extractCandidates(span)) {
      final value = candidate.trim();
      if (value.isEmpty) continue;
      final lower = value.toLowerCase();
      if (lower.startsWith('http://') || lower.startsWith('https://')) {
        continue;
      }
      try {
        final programs = _tryParseOffline(value);
        if (programs.isNotEmpty) return _namesLabel(programs);
      } catch (_) {
        continue;
      }
    }
    return _preview(span);
  }

  /// 与 `HaikuoStore._importCandidate` 相同的离线分支（去掉联网取链接），
  /// 只为提取名字；真正导入仍走现有链路。
  static List<HaikuoProgram> _tryParseOffline(String value) {
    if (HaikuoCodec.looksLikeJson(value)) {
      return HaikuoCodec.parseText(value);
    }
    final decoded = HaikuoCodec.tryBase64(value);
    if (decoded != null && decoded.isNotEmpty) {
      return HaikuoCodec.parseBytes(decoded);
    }
    return HaikuoCodec.parseText(value);
  }

  static String _namesLabel(List<HaikuoProgram> programs) {
    final names = programs
        .map((program) => program.name.trim())
        .where((name) => name.isNotEmpty)
        .toList();
    if (names.isEmpty) return '小程序规则';
    if (names.length <= 3) return names.join('、');
    return '${names.take(3).join('、')}等 ${names.length} 个';
  }

  static String _preview(String span) {
    const maxLength = 24;
    final runes = span.runes.toList();
    if (runes.length <= maxLength) return span;
    return '${String.fromCharCodes(runes.take(maxLength))}…';
  }

  static String _cleanSpan(String value) {
    var cleaned = value.trim();
    while (cleaned.isNotEmpty &&
        _trailingJunk.contains(cleaned[cleaned.length - 1])) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    // 口令后的中文正文（如“，快导入”）不是口令的一部分：最后一个 ￥
    // 之后还带中文标点的，把尾巴截掉；口令本身以 ￥ 结尾也能正常导入。
    final lastYen = cleaned.lastIndexOf('￥');
    if (lastYen >= 0 && lastYen < cleaned.length - 1) {
      final tail = cleaned.substring(lastYen + 1);
      if (tail.contains(RegExp(r'[，。、；：！？]'))) {
        cleaned = cleaned.substring(0, lastYen + 1);
      }
    }
    return cleaned.trim();
  }

  static List<HaikuoProgram>? _tryParseJson(String text) {
    try {
      final programs = HaikuoCodec.parseJsonText(text);
      return programs.isEmpty ? null : programs;
    } catch (_) {
      return null;
    }
  }

  /// 嵌在正文里的 JSON：先试“第一个 { 或 [ 到最后一个 } 或 ]”的切片，
  /// 再逐行试单行 JSON（多条 JSON 各占一行时）。
  static List<_Span> _findJsonSpans(String text) {
    final spans = <_Span>[];
    final slice = _jsonSlice(text);
    if (slice != null) {
      final programs = _tryParseJson(slice.$3);
      if (programs != null) {
        spans.add(_Span(slice.$1, slice.$2, slice.$3, programs));
      }
    }
    var offset = 0;
    for (final line in text.split('\n')) {
      final start = text.indexOf(line, offset);
      offset = start + line.length;
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (!HaikuoCodec.looksLikeJson(trimmed)) continue;
      final programs = _tryParseJson(trimmed);
      if (programs != null) {
        spans.add(_Span(start, start + line.length, trimmed, programs));
      }
    }
    return spans;
  }

  static (int, int, String)? _jsonSlice(String text) {
    final openCurly = text.indexOf('{');
    final openSquare = text.indexOf('[');
    if (openCurly == -1 && openSquare == -1) return null;
    final int start;
    final String close;
    if (openCurly == -1 || (openSquare != -1 && openSquare < openCurly)) {
      start = openSquare;
      close = ']';
    } else {
      start = openCurly;
      close = '}';
    }
    final end = text.lastIndexOf(close);
    if (end <= start) return null;
    return (start, end + 1, text.substring(start, end + 1));
  }
}

class _Span {
  const _Span(this.start, this.end, this.text, this.programs);

  final int start;
  final int end;
  final String text;

  /// 已验证能解析出的规则（仅 JSON 段有）；名字直接取规则名，不再二次解析。
  final List<HaikuoProgram>? programs;
}
