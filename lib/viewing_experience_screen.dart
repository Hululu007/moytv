import 'package:flutter/material.dart';

import 'local_store.dart';
import 'tmdb/tmdb_config.dart';
import 'tmdb/tmdb_settings_page.dart';
import 'viewing_experience_settings.dart';

class ViewingExperienceScreen extends StatefulWidget {
  const ViewingExperienceScreen({super.key, required this.store});

  final LocalStore store;

  @override
  State<ViewingExperienceScreen> createState() =>
      _ViewingExperienceScreenState();
}

class _ViewingExperienceScreenState extends State<ViewingExperienceScreen> {
  ViewingExperienceSettings? _settings;
  TmdbConfig? _tmdbConfig;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await ViewingExperienceSettings.load();
    final tmdb = await TmdbConfig.load();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _tmdbConfig = tmdb;
    });
  }

  Future<void> _updateSettings(ViewingExperienceSettings next) async {
    setState(() => _settings = next);
    await next.save();
  }

  Future<void> _updatePlayback({bool? danmaku, bool? adBlock}) async {
    final prefs = widget.store.playbackPreferences;
    await widget.store.setPlaybackPreferences(
      prefs.copyWith(
        danmaku: danmaku ?? prefs.danmaku,
        adBlock: adBlock ?? prefs.adBlock,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openTmdb() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const TmdbSettingsPage()),
    );
    if (!mounted) return;
    final tmdb = await TmdbConfig.load();
    setState(() => _tmdbConfig = tmdb);
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final tmdb = _tmdbConfig;
    return Scaffold(
      appBar: AppBar(title: const Text('观看体验')),
      body: settings == null || tmdb == null
          ? const Center(child: CircularProgressIndicator())
          : AnimatedBuilder(
              animation: widget.store,
              builder: (context, _) {
                final current = widget.store.playbackPreferences;
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        SwitchListTile(
                          key: const ValueKey('viewing-immersive-switch'),
                          title: const Text('沉浸式首页与详情'),
                          subtitle: const Text('海报背景和玻璃控件；关闭恢复旧版'),
                          value: settings.immersive,
                          onChanged: (value) => _updateSettings(
                            settings.copyWith(immersive: value),
                          ),
                        ),
                        SwitchListTile(
                          key: const ValueKey('viewing-detail-poster-switch'),
                          title: const Text('详情页海报背景'),
                          subtitle: const Text('用影片海报作详情页背景'),
                          value: settings.detailPosterBackground,
                          onChanged: (value) => _updateSettings(
                            settings.copyWith(detailPosterBackground: value),
                          ),
                        ),
                        ListTile(
                          key: const ValueKey('viewing-tmdb-entry'),
                          leading: const Icon(Icons.image_outlined),
                          title: const Text('TMDB 资料配置'),
                          subtitle: Text(
                            tmdb.configured
                                ? '已配置 apikey · 海报、背景、剧情与剧集预览'
                                : '未配置 apikey',
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: _openTmdb,
                        ),
                        const Divider(),
                        SwitchListTile(
                          key: const ValueKey('viewing-danmaku-switch'),
                          title: const Text('弹幕设置'),
                          subtitle: const Text('播放时显示弹幕'),
                          value: current.danmaku,
                          onChanged: (value) => _updatePlayback(danmaku: value),
                        ),
                        SwitchListTile(
                          key: const ValueKey('viewing-m3u8-switch'),
                          title: const Text('M3U8 边下边播'),
                          subtitle: const Text('播放时同步缓存当前 M3U8'),
                          value: settings.m3u8DownloadWhilePlaying,
                          onChanged: (value) => _updateSettings(
                            settings.copyWith(m3u8DownloadWhilePlaying: value),
                          ),
                        ),
                        SwitchListTile(
                          key: const ValueKey('viewing-adblock-switch'),
                          title: const Text('广告过滤'),
                          subtitle: const Text('播放时过滤广告请求'),
                          value: current.adBlock,
                          onChanged: (value) => _updatePlayback(adBlock: value),
                        ),
                        SwitchListTile(
                          key: const ValueKey('viewing-sniffer-switch'),
                          title: const Text('深度嗅探'),
                          subtitle: const Text('播不出来时自动嗅探播放地址'),
                          value: settings.deepSniffer,
                          onChanged: (value) => _updateSettings(
                            settings.copyWith(deepSniffer: value),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
