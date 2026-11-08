import 'dart:convert';

import 'live_models.dart';

enum LiveApiPlayKind { direct, bilibili, huya }

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
  'huya': LiveApiSpec(
    id: 'huya',
    listUrl:
        'https://www.huya.com/cache.php?m=LiveList&do=getLiveListByPage&gameId={platform}&page={page}',
    listPaths: ['data.datas', 'data.list', 'data.rooms', 'data'],
    titleKeys: ['roomName', 'title'],
    nameKeys: ['nick', 'uname'],
    coverKeys: ['screenshot', 'cover'],
    idKeys: ['roomId', 'uid', 'id'],
    playKeys: [],
    playUrl:
        'https://mp.huya.com/cache.php?m=Live&do=profileRoom&roomid={id}',
    playKind: LiveApiPlayKind.huya,
    derivePlatformName: true,
    deriveNameKey: 'gameFullName',
    deriveCountPath: 'data.totalCount',
    singlePlatformId: '1',
    singlePlatformName: '虎牙直播',
    paginated: true,
    headers: {'Referer': 'https://www.huya.com/'},
  ),
  'pandalive': LiveApiSpec(
    id: 'pandalive',
    listUrl: 'https://api.pandalive.co.kr/v1/live',
    listPaths: ['list', 'data.list', 'data'],
    titleKeys: ['title', 'roomTitle', 'name'],
    nameKeys: ['userId', 'nick', 'username'],
    coverKeys: ['thumbnail', 'thumb', 'image', 'cover'],
    idKeys: ['userId', 'id', 'roomId'],
    playKeys: ['playUrl', 'streamUrl', 'hlsUrl', 'url'],
    singlePlatformName: '全部',
  ),
  'sakuralive': LiveApiSpec(
    id: 'sakuralive',
    listUrl:
        'https://chat.sakuralive.com/jsonSL/listing/freechat?guest=slen',
    listPaths: ['online_performers', 'data.online_performers'],
    titleKeys: ['name', 'username', 'title'],
    nameKeys: ['username', 'name'],
    coverKeys: ['image', 'thumb', 'cover'],
    idKeys: ['username', 'name', 'id'],
    playKeys: ['playUrl', 'streamUrl', 'hlsUrl', 'url'],
    singlePlatformName: '全部',
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
  'stripchat': '只有站址与镜像站，列表接口未还原；播放原走原 App 的 HLS 代理，不用。',
  'myfreecams': 'FcwExtResp.php 已 404，modelobject.php 未验。',
  'bongacams': 'listing_v3.php 匿名调只回 null，需补参数。',
  'cam4': 'directoryCams 片段归属未证实。',
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
  final decoded = _decodeJson(text);
  if (decoded == null) return null;
  switch (spec.playKind) {
    case LiveApiPlayKind.bilibili:
      return _bilibiliPlayUrl(decoded);
    case LiveApiPlayKind.huya:
      return _huyaPlayUrl(decoded);
    case LiveApiPlayKind.direct:
      for (final path in spec.playPaths) {
        final value = _atPath(decoded, path);
        if (value is String && isPlayableLiveUrl(value)) return value.trim();
      }
      return null;
  }
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

String? _huyaPlayUrl(dynamic decoded) {
  final candidates = <String>[];
  final stream = _atPath(decoded, 'data.stream');
  if (stream is Map) {
    for (final key in ['hls', 'flv']) {
      final entry = stream[key];
      if (entry is Map) {
        final url = '${entry['url'] ?? ''}'.trim();
        if (url.isNotEmpty) candidates.add(url);
      } else if (entry is String && entry.trim().isNotEmpty) {
        candidates.add(entry.trim());
      }
    }
  }
  for (final path in ['data.hls', 'data.flv', 'data.url', 'data.streamUrl']) {
    final value = _atPath(decoded, path);
    if (value is String && value.trim().isNotEmpty) candidates.add(value);
  }
  for (final url in candidates) {
    if (isPlayableLiveUrl(url)) return url;
  }
  return null;
}
