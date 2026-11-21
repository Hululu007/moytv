import 'jar_bridge.dart';
import 'models.dart';

class JarHaijiaoTakeover {
  JarHaijiaoTakeover._();

  static const Map<String, String> _byClass = {
    'com.github.catvod.spider.ZakaHaijiaoAmns': 'v_haijiao',
    'com.github.catvod.spider.ZakaHj1Amns': 'v_haijiao_fanguo',
    'com.github.catvod.spider.ZakaHjwAmns': 'v_hjw',
    'com.github.catvod.spider.ZakaHjAppAmns': 'v_haijiao_fanguo',
    // 2026-11-22：三个 MissAV jar 蜘蛛统一交给 Go 核的 MissAV 实现。
    // jar 里的解析写死在 missav.ws 自家域上，CF 一挡就整站空；Go 核
    // 带镜像降级（missav.fans / thisav.my），封面、女优一览、播放都能出。
    'com.github.catvod.spider.ZakaMissavAmns': 'v_missav',
    'com.github.catvod.spider.ZakaMissavOffAmns': 'v_missav',
    'com.github.catvod.spider.ZakaMissavtAmns': 'v_missav',
    // 2026-11-22:「MissAV镜像|免代理」走的是 ZakaMirrorAmns,jar 里只认
    // thisav.my 的老版式,站点改版后详情页一片空白(女优卡点进去没作品)。
    // 同样交给 Go 核,镜像降级和封面、播放都在那边。
    'com.github.catvod.spider.ZakaMirrorAmns': 'v_missav',
    // 2026-11-22（v42）：用户点名的这批 jar 站，jar 里的类在 ART 上被
    // verifier 拒（ZakaJavmapAmns.resolve 声明返回 String[] 实际返回
    // String），整站直接崩：没分类、没图、点开不能播。Go 核里早就有
    // 这五个站的实现，把类名接过去即可，不再依赖 jar 字节码。
    'com.github.catvod.spider.ZakaJavrateAmns': 'v_javrate',
    'com.github.catvod.spider.ZakaJavmapAmns': 'v_javmap',
    'com.github.catvod.spider.ZakaPigavAmns': 'v_pigav',
    'com.github.catvod.spider.ZakaGoodavAmns': 'v_goodav',
    'com.github.catvod.spider.Zaka9SexAmns': 'v_avbigplat',
  };

  static const Map<String, String> _byKey = {
    'ZakaHaijiao': 'v_haijiao',
    'ZakaHj1': 'v_haijiao_fanguo',
    'ZakaHjw': 'v_hjw',
    'ZakaHjApp': 'v_haijiao_fanguo',
    'ZakaMissav': 'v_missav',
    'ZakaMissavOff': 'v_missav',
    'missavt': 'v_missav',
    'ZakaMirror': 'v_missav',
    'ZakaJavrate': 'v_javrate',
    'zakajavmap': 'v_javmap',
    'zakapigav': 'v_pigav',
    'goodav': 'v_goodav',
    'avbigplat': 'v_avbigplat',
  };

  static String? goSourceForJarSite(String source) {
    if (!JarBridge.isJarSource(source)) return null;
    final spec = JarBridge.specFor(source);
    if (spec != null) {
      final mapped = _byClass[spec.className];
      if (mapped != null) return mapped;
    }
    final parts = source.split(':');
    if (parts.length >= 3) {
      return _byKey[parts.last];
    }
    return null;
  }

  static String? goSourceForSpec(JarSiteSpec spec) => _byClass[spec.className];

  static Drama remapDrama(Drama drama, String goSource) => Drama(
        id: drama.id.startsWith('$goSource:')
            ? drama.id
            : '$goSource:${drama.id}',
        source: goSource,
        title: drama.title,
        sourceId: drama.sourceId.isNotEmpty ? drama.sourceId : drama.id,
        description: drama.description,
        cover: drama.cover,
        episodes: drama.episodes,
        category: drama.category,
        vip: drama.vipStatus,
        heat: drama.heat,
        views: drama.views,
        onlineDate: drama.onlineDate,
        tags: drama.tags,
        releaseStatus: drama.releaseStatus,
        kind: drama.kind,
        folderId: drama.folderId,
        peers: drama.peers,
      );
}
