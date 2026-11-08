import 'jar_bridge.dart';
import 'models.dart';

class JarHaijiaoTakeover {
  JarHaijiaoTakeover._();

  static const Map<String, String> _byClass = {
    'com.github.catvod.spider.ZakaHaijiaoAmns': 'v_haijiao',
    'com.github.catvod.spider.ZakaHj1Amns': 'v_haijiao_fanguo',
    'com.github.catvod.spider.ZakaHjwAmns': 'v_hjw',
    'com.github.catvod.spider.ZakaHjAppAmns': 'v_haijiao_fanguo',
  };

  static const Map<String, String> _byKey = {
    'ZakaHaijiao': 'v_haijiao',
    'ZakaHj1': 'v_haijiao_fanguo',
    'ZakaHjw': 'v_hjw',
    'ZakaHjApp': 'v_haijiao_fanguo',
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
