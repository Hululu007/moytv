import 'dart:convert';

/// 回看模板（m3u 的 catchup / catchup-source / catchup-replace）：
/// type 为 default 时 source 本身就是回看地址模板；为 append（或空）
/// 时先按 replace（「正则,替换」）改直播地址、再把 source 模板
/// 拼到地址后面。模板里 ${(b)格式} / ${(e)格式} 是节目起止时间。
/// 地址生成见 live_catchup.dart 的 formatLiveCatchupUrl。
class LiveCatchup {
  const LiveCatchup({this.type = '', this.source = '', this.replace = ''});

  final String type;
  final String source;
  final String replace;

  bool get isEmpty => source.isEmpty;

  Map<String, dynamic> toJson() => {
    'type': type,
    'source': source,
    'replace': replace,
  };

  static LiveCatchup? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final item = LiveCatchup(
      type: raw['type'] as String? ?? '',
      source: raw['source'] as String? ?? '',
      replace: raw['replace'] as String? ?? '',
    );
    return item.isEmpty ? null : item;
  }
}

class LiveChannel {
  const LiveChannel({
    required this.key,
    required this.name,
    required this.urls,
    this.number = '',
    this.headers = const {},
    this.logo = '',
    this.group = '',
    this.source = '',
    this.tvgId = '',
    this.tvgName = '',
    this.token = '',
    this.subtitle = '',
    this.catchup,
    this.licenseKey = '',
    this.licenseType = '',
    this.format = '',
  });

  final String key;
  final String name;
  final List<String> urls;
  final String number;
  final Map<String, String> headers;
  final String logo;
  final String group;
  final String source;
  final String tvgId;

  /// #EXTINF 的 tvg-name：节目单对台时 tvg-id 对不上用它按名匹配。
  final String tvgName;
  final String token;
  final String subtitle;

  /// 回看模板；null 表示该频道没声明回看。
  final LiveCatchup? catchup;

  /// #KODIPROP 的 DRM 授权键与类型：只解析存储——当前播放器
  /// （media_kit/mpv）没有 DRM 解密能力，起播时用不上，见报告。
  final String licenseKey;
  final String licenseType;

  /// 清单类型提示（#KODIPROP manifest_type / txt 的 format 设置行），
  /// 如 hls / mpd；只存储，播放器按地址自动识别，不强制。
  final String format;

  String get url => urls.isEmpty ? '' : urls.first;
  bool get playable => urls.any(isPlayableLiveUrl);
  String get label => number.isEmpty ? name : '$number  $name';

  LiveChannel withUrls(List<String> values) => LiveChannel(
    key: key,
    name: name,
    urls: values,
    number: number,
    headers: headers,
    logo: logo,
    group: group,
    source: source,
    tvgId: tvgId,
    tvgName: tvgName,
    token: token,
    subtitle: subtitle,
    catchup: catchup,
    licenseKey: licenseKey,
    licenseType: licenseType,
    format: format,
  );

  LiveChannel withPlayback(String value, Map<String, String> values) =>
      LiveChannel(
        key: key,
        name: name,
        urls: [value],
        number: number,
        headers: mergeLiveHeaders(headers, values),
        logo: logo,
        group: group,
        source: source,
        tvgId: tvgId,
        tvgName: tvgName,
        token: token,
        subtitle: subtitle,
        catchup: catchup,
        licenseKey: licenseKey,
        licenseType: licenseType,
        format: format,
      );

  static String makeKey(String source, String group, String name) =>
      '$source\u0000$group\u0000$name';

  Map<String, dynamic> toFavourite() => {
    'key': key,
    'name': name,
    'group': group,
    'source': source,
    'url': url,
    'urls': urls,
    'headers': headers,
    'logo': logo,
    'number': number,
    'token': token,
    'subtitle': subtitle,
    'tvgId': tvgId,
    'tvgName': tvgName,
    if (catchup != null) 'catchup': catchup!.toJson(),
    'licenseKey': licenseKey,
    'licenseType': licenseType,
    'format': format,
  };

  static LiveChannel fromFavourite(Map<String, dynamic> json) => LiveChannel(
    key: json['key'] as String? ?? '',
    name: json['name'] as String? ?? '',
    urls: (json['urls'] as List? ?? [json['url']])
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toList(),
    headers: (json['headers'] as Map? ?? {}).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    ),
    logo: json['logo'] as String? ?? '',
    group: json['group'] as String? ?? '',
    source: json['source'] as String? ?? '',
    number: json['number'] as String? ?? '',
    token: json['token'] as String? ?? '',
    subtitle: json['subtitle'] as String? ?? '',
    tvgId: json['tvgId'] as String? ?? '',
    tvgName: json['tvgName'] as String? ?? '',
    catchup: LiveCatchup.fromJson(json['catchup']),
    licenseKey: json['licenseKey'] as String? ?? '',
    licenseType: json['licenseType'] as String? ?? '',
    format: json['format'] as String? ?? '',
  );
}

class LiveGroup {
  const LiveGroup(this.name, this.channels);
  final String name;
  final List<LiveChannel> channels;

  int get count => channels.length;
}

class LiveLine {
  const LiveLine({
    required this.group,
    required this.channel,
    required this.index,
  });
  final String group;
  final LiveChannel channel;
  final int index;
}

class LivePlatform {
  const LivePlatform({
    required this.id,
    required this.name,
    this.logo = '',
    this.count = 0,
    this.subtitle = '',
    this.endpoint = '',
  });

  final String id;
  final String name;
  final String logo;
  final int count;
  final String subtitle;

  /// 提供该分类的镜像地址。同一面板的不同镜像各自维护分类子集， поэтому
  /// 分类要记住它来自哪个镜像，取频道时才不会请求到对不上的域名。
  final String endpoint;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'logo': logo,
    'count': count,
    'subtitle': subtitle,
    'endpoint': endpoint,
  };

  static LivePlatform fromJson(Map<String, dynamic> json) => LivePlatform(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    logo: json['logo'] as String? ?? '',
    count: json['count'] as int? ?? 0,
    subtitle: json['subtitle'] as String? ?? '',
    endpoint: json['endpoint'] as String? ?? '',
  );
}

class LivePlayback {
  const LivePlayback({required this.url, this.headers = const {}});
  final String url;
  final Map<String, String> headers;
}

final Map<String, List<LiveChannel>> importedLiveChannels = {};

/// m3u 订阅频道的按需加载器：LocalStore 在构造时装上，dispose 时撤掉。
/// 仓库取不到已加载的频道时调它读本地 m3u 副本重解析；没装上时
/// （如尚未建好 LocalStore）走原先的“暂时没有频道”报错。
/// force 为真时重读文件，不读内存里的旧列表。
typedef ImportedLiveChannelsLoader =
    Future<List<LiveChannel>> Function(String sourceId, {bool force});

ImportedLiveChannelsLoader? loadImportedLiveChannels;

const livePageSize = 60;
const liveUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36';

bool isPlayableLiveUrl(String url) {
  final text = url.trim();
  if (!text.contains('://')) return false;
  final scheme = text.split('://').first.toLowerCase();
  return const {
    'http',
    'https',
    'rtmp',
    'rtsp',
    'rtp',
    'udp',
    'rtmps',
    'rtmpe',
    'rtmpt',
  }.contains(scheme);
}

Map<String, String> parseLiveHeaders(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const {};
  final result = <String, String>{};
  dynamic decoded;
  if (text.startsWith('{')) {
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      decoded = null;
    }
  }
  if (decoded is Map) {
    for (final entry in decoded.entries) {
      result[entry.key.toString()] = entry.value.toString();
    }
    return result;
  }
  for (final pair in text.split(RegExp(r'[&;]'))) {
    final at = pair.indexOf('=');
    if (at <= 0) continue;
    final key = pair.substring(0, at).trim();
    final value = pair.substring(at + 1).trim();
    if (key.isEmpty || value.isEmpty) continue;
    result[key] = value;
  }
  return result;
}

Map<String, String> mergeLiveHeaders(
  Map<String, String> base,
  Map<String, String> extra,
) {
  if (base.isEmpty) return extra;
  if (extra.isEmpty) return base;
  return {...base, ...extra};
}

/// 换台列表行第二行的真实信息：优先源数据自带的 subtitle（平台源的
/// 房间/主播名），收藏混排时落到频道所属分组，多线路频道落到线路数，
/// 都没有就返回空（只显示频道名）。绝不编节目单：没有真实 EPG 数据时
/// 不显示任何节目名。
String liveChannelRowCaption(
  LiveChannel channel, {
  bool inFavourites = false,
}) {
  if (channel.subtitle.isNotEmpty) return channel.subtitle;
  if (inFavourites && channel.group.isNotEmpty) return channel.group;
  if (channel.urls.length > 1) return '${channel.urls.length} 条线路';
  return '';
}

/// 分组/换台的位置记忆：每个直播源上次看的分组、每个分组的频道列表
/// 滚动位置。只记内存态（LiveRepository 持有，随应用进程走），
/// 切分组、切源回来都不丢位置；滚动位置只记非负值。
class LiveGroupMemory {
  final Map<String, String> _lastGroupBySource = {};
  final Map<String, double> _offsets = {};

  String lastGroupFor(String sourceId) => _lastGroupBySource[sourceId] ?? '';

  void rememberGroup(String sourceId, String groupId) {
    if (sourceId.isEmpty || groupId.isEmpty) return;
    _lastGroupBySource[sourceId] = groupId;
  }

  double offsetFor(String sourceId, String groupId) =>
      _offsets['$sourceId\u0000$groupId'] ?? 0;

  void rememberOffset(String sourceId, String groupId, double offset) {
    if (sourceId.isEmpty || groupId.isEmpty) return;
    _offsets['$sourceId\u0000$groupId'] = offset < 0 ? 0 : offset;
  }

  void clear() {
    _lastGroupBySource.clear();
    _offsets.clear();
  }
}

/// 上次观看的直播：源 + 分组 + 频道 + 点播进度，持久化在
/// SharedPreferences（LiveStore，键 live.lastWatched），重启 App 还在。
/// 频道用 key 认（源\0分组名\0频道名），不用 url：url 会过期，
/// 续播时一律按 key 在新拉的频道列表里重找，找不到就回退并清掉。
class LiveLastWatched {
  const LiveLastWatched({
    required this.sourceId,
    required this.groupId,
    required this.groupName,
    required this.channelKey,
    required this.channelName,
    this.positionMs = 0,
    required this.updatedAtMs,
  });

  final String sourceId;

  /// 续播要进的分组 id（平台 id）。收藏里播的频道没有分组 id，
  /// 此时为空，靠 groupName 按名匹配。
  final String groupId;

  /// 分组名（平台名 / 频道自身的 group）：平台 id 变了时按名兜底。
  final String groupName;
  final String channelKey;
  final String channelName;

  /// 点播（m3u 文件型）上次看到的毫秒位置；直播流恒为 0。
  final int positionMs;
  final int updatedAtMs;

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'groupId': groupId,
    'groupName': groupName,
    'channelKey': channelKey,
    'channelName': channelName,
    'positionMs': positionMs,
    'updatedAtMs': updatedAtMs,
  };

  static LiveLastWatched? fromJson(Map<String, dynamic> json) {
    final sourceId = json['sourceId'] as String? ?? '';
    final channelKey = json['channelKey'] as String? ?? '';
    final channelName = json['channelName'] as String? ?? '';
    if (sourceId.isEmpty || channelKey.isEmpty || channelName.isEmpty) {
      return null;
    }
    return LiveLastWatched(
      sourceId: sourceId,
      groupId: json['groupId'] as String? ?? '',
      groupName: json['groupName'] as String? ?? '',
      channelKey: channelKey,
      channelName: channelName,
      positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  LiveLastWatched withPosition(int value) => LiveLastWatched(
    sourceId: sourceId,
    groupId: groupId,
    groupName: groupName,
    channelKey: channelKey,
    channelName: channelName,
    positionMs: value < 0 ? 0 : value,
    updatedAtMs: updatedAtMs,
  );
}
