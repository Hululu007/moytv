import 'builtin_legado_sources.dart';
import 'content_audio.dart';
import 'content_fanqie_music.dart';
import 'content_http.dart';
import 'content_jar_audio.dart';
import 'content_lrts.dart';
import 'content_models.dart';
import 'content_py.dart';

class ContentRegistry {
  ContentRegistry._();

  static final ContentHttp _http = ContentHttp();

  static final List<ContentSource> _sources = [
    TingshuwangSource(_http),
    PyContentSource(
      id: 'ximalaya',
      name: '喜马拉雅',
      assetPath: 'assets/audio_spiders/ximalaya.py',
    ),
    PyContentSource(
      id: 'hongguo_audio',
      name: '红果听书',
      assetPath: 'assets/audio_spiders/hongguo.py',
      fixedCategoryId: 'audio',
      fixedCategoryName: '听书',
      filterKey: 'acat',
    ),
    LrtsSource(_http),
    PyContentSource(
      id: 'hsvoice31',
      name: '🔞黄色有声小说',
      assetPath: 'assets/audio_spiders/hsvoice31.py',
    ),
    PyContentSource(
      id: 'tingyou',
      name: '听友听书',
      assetPath: 'assets/audio_spiders/tingyou.py',
    ),
    PyContentSource(
      id: 'hysxs',
      name: '🔞H有声小说',
      assetPath: 'assets/audio_spiders/hysxs.py',
    ),
    PyContentSource(
      id: 'asmrmoon',
      name: '🔞ASMR MOON',
      assetPath: 'assets/audio_spiders/asmrmoon.py',
    ),
    JarAudioContentSource(),
    FanqieMusicSource(_http),
  ];

  static final List<ContentSource> _novelBuiltins = [
    PyContentSource(
      id: 'aabook',
      name: '🔞疯情书库',
      assetPath: 'assets/novel_spiders/aabook.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'ylxs',
      name: '🔞月亮小说',
      assetPath: 'assets/novel_spiders/ylxs.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'cheniyo',
      name: '🔞桃色书屋',
      assetPath: 'assets/novel_spiders/cheniyo.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'hwg4',
      name: '🔞黄文阁',
      assetPath: 'assets/novel_spiders/hwg4.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'buliang',
      name: '🔞不良小说网',
      assetPath: 'assets/novel_spiders/buliang.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'yinse',
      name: '🔞淫色小说网',
      assetPath: 'assets/novel_spiders/yinse.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'mhbl',
      name: '🔞漫画部落',
      assetPath: 'assets/novel_spiders/mhbl.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'ho5ho',
      name: '🔞ho5ho',
      assetPath: 'assets/novel_spiders/ho5ho.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'modu18',
      name: '🔞魔都18',
      assetPath: 'assets/novel_spiders/modu18.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'h528',
      name: '🔞風月文學網',
      assetPath: 'assets/novel_spiders/h528.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: '69story',
      name: '🔞69成人小說網',
      assetPath: 'assets/novel_spiders/69story.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'canovel',
      name: '🔞CA情色小說',
      assetPath: 'assets/novel_spiders/canovel.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: '1000novel',
      name: '🔞1000成人小說網',
      assetPath: 'assets/novel_spiders/1000novel.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'nnhanman',
      name: '🔞鸟鸟韩漫',
      assetPath: 'assets/novel_spiders/nnhanman.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'jywx2',
      name: '🔞九一文学网',
      assetPath: 'assets/novel_spiders/jywx2.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: '55comics',
      name: '🔞污污漫书',
      assetPath: 'assets/novel_spiders/55comics.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'kmh001',
      name: '🔞K漫画',
      assetPath: 'assets/novel_spiders/kmh001.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'csmanhua',
      name: '🔞成色漫画',
      assetPath: 'assets/novel_spiders/csmanhua.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'kxmanhua',
      name: '🔞开心看漫画',
      assetPath: 'assets/novel_spiders/kxmanhua.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'akmh',
      name: '🔞爱看漫画',
      assetPath: 'assets/novel_spiders/akmh.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'hhlz',
      name: '🔞嘿嘿连载',
      assetPath: 'assets/novel_spiders/hhlz.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'zymk',
      name: '知音漫客',
      assetPath: 'assets/novel_spiders/zymk.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'dongmanla',
      name: '动漫啦',
      assetPath: 'assets/novel_spiders/dongmanla.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'jisu_1kkk',
      name: '极速漫画',
      assetPath: 'assets/novel_spiders/jisu_1kkk.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'kanman',
      name: '看漫画',
      assetPath: 'assets/novel_spiders/kanman.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'baozi',
      name: '包子漫画',
      assetPath: 'assets/novel_spiders/baozi.py',
      section: ContentSection.novel,
    ),
    PyContentSource(
      id: 'manga18fx',
      name: '🔞Manga18fx',
      assetPath: 'assets/novel_spiders/manga18fx.py',
      section: ContentSection.novel,
    ),
  ];

  static final List<ContentSource> _novelImports = [];

  /// 用户关掉的内置书源 id（开关可再开回来）。
  static Set<String> _hiddenLegadoIds = const {};

  /// 用户删掉的内置书源 id（记删除态，重启不复活；只能在管理里恢复）。
  static Set<String> _removedLegadoIds = const {};

  /// 全部内置 JSON 书源（不过滤，管理界面与测试用）。
  static List<ContentSource> get novelJsonBuiltins =>
      List.unmodifiable(builtinLegadoSources);

  static Set<String> get hiddenLegadoIds => Set.unmodifiable(_hiddenLegadoIds);

  static Set<String> get removedLegadoIds =>
      Set.unmodifiable(_removedLegadoIds);

  static void setNovelJsonVisibility({
    Set<String> hidden = const {},
    Set<String> removed = const {},
  }) {
    _hiddenLegadoIds = Set.of(hidden);
    _removedLegadoIds = Set.of(removed);
  }

  static void setNovelImports(List<ContentSource> sources) {
    _novelImports
      ..clear()
      ..addAll(sources);
  }

  static List<ContentSource> _baseFor(ContentSection section) {
    return section == ContentSection.novel
        ? [
            ..._novelBuiltins,
            for (final source in builtinLegadoSources)
              if (!_hiddenLegadoIds.contains(source.id) &&
                  !_removedLegadoIds.contains(source.id))
                source,
            ..._novelImports,
          ]
        : [
            for (final source in _sources)
              if (source.section == section) source,
          ];
  }

  static List<ContentSource> sourcesFor(ContentSection section) {
    return List.unmodifiable(_baseFor(section));
  }

  static List<ContentSource> get allSources => List.unmodifiable(_sources);

  static bool isKnownId(String id) => _sources.any((source) => source.id == id);
}
