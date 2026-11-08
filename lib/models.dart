import 'dart:convert';

import 'app_build.dart';

/// 用户自定义的 MacCMS / XBPQ 站源记录。
class CustomSourceSite {
  const CustomSourceSite({
    required this.id,
    required this.name,
    required this.base,
    this.rule = '',
    this.kind = '',
  });
  final String id;
  final String name;
  final String base;
  final String rule;

  /// 源类型：web=网页源（走 HTML 抓取）/ json=JSON 源（直连 API）/ 空=自动识别。
  final String kind;

  factory CustomSourceSite.fromJson(Map<String, dynamic> json) =>
      CustomSourceSite(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        base: json['base'] as String? ?? '',
        rule: json['rule'] as String? ?? '',
        kind: (json['kind'] as String? ?? json['type'] as String? ?? ''),
      );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'base': base,
    if (rule.isNotEmpty) 'rule': rule,
    if (kind.isNotEmpty) 'kind': kind,
  };
  bool get isCustom => SourceSite.isCustomId(id);
  bool get hasRule => rule.trim().isNotEmpty;
  SourceSite get asSourceSite => SourceSite(
    id,
    name,
    base,
    section: SourceSite.sectionVideo,
    origin: SourceSite.originConfig,
  );
}

class ClearanceChallenge {
  const ClearanceChallenge({
    required this.host,
    required this.url,
    required this.userAgent,
  });
  final String host;
  final String url;
  final String userAgent;

  factory ClearanceChallenge.fromJson(
    Map<String, dynamic> json,
    String userAgent,
  ) => ClearanceChallenge(
    host: json['host'] as String? ?? '',
    url: json['url'] as String? ?? '',
    userAgent: userAgent,
  );
}

class SourceSite {
  const SourceSite(
    this.id,
    this.name,
    this.description, {
    this.section = sectionDrama,
    this.slotId = '',
    this.origin = originBuiltin,
    this.configId = '',
    this.configName = '',
    this.importType = '',
    this.importExt = '',
  });

  static const sectionDrama = 'drama';
  static const sectionVideo = 'video';
  static const originBuiltin = 'builtin';
  static const originConfig = 'config';
  static const originImport = 'import';

  final String id;
  final String name;
  final String description;
  final String section;
  final String slotId;
  final String origin;
  final String configId;
  final String configName;
  final String importType;
  final String importExt;
  bool get isVideoSection => section == sectionVideo;
  bool get isDramaSection => section != sectionVideo;
  String get coreSlotId => slotId.isEmpty ? id : slotId;
  bool get onlineSearch =>
      isVideoSection || id == 'hongguo' || pagedSearch || duanjuOnlineSearch;
  bool get duanjuOnlineSearch => const {
    'yaguo',
    'maoguo',
    'fanguo',
    'guanguo',
    'heguo',
    'xingguo',
    'huaguo',
    'niuguo',
    'wangguo',
    'faguo',
    'wuguo',
    'huangdou_yh',
    'ai2026',
    'ai4k',
    'aidj',
    'aiduanju',
    'aimove',
    'aisxpc',
    'danai',
    'dj69',
    'dj91',
    'djwo',
    'duanjuone',
    'aihi',
    'ficeforand',
    'aipornx',
    'aiyinhang',
    'sexaix',
    'aiwu',
    'youzidj',
    'jinguo',
    'jinguo_jg',
  }.contains(id);
  bool get pagedSearch =>
      isVideoSection ||
      id == 'huangju' ||
      id == 'yeguo' ||
      id == 'dsd' ||
      id == 'guipian' ||
      id == 'hanxiaoquan' ||
      id == 'ikanbot' ||
      id == 'a123' ||
      duanjuPaged;
  bool get duanjuPaged => const {
    'yaguo',
    'guanguo',
    'huaguo',
    'niuguo',
    'wangguo',
    'faguo',
    'wuguo',
    'huangdou_yh',
    'ai2026',
    'ai4k',
    'aidj',
    'aiduanju',
    'aimove',
    'aisxpc',
    'danai',
    'dj69',
    'dj91',
    'djwo',
    'duanjuone',
    'aihi',
    'ficeforand',
    'aipornx',
    'aiyinhang',
    'sexaix',
    'aiwu',
    'youzidj',
    'jinguo',
    'jinguo_jg',
  }.contains(id);
  bool get searchSuggestions => id == 'hongguo';
  String get groupId => switch (id) {
    'huangguo-video' || 'huangguoai' || 'cloudfront' => 'huangguo',
    _ => id,
  };
  String get groupName => groupId == 'huangguo' ? '黄果' : name;
  String get entryName => switch (id) {
    'huangguo-video' => '视频',
    'huangguoai' => 'AI',
    'cloudfront' => '旧版',
    _ => name,
  };

  static const hongguo = SourceSite(
    'hongguo',
    '红果',
    '短剧 · 漫剧 · AI 剧 · 小说 · 听书',
    section: sectionDrama,
  );
  static const dsd = SourceSite('dsd', '帝果', '分类视频 · 在线搜索');
  static const guipian = SourceSite(
    'guipian',
    '鬼片',
    '鬼片 · 电视剧 · 动漫',
    section: sectionDrama,
  );
  static const ikanbot = SourceSite(
    'ikanbot',
    '爱看机器人',
    '电影 · 剧集 · 多线路搜索',
    section: sectionDrama,
  );
  static const a123 = SourceSite(
    'a123',
    'A123',
    '电影 · 连续剧 · 综艺 · 动漫 · 多线路',
    section: sectionDrama,
  );
  static const hanxiaoquan = SourceSite(
    'hanxiaoquan',
    '韩小圈',
    '韩剧 · 韩国电影 · 综艺动漫',
    section: sectionDrama,
  );
  static const duanjuValues = [
    SourceSite('yaguo', '芽果', '星芽短剧 · 登录接口'),
    SourceSite('maoguo', '猫果', '七猫短剧 · 签名接口'),
    SourceSite('fanguo', '饭果', '西饭短剧 · 搜索接口'),
    SourceSite('guanguo', '观果', '围观短剧 · 分类接口'),
    SourceSite('heguo', '河果', '河马剧场 · 网页接口'),
    SourceSite('xingguo', '星果', '星星短剧 · 连载接口'),
    SourceSite('huaguo', '花果', '花生短剧 · 网页目录'),
    SourceSite('niuguo', '牛果', '牛牛短剧 · 分类接口'),
    SourceSite('wangguo', '网果', '短剧网站 · 网页目录'),
    SourceSite('faguo', '发果', '168 短剧 · 网页目录'),
    SourceSite('wuguo', '伍果', '五五短剧 · 网页目录'),
    SourceSite('huangdou_yh', '黄豆短剧', '欲火移植 · 加密接口 · 只出免费集'),
  ];
  static const videoValues = [
    SourceSite(
      'v_missav',
      'MissAV',
      'MissAV 镜像 · 槽位 hongguo',
      section: sectionVideo,
      slotId: 'hongguo',
    ),
    SourceSite(
      'v_xvideos',
      'XVideos',
      'XVideos · 需梯子',
      section: sectionVideo,
      slotId: 'ikanbot',
    ),
    SourceSite(
      'v_hsck',
      '黄色仓库',
      'hsck123 · 槽位 a123',
      section: sectionVideo,
      slotId: 'a123',
    ),
    SourceSite(
      'v_javmap',
      '日本AV大全',
      'JavMap · 槽位 hanxiaoquan',
      section: sectionVideo,
      slotId: 'hanxiaoquan',
    ),
    SourceSite(
      'v_dayday',
      '天天A片',
      'vjav.tube · 槽位 guipian',
      section: sectionVideo,
      slotId: 'guipian',
    ),
    SourceSite(
      'v_whos',
      'whos识图',
      'whos.tv · 槽位 huangdou',
      section: sectionVideo,
      slotId: 'huangdou',
    ),
    SourceSite(
      'v_91sanji',
      '91三级',
      '91sanji · 槽位 huangju',
      section: sectionVideo,
      slotId: 'huangju',
    ),
    SourceSite(
      'v_hstv',
      'HSTV',
      'HSTV 仅免费 · 槽位 yeguo',
      section: sectionVideo,
      slotId: 'yeguo',
    ),
    SourceSite(
      'v_dsd',
      '懂色帝',
      'DSD · 槽位 dsd',
      section: sectionVideo,
      slotId: 'dsd',
    ),
    SourceSite(
      'v_javmit',
      'Javmit',
      'javmit · 槽位 huangguo-video',
      section: sectionVideo,
      slotId: 'huangguo-video',
    ),
    SourceSite(
      'v_vjav',
      'VJAV',
      'vjav.com · 槽位 huangguoai',
      section: sectionVideo,
      slotId: 'huangguoai',
    ),
    SourceSite(
      'v_qishe',
      '妻社',
      '人妻社 · 槽位 cloudfront',
      section: sectionVideo,
      slotId: 'cloudfront',
    ),
    SourceSite(
      'v_aipornx',
      'AIPornX',
      'aipornx · 槽位 yaguo',
      section: sectionVideo,
      slotId: 'yaguo',
    ),
    SourceSite(
      'v_haijiao_fanguo',
      '海角社区',
      'haijiao · 槽位 fanguo',
      section: sectionVideo,
      slotId: 'fanguo',
    ),
    SourceSite(
      'v_javher',
      'JavHer',
      'JavHer 预告 · 槽位 guanguo',
      section: sectionVideo,
      slotId: 'guanguo',
    ),
    SourceSite(
      'v_one',
      'ONE',
      'ONE · 槽位 heguo',
      section: sectionVideo,
      slotId: 'heguo',
    ),
    SourceSite(
      'v_javhd',
      'JavHD',
      'javhd · 槽位 xingguo',
      section: sectionVideo,
      slotId: 'xingguo',
    ),
    SourceSite(
      'v_yuuhc',
      '欲含春',
      'yuuhc · 槽位 huaguo',
      section: sectionVideo,
      slotId: 'huaguo',
    ),
    SourceSite(
      'v_setang',
      '色堂',
      'setang · 槽位 niuguo',
      section: sectionVideo,
      slotId: 'niuguo',
    ),
    SourceSite(
      'v_javxu',
      'JavXu',
      'javxu · 槽位 wangguo',
      section: sectionVideo,
      slotId: 'wangguo',
    ),
    SourceSite(
      'v_javrate',
      '鉴赏师',
      'javrate · 槽位 faguo',
      section: sectionVideo,
      slotId: 'faguo',
    ),
    SourceSite(
      'v_99jj',
      '久久热',
      '99jj · 槽位 wuguo',
      section: sectionVideo,
      slotId: 'wuguo',
    ),
    SourceSite(
      'v_javmenu',
      'JavMenu',
      'javmenu.com',
      section: sectionVideo,
      slotId: 'javmenu',
    ),
    SourceSite(
      'v_xszav',
      'XSZAV',
      'cn.xsz-av.com',
      section: sectionVideo,
      slotId: 'xszav',
    ),
    SourceSite(
      'v_123av',
      '123AV',
      '123av.com',
      section: sectionVideo,
      slotId: 'av123',
    ),
    SourceSite(
      'v_520av',
      '520AV影城',
      '520avtv.com',
      section: sectionVideo,
      slotId: 'av520',
    ),
    SourceSite(
      'v_pigav',
      'PIGAV',
      'pigav.com',
      section: sectionVideo,
      slotId: 'pigav',
    ),
    SourceSite(
      'v_aoxx69',
      'AOXX69',
      'aoxx69.app · 亞洲綜合',
      section: sectionVideo,
      slotId: 'aoxx69',
    ),
    SourceSite(
      'v_javdb',
      'JavDB',
      'JavDB 磁力',
      section: sectionVideo,
      slotId: 'javdb',
    ),
    SourceSite(
      'v_z2_17rip',
      '🔞17rip',
      '17rip.com',
      section: sectionVideo,
      slotId: 'z2_17rip',
    ),
    SourceSite(
      'v_z2_321av',
      '🔞321AV',
      '321av.net',
      section: sectionVideo,
      slotId: 'z2_321av',
    ),
    SourceSite(
      'v_z2_av6k',
      '🔞AV6K',
      'av6k.com',
      section: sectionVideo,
      slotId: 'z2_av6k',
    ),
    SourceSite(
      'v_z2_7mm',
      '🔞7MMTV',
      '7mmtv.sx',
      section: sectionVideo,
      slotId: 'z2_7mm',
    ),
    SourceSite(
      'v_z2_xanimu',
      '🔞Xanimu',
      'xanimu.one',
      section: sectionVideo,
      slotId: 'z2_xanimu',
    ),
    SourceSite(
      'v_z2_cn',
      '🔞中文秘密资源',
      'cnlovehubx18.xyz',
      section: sectionVideo,
      slotId: 'z2_cn',
    ),
    SourceSite(
      'v_xhy11',
      '小黄鸭',
      'xhy11.cc',
      section: sectionVideo,
      slotId: 'xhy11',
    ),
    SourceSite(
      'v_jack20',
      '後宮電影院',
      '20jack.com',
      section: sectionVideo,
      slotId: 'jack20',
    ),
    SourceSite(
      'v_javguru',
      'JavGuru',
      'jav.guru',
      section: sectionVideo,
      slotId: 'javguru',
    ),
    SourceSite('v_sihu', '四虎', '4hu.tv', section: sectionVideo, slotId: 'sihu'),
    SourceSite(
      'v_tg',
      '🔞tg频道',
      'tg.i-c-a.su 网关',
      section: sectionVideo,
      slotId: 'tg',
    ),
    SourceSite(
      'v_kuaihuo',
      '🔞快活影院',
      'tbryy · 静态站直取',
      section: sectionVideo,
      slotId: 'kuaihuo',
    ),
    SourceSite(
      'v_avbigplat',
      '🔞AV大平台',
      '9sex · 备用域可直达',
      section: sectionVideo,
      slotId: 'avbigplat',
    ),
    SourceSite(
      'v_hxc',
      '🔞含羞草',
      '加密API · 站方预告口径',
      section: sectionVideo,
      slotId: 'hxc',
    ),
    SourceSite(
      'v_hjw',
      '🔞海角网',
      'web版 · 子域池活入口',
      section: sectionVideo,
      slotId: 'hjw',
    ),
    SourceSite(
      'v_goodav',
      '🔞GoodAV',
      'goodav17 · jar配方移植 · 全链实拉',
      section: sectionVideo,
      slotId: 'goodav',
    ),
    SourceSite(
      'v_ikun',
      '🔞iKun资源',
      'ikunzyapi · MacCMS聚合 · 全链实拉',
      section: sectionVideo,
      slotId: 'ikun',
    ),
    SourceSite(
      'v_senlin',
      '🔞森林资源',
      'senlin聚合 · 6源MacCMS · 全链实拉',
      section: sectionVideo,
      slotId: 'yh_senlin',
    ),
    SourceSite(
      'v_km',
      '🔞快猫',
      '欲火移植 · 待真机验',
      section: sectionVideo,
      slotId: 'yh_km',
    ),
    SourceSite(
      'v_lxs',
      '🔞撸先生',
      '欲火移植 · 封面解密 · 全链实拉',
      section: sectionVideo,
      slotId: 'yh_lxs',
    ),
    SourceSite(
      'v_km2',
      '🔞新快猫',
      '欲火移植 · 全链验通',
      section: sectionVideo,
      slotId: 'yh_km2',
    ),
    SourceSite(
      'v_maomi',
      '🔞猫咪',
      '欲火移植 · 待真机验',
      section: sectionVideo,
      slotId: 'yh_maomi',
    ),
    SourceSite(
      'v_fulao2',
      '🔞腐老二',
      '欲火移植 · 令牌门待解',
      section: sectionVideo,
      slotId: 'yh_fulao2',
    ),
    SourceSite(
      'v_xj',
      '🔞香蕉视频',
      '欲火移植 · 全腿实测',
      section: sectionVideo,
      slotId: 'yh_xj',
    ),
    SourceSite(
      'v_cucumber',
      '🔞黄瓜视频',
      '欲火移植 · 全链验通',
      section: sectionVideo,
      slotId: 'yh_cucumber',
    ),
    SourceSite(
      'v_avbobo',
      '🔞AVbobo',
      '欲火移植 · 内置共享账号登录',
      section: sectionVideo,
      slotId: 'yh_avbobo',
    ),
    SourceSite(
      'v_bilibili',
      '🔞逼哩',
      '欲火移植 · 待真机验',
      section: sectionVideo,
      slotId: 'yh_bilibili',
    ),
    SourceSite(
      'v_fruitpie',
      '🔞水果派',
      '欲火移植 · 全链验通',
      section: sectionVideo,
      slotId: 'yh_fruitpie',
    ),
    SourceSite(
      'v_melon',
      '🔞melon',
      '欲火移植 · 全链验通',
      section: sectionVideo,
      slotId: 'yh_melon',
    ),
    SourceSite(
      'v_hl365',
      '🔞黑料不打烊',
      '欲火移植 · 全链验通',
      section: sectionVideo,
      slotId: 'yh_hl365',
    ),
    SourceSite(
      'v_pron91',
      '🔞91pron',
      '欲火移植 · 全链验通',
      section: sectionVideo,
      slotId: 'yh_pron91',
    ),
    SourceSite(
      'v_short91',
      '🔞91短视频',
      '欲火移植 · 全链验通',
      section: sectionVideo,
      slotId: 'yh_short91',
    ),
    SourceSite(
      'v_melon51',
      '🔞51西瓜',
      '欲火移植 · 全链验通',
      section: sectionVideo,
      slotId: 'yh_melon51',
    ),
    SourceSite(
      'v_utube',
      '🔞utube',
      '欲火移植 · 全链验通',
      section: sectionVideo,
      slotId: 'yh_utube',
    ),
    SourceSite(
      'v_av91',
      '🔞av91',
      '欲火移植 · 免费腿全链验通',
      section: sectionVideo,
      slotId: 'yh_av91',
    ),
    SourceSite(
      'v_md',
      '🔞麻豆',
      '欲火移植 · 全链验通',
      section: sectionVideo,
      slotId: 'yh_md',
    ),
    SourceSite(
      'v_haijiao',
      '🔞海角社区',
      '欲火移植 · 除搜索封面外全验',
      section: sectionVideo,
      slotId: 'yh_haijiao',
    ),
    SourceSite(
      'v_sex8',
      '🔞杏吧视频·夜杏有声',
      '欲火移植 · 全链验通 · 无搜索',
      section: sectionVideo,
      slotId: 'yh_sex8',
    ),
    SourceSite(
      'v_gdian',
      '🔞G点短视频',
      '欲火移植 · 待真机验',
      section: sectionVideo,
      slotId: 'yh_gdian',
    ),
    SourceSite(
      'v_ins',
      '🔞INS社区',
      '欲火移植 · 待真机验',
      section: sectionVideo,
      slotId: 'yh_ins',
    ),
    SourceSite(
      'v_huangguo',
      '🔞黄果',
      '欲火移植 · 全腿实测',
      section: sectionVideo,
      slotId: 'yh_huangguo',
    ),
    SourceSite(
      'v_mjv011',
      '🔞mjv011',
      'mjv011.com · 小说/图片/视频 · 槽位 mjv011',
      section: sectionVideo,
      slotId: 'mjv011',
    ),
  ];
  static const knownValues = [
    hongguo,
    SourceSite('hgtv', 'HGTV', '短剧 · 漫剧 · AI 剧', section: sectionDrama),
    SourceSite('hgtvmirror', '红果镜像', '镜站 · 真人剧 · 漫剧 · AI 剧', section: sectionDrama),
    ikanbot,
    a123,
    hanxiaoquan,
    guipian,
    SourceSite('huangdou', 'whos识图', '识图', section: sectionDrama),
    SourceSite('huangju', '剧果', '热门 · 最新 · 分类短剧', section: sectionDrama),
    SourceSite('yeguo', '野果', '分类短剧 · 在线搜索', section: sectionDrama),
    dsd,
    SourceSite('huangguo-video', '黄果视频', '视频剧集'),
    SourceSite('huangguoai', '黄果 AI', 'AI 短剧'),
    SourceSite('cloudfront', '黄果旧版', '旧 API 剧库'),
    SourceSite(
      'youtube',
      'YouTube',
      'YouTube · 高清 DASH · 短剧区',
      section: sectionDrama,
    ),
    ...duanjuValues,
    ...videoValues,
  ];
  static const allValues = [
    hongguo,
    SourceSite('hgtv', 'HGTV', '短剧 · 漫剧 · AI 剧', section: sectionDrama),
    SourceSite('hgtvmirror', '红果镜像', '镜站 · 真人剧 · 漫剧 · AI 剧', section: sectionDrama),
    ikanbot,
    a123,
    hanxiaoquan,
    guipian,
    SourceSite('huangdou', 'whos识图', '识图', section: sectionDrama),
    SourceSite('huangju', '剧果', '热门 · 最新 · 分类短剧', section: sectionDrama),
    SourceSite('yeguo', '野果', '分类短剧 · 在线搜索', section: sectionDrama),
    dsd,
    SourceSite('huangguo-video', '黄果视频', '视频剧集'),
    SourceSite('huangguoai', '黄果 AI', 'AI 短剧'),
    SourceSite('cloudfront', '黄果旧版', '旧 API 剧库'),
    SourceSite(
      'youtube',
      'YouTube',
      'YouTube · 高清 DASH · 短剧区',
      section: sectionDrama,
    ),
    ...duanjuValues,
    ...videoValues,
  ];
  static const values = allSourcesEnabled ? knownValues : [hongguo];

  /// 当前会话已注册的自定义源 ID，供可用性判断与站源归一化使用。
  static final Set<String> customIds = {};

  /// 导入配置（TVBox 远程配置等）动态注册的站点，key 为站点 id。
  /// 导入功能本体负责填充与持久化，本表只是壳侧的预留注册结构：
  /// 配置删除时只需移除该配置名下的条目，内置站不受影响。
  static final Map<String, SourceSite> importedSites = {};

  /// py 导入站的蜘蛛文件名（应用文档目录 imported_spiders/ 下），key 为站点 id。
  static final Map<String, String> importedPyFiles = {};
  static final Map<String, String> importedJsFiles = {};
  static final Map<String, String> importedPyRemoteUrls = {};
  static bool isCustomId(String id) => id.startsWith('custom:');
  static bool isAvailable(String id) =>
      values.any((site) => site.id == id) ||
      customIds.contains(id) ||
      importedSites.containsKey(id);
  static bool isKnown(String id) =>
      allValues.any((site) => site.id == id) ||
      customIds.contains(id) ||
      importedSites.containsKey(id);
  static SourceSite byId(String id) {
    final imported = importedSites[id];
    if (imported != null) return imported;
    if (customIds.contains(id)) {
      return SourceSite(
        id,
        customName(id),
        '自定义站源',
        section: sectionVideo,
        origin: originConfig,
      );
    }
    return allValues.firstWhere((site) => site.id == id, orElse: () => hongguo);
  }

  static String customName(String id) {
    if (id.startsWith('custom:')) return '自定义源';
    return id;
  }

  /// 从未配置过「源显示列表」时默认隐藏的内置站源。
  /// 默认可见集 = 红果、韩小圈、鬼片、A123、爱看机器人，
  /// 其余内置源（whos识图、剧果、野果、帝果、黄果视频、黄果 AI、黄果旧版、
  /// 芽果、猫果、饭果、观果、河果、星果、花果、牛果、网果、发果、伍果）默认隐藏。
  static const defaultHiddenSiteIds = <String>{
    'huangdou',
    'huangju',
    'yeguo',
    'dsd',
    'huangguo-video',
    'huangguoai',
    'cloudfront',
    'yaguo',
    'maoguo',
    'fanguo',
    'guanguo',
    'heguo',
    'xingguo',
    'huaguo',
    'niuguo',
    'wangguo',
    'faguo',
    'wuguo',
  };
}

bool isVodZoneSource(SourceSite site) =>
    site.isVideoSection &&
    (site.origin == SourceSite.originConfig ||
        (site.origin == SourceSite.originImport &&
            (site.importType == 'py' || site.importType == 'jar')) ||
        (site.origin == SourceSite.originBuiltin &&
            !site.name.startsWith('🔞')));

bool isMidnightZoneSource(SourceSite site) =>
    site.isVideoSection && site.origin == SourceSite.originBuiltin;

class SourceGroup {
  const SourceGroup(
    this.id,
    this.name,
    this.sources, {
    this.origin = SourceSite.originBuiltin,
    this.configId = '',
  });
  final String id;
  final String name;
  final List<SourceSite> sources;

  /// 分组来源：builtin=内置写死站点；config=某份导入配置。
  final String origin;

  /// origin=config 时所属配置的 id；删配置只删该组，内置组恒在。
  final String configId;
  bool get isConfig => origin == SourceSite.originConfig;

  factory SourceGroup.config({
    required String configId,
    required String name,
    required List<SourceSite> sources,
  }) => SourceGroup(
    'config:$configId',
    name,
    sources,
    origin: SourceSite.originConfig,
    configId: configId,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'origin': origin,
    if (configId.isNotEmpty) 'configId': configId,
    'sourceIds': [for (final source in sources) source.id],
  };

  factory SourceGroup.fromJson(Map<String, dynamic> json) => SourceGroup(
    json['id'] as String? ?? '',
    json['name'] as String? ?? '',
    [
      for (final id in json['sourceIds'] as List? ?? const [])
        SourceSite.byId(id as String),
    ],
    origin: json['origin'] as String? ?? SourceSite.originBuiltin,
    configId: json['configId'] as String? ?? '',
  );

  static List<SourceGroup> fromSources(Iterable<SourceSite> sources) {
    final groups = <String, List<SourceSite>>{};
    for (final source in sources) {
      (groups[source.groupId] ??= []).add(source);
    }
    return [
      for (final group in groups.entries)
        SourceGroup(group.key, group.value.first.groupName, group.value),
    ];
  }

  /// 站点切换的展示分组：内置短剧组 / 内置影视组 / 导入配置组。
  /// [imported] 为已导入配置各自的分组（本轮可为空组渲染），
  /// 与内置组并列返回；内置组恒在，不随配置增删变化。
  static List<SourceGroup> sectionGroups(
    Iterable<SourceSite> sources, {
    List<SourceGroup> imported = const [],
  }) {
    final drama = <SourceSite>[];
    final video = <SourceSite>[];
    final importedSites = <SourceSite>[];
    final looseConfig = <SourceSite>[];
    final byConfig = <String, List<SourceSite>>{};
    for (final source in sources) {
      if (source.origin == SourceSite.originImport) {
        importedSites.add(source);
      } else if (source.origin == SourceSite.originConfig) {
        if (source.configId.isNotEmpty) {
          (byConfig[source.configId] ??= []).add(source);
        } else {
          looseConfig.add(source);
        }
      } else if (source.isVideoSection) {
        video.add(source);
      } else {
        drama.add(source);
      }
    }
    return [
      if (drama.isNotEmpty) SourceGroup('builtin:drama', '内置短剧', drama),
      if (video.isNotEmpty) SourceGroup('builtin:video', '内置影视', video),
      if (importedSites.isNotEmpty)
        SourceGroup(
          'import',
          '导入',
          importedSites,
          origin: SourceSite.originImport,
        ),
      if (looseConfig.isNotEmpty)
        SourceGroup(
          'config:custom',
          '导入配置',
          looseConfig,
          origin: SourceSite.originConfig,
          configId: 'custom',
        ),
      for (final entry in byConfig.entries)
        SourceGroup.config(
          configId: entry.key,
          name: entry.value.first.configName.isNotEmpty
              ? entry.value.first.configName
              : '导入配置',
          sources: entry.value,
        ),
      ...imported,
    ];
  }
}

class CatalogCategory {
  const CatalogCategory(
    this.id,
    this.name, {
    this.local = false,
    this.kind = '',
    this.folderId = '',
  });
  static const all = CatalogCategory('', '全部');
  final String id;
  final String name;
  final bool local;

  /// 分类条目本身也可为文件夹（多级分类）：kind=folder 时点入下钻。
  final String kind;
  final String folderId;
  bool get isFolder => kind == 'folder' || folderId.isNotEmpty;
  String get drillId => folderId.isNotEmpty ? folderId : id;
  factory CatalogCategory.fromJson(Map<String, dynamic> json) =>
      CatalogCategory(
        json['id'] as String? ?? '',
        json['name'] as String? ?? '全部',
        kind: json['kind'] as String? ?? '',
        folderId: json['folderId'] as String? ?? '',
      );
}

class CatalogTag {
  const CatalogTag(this.id, this.name);
  final String id;
  final String name;
  String get folderId => id.startsWith('tag:') ? id : 'tag:$id';
  factory CatalogTag.fromJson(Object? value) {
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      return CatalogTag(
        map['id']?.toString() ?? '',
        map['name']?.toString() ?? '',
      );
    }
    final text = value?.toString() ?? '';
    return CatalogTag(text, text);
  }
}

class CatalogFilterOption {
  const CatalogFilterOption(this.id, this.name);
  final String id;
  final String name;
  factory CatalogFilterOption.fromJson(Map<String, dynamic> json) =>
      CatalogFilterOption(
        json['id']?.toString() ?? '',
        json['name']?.toString() ?? '',
      );
}

class CatalogFilterGroup {
  const CatalogFilterGroup(this.key, this.name, this.options);
  final String key;
  final String name;
  final List<CatalogFilterOption> options;
  factory CatalogFilterGroup.fromJson(Map<String, dynamic> json) =>
      CatalogFilterGroup(
        json['key']?.toString() ?? '',
        json['name']?.toString() ?? '',
        [
          for (final row in json['options'] as List? ?? const [])
            if (row is Map)
              CatalogFilterOption.fromJson(Map<String, dynamic>.from(row)),
        ].where((option) => option.id.isNotEmpty).toList(),
      );
}

int intValue(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

class Drama {
  const Drama({
    required this.id,
    required this.source,
    required this.title,
    this.sourceId = '',
    this.description = '',
    this.cover = '',
    this.episodes = 0,
    this.category = '',
    bool? vip,
    this.heat = '',
    this.views = '',
    this.onlineDate = '',
    this.tags = const [],
    this.releaseStatus = '',
    this.kind = 'video',
    this.folderId = '',
    // peers 是跨源聚合搜索里其它站源的同一部剧，用于一键切换播放源。
    this.peers = const [],
  }) : vipStatus = vip;
  final String id;
  final String source;
  final String sourceId;
  final String title;
  final String description;
  final String cover;
  final int episodes;
  final String category;
  final bool? vipStatus;
  bool get vip => vipStatus == true;
  final String heat;
  final String views;
  final String onlineDate;
  final List<String> tags;
  final String releaseStatus;

  /// 目录条目类型：video=视频卡（缺省）；folder=文件夹卡，点击以
  /// [folderId] 作为 category 参数再次请求目录实现下钻（层级不限）。
  final String kind;
  final String folderId;
  bool get isFolder => kind == 'folder';
  bool get isTagFolder => isFolder && folderId.startsWith('tag:');
  final List<Drama> peers;
  String get releaseLabel => switch (releaseStatus) {
    'finished' || 'completed' => '已完结',
    'ongoing' => '连载中',
    _ => '状态未知',
  };

  factory Drama.fromJson(Map<String, dynamic> json) => Drama(
    id: json['id'] as String? ?? '',
    source: json['source'] as String? ?? 'hongguo',
    sourceId: json['sourceId'] as String? ?? '',
    title: json['title'] as String? ?? '短剧',
    description: json['description'] as String? ?? '',
    cover: json['cover'] as String? ?? json['pic'] as String? ?? '',
    episodes: intValue(json['episodes']),
    category: json['category'] as String? ?? '',
    vip: json['vip'] == true
        ? true
        : json['vip'] == false &&
              (json['source'] != 'huangdou' ||
                  intValue(json['metadataSchema']) >= 1)
        ? false
        : null,
    heat: json['heat']?.toString() ?? '',
    views: json['views']?.toString() ?? '',
    onlineDate: json['onlineDate'] as String? ?? '',
    tags: [
      for (final tag in json['tags'] as List? ?? const [])
        if (tag is String)
          tag
        else if (tag is Map)
          (tag['name']?.toString() ?? '')
        else
          '',
    ].where((tag) => tag.isNotEmpty).toList(),
    releaseStatus: json['releaseStatus'] as String? ?? '',
    kind: json['kind'] as String? ?? 'video',
    folderId: json['folderId'] as String? ?? '',
    peers: [
      for (final row in json['peers'] as List? ?? const [])
        Drama.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
  );
  Map<String, dynamic> toJson() => {
    'metadataSchema': 1,
    'id': id,
    'source': source,
    'sourceId': sourceId,
    'title': title,
    'description': description,
    'cover': cover,
    'episodes': episodes,
    'category': category,
    'vip': vipStatus,
    'heat': heat,
    'views': views,
    'onlineDate': onlineDate,
    'tags': tags,
    'releaseStatus': releaseStatus,
    if (kind != 'video') 'kind': kind,
    if (folderId.isNotEmpty) 'folderId': folderId,
    if (peers.isNotEmpty) 'peers': [for (final peer in peers) peer.toJson()],
  };

  // withPeers 复制一份并替换跨源副本列表，用于切换播放源时把副本关系传递下去。
  Drama withPeers(List<Drama> value) => Drama(
    id: id,
    source: source,
    sourceId: sourceId,
    title: title,
    description: description,
    cover: cover,
    episodes: episodes,
    category: category,
    vip: vipStatus,
    heat: heat,
    views: views,
    onlineDate: onlineDate,
    tags: tags,
    releaseStatus: releaseStatus,
    kind: kind,
    folderId: folderId,
    peers: value,
  );

  Drama merge(Drama fresh) {
    if (id != fresh.id) return fresh;
    const genericCategories = {
      '短剧',
      '真人剧',
      '漫剧',
      'AI剧',
      'AI 剧',
      'AI短剧',
      'AI 短剧',
      'AI漫剧',
      'AI 漫剧',
    };
    return Drama(
      id: id,
      source: fresh.source.isEmpty ? source : fresh.source,
      sourceId: fresh.sourceId.isEmpty ? sourceId : fresh.sourceId,
      title: fresh.title.isEmpty || fresh.title == '短剧' ? title : fresh.title,
      description: fresh.description.isEmpty ? description : fresh.description,
      cover: fresh.cover.isEmpty ? cover : fresh.cover,
      episodes: fresh.episodes > 0 ? fresh.episodes : episodes,
      category:
          fresh.category.isEmpty ||
              genericCategories.contains(fresh.category) &&
                  category.isNotEmpty &&
                  !genericCategories.contains(category)
          ? category
          : fresh.category,
      vip: fresh.vipStatus ?? vipStatus,
      heat: fresh.heat.isEmpty ? heat : fresh.heat,
      views: fresh.views.isEmpty ? views : fresh.views,
      onlineDate: fresh.onlineDate.isEmpty ? onlineDate : fresh.onlineDate,
      tags: fresh.tags.isEmpty ? tags : fresh.tags,
      releaseStatus:
          fresh.releaseStatus.isEmpty || fresh.releaseStatus == 'unknown'
          ? releaseStatus
          : fresh.releaseStatus,
      kind: fresh.kind,
      folderId: fresh.folderId.isEmpty ? folderId : fresh.folderId,
      peers: fresh.peers.isEmpty ? peers : fresh.peers,
    );
  }
}

class Episode {
  Episode(this.raw, int fallback)
    : id = raw['id'] as String? ?? '',
      title = raw['title'] as String? ?? '第$fallback集',
      number = intValue(raw['currentEpisode']) > 0
          ? intValue(raw['currentEpisode'])
          : fallback,
      vip = raw['vip'] == true,
      vertical = raw['vertical'] as bool?;
  final Map<String, dynamic> raw;
  final String id;
  final String title;
  final int number;
  final bool vip;
  final bool? vertical;
}

class DetailTag {
  const DetailTag({required this.id, required this.name});
  final String id;
  final String name;
  factory DetailTag.fromJson(Object? value) {
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      final name = map['name'] as String? ?? '';
      return DetailTag(id: map['id'] as String? ?? name, name: name);
    }
    final name = value?.toString() ?? '';
    return DetailTag(id: name, name: name);
  }
}

class MagnetLink {
  const MagnetLink({
    required this.name,
    required this.url,
    this.sizeLabel = '',
    this.quality = '',
    this.date = '',
    this.tags = const [],
  });
  final String name;
  final String url;
  final String sizeLabel;
  final String quality;
  final String date;
  final List<String> tags;

  factory MagnetLink.fromJson(Map<String, dynamic> json) => MagnetLink(
    name: json['name'] as String? ?? '',
    url: json['url'] as String? ?? '',
    sizeLabel: json['sizeLabel'] as String? ?? '',
    quality: json['quality'] as String? ?? '',
    date: json['date'] as String? ?? '',
    tags: [
      for (final row in json['tags'] as List? ?? const [])
        if (row != null && row.toString().isNotEmpty) row.toString(),
    ],
  );

  String get metaLabel => [
    if (sizeLabel.isNotEmpty) sizeLabel,
    if (quality.isNotEmpty) quality,
    for (final tag in tags) tag,
    if (date.length == 8)
      '${date.substring(0, 4)}-${date.substring(4, 6)}-${date.substring(6, 8)}',
  ].join(' · ');
}

class DramaDetail {
  DramaDetail(
    this.drama,
    this.episodes, {
    this.warning = '',
    this.backdrop = '',
    this.stills = const [],
    this.related = const [],
    this.tags = const [],
    this.magnets = const [],
  });
  final Drama drama;
  final List<Episode> episodes;
  final String warning;
  final String backdrop;
  final List<String> stills;
  final List<Drama> related;
  final List<DetailTag> tags;
  final List<MagnetLink> magnets;

  DramaDetail withDrama(Drama value) => DramaDetail(
    value,
    episodes,
    warning: warning,
    backdrop: backdrop,
    stills: stills,
    related: related,
    tags: tags,
    magnets: magnets,
  );

  DramaDetail withEpisodes(List<Episode> value) => DramaDetail(
    drama,
    value,
    warning: warning,
    backdrop: backdrop,
    stills: stills,
    related: related,
    tags: tags,
    magnets: magnets,
  );

  factory DramaDetail.fromJson(Map<String, dynamic> json) {
    final rows = json['chapters'] as List? ?? const [];
    final dramaJson = Map<String, dynamic>.from(json['drama'] as Map);
    Object? pick(String key) => json[key] ?? dramaJson[key];
    final stillsRaw = pick('stills');
    final relatedRaw = pick('related');
    final tagsRaw = pick('tags');
    final magnetsRaw = pick('magnets');
    return DramaDetail(
      Drama.fromJson(dramaJson),
      [
        for (var i = 0; i < rows.length; i++)
          Episode(Map<String, dynamic>.from(rows[i] as Map), i + 1),
      ],
      warning: json['warning'] as String? ?? '',
      backdrop: pick('backdrop') as String? ?? '',
      stills: [
        for (final row in stillsRaw as List? ?? const [])
          if (row != null && row.toString().isNotEmpty) row.toString(),
      ],
      related: [
        for (final row in relatedRaw as List? ?? const [])
          if (row is Map) Drama.fromJson(Map<String, dynamic>.from(row)),
      ],
      tags: [
        for (final row in tagsRaw as List? ?? const [])
          if (row != null) DetailTag.fromJson(row),
      ].where((tag) => tag.name.isNotEmpty).toList(),
      magnets: [
        for (final row in magnetsRaw as List? ?? const [])
          if (row is Map) MagnetLink.fromJson(Map<String, dynamic>.from(row)),
      ].where((magnet) => magnet.url.isNotEmpty).toList(),
    );
  }
}

class CatalogPage {
  CatalogPage(
    this.items, {
    this.hasMore = false,
    this.warning = '',
    this.page = 1,
    this.fresh = false,
    this.tags = const [],
    this.filters = const [],
  });
  final List<Drama> items;
  final bool hasMore;
  final String warning;
  final int page;
  final bool fresh;

  /// 分类响应携带的标签集（标签一等浏览维度），渲染为可点 chip，
  /// 点击以 tag 的 folderId（tag: 前缀）下钻。
  final List<CatalogTag> tags;

  /// 分类响应携带的筛选组（站源侧筛选面板，如主题/设定/背景），
  /// 渲染为筛选行，选项透传回站源作二次筛选。
  final List<CatalogFilterGroup> filters;
  factory CatalogPage.fromJson(Map<String, dynamic> json) => CatalogPage(
    [
      for (final row in json['items'] as List? ?? const [])
        Drama.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
    hasMore: json['hasMore'] == true,
    warning: json['warning'] as String? ?? '',
    page: intValue(json['page']) > 0 ? intValue(json['page']) : 1,
    fresh: json['fresh'] == true,
    tags: [
      for (final row in json['tags'] as List? ?? const [])
        CatalogTag.fromJson(row),
    ].where((tag) => tag.id.isNotEmpty).toList(),
    filters: [
      for (final row in json['filters'] as List? ?? const [])
        if (row is Map)
          CatalogFilterGroup.fromJson(Map<String, dynamic>.from(row)),
    ].where((group) => group.key.isNotEmpty).toList(),
  );
}

class PlaybackPlan {
  const PlaybackPlan({
    required this.url,
    this.originalUrl = '',
    this.headers = const {},
    this.decryptionKey = '',
    this.quality = 0,
    this.qualities = const [],
    this.session = '',
    this.danmakuId = '',
    this.prefetchedBytes = 0,
    this.expiresAt = 0,
    this.routeIndex = 0,
    this.routeCount = 1,
    this.local = false,
    this.needsParse = false,
  });
  final String url;
  final String originalUrl;
  final Map<String, String> headers;
  final String decryptionKey;
  final int quality;
  final List<int> qualities;
  final String session;
  final String danmakuId;
  final int prefetchedBytes;
  final int expiresAt;
  final int routeIndex;
  final int routeCount;
  final bool local;
  final bool needsParse;
  bool get hasAlternative => session.isNotEmpty && routeIndex + 1 < routeCount;

  PlaybackPlan withDanmaku(String sessionValue, String danmakuIdValue) =>
      PlaybackPlan(
        url: url,
        originalUrl: originalUrl,
        headers: headers,
        decryptionKey: decryptionKey,
        quality: quality,
        qualities: qualities,
        session: sessionValue,
        danmakuId: danmakuIdValue,
        prefetchedBytes: prefetchedBytes,
        expiresAt: expiresAt,
        routeIndex: routeIndex,
        routeCount: routeCount,
        local: local,
        needsParse: needsParse,
      );

  PlaybackPlan withUrl(String value) => PlaybackPlan(
    url: value,
    originalUrl: originalUrl,
    headers: headers,
    decryptionKey: decryptionKey,
    quality: quality,
    qualities: qualities,
    session: session,
    danmakuId: danmakuId,
    prefetchedBytes: prefetchedBytes,
    expiresAt: expiresAt,
    routeIndex: routeIndex,
    routeCount: routeCount,
    local: local,
    needsParse: needsParse,
  );

  PlaybackPlan withHeaders(Map<String, String> value) => PlaybackPlan(
    url: url,
    originalUrl: originalUrl,
    headers: value,
    decryptionKey: decryptionKey,
    quality: quality,
    qualities: qualities,
    session: session,
    danmakuId: danmakuId,
    prefetchedBytes: prefetchedBytes,
    expiresAt: expiresAt,
    routeIndex: routeIndex,
    routeCount: routeCount,
    local: local,
    needsParse: needsParse,
  );

  PlaybackPlan withNeedsParse(bool value) => PlaybackPlan(
    url: url,
    originalUrl: originalUrl,
    headers: headers,
    decryptionKey: decryptionKey,
    quality: quality,
    qualities: qualities,
    session: session,
    danmakuId: danmakuId,
    prefetchedBytes: prefetchedBytes,
    expiresAt: expiresAt,
    routeIndex: routeIndex,
    routeCount: routeCount,
    local: local,
    needsParse: value,
  );
  factory PlaybackPlan.fromJson(Map<String, dynamic> json) => PlaybackPlan(
    url: json['url'] as String? ?? '',
    originalUrl: json['originalUrl'] as String? ?? '',
    local: json['local'] == true,
    headers: (json['headers'] as Map? ?? {}).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    ),
    decryptionKey: json['decryptionKey'] as String? ?? '',
    quality: intValue(json['quality']),
    qualities: (json['qualities'] as List? ?? []).map(intValue).toSet().toList()
      ..sort((a, b) => b.compareTo(a)),
    session: json['session'] as String? ?? '',
    danmakuId: json['danmakuId'] as String? ?? '',
    prefetchedBytes: intValue(json['prefetchedBytes']),
    expiresAt: intValue(json['expiresAt']),
    routeIndex: intValue(json['routeIndex']),
    routeCount: intValue(json['routeCount']) > 0
        ? intValue(json['routeCount'])
        : 1,
    needsParse: json['parse'] == true || json['needsParse'] == true,
  );
}

class WatchEntry {
  WatchEntry({
    required this.drama,
    required this.episode,
    required this.position,
    required this.duration,
    required this.updatedAt,
  });
  final Drama drama;
  final int episode;
  final double position;
  final double duration;
  final DateTime updatedAt;
  bool get finished => duration > 1 && position >= duration - 1;
  Map<String, dynamic> toJson() => {
    'drama': drama.toJson(),
    'episode': episode,
    'position': position,
    'duration': duration,
    'updatedAt': updatedAt.toIso8601String(),
  };
  factory WatchEntry.fromJson(Map<String, dynamic> json) => WatchEntry(
    drama: Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
    episode: intValue(json['episode']),
    position: (json['position'] as num?)?.toDouble() ?? 0,
    duration: (json['duration'] as num?)?.toDouble() ?? 0,
    updatedAt:
        DateTime.tryParse(json['updatedAt'].toString()) ?? DateTime(2000),
  );
}

class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.drama,
    required this.episode,
    required this.state,
    this.bytes = 0,
    this.total = 0,
    this.progress = 0,
    this.quality = 0,
    this.actualQuality = 0,
    this.error = '',
    this.created = 0,
    this.revision = 0,
    this.archived = false,
  });
  final int created;
  final int revision;
  final bool archived;
  final String id;
  final Drama drama;
  final Episode episode;
  final String state;
  final int bytes;
  final int total;
  final double progress;
  final int quality;
  final int actualQuality;
  final String error;
  bool get completed => state == 'completed';
  bool get active => state == 'queued' || state == 'downloading';
  bool get resumable => state == 'paused' || state == 'failed';
  String get stateLabel => switch (state) {
    'queued' => '等待下载',
    'downloading' => '正在下载',
    'paused' => '已暂停',
    'failed' => '下载失败',
    'completed' => '已下载',
    'removing' => '正在取消',
    _ => '等待更新',
  };
  factory DownloadJob.fromJson(Map<String, dynamic> value) => DownloadJob(
    id: value['id'] as String? ?? '',
    drama: Drama.fromJson(Map<String, dynamic>.from(value['drama'] as Map)),
    episode: Episode(
      Map<String, dynamic>.from(value['chapter'] as Map),
      intValue(value['index']),
    ),
    state: value['state'] as String? ?? 'failed',
    bytes: intValue(value['bytes']),
    total: intValue(value['total']),
    progress: ((value['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1),
    quality: intValue(value['quality']),
    actualQuality: intValue(value['actualQuality']),
    error: value['error'] as String? ?? '',
    created: intValue(value['created']),
    revision: intValue(value['revision']),
    archived: value['archived'] == true,
  );
}

List<Map<String, dynamic>> readJsonList(String? value) {
  try {
    return (jsonDecode(value ?? '[]') as List)
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  } catch (_) {
    return [];
  }
}
