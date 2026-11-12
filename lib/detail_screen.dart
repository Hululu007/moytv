import 'dart:async';

import 'app_page_route.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'app_layout.dart';
import 'atmosphere_background.dart';
import 'ios_dialogs.dart';
import 'liquid_glass.dart';
import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'package:media_kit/media_kit.dart';

import 'playback_queue.dart';
import 'player_picker.dart';
import 'player_screen.dart';
import 'widgets.dart';
import 'sources_screen.dart';
import 'episode_browser.dart';
import 'nonvideo_content.dart';
import 'follow_state.dart';
import 'watchroom/controller.dart';
import 'watchroom/models.dart';
import 'watchroom/room_screen.dart';
import 'hongguo_series.dart';
import 'tmdb/tmdb_config.dart';
import 'tmdb/tmdb_metadata.dart';
import 'tmdb/tmdb_service.dart';
import 'viewing_experience_settings.dart';
import 'torrent/torrent_home_screen.dart';

typedef DetailTagTap =
    void Function(String sourceId, String tagId, String tagName);

Drama _dramaWithCover(Drama drama, String cover) => Drama(
  id: drama.id,
  source: drama.source,
  sourceId: drama.sourceId,
  title: drama.title,
  description: drama.description,
  cover: cover,
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

class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.drama,
    required this.repository,
    required this.store,
    this.resumeOnOpen = false,
    this.onTagTap,
    this.queue,
    this.playerFactory,
    this.videoBuilder,
  });
  final Drama drama;
  final AppRepository repository;
  final LocalStore store;
  final bool resumeOnOpen;

  /// 标签点击回调：以 sourceId + tagId 打开该标签的目录列表。
  /// TODO(shell): 目录侧标签列表入口由壳子代理提供并在构造 DetailScreen 时
  /// 注入；未注入时标签仅展示、点击给未接入提示。
  final DetailTagTap? onTagTap;

  /// 进入播放时透传给播放器的列表上下文队列（单集上下滑切条目用）。
  final PlaybackQueue? queue;
  final Player Function()? playerFactory;
  final Widget Function(Widget controls)? videoBuilder;
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  DramaDetail? _detail;
  String? _error;
  bool _loading = true;
  int _generation = 0;
  int _episodePage = 0;
  bool _expandedDescription = false;
  bool _episodesExpanded = false;
  final _episodeAnchor = GlobalKey();
  final _detailScroll = ScrollController();
  final _playFocus = FocusNode(debugLabel: 'tv-detail-play');
  bool _initialActionHandled = false;
  int? _embeddedIndex;
  bool _audioLine = false;
  double _embeddedPosition = 0;
  GlobalKey? _embeddedKey;
  bool _embeddedFullscreen = false;
  late final int _profileEpoch;
  ViewingExperienceSettings _viewing = const ViewingExperienceSettings();
  TmdbConfig _tmdbConfig = const TmdbConfig();
  TmdbMetadata? _tmdb;
  Widget? get _sourceDiagnostics => widget.repository.supportsSourceManagement
      ? SourceDiagnosticsButton(
          repository: widget.repository,
          store: widget.store,
          drama: widget.drama,
        )
      : null;

  @override
  void initState() {
    super.initState();
    _profileEpoch = widget.store.profileEpoch;
    widget.store.addListener(_onStoreChanged);
    _load();
    unawaited(_loadViewing());
  }

  @override
  void didUpdateWidget(covariant DetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
    }
  }

  @override
  void dispose() {
    _detailScroll.dispose();
    _playFocus.dispose();
    widget.store.removeListener(_onStoreChanged);
    _generation++;
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadViewing() async {
    final settings = await ViewingExperienceSettings.load();
    final tmdb = await TmdbConfig.load();
    if (mounted) {
      setState(() {
        _viewing = settings;
        _tmdbConfig = tmdb;
      });
    }
  }

  Future<void> _loadTmdb(Drama drama) async {
    final config = await TmdbConfig.load();
    if (!mounted) return;
    if (!config.configured) return;
    setState(() => _tmdbConfig = config);
    try {
      final meta = await TmdbService.instance.fetchMetadata(
        title: drama.title,
        year: yearFromText(drama.onlineDate),
        typeHint: tmdbMediaTypeHint(drama.category, drama.title),
        config: config,
      );
      if (!mounted) return;
      setState(() => _tmdb = meta);
    } catch (_) {
      // TMDB 拉不到只影响海报/剧情补充，详情页照常显示站源内容。
    }
  }

  Drama _tmdbPosterDrama(Drama drama) {
    final poster = _tmdb?.posterUrl(_tmdbConfig) ?? '';
    if (poster.isEmpty) return drama;
    return _dramaWithCover(drama, poster);
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await widget.repository.detail(widget.drama);
      if (!mounted ||
          generation != _generation ||
          _profileEpoch != widget.store.profileEpoch) {
        return;
      }
      final merged = widget.repository.catalogUpdates
          .current(widget.drama)
          .merge(detail.drama);
      setState(() {
        _detail = detail.withDrama(merged);
        _loading = false;
        _episodePage =
            resumeEpisodeIndex(
              detail.episodes,
              widget.store.watched(merged.id),
            ) ~/
            episodePageSize;
      });
      widget.repository.catalogUpdates.publish(merged, retryCover: true);
      unawaited(_supplement(merged, generation));
      unawaited(_loadTmdb(merged));
      await saveUserChange(context, () => widget.store.refreshDrama(merged));
      if (mounted &&
          generation == _generation &&
          _profileEpoch == widget.store.profileEpoch &&
          !_initialActionHandled &&
          detail.episodes.isNotEmpty) {
        _initialActionHandled = true;
        if (widget.resumeOnOpen) {
          unawaited(
            _play(
              resumeEpisodeIndex(
                detail.episodes,
                widget.store.watched(merged.id),
              ),
              resume: true,
            ),
          );
        }
      }
    } catch (error) {
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
      widget.repository.catalogUpdates.publish(
        widget.repository.catalogUpdates.current(widget.drama),
        retryCover: true,
      );
    }
  }

  Future<void> _supplement(Drama drama, int generation) async {
    try {
      final fresh = await widget.repository.supplementMetadata(drama);
      if (!mounted ||
          generation != _generation ||
          fresh == null ||
          _detail == null) {
        return;
      }
      final updated = _detail!.drama.merge(fresh);
      setState(() {
        _detail = _detail!.withDrama(updated);
      });
      widget.repository.catalogUpdates.publish(updated);
      await saveUserChange(context, () => widget.store.refreshDrama(updated));
    } catch (_) {}
  }

  Future<void> _play(
    int index, {
    bool resume = false,
    bool fullscreen = false,
  }) async {
    final rawDetail = _detail;
    if (rawDetail == null ||
        index < 0 ||
        index >= rawDetail.episodes.length ||
        _profileEpoch != widget.store.profileEpoch ||
        !widget.store.allowsSource(rawDetail.drama.source)) {
      return;
    }
    final detail = _displayDetail(rawDetail);
    if (detail.episodes[index].vip &&
        detail.drama.source != SourceSite.dsd.id) {
      final accepted = await confirmAction(
        context,
        title: '这是一集 VIP 内容',
        message: '站源可能只提供试看或限制播放。',
        confirm: '尝试播放',
      );
      if (!accepted || !mounted) {
        return;
      }
    }
    final saved = widget.store.watched(detail.drama.id);
    final position =
        resume &&
            saved?.episode == detail.episodes[index].number &&
            !saved!.finished
        ? saved.position
        : 0.0;
    if (!mounted || _profileEpoch != widget.store.profileEpoch) {
      return;
    }
    if (selectedPlayer(widget.store) == AppPlayer.xigua) {
      await pushPlayer<void>(
        context,
        detail: detail,
        initialIndex: index,
        initialPosition: position,
        repository: widget.repository,
        store: widget.store,
        queue: widget.queue,
        startFullscreen: fullscreen,
      );
      if (mounted) {
        setState(() {});
      }
      return;
    }
    if (_embeddedIndex == index && _embeddedKey != null) {
      if (fullscreen && !_embeddedFullscreen) {
        setState(() => _embeddedFullscreen = true);
      }
      return;
    }
    setState(() {
      _embeddedIndex = index;
      _embeddedPosition = position;
      _embeddedKey = GlobalKey();
      _embeddedFullscreen = fullscreen;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _detailScroll.hasClients) {
        _detailScroll.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  bool _hasAudioLine(DramaDetail detail) => detail.episodes.any(
    (episode) => (episode.raw['routes'] as List? ?? const []).isNotEmpty,
  );

  List<Episode> _displayEpisodes(DramaDetail detail) {
    if (!_audioLine) return detail.episodes;
    return detail.episodes.map((episode) {
      final routes = episode.raw['routes'] as List? ?? const [];
      if (routes.isEmpty) return episode;
      final raw = Map<String, dynamic>.from(episode.raw);
      raw['videoUrl'] = routes.first.toString();
      return Episode(raw, episode.number);
    }).toList();
  }

  DramaDetail _displayDetail(DramaDetail detail) {
    final displayed = _displayEpisodes(detail);
    if (identical(displayed, detail.episodes)) return detail;
    return detail.withEpisodes(displayed);
  }

  void _closeEmbedded() {
    if (_embeddedIndex == null) return;
    setState(() {
      _embeddedIndex = null;
      _embeddedFullscreen = false;
      _embeddedKey = null;
    });
  }

  Widget? _embeddedArea(List<Episode> episodes) {
    if (_embeddedIndex == null || _detail == null) return null;
    final index = _embeddedIndex!.clamp(0, episodes.length - 1);
    if (nonVideoKindOfEpisode(episodes[index]) != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: 560, child: _embeddedPlayer()),
          _embeddedBar(episodes),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(aspectRatio: 16 / 9, child: _embeddedPlayer()),
        _embeddedBar(episodes),
      ],
    );
  }

  void _toggleEmbeddedFullscreen() {
    if (_embeddedIndex == null) return;
    setState(() => _embeddedFullscreen = !_embeddedFullscreen);
  }

  Widget _embeddedPlayer() {
    final detail = _displayDetail(_detail!);
    final index = _embeddedIndex!.clamp(0, detail.episodes.length - 1);
    return PlayerScreen(
      key: _embeddedKey,
      detail: detail,
      initialIndex: index,
      initialPosition: _embeddedPosition,
      repository: widget.repository,
      store: widget.store,
      embedded: true,
      embeddedFullscreen: _embeddedFullscreen,
      onEmbeddedClose: _closeEmbedded,
      onEmbeddedFullscreen: _toggleEmbeddedFullscreen,
      onEmbeddedIndexChanged: (value) {
        if (mounted) setState(() => _embeddedIndex = value);
      },
      playerFactory: widget.playerFactory,
      videoBuilder: widget.videoBuilder,
    );
  }

  Widget _embeddedBar(List<Episode> episodes) {
    final index = _embeddedIndex;
    final number = index != null && index >= 0 && index < episodes.length
        ? episodes[index].number
        : null;
    final nonVideoKind = index != null && index >= 0 && index < episodes.length
        ? nonVideoKindOfEpisode(episodes[index])
        : null;
    final label = nonVideoKind == null
        ? '正在播放'
        : nonVideoKind == NonVideoKind.novel
        ? '正在阅读'
        : '正在浏览图片';
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              number == null ? label : '$label · 第 $number 集',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white),
            ),
          ),
          TextButton(
            key: const ValueKey('toggle-embedded-fullscreen'),
            onPressed: _toggleEmbeddedFullscreen,
            child: Text(_embeddedFullscreen ? '退出全屏' : '全屏'),
          ),
          TextButton(
            key: const ValueKey('close-embedded-player'),
            onPressed: _closeEmbedded,
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _pushToWatchRoom() async {
    final detail = _detail;
    final episodes = detail?.episodes ?? <Episode>[];
    if (detail == null || episodes.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂无可推送的剧集')));
      }
      return;
    }
    final drama = detail.drama;
    if (widget.store.profileEpoch != _profileEpoch ||
        !widget.store.allowsSource(drama.source)) {
      return;
    }
    final watched = widget.store.watched(drama.id);
    final index = resumeEpisodeIndex(
      episodes,
      watched,
    ).clamp(0, episodes.length - 1);
    final room = WatchRoomController.instance;
    try {
      if (room.inRoom && !room.isHost) {
        throw StateError('只有房主可以更换房间视频');
      }
      if (!room.inRoom) {
        await room.createRoom(preferences: widget.store.preferences);
      }
      room.setVideo(
        RoomVideo(
          source: drama.source,
          dramaId: drama.id,
          title: drama.title,
          cover: drama.cover,
          sourceId: drama.sourceId,
          episodeIndex: index,
          episodeTitle: episodes[index].title,
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      appPageRoute<void>(
        builder: (_) =>
            WatchRoomScreen(repository: widget.repository, store: widget.store),
      ),
    );
  }

  Future<void> _openSeriesDrama(Drama drama) async {
    if (_profileEpoch != widget.store.profileEpoch ||
        drama.id == (_detail?.drama.id ?? widget.drama.id)) {
      return;
    }
    final anchor = _detail?.drama ?? widget.drama;
    if (widget.store.following(anchor.id)?.seriesSeasons[drama.id]?.read ==
        false) {
      await saveUserChange(
        context,
        () => widget.store.markSeriesSeasonRead(anchor.id, drama.id),
      );
      if (!mounted) return;
    }
    await Navigator.of(context).pushReplacement(
      appPageRoute<void>(
        settings: const RouteSettings(name: 'detail'),
        builder: (_) => DetailScreen(
          drama: drama,
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
  }

  // _openPeerSource 切换到同一部剧在其它站源的副本继续播放。
  Future<void> _openPeerSource(Drama current, Drama peer) async {
    if (peer.id == current.id) return;
    final peers = <Drama>[
      current.withPeers(const []),
      ...current.peers.where((item) => item.id != peer.id),
    ];
    await Navigator.of(context).pushReplacement(
      appPageRoute<void>(
        settings: const RouteSettings(name: 'detail'),
        builder: (_) => DetailScreen(
          drama: peer.withPeers(peers),
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  // _sourceSwitcher 展示同一部剧在其它站源的副本，可一键切换播放源。
  Widget _sourceSwitcher(Drama drama) {
    if (drama.peers.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.swap_horiz_rounded, size: 15, color: colors.primary),
              const SizedBox(width: 6),
              Text(
                '切换播放源',
                style: TextStyle(
                  color: colors.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final peer in drama.peers)
                ActionChip(
                  key: ValueKey('peer-source-${peer.source}'),
                  avatar: Icon(
                    Icons.play_arrow_rounded,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  label: Text(
                    peer.episodes > 0
                        ? '${SourceSite.byId(peer.source).name} · ${peer.episodes} 集'
                        : SourceSite.byId(peer.source).name,
                  ),
                  onPressed: () => _openPeerSource(drama, peer),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final drama = _detail?.drama ?? widget.drama;
    final watched = widget.store.watched(drama.id);
    final episodes = _detail == null ? <Episode>[] : _displayEpisodes(_detail!);
    final resumeIndex = resumeEpisodeIndex(episodes, watched);
    final television = AppLayout.isTelevision(context);
    final allowed =
        widget.store.profileEpoch == _profileEpoch &&
        widget.store.allowsSource(drama.source);
    final useGlass = glassDesign(context) && _viewing.immersive;
    if (_embeddedIndex != null && _detail != null && _embeddedFullscreen) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _toggleEmbeddedFullscreen();
        },
        child: Scaffold(backgroundColor: Colors.black, body: _embeddedPlayer()),
      );
    }
    return PopScope(
      canPop: _embeddedIndex == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _embeddedIndex == null) {
          return;
        }
        if (_embeddedFullscreen) {
          _toggleEmbeddedFullscreen();
        } else {
          _closeEmbedded();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).maybePop(),
          const SingleActivator(LogicalKeyboardKey.goBack): () =>
              Navigator.of(context).maybePop(),
        },
        child: Scaffold(
          appBar: AppBar(
            toolbarHeight: television ? 64 : null,
            title: Text(drama.title, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                tooltip: '推送到一起看',
                onPressed: allowed ? () => unawaited(_pushToWatchRoom()) : null,
                icon: const Icon(Icons.meeting_room_rounded),
              ),
              RefreshAction(
                loading: _loading,
                tooltip: '更新剧集信息',
                onPressed: allowed ? _load : null,
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            bottom: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1200),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (!allowed) {
                      return const StatusPanel(
                        title: '当前用户无权访问',
                        message: '请返回剧库后重新选择。',
                      );
                    }
                    if (television || constraints.maxWidth >= 960) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: (constraints.maxWidth * .34).clamp(
                              250.0,
                              360.0,
                            ),
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _overview(drama),
                                  _descriptionSection(drama),
                                  _magnetSection(),
                                  _tmdbEpisodeSection(),
                                  _relatedSection(drama),
                                ],
                              ),
                            ),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(
                            child:
                                _loading || _error != null || episodes.isEmpty
                                ? _episodeStatus()
                                : Column(
                                    children: [
                                      if (_embeddedArea(episodes) != null)
                                        _embeddedArea(episodes)!,
                                      _seriesSelector(drama),
                                      _lineSelector(),
                                      Expanded(
                                        child: EpisodeBrowser(
                                          episodes: episodes,
                                          currentNumber: watched?.episode,
                                          onExitDown: () =>
                                              _playFocus.requestFocus(),
                                          onSelected: (index) => _play(index),
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ],
                      );
                    }
                    final start = _episodePage * episodePageSize;
                    final visible = episodes
                        .skip(start)
                        .take(episodePageSize)
                        .toList();
                    final tmdbMatched = matchTmdbEpisodes(
                      [for (final episode in episodes) episode.title],
                      _tmdb?.episodes ?? const [],
                    );
                    final posterFallback = _tmdbPosterDrama(drama).cover;
                    final showEpisodes = _episodesExpanded;
                    return CustomScrollView(
                      controller: _detailScroll,
                      slivers: [
                        if (_embeddedArea(episodes) != null)
                          SliverToBoxAdapter(child: _embeddedArea(episodes)!)
                        else
                          SliverToBoxAdapter(
                            child: _hero(
                              drama,
                              ready:
                                  allowed && !_loading && episodes.isNotEmpty,
                              resumeIndex: resumeIndex,
                            ),
                          ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                            child: _overview(drama),
                          ),
                        ),
                        if (_loading || _error != null || episodes.isEmpty)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: _episodeStatus(),
                          )
                        else ...[
                          SliverToBoxAdapter(child: _seriesSelector(drama)),
                          SliverToBoxAdapter(child: _lineSelector()),
                          SliverToBoxAdapter(
                            child: _episodeSummary(
                              episodes,
                              currentNumber: watched?.episode,
                              expanded: showEpisodes,
                            ),
                          ),
                          if (showEpisodes) ...[
                            SliverToBoxAdapter(
                              child: EpisodeRangeBar(
                                key: _episodeAnchor,
                                episodes: episodes,
                                page: _episodePage,
                                title: '分组',
                                currentNumber: watched?.episode,
                                onLocate: _locateEpisode,
                              ),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                              sliver: SliverGrid(
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: _episodeColumns(
                                        constraints.maxWidth,
                                      ),
                                      mainAxisExtent: _episodeCardExtent(
                                        context,
                                        constraints.maxWidth,
                                      ),
                                      crossAxisSpacing: 10,
                                      mainAxisSpacing: 10,
                                    ),
                                delegate: SliverChildBuilderDelegate((
                                  context,
                                  index,
                                ) {
                                  final episode = visible[index];
                                  final tmdb = tmdbMatched[start + index];
                                  return _EpisodePreviewCard(
                                    key: ValueKey('episode-${episode.number}'),
                                    episode: episode,
                                    tmdb: tmdb,
                                    stillUrl: tmdb == null
                                        ? ''
                                        : _tmdbConfig.imageUrl(
                                            tmdb.stillPath,
                                            size: 'w500',
                                          ),
                                    posterUrl: posterFallback,
                                    current: episode.number == watched?.episode,
                                    onPressed: () => _play(start + index),
                                  );
                                }, childCount: visible.length),
                              ),
                            ),
                          ],
                        ],
                        if (!_loading) ...[
                          SliverToBoxAdapter(child: _descriptionSection(drama)),
                          SliverToBoxAdapter(child: _magnetSection()),
                          SliverToBoxAdapter(child: _relatedSection(drama)),
                        ],
                        if (useGlass)
                          SliverToBoxAdapter(
                            child: SizedBox(
                              height: 88 + MediaQuery.paddingOf(context).bottom,
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          extendBody: useGlass,
          bottomNavigationBar: useGlass
              ? _glassPlayBar(allowed, episodes, resumeIndex, watched)
              : Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: SafeArea(
                    top: false,
                    child: Center(
                      heightFactor: 1,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1000),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  key: const ValueKey('start-play'),
                                  autofocus: television,
                                  focusNode: _playFocus,
                                  style: FilledButton.styleFrom(
                                    minimumSize: const Size(0, 52),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                  ),
                                  onPressed:
                                      !allowed || _loading || episodes.isEmpty
                                      ? null
                                      : () => _play(resumeIndex, resume: true),
                                  icon: const Icon(
                                    Icons.play_arrow_rounded,
                                    size: 26,
                                  ),
                                  label: Text(
                                    watched != null && episodes.isNotEmpty
                                        ? '继续播放 · 第 ${episodes[resumeIndex].number} 集'
                                        : '立即播放',
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _glassPlayBar(
    bool allowed,
    List<Episode> episodes,
    int resumeIndex,
    WatchEntry? watched,
  ) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final ready = allowed && !_loading && episodes.isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottom < 18 ? 12 : bottom - 6),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: LiquidGlass(
            borderRadius: const BorderRadius.all(Radius.circular(34)),
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: Row(
                children: [
                  Expanded(
                    child: PressableScale(
                      enabled: ready,
                      pressedScale: .97,
                      child: FilledButton.icon(
                        key: const ValueKey('start-play'),
                        focusNode: _playFocus,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 52),
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                        ),
                        onPressed: ready
                            ? () {
                                HapticFeedback.lightImpact();
                                _play(resumeIndex, resume: true);
                              }
                            : null,
                        icon: const Icon(LucideIcons.play, size: 20),
                        label: Text(
                          watched != null && episodes.isNotEmpty
                              ? '继续播放 · 第 ${episodes[resumeIndex].number} 集'
                              : '立即播放',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hero(Drama drama, {required bool ready, required int resumeIndex}) {
    Widget playButton() {
      return Center(
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.3),
            border: Border.all(color: Colors.white70, width: 1.5),
          ),
          child: const Icon(
            Icons.play_arrow_rounded,
            color: Colors.white,
            size: 44,
          ),
        ),
      );
    }

    Widget posterTap() {
      return Positioned.fill(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: ready ? () => _play(resumeIndex, resume: true) : null,
          ),
        ),
      );
    }

    final detail = _detail;
    final shown = _tmdbPosterDrama(drama);
    final tmdbBackdrop = _tmdb?.backdropUrl(_tmdbConfig) ?? '';
    final backdrop = detail?.backdrop ?? '';
    final urls = <String>[
      if (tmdbBackdrop.isNotEmpty) tmdbBackdrop,
      if (backdrop.isNotEmpty && backdrop != tmdbBackdrop) backdrop,
      for (final still in detail?.stills ?? const <String>[])
        if (still.isNotEmpty && still != backdrop && still != tmdbBackdrop)
          still,
    ];
    if (urls.isEmpty || !_viewing.posterBackgroundActive) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DramaCover(drama: shown, repository: widget.repository, radius: 0),
            posterTap(),
            playButton(),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AtmosphereBackground(
                url: urls.first,
                repository: widget.repository,
                drama: Drama(
                  id: '${drama.id}#backdrop',
                  source: drama.source,
                  title: drama.title,
                  cover: urls.first,
                ),
              ),
              DramaCover(
                key: ValueKey('backdrop-${urls.first}'),
                drama: Drama(
                  id: '${drama.id}#backdrop',
                  source: drama.source,
                  title: drama.title,
                  cover: urls.first,
                ),
                repository: widget.repository,
                radius: 0,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black12, Colors.black45],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    SizedBox(
                      width: 104,
                      height: 148,
                      child: DramaCover(
                        drama: shown,
                        repository: widget.repository,
                        radius: 12,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            drama.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (drama.episodes > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                '共 ${drama.episodes} 集',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              posterTap(),
              playButton(),
            ],
          ),
        ),
        if (urls.length > 1)
          SizedBox(
            height: 92,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              itemCount: urls.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.only(right: 10),
                child: SizedBox(
                  width: 128,
                  child: DramaCover(
                    key: ValueKey('still-$index-${urls[index]}'),
                    drama: Drama(
                      id: '${drama.id}#still$index',
                      source: drama.source,
                      title: drama.title,
                      cover: urls[index],
                    ),
                    repository: widget.repository,
                    radius: 10,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _descriptionSection(Drama drama) {
    final tmdbOverview = _tmdb?.overview ?? '';
    final overview = tmdbOverview.isNotEmpty ? tmdbOverview : drama.description;
    final fromTmdb = tmdbOverview.isNotEmpty;
    if (overview.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('简介', style: Theme.of(context).textTheme.titleMedium),
              if (fromTmdb) ...[
                const SizedBox(width: 8),
                Text(
                  '资料来源：TMDB',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            overview,
            maxLines: _expandedDescription ? null : 3,
            overflow: _expandedDescription
                ? TextOverflow.visible
                : TextOverflow.ellipsis,
            style: TextStyle(color: colors.onSurfaceVariant, height: 1.6),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () =>
                  setState(() => _expandedDescription = !_expandedDescription),
              child: Text(_expandedDescription ? '收起简介' : '展开简介'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _magnetSection() {
    final magnets = _detail?.magnets ?? const <MagnetLink>[];
    if (magnets.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('磁力链接', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '种子引擎未接入：点开可解析与保存，不能下载、不能播放',
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 8),
          for (final magnet in magnets)
            ListTile(
              key: ValueKey('detail-magnet-${magnet.url}'),
              contentPadding: EdgeInsets.zero,
              title: Text(magnet.name.isEmpty ? '磁力链接' : magnet.name),
              subtitle: magnet.metaLabel.isEmpty
                  ? null
                  : Text(magnet.metaLabel),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(
                appPageRoute<void>(
                  builder: (_) => TorrentHomePage(initialMagnet: magnet.url),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tmdbEpisodeSection() {
    final tmdb = _tmdb;
    if (tmdb == null || !tmdb.isTv || tmdb.episodes.isEmpty) {
      return const SizedBox.shrink();
    }
    final shown = tmdb.episodes.take(10).toList();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('剧集预览', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 8),
              Text(
                '资料来源：TMDB',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final episode in shown)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: CircleAvatar(child: Text('${episode.episodeNumber}')),
              title: Text(
                episode.name.isEmpty
                    ? '第 ${episode.episodeNumber} 集'
                    : episode.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: episode.airDate.isNotEmpty
                  ? Text(episode.airDate)
                  : null,
            ),
          if (tmdb.episodes.length > shown.length)
            Text(
              '共 ${tmdb.episodes.length} 集',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _relatedSection(Drama drama) {
    final related = _detail?.related ?? const <Drama>[];
    if (related.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('相关推荐', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = (constraints.maxWidth / 150).floor().clamp(2, 6);
              final tileWidth =
                  (constraints.maxWidth - (columns - 1) * 10) / columns;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  mainAxisExtent: DramaTile.extentFor(context, tileWidth),
                ),
                itemCount: related.length,
                itemBuilder: (context, index) => DramaTile(
                  key: ValueKey('related-${related[index].id}'),
                  drama: related[index],
                  repository: widget.repository,
                  onTap: () => _openRelated(related, related[index]),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _openRelated(List<Drama> related, Drama target) async {
    if (_profileEpoch != widget.store.profileEpoch ||
        target.id == (_detail?.drama.id ?? widget.drama.id)) {
      return;
    }
    await Navigator.of(context).push(
      appPageRoute<void>(
        settings: const RouteSettings(name: 'detail'),
        builder: (_) => DetailScreen(
          drama: target,
          repository: widget.repository,
          store: widget.store,
          onTagTap: widget.onTagTap,
          queue: PlaybackQueue.around(related, target),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _episodeStatus() {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator.adaptive(),
        ),
      );
    }
    return StatusPanel(
      title: _error != null ? '剧集信息暂时不可用' : '暂时没有可播放的集数',
      message: _error ?? '可以更新剧集信息后重试。',
      onRetry: _load,
      secondaryAction: _sourceDiagnostics,
    );
  }

  Widget _episodeSummary(
    List<Episode> episodes, {
    required int? currentNumber,
    required bool expanded,
  }) {
    final colors = Theme.of(context).colorScheme;
    final current = currentNumber == null ? '' : ' · 当前第 $currentNumber 集';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Material(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _episodesExpanded = !expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.grid_view_rounded, color: colors.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '选集 · ${episodes.length} 集$current',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(expanded ? '收起' : '展开'),
                const SizedBox(width: 2),
                Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _lineSelector() {
    final detail = _detail;
    if (detail == null || !_hasAudioLine(detail)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Row(
        children: [
          ChoiceChip(
            label: const Text('阅读'),
            selected: !_audioLine,
            onSelected: (_) {
              if (_audioLine) {
                setState(() {
                  _audioLine = false;
                  _embeddedIndex = null;
                });
              }
            },
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('听书'),
            selected: _audioLine,
            onSelected: (_) {
              if (!_audioLine) {
                setState(() {
                  _audioLine = true;
                  _embeddedIndex = null;
                });
              }
            },
          ),
        ],
      ),
    );
  }

  void _locateEpisode(int index) {
    setState(() {
      _episodePage = index ~/ episodePageSize;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final anchor = _episodeAnchor.currentContext;
      if (!mounted || anchor == null || !_detailScroll.hasClients) return;
      final render = anchor.findRenderObject();
      if (render is! RenderBox || !render.hasSize) return;
      final viewport = RenderAbstractViewport.maybeOf(render);
      if (viewport == null) return;
      final start = viewport.getOffsetToReveal(render, 0).offset;
      final extent = _episodeCardExtent(context, render.size.width);
      final columns = _episodeColumns(render.size.width);
      final target =
          start +
          render.size.height +
          (index % episodePageSize ~/ columns) * (extent + 10) -
          _detailScroll.position.viewportDimension * .3;
      _detailScroll.animateTo(
        target.clamp(0.0, _detailScroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  int _episodeColumns(double width) {
    // 预览图卡片：单卡最小约 168 逻辑像素，手机 2 列、宽屏最多 4 列。
    return ((width - 40) / 176).floor().clamp(2, 4);
  }

  /// 预览图卡片的网格高度：16:9 图 + 文字区（标题一行 + 副标题一行，
  /// 随文字缩放放大，上限 1.4 倍）。网格与定位滚动共用同一算法。
  double _episodeCardExtent(BuildContext context, double width) {
    final columns = _episodeColumns(width);
    final tileWidth = (width - 40 - (columns - 1) * 10) / columns;
    final factor = MediaQuery.textScalerOf(context).scale(14) / 14;
    final textScale = math.min(1.4, math.max(1.0, factor));
    return tileWidth * 9 / 16 + 56 * textScale;
  }

  List<DetailTag> _effectiveTags(Drama drama) {
    final structured = _detail?.tags ?? const <DetailTag>[];
    if (structured.isNotEmpty) return structured;
    return [for (final name in drama.tags) DetailTag(id: name, name: name)];
  }

  void _onTagPressed(Drama drama, DetailTag tag) {
    final onTagTap = widget.onTagTap;
    if (onTagTap != null) {
      onTagTap(drama.source, tag.id, tag.name);
      return;
    }
    // TODO(shell): 标签目录入口未注入时仅提示，接入后走 onTagTap 回调。
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('标签浏览入口待接入')));
  }

  Widget _overview(Drama drama) {
    final colors = Theme.of(context).colorScheme;
    final shown = _tmdbPosterDrama(drama);
    final meta = [
      SourceSite.byId(drama.source).name,
      if (drama.episodes > 0) '共 ${drama.episodes} 集',
      if (drama.releaseStatus.isNotEmpty && drama.releaseStatus != 'unknown')
        drama.releaseLabel,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 92,
              height: 138,
              child: DramaCover(drama: shown, repository: widget.repository),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    drama.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    meta.join(' · '),
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  if (drama.category.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        drama.category,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ),
                  if (drama.source == 'huangdou')
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        drama.vipStatus == null
                            ? 'VIP 状态待补齐'
                            : drama.vip
                            ? 'VIP 内容'
                            : '免费内容',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _followingControls(drama),
        _sourceSwitcher(drama),
        if (drama.onlineDate.isNotEmpty ||
            drama.heat.isNotEmpty ||
            drama.views.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              [
                if (drama.onlineDate.isNotEmpty) '${drama.onlineDate} 上线',
                if (drama.heat.isNotEmpty) '热度 ${drama.heat}',
                if (drama.views.isNotEmpty) '播放 ${drama.views}',
              ].join(' · '),
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          ),
        if (_effectiveTags(drama).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in _effectiveTags(drama).take(12))
                  ActionChip(
                    key: ValueKey('detail-tag-${tag.id}'),
                    label: Text(tag.name),
                    onPressed: () => _onTagPressed(drama, tag),
                  ),
              ],
            ),
          ),
        if (_detail?.warning.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _detail!.warning,
              style: TextStyle(color: colors.error),
            ),
          ),
      ],
    );
  }

  Widget _seriesSelector(Drama drama) {
    final entries = hongguoSeriesEntries(
      drama,
      widget.store.seriesDramasFor(drama),
    );
    if (entries.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final notices = widget.store.following(drama.id)?.seriesSeasons ?? const {};
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('相关推荐', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in entries)
                ChoiceChip(
                  key: ValueKey('series-${entry.drama.id}'),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            '${entry.label} · ${entry.drama.title}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (notices[entry.drama.id]?.read == false) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.fiber_new_rounded,
                            size: 18,
                            color: colors.primary,
                          ),
                        ],
                      ],
                    ),
                  ),
                  selected: entry.drama.id == drama.id,
                  onSelected: entry.drama.id == drama.id
                      ? null
                      : (_) => _openSeriesDrama(entry.drama),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _followingControls(Drama drama) {
    final ready = !_loading && (_detail?.episodes.isNotEmpty ?? false);
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          key: const ValueKey('join-watch-room'),
          onPressed: ready ? () => unawaited(_pushToWatchRoom()) : null,
          icon: const Icon(Icons.meeting_room_rounded, size: 20),
          label: const Text('加入房间一起看'),
        ),
      ],
    );
  }
}

/// 详情页选集区的预览图卡片：16:9 剧照（TMDB still 优先、本剧海报
/// 兜底、都没有时显示带集号的占位块）+ 左上角集号角标 + 可播标题
/// + TMDB 集名/播出日期副标题。点按播放该集；图片加载失败时只显示
/// 占位块，不闪退、不留空白。无时长字段，卡片上不显示时长。
class _EpisodePreviewCard extends StatelessWidget {
  const _EpisodePreviewCard({
    super.key,
    required this.episode,
    required this.tmdb,
    required this.stillUrl,
    required this.posterUrl,
    required this.current,
    required this.onPressed,
  });

  final Episode episode;
  final TmdbEpisode? tmdb;
  final String stillUrl;
  final String posterUrl;
  final bool current;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final imageUrl = stillUrl.isNotEmpty ? stillUrl : posterUrl;
    final subtitleParts = <String>[
      if (tmdb != null &&
          tmdb!.name.isNotEmpty &&
          tmdb!.name != episode.title)
        tmdb!.name,
      if (tmdb != null && tmdb!.airDate.isNotEmpty) tmdb!.airDate,
    ];
    final subtitle = subtitleParts.join(' · ');
    return Semantics(
      button: true,
      label: '第 ${episode.number} 集${episode.vip ? '，VIP 试看' : ''}',
      child: Material(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: current ? colors.primary : colors.outlineVariant,
                width: current ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              colors.surfaceContainerHighest,
                              colors.surfaceContainer,
                            ],
                          ),
                        ),
                        child: Center(
                          child: Text(
                            '${episode.number}',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: colors.onSurfaceVariant.withValues(
                                alpha: .55,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (imageUrl.isNotEmpty && !DramaCover.imagesDisabled)
                        Image.network(
                          imageUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              const SizedBox.shrink(),
                        ),
                      Positioned(
                        left: 6,
                        top: 6,
                        child: _badge('${episode.number}'),
                      ),
                      if (episode.vip)
                        Positioned(
                          right: 6,
                          top: 6,
                          child: _badgeIcon(Icons.workspace_premium_rounded),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        episode.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(
                          fontWeight: current
                              ? FontWeight.w700
                              : FontWeight.w600,
                          color: current ? colors.primary : null,
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _badge(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget _badgeIcon(IconData icon) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Icon(icon, size: 14, color: Colors.white),
  );
}
