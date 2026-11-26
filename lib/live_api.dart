import 'dart:convert';

import 'live_models.dart';

enum LiveApiPlayKind { direct, bilibili, huya, passthrough }

class LiveApiSpec {
  const LiveApiSpec({
    required this.id,
    required this.listUrl,
    this.listPaths = const ['data.list', 'list', 'data'],
    this.titleKeys = const ['title'],
    this.nameKeys = const ['uname', 'nick', 'username'],
    this.coverKeys = const ['cover'],
    this.idKeys = const ['roomid', 'roomId', 'id'],
    this.playKeys = const ['playUrl', 'streamUrl', 'hlsUrl', 'url'],
    this.playUrl = '',
    this.playKind = LiveApiPlayKind.direct,
    this.playPaths = const ['data.url', 'url'],
    this.platformsUrl = '',
    this.platformPaths = const ['data'],
    this.platformIdKey = 'id',
    this.platformNameKey = 'name',
    this.platformParentKey = 'parent_id',
    this.platformChildKey = 'list',
    this.flattenPlatforms = false,
    this.derivePlatformName = false,
    this.deriveNameKey = 'gameFullName',
    this.deriveCountPath = 'data.totalCount',
    this.singlePlatformId = 'all',
    this.singlePlatformName = '全部',
    this.paginated = false,
    this.headers = const {},
  });

  final String id;
  final String listUrl;
  final List<String> listPaths;
  final List<String> titleKeys;
  final List<String> nameKeys;
  final List<String> coverKeys;
  final List<String> idKeys;
  final List<String> playKeys;
  final String playUrl;
  final LiveApiPlayKind playKind;
  final List<String> playPaths;
  final String platformsUrl;
  final List<String> platformPaths;
  final String platformIdKey;
  final String platformNameKey;
  final String platformParentKey;
  final String platformChildKey;
  final bool flattenPlatforms;
  final bool derivePlatformName;
  final String deriveNameKey;
  final String deriveCountPath;
  final String singlePlatformId;
  final String singlePlatformName;
  final bool paginated;
  final Map<String, String> headers;

  String listUrlFor(LivePlatform platform, {int page = 1}) => listUrl
      .replaceAll('{platform}', platform.id)
      .replaceAll('{endpoint}', platform.endpoint)
      .replaceAll('{page}', '$page');

  String playUrlFor(String roomId) =>
      playUrl.replaceAll('{id}', Uri.encodeComponent(roomId));
}

const liveApiSpecs = <String, LiveApiSpec>{
  'bilibili': LiveApiSpec(
    id: 'bilibili',
    listUrl:
        'https://api.live.bilibili.com/room/v3/area/getRoomList?area_id={platform}&parent_area_id={endpoint}&page={page}&page_size=30',
    listPaths: ['data.list'],
    titleKeys: ['title'],
    nameKeys: ['uname'],
    coverKeys: ['cover'],
    idKeys: ['roomid'],
    playKeys: [],
    playUrl:
        'https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo?room_id={id}&protocol=0,1&format=0,1,2&codec=0,1&qn=10000&platform=web&ptype=8',
    playKind: LiveApiPlayKind.bilibili,
    platformsUrl: 'https://api.live.bilibili.com/room/v1/Area/getList',
    platformPaths: ['data'],
    flattenPlatforms: true,
    paginated: true,
    headers: {'Referer': 'https://live.bilibili.com/'},
  ),
  // 虎牙：www 主机的 cache.php 列表（m.huya.com 回错误页，不用）；
  // 播放取房间页 HTML 里 hyPlayerConfig.stream 的内嵌 JSON，
  // 用页面自带的 anticode 拼 FLV 地址（见 _huyaPlayUrl）。
  'huya': LiveApiSpec(
    id: 'huya',
    listUrl:
        'https://www.huya.com/cache.php?m=LiveList&do=getLiveListByPage&gameId=0&page={page}',
    listPaths: ['data.datas'],
    titleKeys: ['introduction', 'roomName'],
    nameKeys: ['nick'],
    coverKeys: ['screenshot'],
    idKeys: ['profileRoom'],
    playKeys: [],
    playUrl: 'https://www.huya.com/{id}',
    playKind: LiveApiPlayKind.huya,
    paginated: true,
    headers: {'Referer': 'https://www.huya.com/'},
  ),
  // Stripchat：前台公开列表接口（blocks 首块的 models），
  // 播放地址按主播 id 直拼 doppiocdn 的 HLS 主列表，不另取流。
  'stripchat': LiveApiSpec(
    id: 'stripchat',
    listUrl: 'https://stripchat.com/api/front/v2/models?limit=60&primaryTag=girls',
    listPaths: ['blocks.0.models'],
    titleKeys: ['username'],
    nameKeys: ['username'],
    coverKeys: [],
    idKeys: ['id'],
    playKeys: [],
    playUrl: 'https://edge-hls.doppiocdn.com/hls/{id}/master/{id}.m3u8',
    playKind: LiveApiPlayKind.passthrough,
    headers: {'Referer': 'https://stripchat.com/'},
  ),
  // Cam4：目录 JSON 的 users 自带 hlsPreviewUrl（HLS 预览即公开直播流）。
  'cam4': LiveApiSpec(
    id: 'cam4',
    listUrl:
        'https://www.cam4.com/directoryCams?directoryJson=true&online=true&url=/directoryCams',
    listPaths: ['users'],
    titleKeys: ['username'],
    nameKeys: ['username'],
    coverKeys: ['profileImageLink', 'snapshotImageLink'],
    idKeys: ['username'],
    playKeys: ['hlsPreviewUrl'],
    headers: {'Referer': 'https://www.cam4.com/'},
  ),
};

LiveApiSpec? liveApiSpecById(String id) => liveApiSpecs[id];

/// 待接入：已从绿果鉴包里提出地址，但列表或播放接口未完整还原，
/// 暂不登记为内置源，等接口补齐后再翻为可用。
const pendingLiveApiSources = <String, String>{
  'douyu': '列表接口需有效的分类号（type=1 回“分类信息不存在”），取流需加密签名。',
  'yy': '只有站址，没有列表与播放接口。',
  'netease_cc': '分类列表已验活，房间列表接口未还原。',
  'chaturbate': '房间列表匿名调被 302 拦回首页，需登录会话。',
  'myfreecams': 'FcwExtResp.php 已 404，modelobject.php 未验。',
  'bongacams': 'listing_v3.php 匿名调只回 null，需补参数。',
  'livejasmin': 'front models 路径的宿主未证实。',
  'flirt4free': '只有站址，没有列表与播放接口。',
  'secretfriends': '只有站址，没有列表与播放接口。',
  'sinparty': '只有 WebRTC 播放地址，当前播放器不接 WebRTC。',
  'hotica': 'api.hotica.com 匿名调回空响应。',
  'uu': '只有一个类名，没有任何地址。',
};

dynamic _atPath(dynamic node, String path) {
  dynamic current = node;
  for (final part in path.split('.')) {
    if (current is Map) {
      current = current[part];
    } else if (current is List) {
      final index = int.tryParse(part);
      if (index == null || index < 0 || index >= current.length) return null;
      current = current[index];
    } else {
      return null;
    }
    if (current == null) return null;
  }
  return current;
}

List<dynamic> _findList(dynamic decoded, List<String> paths) {
  for (final path in paths) {
    final value = _atPath(decoded, path);
    if (value is List) return value;
  }
  return const [];
}

String _pickString(Map row, List<String> keys) {
  for (final key in keys) {
    final value = row[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is num) return '$value';
  }
  return '';
}

dynamic _decodeJson(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

List<LivePlatform> parseApiPlatforms(LiveApiSpec spec, String text) {
  final decoded = _decodeJson(text);
  if (decoded == null) return const [];
  final rows = _findList(decoded, spec.platformPaths);
  final result = <LivePlatform>[];
  for (final row in rows.whereType<Map>()) {
    if (spec.flattenPlatforms) {
      final parentId = _pickString(row, [spec.platformIdKey]);
      final children = row[spec.platformChildKey];
      if (children is List) {
        for (final child in children.whereType<Map>()) {
          final id = _pickString(child, [spec.platformIdKey]);
          final name = _pickString(child, [spec.platformNameKey]);
          if (id.isEmpty || name.isEmpty) continue;
          result.add(LivePlatform(id: id, name: name, endpoint: parentId));
        }
      }
      continue;
    }
    final id = _pickString(row, [spec.platformIdKey]);
    final name = _pickString(row, [spec.platformNameKey]);
    if (id.isEmpty || name.isEmpty) continue;
    result.add(LivePlatform(id: id, name: name));
  }
  return result;
}

String deriveApiPlatformName(LiveApiSpec spec, String text) {
  final decoded = _decodeJson(text);
  if (decoded == null) return spec.singlePlatformName;
  final rows = _findList(decoded, spec.listPaths);
  final first = rows.whereType<Map>().firstOrNull;
  if (first == null) return spec.singlePlatformName;
  final name = _pickString(first, [spec.deriveNameKey]);
  return name.isEmpty ? spec.singlePlatformName : name;
}

int deriveApiPlatformCount(LiveApiSpec spec, String text) {
  final decoded = _decodeJson(text);
  if (decoded == null) return 0;
  final value = _atPath(decoded, spec.deriveCountPath);
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? 0;
}

List<LiveChannel> parseApiChannels(
  LiveApiSpec spec,
  LivePlatform platform,
  String text,
  String sourceId,
) {
  final decoded = _decodeJson(text);
  if (decoded == null) return const [];
  final rows = _findList(decoded, spec.listPaths);
  final result = <LiveChannel>[];
  var number = 0;
  for (final row in rows.whereType<Map>()) {
    final title = _pickString(row, spec.titleKeys);
    if (title.isEmpty) continue;
    final roomId = _pickString(row, spec.idKeys);
    final play = _pickString(row, spec.playKeys);
    final playable = play.isNotEmpty && isPlayableLiveUrl(play);
    number++;
    result.add(
      LiveChannel(
        key: LiveChannel.makeKey(sourceId, platform.name, title),
        name: title,
        urls: playable ? [play] : const [],
        number: number.toString().padLeft(3, '0'),
        // token  carries the room id so playback can resolve it later.
        token: roomId,
        headers: spec.headers,
        logo: _pickString(row, spec.coverKeys),
        group: platform.name,
        source: sourceId,
        subtitle: _pickString(row, spec.nameKeys),
      ),
    );
  }
  return result;
}

String? parseApiPlayUrl(LiveApiSpec spec, String text) {
  // 虎牙的取流输入是房间页 HTML 而不是 JSON，单独走文本解析。
  if (spec.playKind == LiveApiPlayKind.huya) return _huyaPlayUrl(text);
  final decoded = _decodeJson(text);
  if (decoded == null) return null;
  switch (spec.playKind) {
    case LiveApiPlayKind.bilibili:
      return _bilibiliPlayUrl(decoded);
    case LiveApiPlayKind.direct:
      for (final path in spec.playPaths) {
        final value = _atPath(decoded, path);
        if (value is String && isPlayableLiveUrl(value)) return value.trim();
      }
      return null;
    case LiveApiPlayKind.huya:
    case LiveApiPlayKind.passthrough:
      return null;
  }
}

/// 从虎牙房间页 HTML 里取播放地址：页面脚本 hyPlayerConfig 的
/// stream 字段是内嵌 JSON，data[0].gameStreamInfoList 给出各 CDN 的
/// FLV 基址、流名与页面自带的 anticode（服务端按本次页面生成、
/// 短时有效，取流时现抓现用），拼成完整 FLV 地址。
String? _huyaPlayUrl(String html) {
  final configAt = html.indexOf('hyPlayerConfig');
  if (configAt < 0) return null;
  final streamAt = html.indexOf('stream:', configAt);
  if (streamAt < 0) return null;
  final objectAt = html.indexOf('{', streamAt);
  if (objectAt < 0) return null;
  final objectText = _balancedObject(html, objectAt);
  if (objectText == null) return null;
  final decoded = _decodeJson(objectText);
  if (decoded is! Map) return null;
  final data = decoded['data'];
  if (data is! List || data.isEmpty) return null;
  final first = data.first;
  if (first is! Map) return null;
  final infos = first['gameStreamInfoList'];
  if (infos is! List) return null;
  Map? chosen;
  for (final info in infos.whereType<Map>()) {
    final base = '${info['sFlvUrl'] ?? ''}'.trim();
    if (base.isEmpty) continue;
    chosen ??= info;
    if (info['iIsMaster'] == 1) {
      chosen = info;
      break;
    }
  }
  if (chosen == null) return null;
  final base = '${chosen['sFlvUrl']}'.trim();
  final name = '${chosen['sStreamName'] ?? ''}'.trim();
  final suffix = '${chosen['sFlvUrlSuffix'] ?? ''}'.trim();
  final anticode = '${chosen['sFlvAntiCode'] ?? ''}'.trim();
  if (name.isEmpty || anticode.isEmpty) return null;
  final url = '$base/$name.${suffix.isEmpty ? 'flv' : suffix}?$anticode';
  return isPlayableLiveUrl(url) ? url : null;
}

/// 从 [start]（指向 '{'）起按括号配平截出整个 JSON 对象文本，
/// 跳过字符串内部的括号与转义；配不平返回 null。
String? _balancedObject(String text, int start) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < text.length; i++) {
    final ch = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) return text.substring(start, i + 1);
    }
  }
  return null;
}

String? _bilibiliPlayUrl(dynamic decoded) {
  final streams = _atPath(decoded, 'data.playurl_info.playurl.stream');
  if (streams is! List) return null;
  String? fallback;
  for (final stream in streams.whereType<Map>()) {
    final protocol = '${stream['protocol_name'] ?? ''}';
    final formats = stream['format'];
    if (formats is! List) continue;
    for (final format in formats.whereType<Map>()) {
      final formatName = '${format['format_name'] ?? ''}';
      final codecs = format['codec'];
      if (codecs is! List) continue;
      for (final codec in codecs.whereType<Map>()) {
        final base = '${codec['base_url'] ?? ''}';
        if (base.isEmpty) continue;
        final infos = codec['url_info'];
        if (infos is! List) continue;
        for (final info in infos.whereType<Map>()) {
          final host = '${info['host'] ?? ''}'.trim();
          if (host.isEmpty) continue;
          final extra = '${info['extra'] ?? ''}';
          final url = '$host$base$extra';
          if (!isPlayableLiveUrl(url)) continue;
          final preferred =
              protocol == 'http_hls' &&
              formatName == 'ts' &&
              '${codec['codec_name'] ?? ''}' == 'avc';
          if (preferred) return url;
          fallback ??= url;
        }
      }
    }
  }
  return fallback;
}

