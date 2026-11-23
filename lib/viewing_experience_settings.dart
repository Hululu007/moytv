import 'package:shared_preferences/shared_preferences.dart';

class ViewingExperienceSettings {
  const ViewingExperienceSettings({
    this.immersive = true,
    this.detailPosterBackground = true,
    this.m3u8DownloadWhilePlaying = false,
    this.deepSniffer = true,
    this.autoWriteSiteDb = true,
  });

  static const String keyImmersive = 'moyi_viewing_immersive';
  static const String keyDetailPosterBackground =
      'moyi_viewing_detail_poster_background';
  static const String keyM3u8DownloadWhilePlaying =
      'moyi_viewing_m3u8_download_while_playing';
  static const String keyDeepSniffer = 'moyi_viewing_deep_sniffer';
  static const String keyAutoWriteSiteDb = 'moyi_viewing_auto_write_site_db';

  final bool immersive;
  final bool detailPosterBackground;
  final bool m3u8DownloadWhilePlaying;
  final bool deepSniffer;

  /// 播起来后自动把能播的片写进共用站点库（MYTV/db/站点库.db）：
  /// 默认开；播不了的不写，开关关了也不写。
  final bool autoWriteSiteDb;

  bool get posterBackgroundActive => immersive && detailPosterBackground;

  ViewingExperienceSettings copyWith({
    bool? immersive,
    bool? detailPosterBackground,
    bool? m3u8DownloadWhilePlaying,
    bool? deepSniffer,
    bool? autoWriteSiteDb,
  }) => ViewingExperienceSettings(
    immersive: immersive ?? this.immersive,
    detailPosterBackground:
        detailPosterBackground ?? this.detailPosterBackground,
    m3u8DownloadWhilePlaying:
        m3u8DownloadWhilePlaying ?? this.m3u8DownloadWhilePlaying,
    deepSniffer: deepSniffer ?? this.deepSniffer,
    autoWriteSiteDb: autoWriteSiteDb ?? this.autoWriteSiteDb,
  );

  static Future<ViewingExperienceSettings> load([
    SharedPreferences? prefs,
  ]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    return ViewingExperienceSettings(
      immersive: store.getBool(keyImmersive) ?? true,
      detailPosterBackground: store.getBool(keyDetailPosterBackground) ?? true,
      m3u8DownloadWhilePlaying:
          store.getBool(keyM3u8DownloadWhilePlaying) ?? false,
      deepSniffer: store.getBool(keyDeepSniffer) ?? true,
      autoWriteSiteDb: store.getBool(keyAutoWriteSiteDb) ?? true,
    );
  }

  Future<void> save([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    await store.setBool(keyImmersive, immersive);
    await store.setBool(keyDetailPosterBackground, detailPosterBackground);
    await store.setBool(keyM3u8DownloadWhilePlaying, m3u8DownloadWhilePlaying);
    await store.setBool(keyDeepSniffer, deepSniffer);
    await store.setBool(keyAutoWriteSiteDb, autoWriteSiteDb);
  }
}
