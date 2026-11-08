enum LiveProtocol { pingtai, list, api }

class LiveSource {
  const LiveSource({
    required this.id,
    required this.name,
    required this.description,
    required this.protocol,
    this.endpoints = const [],
    this.script = '',
    this.headers = const {},
    this.epg = '',
    this.proxies = const [],
    this.group = '',
    this.adult = false,
    this.builtin = true,
    this.enabled = true,
    this.paginated = false,
    this.greenCategoryFilter = true,
  });

  final String id;
  final String name;
  final String description;
  final LiveProtocol protocol;

  /// 同一面板的多个镜像。它们共享内容但各自维护分类子集，合并后按分类路由。
  final List<String> endpoints;
  final String script;

  String get endpoint => endpoints.isEmpty ? '' : endpoints.first;
  final Map<String, String> headers;
  final String epg;

  /// 取流代理前缀。源站直连被拒时按顺序作为候选线路拼在原始地址前。
  final List<String> proxies;

  /// 列表型源没有分组信息时的默认分组名。
  final String group;

  /// 成人站源。绿色模式开启时整个源不出现在直播里。
  final bool adult;
  final bool builtin;
  final bool enabled;

  /// 是否支持按页续载。整类一次返回的源不参与滚动加载。
  final bool paginated;

  /// 绿色模式下是否按白名单过滤分类。主流直播源的分类是分区/游戏名，
  /// 不在白名单里，设为 false 才能正常显示；成人源与导入源保持默认 true。
  final bool greenCategoryFilter;

  static const values = <LiveSource>[
    LiveSource(
      id: 'xiuguo',
      name: '🔞秀果',
      description: '主播直播 · 实时开播',
      protocol: LiveProtocol.pingtai,
      endpoints: [
        'http://api.vipmisss.com:81/xcdsw',
        'http://api.hclyz.com:81/mf',
      ],
      adult: true,
    ),
    LiveSource(
      id: 'maiyoux',
      name: '🔞欲火聚合',
      description: '欲火移植 · 平台动态聚合 · 实时开播',
      protocol: LiveProtocol.pingtai,
      endpoints: [
        'http://api.maiyoux.com:81/mf',
        'http://api.vipmisss.com:81/xcdsw',
      ],
      adult: true,
    ),
    LiveSource(
      id: 'bnzb',
      name: '🔞百年直播',
      description: '百年直播 · 多平台聚合 · 实时开播',
      protocol: LiveProtocol.pingtai,
      endpoints: ['http://api.vipmisss.com:81/xcdsw'],
      adult: true,
    ),
    LiveSource(
      id: 'user_m3u',
      name: '🔞成人点播',
      description: '用户提供的 m3u · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/user_m3u.m3u'],
      adult: true,
    ),
    LiveSource(
      id: 'bilibili',
      name: '哔哩哔哩',
      description: 'B站直播 · 分区房间 · 列表已验活',
      protocol: LiveProtocol.api,
      greenCategoryFilter: false,
      paginated: true,
    ),
    LiveSource(
      id: 'huya',
      name: '虎牙',
      description: '虎牙直播 · 热门房间 · 列表已验活',
      protocol: LiveProtocol.api,
      greenCategoryFilter: false,
      paginated: true,
    ),
    LiveSource(
      id: 'pandalive',
      name: 'PandaLive',
      description: '韩国 PandaLive · 在播房间 · 列表已验活，播放待接',
      protocol: LiveProtocol.api,
      greenCategoryFilter: false,
    ),
    LiveSource(
      id: 'sakuralive',
      name: 'SakuraLive',
      description: 'SakuraLive · 在线主播 · 列表已验活，播放待接',
      protocol: LiveProtocol.api,
      greenCategoryFilter: false,
    ),
    LiveSource(
      id: 'm3u_douyin',
      name: '抖音直播',
      description: '445569.xyz 聚合 m3u · 抖音在播',
      protocol: LiveProtocol.list,
      endpoints: ['https://douyin.445569.xyz/live.m3u'],
      group: '抖音直播',
      greenCategoryFilter: false,
    ),
    LiveSource(
      id: 'm3u_douyu',
      name: '斗鱼直播',
      description: '445569.xyz 聚合 m3u · 斗鱼在播',
      protocol: LiveProtocol.list,
      endpoints: ['https://douyu.445569.xyz/live.m3u'],
      group: '斗鱼直播',
      greenCategoryFilter: false,
    ),
    LiveSource(
      id: 'm3u_huya',
      name: '虎牙直播',
      description: '445569.xyz 聚合 m3u · 虎牙在播',
      protocol: LiveProtocol.list,
      endpoints: ['https://huya.445569.xyz/live.m3u'],
      group: '虎牙直播',
      greenCategoryFilter: false,
    ),
    LiveSource(
      id: 'm3u_kugou',
      name: '酷狗直播',
      description: '445569.xyz 聚合 m3u · 酷狗在播',
      protocol: LiveProtocol.list,
      endpoints: ['https://kugou.445569.xyz/live.m3u'],
      group: '酷狗直播',
      greenCategoryFilter: false,
    ),
    LiveSource(
      id: 'm3u_tiktok',
      name: 'TikTok直播',
      description: '445569.xyz 聚合 m3u · TikTok 在播',
      protocol: LiveProtocol.list,
      endpoints: ['https://tiktok.445569.xyz/live.m3u'],
      group: 'TikTok直播',
      greenCategoryFilter: false,
    ),
    LiveSource(
      id: 'm3u_twitch',
      name: 'Twitch直播',
      description: '445569.xyz 聚合 m3u · Twitch 在播',
      protocol: LiveProtocol.list,
      endpoints: ['https://twitch.445569.xyz/live.m3u'],
      group: 'Twitch直播',
      greenCategoryFilter: false,
    ),
    LiveSource(
      id: 'm3u_yy',
      name: 'YY直播',
      description: '445569.xyz 聚合 m3u · YY 在播',
      protocol: LiveProtocol.list,
      endpoints: ['https://yy.445569.xyz/live.m3u'],
      group: 'YY直播',
      greenCategoryFilter: false,
    ),
  ];

  static final List<LiveSource> importedValues = [];

  static final Map<String, LiveSource> importedSources = {};

  static List<LiveSource> get allValues => [
    ...values,
    ...importedValues,
    ...importedSources.values,
  ];

  static List<LiveSource> get all => allValues;

  /// 绿色模式放行的直播分类名。改成白名单而不是罗列成人特征词：直播面板的
  /// 分类以「卡哇伊」「花蝴蝶」「蜜桃」「小妲己」这类花名为主，黑名单列不全，
  /// 实测 137 个分类里只有「卫视直播」属于公开电视直播，其余全是秀场。
  /// 白名单下没被明确认定为绿色的分类一律不展示。
  static final _greenCategory = RegExp(
    r'(卫视|央视|CCTV|CGTN|电视直播|广播|新闻|体育|财经|少儿|纪录|地方台|剧场|电影|电视剧)',
    caseSensitive: false,
  );

  /// 绿色模式下的直播可见性：成人源整源隐藏，成人分类单独隐藏。
  static List<LiveSource> visible(bool greenMode) => [
    for (final source in allValues)
      if (!greenMode || !source.adult) source,
  ];

  static bool hidesCategory(String name, {required bool greenMode}) =>
      greenMode && !_greenCategory.hasMatch(name);

  /// 在既有内置源之外追加一个源，仅用于验证绿色模式的整源过滤。
  static List<LiveSource> spreadWith(
    LiveSource extra, {
    required bool greenMode,
  }) => [
    for (final source in [...values, extra])
      if (!greenMode || !source.adult) source,
  ];

  static LiveSource? byId(String id) =>
      allValues.where((source) => source.id == id).firstOrNull;

  static bool isBuiltin(String id) => values.any((source) => source.id == id);

  LiveSource copyWith({bool? enabled}) => LiveSource(
    id: id,
    name: name,
    description: description,
    protocol: protocol,
    endpoints: endpoints,
    script: script,
    headers: headers,
    epg: epg,
    proxies: proxies,
    group: group,
    adult: adult,
    builtin: builtin,
    enabled: enabled ?? this.enabled,
    paginated: paginated,
    greenCategoryFilter: greenCategoryFilter,
  );
}
