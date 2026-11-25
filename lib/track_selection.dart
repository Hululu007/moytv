/// 音轨/字幕轨切换 + 外挂字幕的纯逻辑层（第 8 点）。
///
/// 只做三件事，全是纯函数/不可变模型，方便单测：
/// 1. [SubtitleSource] 与 [parseSubtitleSources]：把播放结果里的
///    `subs` 字段（源给的字幕列表）归一成强类型列表；
/// 2. [chooseDefaultSubtitle]：外挂字幕的默认选择规则；
/// 3. [TrackChoice]/[TrackMenuEntry] 与两个 build 函数：把播放器
///    当前轨道列表映射成菜单条目模型，UI 只负责渲染与回调用。
library;

/// 一条外挂字幕（来自播放结果的 `subs` 字段）。
class SubtitleSource {
  const SubtitleSource({
    required this.url,
    this.name = '',
    this.lang = '',
    this.format = '',
  });

  final String url;
  final String name;
  final String lang;

  /// 字幕格式：srt / vtt / ass / ssa / ttml 等小写扩展名；源没给时
  /// 由地址扩展名推断，推不出为空串。
  final String format;

  String get label {
    if (name.isNotEmpty) return name;
    if (lang.isNotEmpty) return lang;
    return '外挂字幕';
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    if (name.isNotEmpty) 'name': name,
    if (lang.isNotEmpty) 'lang': lang,
    if (format.isNotEmpty) 'format': format,
  };

  @override
  bool operator ==(Object other) =>
      other is SubtitleSource &&
      other.url == url &&
      other.name == name &&
      other.lang == lang &&
      other.format == format;

  @override
  int get hashCode => Object.hash(url, name, lang, format);
}

String _text(Object? value) => value?.toString().trim() ?? '';

/// 由字幕地址推断格式（只看路径尾部扩展名，忽略查询串）。
String inferSubtitleFormat(String url) {
  var path = url.trim();
  final query = path.indexOf('?');
  if (query >= 0) path = path.substring(0, query);
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return '';
  final ext = path.substring(dot + 1).toLowerCase();
  return const {'srt', 'vtt', 'ass', 'ssa', 'ttml', 'xml', 'lrc'}.contains(ext)
      ? ext
      : '';
}

/// 归一一条 subs 元素；形态不合法（无地址）时返回 null。
SubtitleSource? _subtitleFrom(Object? row) {
  if (row is String) {
    final url = row.trim();
    if (url.isEmpty) return null;
    return SubtitleSource(url: url, format: inferSubtitleFormat(url));
  }
  if (row is! Map) return null;
  final map = Map<String, dynamic>.from(row);
  final url = _text(map['url'] ?? map['v'] ?? map['src'] ?? map['address']);
  if (url.isEmpty) return null;
  var format = _text(map['format'] ?? map['type']).toLowerCase();
  if (format.startsWith('.')) format = format.substring(1);
  if (format.isEmpty) format = inferSubtitleFormat(url);
  return SubtitleSource(
    url: url,
    name: _text(map['name'] ?? map['n'] ?? map['title']),
    lang: _text(map['lang'] ?? map['language']),
    format: format,
  );
}

/// 解析播放结果的 `subs` 字段：数组元素认对象
/// `{url, name, lang, format}`（含 n/v 等别名）与裸地址字符串；
/// 非数组/空一律回空列表，同地址去重保序。
List<SubtitleSource> parseSubtitleSources(Object? raw) {
  if (raw is! List) return const [];
  final seen = <String>{};
  final out = <SubtitleSource>[];
  for (final row in raw) {
    final sub = _subtitleFrom(row);
    if (sub == null) continue;
    if (!seen.add(sub.url)) continue;
    out.add(sub);
  }
  return out;
}

/// 默认字幕语言偏好（小写前缀匹配）：中文优先。
const defaultSubtitleLanguagePreference = [
  'zh',
  'chi',
  'zho',
  'chs',
  'cht',
  'cn',
  '中文',
];

bool _langMatches(String lang, String pref) {
  final value = lang.trim().toLowerCase();
  if (value.isEmpty) return false;
  return value == pref || value.startsWith(pref);
}

/// 外挂字幕默认选择规则（写清，测试锁死）：
/// 1. 按 [preferredLanguages] 顺序，找第一条 lang 命中的字幕；
/// 2. 没有 lang 命中时，找第一条名字含「中文/简体/繁体」的字幕；
/// 3. 都没有时选第一条；
/// 4. 列表为空回 -1（不挂字幕）。
int chooseDefaultSubtitle(
  List<SubtitleSource> subs, {
  List<String> preferredLanguages = defaultSubtitleLanguagePreference,
}) {
  if (subs.isEmpty) return -1;
  for (final pref in preferredLanguages) {
    for (var i = 0; i < subs.length; i++) {
      if (_langMatches(subs[i].lang, pref) ||
          _langMatches(subs[i].name, pref)) {
        return i;
      }
    }
  }
  for (var i = 0; i < subs.length; i++) {
    final name = subs[i].name;
    if (name.contains('中文') || name.contains('简体') || name.contains('繁体')) {
      return i;
    }
  }
  return 0;
}

/// 播放器当前轨道的一条（从 media_kit Tracks 映射过来的纯模型）。
class TrackChoice {
  const TrackChoice({required this.id, this.title = '', this.language = ''});

  final String id;
  final String title;
  final String language;

  String label(String kind, int index) {
    if (title.isNotEmpty) return title;
    if (language.isNotEmpty) return language;
    return '$kind ${index + 1}';
  }
}

enum TrackMenuEntryKind { audio, subtitleEmbedded, subtitleExternal, subtitleOff }

/// 菜单里的一条轨道选项。
class TrackMenuEntry {
  const TrackMenuEntry({
    required this.kind,
    required this.id,
    required this.label,
    required this.selected,
  });

  final TrackMenuEntryKind kind;

  /// audio/内嵌字幕 = 播放器轨道 id；外挂字幕 = `ext:<url>`；关闭 = `sub:no`。
  final String id;
  final String label;
  final bool selected;

  String? get externalUrl =>
      kind == TrackMenuEntryKind.subtitleExternal && id.startsWith('ext:')
      ? id.substring(4)
      : null;
}

/// 音轨菜单条目：按播放器给的顺序原样列出，标当前选中。
List<TrackMenuEntry> buildAudioTrackEntries(
  List<TrackChoice> tracks, {
  String selectedId = '',
}) => [
  for (var i = 0; i < tracks.length; i++)
    TrackMenuEntry(
      kind: TrackMenuEntryKind.audio,
      id: tracks[i].id,
      label: tracks[i].label('音轨', i),
      selected: tracks[i].id == selectedId,
    ),
];

/// 字幕菜单条目：第一条恒为「关闭字幕」，随后内嵌字幕轨，
/// 最后是源给的外挂字幕（[external]）。选中态三选一：
/// [subtitlesOff] 为真标关闭；[selectedExternalUrl] 非空标对应外挂；
/// 否则按 [selectedEmbeddedId] 标内嵌轨。
List<TrackMenuEntry> buildSubtitleTrackEntries(
  List<TrackChoice> embedded, {
  List<SubtitleSource> external = const [],
  String selectedEmbeddedId = '',
  String? selectedExternalUrl,
  bool subtitlesOff = false,
}) {
  final externalSelected = !subtitlesOff && selectedExternalUrl != null;
  return [
    TrackMenuEntry(
      kind: TrackMenuEntryKind.subtitleOff,
      id: 'sub:no',
      label: '关闭字幕',
      selected: subtitlesOff,
    ),
    for (var i = 0; i < embedded.length; i++)
      TrackMenuEntry(
        kind: TrackMenuEntryKind.subtitleEmbedded,
        id: embedded[i].id,
        label: embedded[i].label('字幕', i),
        selected:
            !subtitlesOff &&
            !externalSelected &&
            embedded[i].id == selectedEmbeddedId,
      ),
    for (final sub in external)
      TrackMenuEntry(
        kind: TrackMenuEntryKind.subtitleExternal,
        id: 'ext:${sub.url}',
        label: sub.label,
        selected: externalSelected && sub.url == selectedExternalUrl,
      ),
  ];
}
