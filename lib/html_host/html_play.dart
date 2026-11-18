import 'package:flutter/material.dart';

import '../miniapp/haikuo/haikuo_runner_page.dart';
import '../nonvideo_content.dart';

/// fm.play / fm.vodInline 载荷里的一集：标题 + 直链 + 可选头。
class HtmlPlayEpisode {
  const HtmlPlayEpisode({
    required this.name,
    required this.url,
    this.headers = const {},
  });

  final String name;
  final String url;
  final Map<String, String> headers;
}

/// 解析器型选集：v1 不支持（须回页面再求值），诚实报错，不静默跳过。
class HtmlResolverUnsupported implements Exception {
  const HtmlResolverUnsupported([this.message = 'resolver episodes are not supported']);
  final String message;

  @override
  String toString() => message;
}

Map<String, String> _stringHeaders(dynamic value) {
  if (value is! Map) return const {};
  final headers = <String, String>{};
  value.forEach((key, item) {
    if (item != null) headers[key.toString()] = item.toString();
  });
  return headers;
}

/// 解析 `name$url#name2$url2` 形 vod_play_url 串（TVBox 老格式兜底）。
List<HtmlPlayEpisode> parseHtmlVodPlayUrl(
  String text, {
  Map<String, String> defaultHeaders = const {},
}) {
  final episodes = <HtmlPlayEpisode>[];
  var index = 0;
  for (final part in text.split('#')) {
    index++;
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    final dollar = trimmed.indexOf('\$');
    if (dollar > 0) {
      final name = trimmed.substring(0, dollar).trim();
      final url = trimmed.substring(dollar + 1).trim();
      if (url.isEmpty) continue;
      episodes.add(
        HtmlPlayEpisode(
          name: name.isEmpty ? '第$index集' : name,
          url: url,
          headers: defaultHeaders,
        ),
      );
    } else {
      episodes.add(
        HtmlPlayEpisode(
          name: '第$index集',
          url: trimmed,
          headers: defaultHeaders,
        ),
      );
    }
  }
  return episodes;
}

void _checkResolver(Map map) {
  // mediaUrl 是已解析好的真实地址，有它不再回调解析器。
  if ((map['mediaUrl'] ?? '').toString().trim().isNotEmpty) return;
  final resolver = map['resolver'];
  if (resolver != null &&
      !(resolver is String && resolver.trim().isEmpty) &&
      !(resolver is bool && !resolver)) {
    throw const HtmlResolverUnsupported();
  }
  // 指南 §5 的字段名是 resolve（布尔）：true 表示点集才回调页面解析。
  final resolve = map['resolve'];
  if (resolve == true ||
      (resolve is String && resolve.trim().isNotEmpty)) {
    throw const HtmlResolverUnsupported();
  }
}

List<HtmlPlayEpisode> _episodesFromList(
  List list, {
  Map<String, String> defaultHeaders = const {},
}) {
  final episodes = <HtmlPlayEpisode>[];
  var index = 0;
  for (final item in list) {
    index++;
    if (item is Map) {
      _checkResolver(item);
      final url =
          (item['mediaUrl'] ?? item['url'] ?? item['playUrl'] ?? item['src'] ?? '')
              .toString()
              .trim();
      if (url.isEmpty) continue;
      final name =
          (item['name'] ?? item['title'] ?? '').toString().trim();
      episodes.add(
        HtmlPlayEpisode(
          name: name.isEmpty ? '第$index集' : name,
          url: url,
          headers: {...defaultHeaders, ..._stringHeaders(item['headers'])},
        ),
      );
    } else if (item is String) {
      final trimmed = item.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.contains('#') && trimmed.contains('\$')) {
        episodes.addAll(
          parseHtmlVodPlayUrl(trimmed, defaultHeaders: defaultHeaders),
        );
      } else {
        final dollar = trimmed.indexOf('\$');
        if (dollar > 0) {
          episodes.add(
            HtmlPlayEpisode(
              name: trimmed.substring(0, dollar).trim(),
              url: trimmed.substring(dollar + 1).trim(),
              headers: defaultHeaders,
            ),
          );
        } else {
          episodes.add(
            HtmlPlayEpisode(
              name: '第$index集',
              url: trimmed,
              headers: defaultHeaders,
            ),
          );
        }
      }
    }
  }
  return episodes;
}

/// 选集载荷解析：`List<Map>` / `List<String>` / vod_play_url 串 /
/// `{name: url}` 映射 / 含 episodes|list|urls|url 的对象。
/// 无可播地址时抛 FormatException；解析器型抛 HtmlResolverUnsupported。
List<HtmlPlayEpisode> parseHtmlPlayEpisodes(
  dynamic input, {
  Map<String, String> defaultHeaders = const {},
}) {
  final episodes = _episodesFromInput(input, defaultHeaders: defaultHeaders);
  if (episodes.isEmpty) {
    throw const FormatException('no playable url in payload');
  }
  return episodes;
}

List<HtmlPlayEpisode> _episodesFromInput(
  dynamic input, {
  Map<String, String> defaultHeaders = const {},
}) {
  if (input is List) {
    return _episodesFromList(input, defaultHeaders: defaultHeaders);
  }
  if (input is String) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return const [];
    if (trimmed.contains('#') || trimmed.contains('\$')) {
      return parseHtmlVodPlayUrl(trimmed, defaultHeaders: defaultHeaders);
    }
    return [
      HtmlPlayEpisode(name: '正片', url: trimmed, headers: defaultHeaders),
    ];
  }
  if (input is Map) {
    _checkResolver(input);
    for (final key in const ['episodes', 'list', 'urls']) {
      if (input[key] != null) {
        return _episodesFromInput(
          input[key],
          defaultHeaders: defaultHeaders,
        );
      }
    }
    final direct =
        (input['mediaUrl'] ?? input['url'] ?? input['playUrl'] ?? input['src'] ?? '')
            .toString()
            .trim();
    if (direct.isNotEmpty) {
      final name = (input['name'] ?? input['title'] ?? '').toString().trim();
      return [
        HtmlPlayEpisode(
          name: name.isEmpty ? '正片' : name,
          url: direct,
          headers: {...defaultHeaders, ..._stringHeaders(input['headers'])},
        ),
      ];
    }
    // {name: url} 映射形：只认带协议的值，元数据键不参与
    // （否则 {'title': 'x'} 会被误当成一集）。
    const metadataKeys = {
      'title',
      'name',
      'headers',
      'index',
      'initialIndex',
      'subtitle',
      'subtitleUrl',
      'resolver',
      'resolve',
      'mediaUrl',
      'line',
      'episodes',
      'list',
      'urls',
      'url',
      'playUrl',
      'src',
      'vod_id',
      'vod_name',
      'vod_pic',
      'vod_content',
      'vod_class',
      'vod_play_from',
      'vod_play_url',
    };
    final episodes = <HtmlPlayEpisode>[];
    input.forEach((key, value) {
      if (metadataKeys.contains(key.toString())) return;
      if (value is String) {
        final url = value.trim();
        if (url.isNotEmpty && url.contains('://')) {
          episodes.add(
            HtmlPlayEpisode(
              name: key.toString(),
              url: url,
              headers: defaultHeaders,
            ),
          );
        }
      }
    });
    return episodes;
  }
  return const [];
}

/// 一次播放请求：解析后的选集 + 标题/头/字幕/起播集。
class HtmlPlayRequest {
  const HtmlPlayRequest({
    required this.episodes,
    this.initialIndex = 0,
    this.title = '',
    this.headers = const {},
    this.subtitleUrl = '',
  });

  final List<HtmlPlayEpisode> episodes;
  final int initialIndex;
  final String title;
  final Map<String, String> headers;
  final String subtitleUrl;
}

HtmlPlayRequest parseHtmlPlayPayload(
  dynamic payload, {
  Map<String, String> defaultHeaders = const {},
}) {
  final headers = {...defaultHeaders};
  String title = '';
  String subtitleUrl = '';
  var initialIndex = 0;
  var hasExplicitIndex = false;
  String mark = '';
  dynamic episodeInput = payload;
  if (payload is Map) {
    _checkResolver(payload);
    headers.addAll(_stringHeaders(payload['headers']));
    title = (payload['title'] ?? payload['name'] ?? payload['vod_name'] ?? '')
        .toString()
        .trim();
    subtitleUrl =
        (payload['subtitle'] ?? payload['subtitleUrl'] ?? '').toString().trim();
    final rawIndex = payload['index'] ?? payload['initialIndex'];
    if (rawIndex is num) {
      initialIndex = rawIndex.toInt();
      hasExplicitIndex = true;
    }
    mark = (payload['mark'] ?? '').toString().trim();
    episodeInput =
        payload['episodes'] ?? payload['list'] ?? payload['urls'] ?? payload;
    if (episodeInput is List && episodeInput.isEmpty) episodeInput = payload;
    if (identical(episodeInput, payload)) {
      // 只有 vod_play_url 串、没有 episodes 列表时（如指南 §5 的
      // vodInline 载荷简写），按 $$$ 分线路展平成选集。
      final playUrl = payload['vod_play_url'];
      if (playUrl is String && playUrl.trim().isNotEmpty) {
        episodeInput = playUrl.split('\$\$\$');
      }
    }
  }
  final episodes = parseHtmlPlayEpisodes(
    episodeInput,
    defaultHeaders: headers,
  );
  if (episodes.isEmpty) {
    throw const FormatException('no playable url in payload');
  }
  if (!hasExplicitIndex && episodeInput is List) {
    final marked = _initialIndexFromMarkers(episodeInput, episodes, mark);
    if (marked != null) initialIndex = marked;
  }
  if (initialIndex < 0) initialIndex = 0;
  if (initialIndex >= episodes.length) initialIndex = episodes.length - 1;
  return HtmlPlayRequest(
    episodes: episodes,
    initialIndex: initialIndex,
    title: title,
    headers: headers,
    subtitleUrl: subtitleUrl,
  );
}

/// mark/active 起播集：按集名匹配（active 优先于 mark）；
// 找不到名字匹配时返回 null（起播集保持默认 0）。
int? _initialIndexFromMarkers(
  List input,
  List<HtmlPlayEpisode> episodes,
  String mark,
) {
  var target = mark;
  for (final item in input) {
    if (item is Map && item['active'] == true) {
      final name = (item['name'] ?? item['label'] ?? item['title'] ?? '')
          .toString()
          .trim();
      if (name.isNotEmpty) target = name;
      break;
    }
  }
  if (target.isEmpty) return null;
  for (var i = 0; i < episodes.length; i++) {
    if (episodes[i].name == target) return i;
  }
  return null;
}

/// 播放入口：按首集地址分流——novel:// 与 pics:// 进阅读/看图页，
/// 其余进海阔播放器壳（直链 + 选集控制器，与海阔运行时同款接线）。
Widget buildHtmlPlayPage(
  HtmlPlayRequest request, {
  ValueChanged<Map<String, dynamic>>? onStateChange,
}) {
  final first = request.episodes[request.initialIndex];
  final nonVideo = parseNonVideoUrl(first.url, headers: first.headers);
  if (nonVideo != null) {
    return HtmlNonVideoPage(request: request, onStateChange: onStateChange);
  }
  final controller = HaikuoPlayerController();
  final episodes = request.episodes;
  Future<bool> selectEpisode(int index) async {
    if (index < 0 || index >= episodes.length) return false;
    final episode = episodes[index];
    if (parseNonVideoUrl(episode.url, headers: episode.headers) != null) {
      return false;
    }
    controller.deliver(
      url: episode.url,
      title: episode.name,
      index: index,
      subtitleUrl: request.subtitleUrl,
      headers: episode.headers,
    );
    return true;
  }

  return HaikuoPlayPage(
    url: first.url,
    title: first.name,
    seriesTitle: request.title,
    episodes: [for (final episode in episodes) episode.name],
    initialIndex: request.initialIndex,
    controller: controller,
    onSelectEpisode: selectEpisode,
    headers: first.headers,
    subtitleUrl: request.subtitleUrl,
    onStateChange: onStateChange,
  );
}

/// fm.vod 载荷：一条线路（名 + 选集）。
class HtmlVodLine {
  const HtmlVodLine({required this.name, required this.episodes});

  final String name;
  final List<HtmlPlayEpisode> episodes;
}

/// fm.vod 详情：标题/海报/简介/分类 + 线路表。载荷自带全部数据，
/// 壳无引擎可查——只有 vodId 没有可播内容时解析即失败，诚实报错。
class HtmlVodDetail {
  const HtmlVodDetail({
    required this.title,
    required this.pic,
    required this.description,
    required this.category,
    required this.lines,
  });

  final String title;
  final String pic;
  final String description;
  final String category;
  final List<HtmlVodLine> lines;

  List<HtmlPlayEpisode> get allEpisodes => [
    for (final line in lines) ...line.episodes,
  ];
}

/// 解析 fm.vod 载荷（TVBox vod 字段 + episodes 列表 + 直链）。
/// 无可播内容时抛 FormatException；解析器型抛 HtmlResolverUnsupported。
HtmlVodDetail parseHtmlVodPayload(Map<String, dynamic> payload) {
  _checkResolver(payload);
  final title =
      (payload['vod_name'] ?? payload['title'] ?? payload['name'] ?? '')
          .toString()
          .trim();
  final pic = (payload['vod_pic'] ?? payload['pic'] ?? payload['cover'] ?? '')
      .toString()
      .trim();
  final description =
      (payload['vod_content'] ?? payload['description'] ?? payload['content'] ?? '')
          .toString()
          .trim();
  final category =
      (payload['vod_class'] ?? payload['category'] ?? payload['type_name'] ?? '')
          .toString()
          .trim();
  final headers = _stringHeaders(payload['headers']);
  final lines = <HtmlVodLine>[];
  final episodesInput = payload['episodes'] ?? payload['list'];
  if (episodesInput != null) {
    final episodes = parseHtmlPlayEpisodes(
      episodesInput,
      defaultHeaders: headers,
    );
    if (episodes.isNotEmpty) {
      final lineName =
          (payload['vod_play_from'] ?? payload['line'] ?? '默认').toString().trim();
      lines.add(
        HtmlVodLine(
          name: lineName.isEmpty ? '默认' : lineName,
          episodes: episodes,
        ),
      );
    }
  } else {
    final playUrl = (payload['vod_play_url'] ?? payload['playUrl'] ?? '').toString();
    final playFrom = (payload['vod_play_from'] ?? '').toString();
    if (playUrl.trim().isNotEmpty) {
      final groups = playUrl.split('\$\$\$');
      final names = playFrom.isEmpty ? <String>[] : playFrom.split('\$\$\$');
      for (var i = 0; i < groups.length; i++) {
        final episodes = parseHtmlVodPlayUrl(groups[i], defaultHeaders: headers);
        if (episodes.isEmpty) continue;
        final name = i < names.length ? names[i].trim() : '';
        lines.add(
          HtmlVodLine(
            name: name.isEmpty ? '线路${i + 1}' : name,
            episodes: episodes,
          ),
        );
      }
    } else {
      final direct =
          (payload['mediaUrl'] ?? payload['url'] ?? payload['src'] ?? '')
              .toString()
              .trim();
      if (direct.isNotEmpty) {
        lines.add(
          HtmlVodLine(
            name: '默认',
            episodes: [
              HtmlPlayEpisode(name: '正片', url: direct, headers: headers),
            ],
          ),
        );
      }
    }
  }
  if (lines.isEmpty) {
    throw const FormatException('vod payload has no playable episodes');
  }
  return HtmlVodDetail(
    title: title,
    pic: pic,
    description: description,
    category: category,
    lines: lines,
  );
}

/// fm.vod 详情页：海报 + 标题 + 简介 + 线路 + 选集；点选集进播放器，
/// 不设“立即播放”按钮（与详情页点海报/选集才播的规矩一致）。
class HtmlVodDetailPage extends StatefulWidget {
  const HtmlVodDetailPage({
    super.key,
    required this.detail,
    required this.siteName,
    this.onStateChange,
  });

  final HtmlVodDetail detail;
  final String siteName;
  final ValueChanged<Map<String, dynamic>>? onStateChange;

  @override
  State<HtmlVodDetailPage> createState() => _HtmlVodDetailPageState();
}

class _HtmlVodDetailPageState extends State<HtmlVodDetailPage> {
  int _lineIndex = 0;

  void _openEpisode(int index) {
    final line = widget.detail.lines[_lineIndex];
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => buildHtmlPlayPage(
          HtmlPlayRequest(
            episodes: line.episodes,
            initialIndex: index,
            title: widget.detail.title,
          ),
          onStateChange: widget.onStateChange,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    final line = detail.lines[_lineIndex];
    return Scaffold(
      appBar: AppBar(title: Text(detail.title.isEmpty ? widget.siteName : detail.title)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (detail.pic.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      detail.pic,
                      width: 110,
                      height: 150,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox(
                        width: 110,
                        height: 150,
                        child: Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  ),
                if (detail.pic.isNotEmpty) const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        detail.title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      if (detail.category.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          detail.category,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (detail.description.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(detail.description),
            ],
            const SizedBox(height: 16),
            if (detail.lines.length > 1)
              Wrap(
                spacing: 8,
                children: [
                  for (var i = 0; i < detail.lines.length; i++)
                    ChoiceChip(
                      label: Text(detail.lines[i].name),
                      selected: i == _lineIndex,
                      onSelected: (_) => setState(() => _lineIndex = i),
                    ),
                ],
              ),
            if (detail.lines.length > 1) const SizedBox(height: 12),
            Text('选集（${line.name}）', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < line.episodes.length; i++)
                  OutlinedButton(
                    onPressed: () => _openEpisode(i),
                    child: Text(line.episodes[i].name),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 非视频内容页：小说文本 / 图片浏览，选集多于一集时可前后切集；
/// 切到视频地址的集时给一个进播放器的按钮，不静默跳过。
class HtmlNonVideoPage extends StatefulWidget {
  const HtmlNonVideoPage({
    super.key,
    required this.request,
    this.onStateChange,
  });

  final HtmlPlayRequest request;
  final ValueChanged<Map<String, dynamic>>? onStateChange;

  @override
  State<HtmlNonVideoPage> createState() => _HtmlNonVideoPageState();
}

class _HtmlNonVideoPageState extends State<HtmlNonVideoPage> {
  late int _index = widget.request.initialIndex;

  HtmlPlayEpisode get _episode => widget.request.episodes[_index];

  void _jump(int next) {
    if (next < 0 || next >= widget.request.episodes.length) return;
    setState(() => _index = next);
  }

  @override
  Widget build(BuildContext context) {
    final episode = _episode;
    final content = parseNonVideoUrl(episode.url, headers: episode.headers);
    final title = widget.request.title.isEmpty
        ? episode.name
        : '${widget.request.title} · ${episode.name}';
    final hasPrev = _index > 0;
    final hasNext = _index < widget.request.episodes.length - 1;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: '上一集',
            onPressed: hasPrev ? () => _jump(_index - 1) : null,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: '下一集',
            onPressed: hasNext ? () => _jump(_index + 1) : null,
          ),
        ],
      ),
      body: content == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('该集为视频地址'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => buildHtmlPlayPage(
                            HtmlPlayRequest(
                              episodes: widget.request.episodes,
                              initialIndex: _index,
                              title: widget.request.title,
                              headers: widget.request.headers,
                              subtitleUrl: widget.request.subtitleUrl,
                            ),
                            onStateChange: widget.onStateChange,
                          ),
                        ),
                      );
                    },
                    child: const Text('打开播放器'),
                  ),
                ],
              ),
            )
          : content.isNovel
          ? NovelReaderView(content: content, title: title)
          : PicsViewerView(content: content, title: title, verticalScroll: true),
    );
  }
}
