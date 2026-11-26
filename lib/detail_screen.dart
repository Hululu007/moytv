import 'dart:async';

import 'app_page_route.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'adult_scrape_service.dart';
import 'app_layout.dart';
import 'atmosphere_background.dart';
import 'catalog_browser.dart';
import 'content_crypto.dart';
import 'crosssite_probe.dart';
import 'crosssite_probe_section.dart';
import 'ios_dialogs.dart';
import 'core_bridge.dart';
import 'cloud_drive/cloud_115_offline.dart';
import 'cloud_drive/cloud_drive_types.dart';
import 'local_store.dart';
import 'models.dart';
import 'package:media_kit/media_kit.dart';

import 'playback_queue.dart';
import 'player_picker.dart';
import 'player_screen.dart';
import 'widgets.dart';
import 'sources_screen.dart';
import 'episode_browser.dart';
import 'episode_frame_cache.dart';
import 'episode_frame_service.dart';
import 'episode_preview_card.dart';
import 'frame_extractor.dart';
import 'nonvideo_content.dart';
import 'follow_state.dart';
import 'hongguo_cloud_records.dart';
import 'hongguo_danmaku.dart';
import 'hongguo_series.dart';
import 'tmdb/tmdb_config.dart';
import 'tmdb/tmdb_metadata.dart';
import 'tmdb/tmdb_service.dart';
import 'viewing_experience_settings.dart';
import 'actress/actress_online_detail.dart';
import 'actress/actress_online_lines.dart';
import 'actress/actress_online_sources.dart';
import 'actress/code_meta_section.dart';
import 'actress/jav_code_meta.dart';
import 'actress/javdb_api.dart';
import 'actress/javdb_image.dart';

typedef DetailTagTap =
    void Function(String sourceId, String tagId, String tagName);

/// 详情页换线回调的返回值：下一条线路的详情与起播集序号。
typedef DetailNextLine = ({DramaDetail detail, int episodeIndex});

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
    this.autoPlayOnOpen = false,
    this.autoPlayEpisodeIndex = 0,
    this.initialDetail,
    this.nextLineOnExhausted,
    this.onRetryProbe,
    this.onTagTap,
    this.queue,
    this.playerFactory,
    this.videoBuilder,
    this.javdbStillsClient,
    this.pan115Gateway,
  });
  final Drama drama;
  final AppRepository repository;
  final LocalStore store;
  final bool resumeOnOpen;

  /// 进页即播：详情取回后立即播 [autoPlayEpisodeIndex] 指定的集
  /// （演员库点卡流程注入，MJV 命中直进详情页并播放）。
  final bool autoPlayOnOpen;
  final int autoPlayEpisodeIndex;

  /// 点卡带进来的候选详情（演员库点作品时数据库那条的集数，直链）：
  /// 站点详情取回是空的（该站未返回详情）时用它的集数播，不丢掉，
  /// 否则明明数据库里有地址也显示“暂时没有可播放的集数”。站点
  /// 有集数时照旧用站点的。不传时行为与此前一字不差。
  final DramaDetail? initialDetail;

  /// 播放耗尽时的换线回调（演员库点卡流程注入）：内嵌播放或跨站
  /// 线路播放耗尽时调用，返回下一条可播线路；返回 null 表示链
  /// 耗尽，保留播放器原错误界面。不传时行为与此前一字不差。
  final Future<DetailNextLine?> Function()? nextLineOnExhausted;

  /// 重试重探回调（演员库点卡流程注入）：播放器报错屏点“重试播放”
  /// 时调——调用方先把链 resetForRetry 再重探，返回下一条可播
  /// 线路；返回 null 表示重探无果，播放器再原地重播同一集。
  /// 不传时重试行为与此前一字不差。只接推出去的播放页，内嵌
  /// 播放器不接（内嵌没有可弹的路由，误接会把详情页本身弹掉）。
  final Future<DetailNextLine?> Function()? onRetryProbe;

  /// 标签点击回调：以 sourceId + tagId 打开该标签的目录列表。
  /// TODO(shell): 目录侧标签列表入口由壳子代理提供并在构造 DetailScreen 时
  /// 注入；未注入时标签仅展示、点击给未接入提示。
  final DetailTagTap? onTagTap;

  /// 进入播放时透传给播放器的列表上下文队列（单集上下滑切条目用）。
  final PlaybackQueue? queue;
  final Player Function()? playerFactory;
  final Widget Function(Widget controls)? videoBuilder;

  /// JavDB 补充链用的接口客户端（剧照补图见 _loadJavdbStills；
  /// 磁力/评论/信息卡系列与评分见 _loadJavdbExtras）。只供测试/
  /// 预览注入，不传时用默认客户端走真接口。
  final JavdbApiClient? javdbStillsClient;

  /// 115 网关（演员库详情页的离线/播放接入，见 _startPan115）：
  /// 演员库入口构造时由 NativeRepository 注入，登录态走网盘
  /// 引擎既有 115 登录；不传时 115 区不出现，其余行为不变。
  /// 只供演员库链与测试注入。
  final Pan115Gateway? pan115Gateway;
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  DramaDetail? _detail;
  String? _error;
  bool _loading = true;
  Set<String> _frameKeys = {};
  late final EpisodeFrameService _frameService;
  int _generation = 0;
  int _episodePage = 0;
  bool _expandedDescription = false;
  bool _episodesExpanded = false;
  final _episodeAnchor = GlobalKey();
  final _detailScroll = ScrollController();
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

  /// 头区演员行匹配结果（番号 → 演员与导演）：详情加载后按番号查
  /// 三站元数据 + who's 索引（与 CodeMetaSection 同一份匹配）。
  /// null = 未匹配到或尚未查完，头区不画演员行。
  CodeMeta? _codeMeta;

  /// JavDB 补充链用的客户端：构造方注入优先，否则本页自建
  /// 一个（无请求时不产生流量）。
  late final JavdbApiClient _javdbStillsClient =
      widget.javdbStillsClient ?? JavdbApiClient();

  /// JavDB 按番号补的磁力（_loadJavdbExtras 填）：空时磁力区
  /// 不显示。走本页自己的区（点按复制），不并入 _detail.magnets
  /// ——通用 _magnetSection 的点按口径是「暂不支持播放」提示，
  /// 与本链的复制口径不合，改它会动通用详情页既有行为。
  List<MagnetLink> _javdbMagnets = const [];

  /// JavDB 按番号补的评论（_loadJavdbExtras 填）：空时评论区
  /// 不显示，只读展示。
  List<JavdbReview> _javdbReviews = const [];

  /// 115 区状态（_startPan115 / _pollPan115 维护）：未登录只
  /// 显示一行提示；网盘已存该番号文件时出播放行；已自动离
  /// 线未下完时显示进度，下完转播放行；都没命中整区不显示。
  bool _pan115LoginHint = false;
  CloudDriveFile? _pan115File;
  bool _pan115Submitted = false;
  double? _pan115Percent;

  /// 已启动过 115 流程（防重复进入）；_pan115Checked 在
  /// 「已登录且网盘无文件、无在跑任务」确认后置真，磁力到
  /// 齐后 _maybeSubmitPan115 只在此后才许提交。
  bool _pan115Started = false;
  bool _pan115Checked = false;
  Timer? _pan115Timer;

  /// 推荐视频（本站同分类优先）：空时推荐区隐藏，不留空壳。
  List<Drama> _recommended = const [];

  /// 文件夹详情的作品列表（vod_tag='folder' 的详情，如 MissAV 女优
  /// folder）：详情加载后以 folderId/id 作 category 调目录，画成
  /// 作品卡片网格，不画选集区；目录失败/回空时退回选集 UI 并提示重试。
  List<Drama> _folderItems = const [];
  bool _folderLoading = false;
  bool _folderLoadingMore = false;
  bool _folderFailed = false;
  bool _folderMoreFailed = false;
  bool _folderHasMore = false;
  int _folderPage = 1;
  // 站方相关接口返回的相关季：只作相关剧集区的优先数据，接口不可
  // 用时该区回落标题规律；空时不额外占位。
  List<HongguoRelatedWork> _apiRelated = const [];
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
    // 未播集真帧：后台取帧服务随详情页创建，复用播放链解析、
    // 原生取帧、现有帧缓存；帧到后并入 _frameKeys，网格卡刷新显示。
    final extractor = FrameExtractor();
    _frameService = EpisodeFrameService(
      resolve: widget.repository.resolve,
      extract: extractor.extract,
      release: widget.repository.release,
      cachedKeys: () => _frameKeys,
      onFrame: (key) {
        if (mounted) {
          setState(() => _frameKeys = {..._frameKeys, key});
        }
      },
    );
    _load();
    unawaited(_loadViewing());
    unawaited(_loadFrameKeys());
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
    _pan115Timer?.cancel();
    _frameService.dispose();
    _detailScroll.dispose();
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

  /// 头区演员行：按番号查三站元数据 + who's 索引（与 CodeMetaSection
  /// 同一份匹配，见 code_meta_section.dart）。代次守卫：刷新后旧
  /// 结果不再写回。查不到时 _codeMeta 为 null，头区不画演员行、
  /// 标签照常显示。
  Future<void> _refreshCodeMeta(Drama drama, int generation) async {
    final meta = await loadCodeMetaForDrama(
      dramaId: drama.id,
      title: drama.title,
      sourceId: drama.sourceId,
    );
    if (!mounted || generation != _generation) return;
    setState(() => _codeMeta = meta);
  }

  /// 剧照补图（2026-11-26）：本地库 / who's 等入口打开的作品
  /// 详情自带剧照为空时，按番号去 JavDB 接口补预览图（番号精
  /// 确相等才认，见 actressJavdbStillsSupplement）。与
  /// _refreshCodeMeta 同一处后台补充链：不挡开页、不报错、
  /// 拉不到保持空、已有剧照不覆盖。JavDB 入口的作品开页时
  /// 已按作品 id 拉过详情补充（openJavdbWork），这里不重复
  /// 拉。代次守卫：换片后旧结果不再写回；写回前再查一次剧
  /// 照仍为空（期间页面自带剧照若已补上就不覆盖）。
  Future<void> _loadJavdbStills(Drama drama, int generation) async {
    if (drama.source == 'javdb') return;
    final detail = _detail;
    if (detail == null || detail.stills.isNotEmpty) return;
    final avId = extractAvId(
      title: drama.title,
      id: drama.id,
      sourceId: drama.sourceId,
    );
    if (avId == null) return;
    final stills = await actressJavdbStillsSupplement(
      current: detail.stills,
      code: avId,
      client: _javdbStillsClient,
    );
    if (!mounted || generation != _generation) return;
    final current = _detail;
    if (current == null || current.stills.isNotEmpty || stills.isEmpty) {
      return;
    }
    setState(() {
      _detail = current.withStills(stills);
    });
  }

  /// JavDB 补充第二路（2026-11-26）：磁力区 + 评论区 + 信息卡
  /// 的系列/评分，与 _loadJavdbStills 同一处后台补充链。按番
  /// 号精确命中 JavDB 作品后并行取三路（磁力、评论、详情），
  /// 每路独立约 6 秒超时、独立失败回空：没数据整区不显示、
  /// 不挡开页、不弹窗。JavDB 入口的作品 sourceId 就是 JavDB
  /// 作品 id，直接用、不再搜索。系列/评分只在详情自带
  /// extraInfo 没有同名行时才并入（本地库自带真值照旧优先），
  /// 评分照接口原值、人数照接口原值，都没给就不显示、不编。
  Future<void> _loadJavdbExtras(Drama drama, int generation) async {
    final avId = extractAvId(
      title: drama.title,
      id: drama.id,
      sourceId: drama.sourceId,
    );
    if (avId == null) return;
    final client = _javdbStillsClient;
    var movieId = '';
    if (drama.source == 'javdb' && drama.sourceId.isNotEmpty) {
      movieId = drama.sourceId;
    } else {
      try {
        final hits = await client
            .searchMovies(avId)
            .timeout(const Duration(seconds: 6));
        final wanted = actressCodeKey(avId);
        for (final hit in hits) {
          if (hit.id.isNotEmpty && actressCodeKey(hit.number) == wanted) {
            movieId = hit.id;
            break;
          }
        }
      } catch (_) {
        return;
      }
    }
    if (movieId.isEmpty) return;
    final magnetsFuture = () async {
      try {
        return await client
            .movieMagnets(movieId)
            .timeout(const Duration(seconds: 6));
      } catch (_) {
        return const <MagnetLink>[];
      }
    }();
    final reviewsFuture = () async {
      try {
        return await client
            .movieReviews(movieId)
            .timeout(const Duration(seconds: 6));
      } catch (_) {
        return const <JavdbReview>[];
      }
    }();
    final extraFuture = () async {
      try {
        return await client
            .movieExtra(movieId)
            .timeout(const Duration(seconds: 6));
      } catch (_) {
        return const JavdbMovieExtra();
      }
    }();
    final magnets = await magnetsFuture;
    final reviews = await reviewsFuture;
    final extra = await extraFuture;
    if (!mounted || generation != _generation) return;
    setState(() {
      if (magnets.isNotEmpty) _javdbMagnets = magnets;
      if (reviews.isNotEmpty) _javdbReviews = reviews;
      final detail = _detail;
      if (detail != null) {
        var series = '';
        for (final row in extra.extraInfo) {
          if (row.$1 == '系列') series = row.$2;
        }
        final additions = <(String, String)>[
          if (series.isNotEmpty &&
              !detail.extraInfo.any((row) => row.$1 == '系列'))
            ('系列', series),
          if (extra.score.isNotEmpty &&
              !detail.extraInfo.any((row) => row.$1 == '评分'))
            (
              '评分',
              extra.scoreCount > 0
                  ? '${extra.score}（共 ${extra.scoreCount} 人评分）'
                  : extra.score,
            ),
        ];
        if (additions.isNotEmpty) {
          _detail = detail.withExtraInfo([
            ...detail.extraInfo,
            ...additions,
          ]);
        }
      }
    });
    // 磁力到齐后 115 自动离线才有提交对象（_startPan115 已
    // 确认网盘无文件/无在跑任务时才真提交，去重在方法内）。
    unawaited(_maybeSubmitPan115(avId, generation));
  }

  /// 115 区启动（2026-11-26）：与 JavDB 补充同一处后台链。
  /// 未登录只出一行提示、不提交不报错；网盘已存该番号文件
  /// 直接出播放行；有同番号/同 hash 的离线任务在跑就显示
  /// 进度并轮询，下完转播放行；都没有时置 _pan115Checked，
  /// 等磁力到齐由 _maybeSubmitPan115 自动提交一次。没磁力
  /// 也没文件时整区不显示。全程不挡页、不弹窗、不跳网盘页。
  Future<void> _startPan115(Drama drama, int generation) async {
    final gateway = widget.pan115Gateway;
    if (gateway == null || _pan115Started) return;
    final avId = extractAvId(
      title: drama.title,
      id: drama.id,
      sourceId: drama.sourceId,
    );
    if (avId == null) return;
    _pan115Started = true;
    try {
      if (!await gateway.isLoggedIn()) {
        if (!mounted || generation != _generation) return;
        setState(() => _pan115LoginHint = true);
        return;
      }
      final file = await gateway
          .findFileByCode(avId)
          .timeout(const Duration(seconds: 20), onTimeout: () => null);
      if (!mounted || generation != _generation) return;
      if (file != null) {
        setState(() => _pan115File = file);
        return;
      }
      final task = await _pan115TaskFor(gateway, avId);
      if (!mounted || generation != _generation) return;
      if (task != null && !task.done) {
        setState(() {
          _pan115Submitted = true;
          _pan115Percent = task.percent;
        });
        _startPan115Polling(avId, generation);
        return;
      }
      _pan115Checked = true;
      await _maybeSubmitPan115(avId, generation);
    } catch (_) {
      // 115 链任何失败都只让本区不显示，不挡详情页。
    }
  }

  /// 在离线任务里找这部作品的任务：磁力 hash 命中或任务名
  /// 含番号（归一化）任一成立。找不到回 null。
  Future<Pan115OfflineTask?> _pan115TaskFor(
    Pan115Gateway gateway,
    String avId,
  ) async {
    final tasks = await gateway
        .listOfflineTasks()
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => const <Pan115OfflineTask>[],
        );
    final key = pan115CodeKeyOf(avId);
    final hashes = {
      for (final magnet in _javdbMagnets) pan115InfoHashOf(magnet.url),
    }..remove('');
    for (final task in tasks) {
      if (task.infoHash.isNotEmpty && hashes.contains(task.infoHash)) {
        return task;
      }
      if (key.isNotEmpty && pan115CodeKeyOf(task.name).contains(key)) {
        return task;
      }
    }
    return null;
  }

  /// 自动离线提交（用户「磁力自动离线 115」口径）：只在
  /// _startPan115 确认过「已登录、网盘无此文件、无在跑任务」
  /// 后、且本页已有 JavDB 磁力时提交排名第一条（movieMagnets
  /// 已照 jar 版 rankMagnets 排序去重，第一条即第一名）。
  /// 去重三道：
  /// ①本地已提交记录里有同 hash 不再提交（转入进度跟随）；
  /// ②提交前再查任务列表，同 hash 在列不提交；③网盘已有
  /// 文件不提交（_startPan115 已查、提交前再兜一次）。
  /// 提交成功记本地记录、页面明示「已提交 115 离线」并
  /// 轮询进度；失败整区回落不显示，不报错不弹窗。
  Future<void> _maybeSubmitPan115(String avId, int generation) async {
    final gateway = widget.pan115Gateway;
    if (gateway == null || !_pan115Checked) return;
    if (_pan115File != null || _pan115Submitted) return;
    if (_javdbMagnets.isEmpty) return;
    try {
      final magnet = _javdbMagnets.first;
      final hash = pan115InfoHashOf(magnet.url);
      if (await gateway.findFileByCode(avId) != null) return;
      final submitted = await gateway.submittedHashes();
      if (hash.isNotEmpty && submitted.contains(hash)) {
        await _followPan115Task(gateway, avId, generation);
        return;
      }
      final existing = await _pan115TaskFor(gateway, avId);
      if (existing != null) {
        if (!existing.done) {
          await _followPan115Task(gateway, avId, generation);
        }
        return;
      }
      final ok = await gateway
          .submitOffline(magnet.url)
          .timeout(const Duration(seconds: 15), onTimeout: () => false);
      if (!ok) return;
      await gateway.recordSubmitted(hash);
      if (!mounted || generation != _generation) return;
      setState(() {
        _pan115Submitted = true;
        _pan115Percent = null;
      });
      _startPan115Polling(avId, generation);
    } catch (_) {
      // 提交失败不提示、不挡页（磁力区仍可手动复制）。
    }
  }

  /// 转入进度跟随：显示已提交与当前进度并开始轮询。
  Future<void> _followPan115Task(
    Pan115Gateway gateway,
    String avId,
    int generation,
  ) async {
    final task = await _pan115TaskFor(gateway, avId);
    if (!mounted || generation != _generation) return;
    setState(() {
      _pan115Submitted = true;
      _pan115Percent = task?.percent;
    });
    _startPan115Polling(avId, generation);
  }

  void _startPan115Polling(String avId, int generation) {
    _pan115Timer?.cancel();
    _pan115Timer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_pollPan115(avId, generation));
    });
  }

  /// 轮询：文件出现（下载完成）即转播放行并停轮询；还在
  /// 跑就刷新进度。失败下轮再来，不提示。
  Future<void> _pollPan115(String avId, int generation) async {
    final gateway = widget.pan115Gateway;
    if (gateway == null) return;
    try {
      final file = await gateway
          .findFileByCode(avId)
          .timeout(const Duration(seconds: 20), onTimeout: () => null);
      if (!mounted || generation != _generation) return;
      if (file != null) {
        _pan115Timer?.cancel();
        setState(() {
          _pan115File = file;
          _pan115Submitted = false;
          _pan115Percent = null;
        });
        return;
      }
      final task = await _pan115TaskFor(gateway, avId);
      if (!mounted || generation != _generation) return;
      if (task != null) {
        setState(() => _pan115Percent = task.percent);
      }
    } catch (_) {
      // 轮询失败不提示。
    }
  }

  /// 115 播放：取直链后在本页直达正式播放器（与在线线路
  /// 同一条 pushPlayer 路径），不跳网盘页找文件（2026-11-26
  /// 用户令）。
  Future<void> _playPan115Line() async {
    final gateway = widget.pan115Gateway;
    final file = _pan115File;
    if (gateway == null || file == null) return;
    final link = await gateway.directLink(file);
    if (link == null || !mounted) return;
    final drama = widget.drama;
    final detail = DramaDetail(
      Drama(
        id: 'pan115:${file.id}',
        source: 'pan115',
        sourceId: file.id,
        title: drama.title,
        cover: drama.cover,
        tags: drama.tags,
      ),
      [
        Episode({
          'id': link.url,
          'title': '正片',
          'direct': true,
          'headers': link.headers,
        }, 1),
      ],
    );
    await _playActressOnlineLine(detail);
  }

  /// 海报点按（2026-11-26 直达口径）：115 已存该番号文件
  /// 时优先落 115 线路（20:10 起播口径：115 正常优先），
  /// 否则播当前详情线路（竞速赢家/库线路已在详情里），都
  /// 在本页直达播放器、不跳别页；115 还在下载中时照 jar
  /// 版 waitPlayable 等不完的口径给百分比提示，不硬播、
  /// 过会儿再点即秒开。
  void _playFromPoster(int resumeIndex) {
    final episodes = _detail?.episodes ?? const <Episode>[];
    if (_pan115File != null) {
      unawaited(_playPan115Line());
    } else if (episodes.isNotEmpty) {
      _play(resumeIndex, resume: true);
    } else if (_pan115Submitted) {
      _showPan115WaitHint();
    }
  }

  /// 115 下载中点按提示（照 jar 版等不完的回话）：带当前
  /// 百分比，明示过 1~2 分钟再点就是秒开。
  void _showPan115WaitHint() {
    final percent = _pan115Percent;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          percent == null
              ? '正在存到 115，过 1~2 分钟再点一次就是秒开'
              : '正在存到 115（已 ${(percent * 100).round()}%），'
                    '过 1~2 分钟再点一次就是秒开',
        ),
      ),
    );
  }

  Future<void> _loadTmdb(Drama drama) async {
    final config = await TmdbConfig.load();
    if (!mounted) return;
    // 不再以“填了 key”设门：没 key 时刮削链直接走不要 key 的公开源。
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

  /// 推荐视频：取本站同分类第一页，同分类优先、凑不满 6 个时用本站
  /// 首页补齐，排除当前这部；取不到数据时该区隐藏。代次守卫：换片后
  /// 旧请求结果不再写回。
  Future<void> _loadRecommended(Drama drama, int generation) async {
    var picked = <Drama>[];
    try {
      var categoryId = '';
      var menus = <CatalogCategory>[];
      try {
        menus = await widget.repository.categories(drama.source);
        final want = categoryName(drama.category);
        for (final menu in menus) {
          if (menu.id.isNotEmpty && categoryName(menu.name) == want) {
            categoryId = menu.id;
            break;
          }
        }
      } catch (_) {
        // 分类表拿不到就按全部取，不让推荐区空着。
      }
      final seen = <String>{drama.id};
      final first = await widget.repository.catalog(
        drama.source,
        category: categoryId,
        page: 1,
      );
      picked = [
        for (final item in first.items)
          if (seen.add(item.id)) item,
      ];
      if (picked.length < 6 && categoryId.isNotEmpty) {
        final fallback = await widget.repository.catalog(drama.source, page: 1);
        for (final item in fallback.items) {
          if (picked.length >= 6) break;
          if (seen.add(item.id)) picked.add(item);
        }
      }
      // 2026-11-24 推荐区修回来：分类匹配不到时（如潮流“成人影片”
      // 不在导航里）第一轮 category='' 对部分蜘蛛回空，之前到此
      // 就认空、推荐区直接消失。仍空时用导航第一个分类再补一轮，
      // 再空才认空。
      if (picked.isEmpty && menus.isNotEmpty) {
        final firstMenu = menus.firstWhere(
          (menu) => menu.id.isNotEmpty && menu.id != categoryId,
          orElse: () => menus.first,
        );
        if (firstMenu.id.isNotEmpty && firstMenu.id != categoryId) {
          final fallback = await widget.repository.catalog(
            drama.source,
            category: firstMenu.id,
            page: 1,
          );
          for (final item in fallback.items) {
            if (picked.length >= 6) break;
            if (seen.add(item.id)) picked.add(item);
          }
        }
      }
      picked = picked.take(6).toList();
    } catch (_) {
      picked = const [];
    }
    if (!mounted ||
        generation != _generation ||
        _profileEpoch != widget.store.profileEpoch) {
      return;
    }
    setState(() => _recommended = picked);
  }

  /// 是否文件夹详情：kind/folderId 是 py 侧的 folder 信号；jar 侧
  /// 的 folder 只在 vod_tag 里（jar 详情把 vod_tag 拆进详情 drama
  /// 的 tags），所以 tags 含 'folder' 也算。已核对：jar_bridge 的
  /// detail 与 _vodToDrama 都把 vod_tag 写进 tags，vod_tag='folder'
  /// 的详情一定命中本判断，无需在详情解析处另补信号。
  bool _isFolderDrama(Drama drama) {
    if (drama.isFolder || drama.folderId.isNotEmpty) return true;
    for (final tag in drama.tags) {
      if (tag.trim().toLowerCase() == 'folder') return true;
    }
    for (final tag in _detail?.tags ?? const <DetailTag>[]) {
      if (tag.name.trim().toLowerCase() == 'folder') return true;
    }
    return false;
  }

  /// 文件夹目录的 category 参数：folderId 优先，否则取 drama.id；
  /// 蜘蛛内部会剥 `folder@` 前缀，两种 id 都应能走。
  /// 已核对浏览网格条目 id 形态：jar 站条目 id 即 vod_id（中继
  /// detail/category 共用的那一个），py 站条目 folderId 即 vodId。
  String _folderCategoryId(Drama drama) {
    var id = drama.folderId.isNotEmpty ? drama.folderId : drama.id;
    if (id.startsWith('folder@')) id = id.substring('folder@'.length);
    return id;
  }

  /// 文件夹作品目录：以 [_folderCategoryId] 调本站目录，分页累加。
  /// 首屏失败/回空时记 [_folderFailed]，界面退回选集 UI 并提示重试；
  /// 翻页失败只记 [_folderMoreFailed]，已有卡片保留、“加载更多”
  /// 按钮变重试。代次守卫：换片后旧请求结果不再写回。
  Future<void> _loadFolder({bool reset = false}) async {
    final drama = _detail?.drama ?? widget.drama;
    final generation = _generation;
    if (reset) {
      setState(() {
        _folderLoading = true;
        _folderFailed = false;
        _folderMoreFailed = false;
        _folderItems = const [];
        _folderPage = 1;
        _folderHasMore = false;
      });
    } else {
      if (_folderLoadingMore || !_folderHasMore) return;
      setState(() {
        _folderLoadingMore = true;
        _folderMoreFailed = false;
      });
    }
    final page = reset ? 1 : _folderPage + 1;
    try {
      final result = await widget.repository.catalog(
        drama.source,
        category: _folderCategoryId(drama),
        page: page,
      );
      if (!mounted ||
          generation != _generation ||
          _profileEpoch != widget.store.profileEpoch) {
        return;
      }
      setState(() {
        _folderItems = reset
            ? result.items
            : [..._folderItems, ...result.items];
        _folderHasMore = result.hasMore;
        _folderPage = page;
        _folderLoading = false;
        _folderLoadingMore = false;
        _folderMoreFailed = false;
        // 目录回空：退回选集 UI（_folderFailed 为真时不画网格）。
        _folderFailed = _folderItems.isEmpty;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _folderLoading = false;
        _folderLoadingMore = false;
        if (reset || _folderItems.isEmpty) {
          _folderFailed = true;
        } else {
          _folderMoreFailed = true;
        }
      });
    }
  }

  /// 相关剧集区站方数据：只对红果数字 id 的剧调相关接口；接口抛错
  /// 或无数据时留空，相关区回落标题规律。代次守卫同推荐区。
  Future<void> _loadSeriesApi(Drama drama, int generation) async {
    var works = const <HongguoRelatedWork>[];
    final seriesId = drama.source == SourceSite.hongguo.id
        ? hongguoNumericId(drama.id)
        : null;
    if (seriesId != null) {
      try {
        works = await HongguoCloudRecords(
          widget.repository,
        ).fetchRelated(seriesId);
      } catch (_) {
        works = const [];
      }
    }
    if (!mounted ||
        generation != _generation ||
        _profileEpoch != widget.store.profileEpoch) {
      return;
    }
    setState(() => _apiRelated = works);
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _recommended = const [];
      _codeMeta = null;
      _apiRelated = const [];
      _folderItems = const [];
      _folderLoading = false;
      _folderLoadingMore = false;
      _folderFailed = false;
      _folderMoreFailed = false;
      _folderHasMore = false;
      _folderPage = 1;
    });
    try {
      final fetched = await widget.repository.detail(widget.drama);
      if (!mounted ||
          generation != _generation ||
          _profileEpoch != widget.store.profileEpoch) {
        return;
      }
      final merged = widget.repository.catalogUpdates
          .current(widget.drama)
          .merge(fetched.drama);
      // 演员库点卡带进来的候选集数（数据库里存的直链）：站点详情取
      // 回是空的（该站未返回详情）时不要丢掉它——就用这条播，否则
      // 明明数据库里有地址也显示“暂时没有可播放的集数”。站点有
      // 集数时照旧用站点的。
      final initial = widget.initialDetail;
      final detail =
          fetched.episodes.isEmpty &&
              initial != null &&
              initial.episodes.isNotEmpty
          ? initial.withDrama(merged)
          : fetched.withDrama(merged);
      setState(() {
        _detail = detail;
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
      unawaited(_loadRecommended(merged, generation));
      unawaited(_loadSeriesApi(merged, generation));
      unawaited(_refreshCodeMeta(merged, generation));
      unawaited(_loadJavdbStills(merged, generation));
      unawaited(_loadJavdbExtras(merged, generation));
      unawaited(_startPan115(merged, generation));
      if (_isFolderDrama(merged)) {
        unawaited(_loadFolder(reset: true));
      }
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
        } else if (widget.autoPlayOnOpen) {
          unawaited(
            _play(
              widget.autoPlayEpisodeIndex.clamp(0, detail.episodes.length - 1),
            ),
          );
        }
      }
    } catch (error) {
      if (!mounted || generation != _generation) {
        return;
      }
      // 2026-11-26：带了候选详情（initialDetail）且仓库详情抛
      // 错时落候选——演员库在线源（123AV/PH）没在仓库注册，
      // detail 必然抛错，但点卡时已经把详情与直链集备齐了，
      // 不该因为查不到站点就整页报错。集数回退口径与上面
      // “取回为空”分支一致；代码元数据照常后台补（演员行/
      // 信息卡靠它），其余补充链跳过（都要走仓库）。
      // JavDB 源例外：它是信息源、点开时本来就没有集数（线
      // 路靠跨站探活与在线线路区按番号自动搜），集数为空也
      // 落候选进页，不整页报错。
      final initial = widget.initialDetail;
      if (initial != null &&
          (initial.episodes.isNotEmpty || widget.drama.source == 'javdb')) {
        setState(() {
          _detail = initial.withDrama(widget.drama);
          _loading = false;
          _episodePage =
              resumeEpisodeIndex(
                initial.episodes,
                widget.store.watched(widget.drama.id),
              ) ~/
              episodePageSize;
        });
        unawaited(_refreshCodeMeta(widget.drama, generation));
        unawaited(_loadJavdbStills(widget.drama, generation));
        unawaited(_loadJavdbExtras(widget.drama, generation));
        unawaited(_startPan115(widget.drama, generation));
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
    } finally {
      // 兜底：提前返回（画像切换、异常）也不能把 _loading 挂死——
      // 挂死后海报点按会被门控卡住，而选集数据明明已显示。
      // 被更新一代取代时不碰（新一代自己负责复位），已卸载时不碰。
      if (mounted && generation == _generation && _loading) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _supplement(Drama drama, int generation) async {
    try {
      // 成人内容先走大站刮削链（MissAV 打头、AVDB 殿后），刮不到
      // 再落回现有原链；非成人内容新链零请求直接返回 null。
      final adult = AdultScrapeService(repository: widget.repository);
      var fresh = await adult.enrich(
        drama,
        candidateSites: widget.store.visibleSources,
        siteVisible: widget.store.siteVisible,
      );
      fresh ??= await widget.repository.supplementMetadata(drama);
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
    // 播放优先：停掉后台取帧（取帧解析与播放解析共用序列号通道），
    // 关播后网格重建时再续取剩余的集。
    _frameService.cancel();
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
        onPlaybackExhausted: widget.nextLineOnExhausted == null
            ? null
            : _onPushedPlayerExhausted,
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

  /// 跨站选线路起播：与本源线路同一条播放链（pushPlayer），
  /// 详情与集序号来自探活取回的对方站源详情。换线回调非空时
  /// （演员库点卡流程），播耗尽继续向回调要下一条线路。
  Future<void> _playCrossSite(DramaDetail detail, int index) async {
    if (index < 0 ||
        index >= detail.episodes.length ||
        _profileEpoch != widget.store.profileEpoch ||
        !widget.store.allowsSource(detail.drama.source)) {
      return;
    }
    _frameService.cancel();
    await pushPlayer<void>(
      context,
      detail: detail,
      initialIndex: index,
      repository: widget.repository,
      store: widget.store,
      queue: widget.queue,
      onPlaybackExhausted: widget.nextLineOnExhausted == null
          ? null
          : _onPushedPlayerExhausted,
      onRetryProbe: widget.onRetryProbe == null ? null : _onPlayerRetry,
    );
    if (mounted) {
      setState(() {});
    }
  }

  /// 内嵌播放耗尽：向换线回调要下一条线路，有就关内嵌、推新线
  /// 路的播放页；链耗尽时什么都不做，内嵌播放器原错误界面留着
  /// （不另弹提示，避免与播放器自身的错误提示打架）。
  Future<void> _onEmbeddedExhausted(BuildContext _) async {
    final nextLine = widget.nextLineOnExhausted;
    if (nextLine == null || !mounted) return;
    final next = await nextLine();
    if (!mounted || _profileEpoch != widget.store.profileEpoch) return;
    if (next == null) return;
    _closeEmbedded();
    await _playCrossSite(next.detail, next.episodeIndex);
  }

  /// 推出去的播放页耗尽：弹掉当前播放页，换链上下一条线路；链
  /// 耗尽时什么都不做，播放器原错误界面留着。
  Future<void> _onPushedPlayerExhausted(BuildContext playerContext) async {
    if (!mounted) return;
    final route = ModalRoute.of(playerContext);
    if (route == null || !route.isCurrent) return;
    final nextLine = widget.nextLineOnExhausted;
    if (nextLine == null) return;
    final next = await nextLine();
    if (!mounted || _profileEpoch != widget.store.profileEpoch) return;
    if (next == null) return;
    // 换线等待期间用户可能已手动退出：再验一次路由仍在最上层，
    // 且播放器 context 仍挂载。
    if (!route.isCurrent || !playerContext.mounted) return;
    Navigator.of(playerContext).pop();
    if (!mounted) return;
    await _playCrossSite(next.detail, next.episodeIndex);
  }

  /// 推出去的播放页重试：先让调用方把链 resetForRetry 重探一遍，
  /// 有新线就弹掉当前播放页、换新线播；重探无果返回 false，
  /// 播放器再原地重播同一集。
  Future<bool> _onPlayerRetry(BuildContext playerContext) async {
    if (!mounted) return false;
    final route = ModalRoute.of(playerContext);
    if (route == null || !route.isCurrent) return false;
    final retryProbe = widget.onRetryProbe;
    if (retryProbe == null) return false;
    final next = await retryProbe();
    if (!mounted || _profileEpoch != widget.store.profileEpoch) return false;
    if (next == null) return false;
    if (!route.isCurrent || !playerContext.mounted) return false;
    Navigator.of(playerContext).pop();
    if (!mounted) return false;
    await _playCrossSite(next.detail, next.episodeIndex);
    return true;
  }

  /// 跨站选线路区：只有带番号的片才显示，无番号返回空盒子。
  Widget _crossSiteSection(Drama drama) {
    final avId = extractAvId(
      title: drama.title,
      id: drama.id,
      sourceId: drama.sourceId,
    );
    if (avId == null) return const SizedBox.shrink();
    return CrossSiteProbeSection(
      key: ValueKey('crosssite-$avId-${drama.source}-${drama.id}'),
      repository: widget.repository,
      store: widget.store,
      avId: avId,
      currentSourceId: drama.source,
      onPlayLine: _playCrossSite,
    );
  }

  /// 在线线路区（2026-11-26 用户令）：带番号的片自动按番号
  /// 去 123AV / PH 搜线路、追加成可点行；与跨站区（who's
  /// py 链等注册站）并行，互不阻塞。无番号不显示。
  Widget _actressOnlineLinesSection(Drama drama) {
    final avId = extractAvId(
      title: drama.title,
      id: drama.id,
      sourceId: drama.sourceId,
    );
    if (avId == null) return const SizedBox.shrink();
    return ActressOnlineLinesSection(
      key: ValueKey('actress-lines-$avId-${drama.source}-${drama.id}'),
      code: avId,
      onPlay: (detail) => unawaited(_playActressOnlineLine(detail)),
      sources: kActressLineSources,
      repository: widget.repository,
    );
  }

  /// 在线线路起播：解析/嗅探只负责取链，地址连请求头递给
  /// 正式播放器（pushPlayer），不在网页里播（2026-11-26
  /// 16:59 令）。这两源未在站点表注册，allowsSource 门不适
  /// 用，走与在线视图点卡相同的直递播放器路径。
  Future<void> _playActressOnlineLine(DramaDetail detail) async {
    _frameService.cancel();
    await pushPlayer<void>(
      context,
      detail: detail,
      initialIndex: 0,
      repository: widget.repository,
      store: widget.store,
      queue: widget.queue,
    );
    if (mounted) {
      setState(() {});
    }
  }

  void _closeEmbedded() {
    if (_embeddedIndex == null) return;
    setState(() {
      _embeddedIndex = null;
      _embeddedFullscreen = false;
      _embeddedKey = null;
    });
    // 内嵌播放时可能新截了帧，关播后刷新一次，网格卡立即换上帧图。
    unawaited(_loadFrameKeys());
  }

  /// 播过留帧：列出已缓存的帧键，网格卡按集合成员关系决定
  /// 显不显示帧图。缓存读失败时当作没有帧。
  Future<void> _loadFrameKeys() async {
    try {
      final keys = await EpisodeFrameCache.instance.warmUp();
      if (mounted) {
        setState(() => _frameKeys = keys);
      }
    } catch (_) {
      // 帧缓存不可用时卡片回落剧照/海报，不影响详情页。
    }
  }

  /// 内嵌播区：播放器 widget 的父链全程恒定（Column → LayoutBuilder
  /// → SizedBox → PlayerScreen），全屏切换只改 SizedBox 的高度，
  /// 不换父级、不重建播放区。以前全屏分支返回另一套 Scaffold，
  /// 播放器从 AspectRatio/SizedBox 挪到 Scaffold body 直下，
  /// 原生画面跟着重挂 → 有声无画；GlobalKey 只保 Dart 侧
  /// Element，不算保护。非全屏时视频按 16:9、非视频内容按 560
  /// 高；全屏时占满详情页体区高度，下面的滚动区自然剩 0 高。
  Widget? _embeddedArea(
    List<Episode> episodes, {
    required double fullscreenHeight,
  }) {
    if (_embeddedIndex == null || _detail == null) return null;
    final index = _embeddedIndex!.clamp(0, episodes.length - 1);
    final nonVideo = nonVideoKindOfEpisode(episodes[index]) != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => SizedBox(
            height: _embeddedFullscreen
                ? fullscreenHeight
                : nonVideo
                ? 560
                : constraints.maxWidth * 9 / 16,
            width: double.infinity,
            child: _embeddedPlayer(),
          ),
        ),
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
      onPlaybackExhausted: widget.nextLineOnExhausted == null
          ? null
          : _onEmbeddedExhausted,
      playerFactory: widget.playerFactory,
      videoBuilder: widget.videoBuilder,
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
          pan115Gateway: widget.pan115Gateway,
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
          pan115Gateway: widget.pan115Gateway,
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
    // 文件夹详情且目录未失败时画作品卡片网格、不画选集区；目录失败
    // 或回空时退回选集 UI（_folderFailed 为真）并在选集区上方提示重试。
    final showFolder = _isFolderDrama(drama) && !_folderFailed;
    final television = AppLayout.isTelevision(context);
    final allowed =
        widget.store.profileEpoch == _profileEpoch &&
        widget.store.allowsSource(drama.source);
    // 内嵌全屏时顶栏连占位一起藏掉：只改 Scaffold 的 appBar 槽位，
    // body 的树位置不动，播区全程挂在同一条链上（见 _embeddedArea）。
    // 以前全屏分支直接返回另一套 Scaffold，把播放器从 Column 里的
    // AspectRatio 挪到 Scaffold body 直下，父级一变原生画面重挂 →
    // 有声无画；GlobalKey 只保 Dart 侧 Element，不算保护。
    final appBar = _embeddedFullscreen
        ? null
        : AppBar(
            // 内嵌播放器打开时只留播放器左上角的常驻返回钮（关播放器
            // 回海报），顶栏不重复画返回箭头；关闭后恢复顶栏返回。
            automaticallyImplyLeading: _embeddedIndex == null,
            toolbarHeight: television ? 64 : null,
            title: Text(drama.title, overflow: TextOverflow.ellipsis),
            actions: [
              RefreshAction(
                loading: _loading,
                tooltip: '更新剧集信息',
                onPressed: allowed ? _load : null,
              ),
            ],
          );
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
          backgroundColor: _embeddedFullscreen ? Colors.black : null,
          appBar: appBar,
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
                            // 内嵌全屏时左栏宽置 0（只改尺寸，不摘树）：
                            // 播区仍在右栏同一条链上，左栏内容不可见。
                            width: _embeddedFullscreen
                                ? 0
                                : (constraints.maxWidth * .34).clamp(
                                    250.0,
                                    360.0,
                                  ),
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _overview(drama),
                                  _infoCard(drama),
                                  _stillsSection(drama),
                                  _descriptionSection(drama),
                                  _magnetSection(),
                                  _crossSiteSection(drama),
                                  _actressOnlineLinesSection(drama),
                                  _javdbMagnetSection(),
                                  _pan115Section(),
                                  _tmdbEpisodeSection(),
                                  _seriesSection(drama),
                                  _relatedSection(drama),
                                  _javdbReviewsSection(),
                                ],
                              ),
                            ),
                          ),
                          if (!_embeddedFullscreen)
                            const VerticalDivider(width: 1),
                          Expanded(
                            child:
                                _loading || _error != null || episodes.isEmpty
                                ? _episodeStatus()
                                : showFolder
                                ? Column(
                                    children: [
                                      _folderHeader(),
                                      if (_folderLoading)
                                        const Expanded(
                                          child: Center(
                                            child:
                                                CircularProgressIndicator.adaptive(),
                                          ),
                                        )
                                      else
                                        Expanded(child: _folderGridView()),
                                      if (_folderHasMore || _folderMoreFailed)
                                        _folderLoadMore(),
                                    ],
                                  )
                                : Column(
                                    children: [
                                      if (_embeddedArea(
                                            episodes,
                                            fullscreenHeight:
                                                constraints.maxHeight,
                                          ) !=
                                          null)
                                        _embeddedArea(
                                          episodes,
                                          fullscreenHeight:
                                              constraints.maxHeight,
                                        )!,
                                      // 内嵌全屏时播区占满右栏高度，播区
                                      // 下面的选集区不画（只藏兄弟项，
                                      // 播区自己的父链不动）。
                                      if (!_embeddedFullscreen) ...[
                                        if (_isFolderDrama(drama) &&
                                            _folderFailed)
                                          _folderErrorBanner(episodes),
                                        _seriesSelector(drama),
                                        _lineSelector(),
                                        // 2026-11-24 用户令：只有一集时不画选集区。
                                        if (episodes.length > 1)
                                          Expanded(
                                            child: EpisodeBrowser(
                                              episodes: episodes,
                                              currentNumber: watched?.episode,
                                              autofocus: true,
                                              onSelected: (index) => _play(index),
                                            ),
                                          ),
                                      ],
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
                    final previews = episodePreviewData(
                      titles: [
                        for (final episode in episodes)
                          displayEpisodeTitle(episode.title, episode.number),
                      ],
                      tmdbEpisodes: _tmdb?.episodes ?? const [],
                      config: _tmdbConfig,
                      tmdbPosterUrl: _tmdb?.posterUrl(_tmdbConfig) ?? '',
                      dramaCover: drama.cover,
                    );
                    final showEpisodes = _episodesExpanded;
                    // 文件夹网格列数与卡宽：与推荐区同一套算法
                    // （150 宽一列、2–6 列），窄屏网格与宽屏网格共用。
                    final folderColumns = (constraints.maxWidth / 150)
                        .floor()
                        .clamp(2, 6);
                    final folderTileWidth =
                        (constraints.maxWidth - 40 - (folderColumns - 1) * 10) /
                        folderColumns;
                    // 内嵌播放器固定在滚动视图之上：以前它是滚动视图
                    // 里的第一个 sliver，上下滑时跟着内容滑走。现在把
                    // 它移出滚动视图、放固定头区（与宽屏/TV 双栏布局
                    // 同款，那边播放器本就在 Column 头区不随滚动走）；
                    // 滚动只动下面的 CustomScrollView，播放器 widget
                    // 与其 GlobalKey 不受滚动影响、不重建、不重播。
                    // 未开播时海报仍是滚动视图第一项，照常随内容滑走。
                    final embedded = _embeddedArea(
                      episodes,
                      fullscreenHeight: constraints.maxHeight,
                    );
                    return Column(
                      children: [
                        ?embedded,
                        Expanded(
                          // 键要稳：开播/关播时头区出现或消失，滚动区
                          // 靠键在 Column 子项里对上号，滚动位置不丢。
                          key: const ValueKey('detail-scroll-area'),
                          child: CustomScrollView(
                            controller: _detailScroll,
                            slivers: [
                              if (embedded == null)
                                SliverToBoxAdapter(
                                  child: _hero(
                                    drama,
                                    // 海报点按只认“有可播的集”：重载/刷新中的
                                    // 瞬时加载态不许卡死海报播放入口（与已删
                                    // 底部钮的行为一致，_play 自带空详情守卫）。
                                    // 演员库作品一部集数都没有但 115 已存该
                                    // 番号文件时也放行，点按落 115 线路直达
                                    // 播放器；115 下载中也放行，点按给百分
                                    // 比提示（_playFromPoster）。
                                    ready:
                                        allowed &&
                                        (episodes.isNotEmpty ||
                                            _pan115File != null ||
                                            _pan115Submitted),
                                    resumeIndex: resumeIndex,
                                  ),
                                ),
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    12,
                                    20,
                                    8,
                                  ),
                                  child: _overview(drama),
                                ),
                              ),
                              SliverToBoxAdapter(child: _infoCard(drama)),
                              SliverToBoxAdapter(
                                child: _stillsSection(drama),
                              ),
                              if (_loading ||
                                  _error != null ||
                                  episodes.isEmpty)
                                SliverFillRemaining(
                                  hasScrollBody: false,
                                  child: _episodeStatus(),
                                )
                              else if (showFolder) ...[
                                SliverToBoxAdapter(child: _folderHeader()),
                                if (_folderLoading)
                                  const SliverToBoxAdapter(
                                    child: Padding(
                                      padding: EdgeInsets.all(32),
                                      child: Center(
                                        child:
                                            CircularProgressIndicator.adaptive(),
                                      ),
                                    ),
                                  )
                                else ...[
                                  SliverPadding(
                                    padding: const EdgeInsets.fromLTRB(
                                      20,
                                      4,
                                      20,
                                      8,
                                    ),
                                    sliver: SliverGrid(
                                      key: const ValueKey('folder-grid'),
                                      gridDelegate:
                                          SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: folderColumns,
                                            crossAxisSpacing: 10,
                                            mainAxisSpacing: 10,
                                            mainAxisExtent: DramaTile.extentFor(
                                              context,
                                              folderTileWidth,
                                            ),
                                          ),
                                      delegate: SliverChildBuilderDelegate(
                                        (context, index) => _folderTile(index),
                                        childCount: _folderItems.length,
                                      ),
                                    ),
                                  ),
                                  if (_folderHasMore || _folderMoreFailed)
                                    SliverToBoxAdapter(
                                      child: _folderLoadMore(),
                                    ),
                                ],
                                if (!_loading) ...[
                                  SliverToBoxAdapter(
                                    child: _seriesSection(drama),
                                  ),
                                  SliverToBoxAdapter(
                                    child: _recommendedSection(drama),
                                  ),
                                  SliverToBoxAdapter(
                                    child: _crossSiteSection(drama),
                                  ),
                                SliverToBoxAdapter(
                                  child: _actressOnlineLinesSection(drama),
                                ),
                                  SliverToBoxAdapter(
                                    child: _javdbMagnetSection(),
                                  ),
                                  SliverToBoxAdapter(
                                    child: _pan115Section(),
                                  ),
                                  SliverToBoxAdapter(
                                    child: _descriptionSection(drama),
                                  ),
                                  SliverToBoxAdapter(child: _magnetSection()),
                                  SliverToBoxAdapter(
                                    child: _relatedSection(drama),
                                  ),
                                  SliverToBoxAdapter(
                                    child: _javdbReviewsSection(),
                                  ),
                                ],
                              ] else ...[
                                if (_isFolderDrama(drama) && _folderFailed)
                                  SliverToBoxAdapter(
                                    child: _folderErrorBanner(episodes),
                                  ),
                                SliverToBoxAdapter(
                                  child: _seriesSelector(drama),
                                ),
                                SliverToBoxAdapter(child: _lineSelector()),
                                SliverToBoxAdapter(
                                  child: _episodeSummary(
                                    episodes,
                                    currentNumber: watched?.episode,
                                    expanded: showEpisodes,
                                  ),
                                ),
                                // 2026-11-24 用户令：详情页自动写入开关隐藏
                                // （功能默认开，开关只留在设置页）。
                                if (showEpisodes && episodes.length > 1) ...[
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
                                    padding: const EdgeInsets.fromLTRB(
                                      20,
                                      4,
                                      20,
                                      24,
                                    ),
                                    sliver: SliverGrid(
                                      gridDelegate:
                                          SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount:
                                                episodePreviewColumns(
                                                  constraints.maxWidth,
                                                ),
                                            mainAxisExtent: _episodeCardExtent(
                                              context,
                                              constraints.maxWidth,
                                            ),
                                            crossAxisSpacing: 8,
                                            mainAxisSpacing: 10,
                                          ),
                                      delegate: SliverChildBuilderDelegate((
                                        context,
                                        index,
                                      ) {
                                        final episode = visible[index];
                                        // 卡片建出来（进入可见/预取范围）才请求取帧：
                                        // 服务内部去重，只补新增的；内嵌播时不取。
                                        if (_embeddedIndex == null) {
                                          _frameService.prefetch(drama, [
                                            episode,
                                          ]);
                                        }
                                        final preview = previews[start + index];
                                        final frameKey =
                                            EpisodeFrameCache.frameKey(
                                              source: drama.source,
                                              dramaId: drama.id,
                                              episodeNumber: episode.number,
                                            );
                                        final framePath =
                                            _frameKeys.contains(frameKey)
                                            ? EpisodeFrameCache.instance
                                                  .pathForKey(frameKey)
                                            : null;
                                        return EpisodePreviewCard(
                                          key: ValueKey(
                                            'episode-${episode.number}',
                                          ),
                                          episode: episode,
                                          tmdb: preview.tmdb,
                                          stillUrl: preview.stillUrl,
                                          posterUrl: preview.posterUrl,
                                          current:
                                              episode.number ==
                                              watched?.episode,
                                          framePath: framePath,
                                          onPressed: () => _play(start + index),
                                        );
                                      }, childCount: visible.length),
                                    ),
                                  ),
                                ],
                              ],
                              if (!_loading) ...[
                                SliverToBoxAdapter(
                                  child: _seriesSection(drama),
                                ),
                                SliverToBoxAdapter(
                                  child: _recommendedSection(drama),
                                ),
                                SliverToBoxAdapter(
                                  child: _crossSiteSection(drama),
                                ),
                              SliverToBoxAdapter(
                                child: _actressOnlineLinesSection(drama),
                              ),
                                SliverToBoxAdapter(
                                  child: _javdbMagnetSection(),
                                ),
                                SliverToBoxAdapter(
                                  child: _pan115Section(),
                                ),
                                SliverToBoxAdapter(
                                  child: _descriptionSection(drama),
                                ),
                                SliverToBoxAdapter(child: _magnetSection()),
                                SliverToBoxAdapter(
                                  child: _relatedSection(drama),
                                ),
                                SliverToBoxAdapter(
                                  child: _javdbReviewsSection(),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hero(Drama drama, {required bool ready, required int resumeIndex}) {
    Widget playButton() {
      // 纯装饰：不接手势，整张海报（含圆心）都由 posterTap 接管点播。
      return IgnorePointer(
        child: Center(
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
        ),
      );
    }

    Widget posterTap() {
      return Positioned.fill(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey('detail-poster-play'),
            onTap: ready ? () => _playFromPoster(resumeIndex) : null,
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

  /// 详情页是不是短剧站的（短剧区登记 SourceSite.section == 'drama'）：
  /// 短剧站不插演员区、不做番号匹配；其余站（视频区/未注册/自定义）都插。
  bool _isShortDramaSource(Drama drama) {
    final id = drama.sourceId;
    if (id.isEmpty || !SourceSite.isKnown(id)) return false;
    return SourceSite.byId(id).isDramaSection;
  }

  Widget _descriptionSection(Drama drama) {
    final tmdbOverview = _tmdb?.overview ?? '';
    final rawOverview =
        tmdbOverview.isNotEmpty ? tmdbOverview : drama.description;
    // 站点简介常带 HTML（女优库 vod_content 如 <p>...</p>），直接显示会露出标签；
    // 先拆段去标签再显示，纯文本简介不受影响。
    final overview = htmlToParagraphs(rawOverview).join('\n');
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
            '磁力播放已移除：仅展示链接信息，暂不支持播放',
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
              onTap: () => ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('磁力链接暂不支持播放'))),
            ),
        ],
      ),
    );
  }

  /// JavDB 磁力区（放在在线线路区下面）：名称 + 大小/日期
  /// 副标照 _magnetSection 的样子，点按=复制磁力链接到剪贴
  /// 板并给中文提示。只给链接：不做站内播放、不做下载器、
  /// 不接第三方网盘。数据为空整区不显示（_loadJavdbExtras
  /// 填 _javdbMagnets）。不并入通用 _magnetSection：它的点
  /// 按口径是「暂不支持播放」提示，与本链复制口径不合，
  /// 改它会动通用详情页既有行为。
  Widget _javdbMagnetSection() {
    if (_javdbMagnets.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      key: const ValueKey('javdb-magnets-section'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('磁力链接', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '来源：JavDB · 点按复制磁力链接',
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 8),
          for (final magnet in _javdbMagnets)
            ListTile(
              key: ValueKey('javdb-magnet-${magnet.url}'),
              contentPadding: EdgeInsets.zero,
              title: Text(magnet.name.isEmpty ? '磁力链接' : magnet.name),
              subtitle: magnet.metaLabel.isEmpty
                  ? null
                  : Text(magnet.metaLabel),
              trailing: const Icon(Icons.copy_outlined, size: 18),
              onTap: () => unawaited(_copyMagnet(magnet.url)),
            ),
        ],
      ),
    );
  }

  /// 115 区（在线线路区附近，磁力区下面）：未登录只出一行
  /// 提示；网盘已存该番号文件出「115 播放」行，点按在本页
  /// 直达正式播放器（_playPan115Line，不跳网盘页）；已自动
  /// 离线未下完显示「已提交 115 离线」与进度，下完自动转
  /// 播放行。没存也没磁力时整区不显示（_startPan115 维护）。
  Widget _pan115Section() {
    final colors = Theme.of(context).colorScheme;
    if (_pan115LoginHint) {
      return Padding(
        key: const ValueKey('actress-pan115-section'),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Row(
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 18,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                // 轻提示口径（2026-11-26 用户令）：115 不是播放
                // 前置条件，未登录只留这一行、不弹窗不挡播放；
                // 登录入口指向 App 现行网盘页登录，演员库不另
                // 建登录界面。
                '115 未登录，登录后可自动离线并在本页播放（去网盘页登录）；未登录不影响在线与本地线路播放',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12.5),
              ),
            ),
          ],
        ),
      );
    }
    final file = _pan115File;
    if (file == null && !_pan115Submitted) {
      return const SizedBox.shrink();
    }
    return Padding(
      key: const ValueKey('actress-pan115-section'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('115', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (file != null)
            ListTile(
              key: const ValueKey('actress-pan115-play'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.play_circle_outline_rounded),
              title: Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: const Text('115 网盘 · 点按播放'),
              onTap: () => unawaited(_playPan115Line()),
            )
          else ...[
            InkWell(
              onTap: _showPan115WaitHint,
              child: Row(
                children: [
                  Icon(
                    Icons.cloud_download_outlined,
                    size: 18,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _pan115Percent == null
                        ? '已提交 115 离线，正在下载…'
                        : '已提交 115 离线，下载中 ${(_pan115Percent! * 100).round()}%',
                    style: const TextStyle(fontSize: 13.5),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _pan115Percent),
          ],
        ],
      ),
    );
  }

  Future<void> _copyMagnet(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('磁力链接已复制')));
  }

  /// JavDB 评论区（作品详情页最下方，只读）：头像走
  /// _detailStillImage（图床地址过 XOR 解密、其余直显），
  /// 没头像用昵称首字占位。数据为空整区不显示；不做发表/
  /// 点赞交互（点赞数只展示）。
  Widget _javdbReviewsSection() {
    if (_javdbReviews.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      key: const ValueKey('javdb-reviews-section'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('评论', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '来源：JavDB',
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 12),
          for (final review in _javdbReviews) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _reviewAvatar(review),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              review.username.isEmpty ? '匿名' : review.username,
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (review.createdAt.isNotEmpty)
                            Text(
                              review.createdAt.length > 10
                                  ? review.createdAt.substring(0, 10)
                                  : review.createdAt,
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(review.content, style: const TextStyle(fontSize: 13.5)),
                      if (review.likes > 0) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.thumb_up_outlined,
                              size: 13,
                              color: colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${review.likes}',
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }

  Widget _reviewAvatar(JavdbReview review) {
    if (review.avatarUrl.isNotEmpty) {
      return ClipOval(
        child: SizedBox(
          width: 36,
          height: 36,
          child: _detailStillImage(review.avatarUrl),
        ),
      );
    }
    return CircleAvatar(
      radius: 18,
      child: Text(
        review.username.isEmpty
            ? '?'
            : String.fromCharCode(review.username.runes.first),
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

  /// 相关剧集区：同系列其它季按季号升序排卡，当前这季标“当前”且
  /// 点按无动作；点其它季的卡进那一季详情页（与选季 chips 同一
  /// 跳转，含新季提醒已读标记）。数据口径：站方相关接口优先（季号
  /// 可信），接口没有/不可用时回落标题规律在站内候选里分组；合并
  /// 与去重见 hongguoMergedSeasonEntries。无兄弟季时隐藏。
  /// 落点：窄屏布局推荐视频区之前；宽屏/TV 左栏相关推荐之前。
  Widget _seriesSection(Drama drama) {
    final entries = hongguoMergedSeasonEntries(
      anchor: drama,
      apiSeasons: [
        for (final work in _apiRelated)
          if (!work.upcoming && work.seriesId.isNotEmpty)
            (drama: work.toDrama(), seasonIndex: work.seasonIndex),
      ],
      candidates: {
        ...?_detail?.related,
        ...widget.store.seriesDramasFor(drama),
      },
    );
    if (entries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('相关剧集', style: Theme.of(context).textTheme.titleMedium),
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
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final isCurrent = entry.drama.id == drama.id;
                  return DramaTile(
                    key: ValueKey('series-card-${entry.drama.id}'),
                    drama: entry.drama,
                    repository: widget.repository,
                    subtitle: entry.label,
                    topBadge: isCurrent ? '当前' : null,
                    onTap: isCurrent
                        ? () {}
                        : () => _openSeriesDrama(entry.drama),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  /// 推荐视频区：选集区下方，取本站视频（同分类优先），卡片与相关
  /// 推荐同一套样式，点卡进详情页（不直接播）；无数据时隐藏。
  /// 落点：窄屏布局选集网格之后、跨站选线区之前（帧画面缩小后空出
  /// 的位置）；宽屏/TV 双栏布局不放（右侧是选集浏览器，左栏已有
  /// 相关推荐）。
  Widget _recommendedSection(Drama drama) {
    if (_recommended.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('推荐视频', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              // 2026-11-24 用户令：推荐视频卡片小一半——列宽档 150→85，
              // 390 宽手机 4 列（单卡约 90 宽，原 2 列约 175 宽）。
              final columns = (constraints.maxWidth / 85).floor().clamp(2, 6);
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
                itemCount: _recommended.length,
                itemBuilder: (context, index) => DramaTile(
                  key: ValueKey('recommended-${_recommended[index].id}'),
                  drama: _recommended[index],
                  repository: widget.repository,
                  onTap: () => _openRelated(_recommended, _recommended[index]),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 文件夹作品区标题：已加载部数只作进度提示，不是总数。
  Widget _folderHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Row(
        children: [
          Expanded(
            child: Text('作品', style: Theme.of(context).textTheme.titleMedium),
          ),
          if (_folderItems.isNotEmpty)
            Text(
              '已加载 ${_folderItems.length} 部',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  /// 文件夹作品卡：与站内其他视频列表同一套 DramaTile，有封面
  /// 显示封面、无封面显示占位卡；点卡进该作品详情页（正常详情
  /// 流程、不直播）。
  DramaTile _folderTile(int index) {
    final item = _folderItems[index];
    return DramaTile(
      key: ValueKey('folder-${item.id}'),
      drama: item,
      repository: widget.repository,
      onTap: () => _openRelated(_folderItems, item),
    );
  }

  /// 文件夹目录分页按钮：有更多页时“加载更多”，翻页失败时变重试。
  Widget _folderLoadMore() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Center(
        child: _folderLoadingMore
            ? const CircularProgressIndicator.adaptive()
            : TextButton(
                key: const ValueKey('folder-load-more'),
                onPressed: () => unawaited(_loadFolder()),
                child: Text(_folderMoreFailed ? '加载失败，点按重试' : '加载更多'),
              ),
      ),
    );
  }

  /// 文件夹目录失败横条：目录失败/回空时退回选集 UI，本横条留在
  /// 选集区上方提示重试，不留空白页。只有一集时选集区本身不画
  /// （2026-11-24 用户令），文案不说“已显示选集”。
  Widget _folderErrorBanner(List<Episode> episodes) {
    final shown = episodes.length > 1 ? '，已显示选集' : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(child: Text('作品列表加载失败$shown')),
              TextButton(
                key: const ValueKey('folder-retry'),
                onPressed: () => unawaited(_loadFolder(reset: true)),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 文件夹作品网格（宽屏右栏用）：与窄屏网格同一套卡片与列数算法。
  Widget _folderGridView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 150).floor().clamp(2, 6);
        final tileWidth = (constraints.maxWidth - (columns - 1) * 10) / columns;
        return GridView.builder(
          key: const ValueKey('folder-grid'),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            mainAxisExtent: DramaTile.extentFor(context, tileWidth),
          ),
          itemCount: _folderItems.length,
          itemBuilder: (context, index) => _folderTile(index),
        );
      },
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
              // 2026-11-24 用户令：相关推荐卡片小一半——与推荐视频同一档
              // （列宽档 150→85，390 宽手机 4 列，单卡约 90 宽）。
              final columns = (constraints.maxWidth / 85).floor().clamp(2, 6);
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
    // 2026-11-23 播着片点推荐视频：先停当前这部（否则旧片音频继续、
    // 画面不切），新详情页进页即播下一部；没在播时照旧只进详情页。
    final wasPlaying = _embeddedIndex != null;
    if (wasPlaying) _closeEmbedded();
    await Navigator.of(context).push(
      appPageRoute<void>(
        settings: const RouteSettings(name: 'detail'),
        builder: (_) => DetailScreen(
          drama: target,
          repository: widget.repository,
          store: widget.store,
          pan115Gateway: widget.pan115Gateway,
          onTagTap: widget.onTagTap,
          queue: PlaybackQueue.around(related, target),
          autoPlayOnOpen: wasPlaying,
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
    // 2026-11-24 用户令：只有一集时不画选集区（选集超过 1 集才出现）；
    // 单集点海报播。
    if (episodes.length <= 1) return const SizedBox.shrink();
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
      final columns = episodePreviewColumns(render.size.width);
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

  /// 预览图卡片的网格高度：16:9 图 + 文字区（标题一行 + 副标题一行，
  /// 随文字缩放放大，上限 1.4 倍）。网格与定位滚动共用同一算法。
  double _episodeCardExtent(BuildContext context, double width) {
    final columns = episodePreviewColumns(width);
    final tileWidth = (width - 40 - (columns - 1) * 8) / columns;
    return episodePreviewCardExtent(context, tileWidth);
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

  /// 头区演员行是否显示：非短剧、非文件夹，且匹配到了演员或导演。
  bool _showCastRow(Drama drama) {
    final meta = _codeMeta;
    if (meta == null || drama.isFolder || _isShortDramaSource(drama)) {
      return false;
    }
    return meta.cast.isNotEmpty || meta.director.isNotEmpty;
  }

  /// 演员区（2026-11-26 照 AvPlay 详情页截图改卡片排）：标题
  /// 「演员」+ 横排照片卡（照片 + 底部白条名字），男女演员都
  /// 列（数据来自番号元数据 castWithAvatars，含男优）；导演
  /// 放标题行右侧小字。点卡走与原文字标签同一入口
  /// （_onTagPressed）。原形态是 ActionChip 小头像行
  /// （2026-11-24），本版按截图换卡片，键与点按行为不变。
  Widget _castChipsRow(Drama drama) {
    final meta = _codeMeta!;
    final cast = meta.castWithAvatars;
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '演员',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              if (meta.director.isNotEmpty)
                Text(
                  '导演：${meta.director}',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final actor in cast) ...[
                  _castCard(drama, actor),
                  const SizedBox(width: 10),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 演员照片卡（规格表 UI_SPEC.md 已证实项：白卡、卡内
  /// 4dp 内边距、照片 1:1 正方形、名字 13sp SemiBold）：
  /// 照片下方白条名字，点卡走标签搜索入口。
  Widget _castCard(Drama drama, ({String name, String avatarUrl}) actor) {
    Widget placeholder() => ColoredBox(
      color: const Color(0xFFF1F1F3),
      child: Center(
        child: Text(
          actor.name.isEmpty ? '?' : actor.name.characters.first,
          style: const TextStyle(
            color: Color(0xFF8E8E93),
            fontSize: 26,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
    return InkWell(
      key: ValueKey('cast-${actor.name}'),
      onTap: () => _onTagPressed(
        drama,
        DetailTag(id: actor.name, name: actor.name),
      ),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 92,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: Colors.white,
        ),
        clipBehavior: Clip.antiAlias,
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 84,
                height: 84,
                child: actor.avatarUrl.isEmpty
                    ? placeholder()
                    : Image.network(
                        actor.avatarUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => placeholder(),
                      ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              actor.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF191919),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 信息卡（2026-11-26 照 AvPlay 详情页截图）：圆角深色卡里
  /// 逐行列 番号 / 发行日期 / 长度 / 制作商——只放真有的字段：
  /// 番号来自番号元数据或番号形标签；日期优先详情自带的
  /// extraInfo、其次 Drama.onlineDate；其余行全走 extraInfo
  /// （在线源详情页自带字段、本地库厂牌）。系列与评分：详情
  /// 自带 extraInfo 有真值照显；没有时由 JavDB 补充链按番号
  /// 补（_loadJavdbExtras，评分照接口原值、人数照原值），
  /// 两路都拿不到就不显示、不编（用户令），截图里的金色
  /// 缎带评分徽标同理不挂。番号可点复制。没有番号也没有附
  /// 加信息时整卡不显示（普通剧集不受影响）。
  Widget _infoCard(Drama drama) {
    final extra = _detail?.extraInfo ?? const <(String, String)>[];
    String extraValue(String label) {
      for (final row in extra) {
        if (row.$1 == label) return row.$2;
      }
      return '';
    }

    var code = _codeMeta?.code ?? '';
    if (code.isEmpty) {
      for (final tag in drama.tags) {
        final value = tag.trim();
        if (RegExp(r'^[A-Za-z]{2,}-?[0-9]{2,}').hasMatch(value)) {
          code = value;
          break;
        }
      }
    }
    final rows = <(String, String, bool)>[
      if (code.isNotEmpty) ('番号', code, true),
      if (extraValue('发行日期').isNotEmpty)
        ('发行日期', extraValue('发行日期'), false)
      else if (drama.onlineDate.isNotEmpty)
        ('发行日期', drama.onlineDate, false),
      for (final row in extra)
        if (row.$1 != '发行日期' && row.$2.isNotEmpty)
          (row.$1, row.$2, false),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      key: const ValueKey('detail-info-card'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 72,
                      child: Text(
                        '${row.$1}：',
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                    Expanded(
                      child: row.$3
                          ? InkWell(
                              key: const ValueKey('detail-info-code'),
                              onTap: () => unawaited(_copyCode(row.$2)),
                              child: Text(
                                row.$2,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            )
                          : Text(
                              row.$2,
                              style: const TextStyle(fontSize: 13.5),
                            ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('番号已复制')));
  }

  /// 剧照区（2026-11-26 照 AvPlay 详情页截图）：标题「剧照」+
  /// 右侧「全部 N >」+ 横排横构图剧照可滑。数据认详情自带
  /// 的 stills（在线源取页内剧照区、py 源取页内剧照）与
  /// JavDB 按番号补的预览图（自带为空才补，见
  /// _loadJavdbStills）；两路都拿不到时 stills 为空、整区
  /// 不显示，不拿封面冒充、不编数量（用户令）。头区那条
  /// stills 缩略条是换背景图用的，与本区并存、职能不同。
  Widget _stillsSection(Drama drama) {
    final seen = <String>{};
    final stills = <String>[
      for (final s in _detail?.stills ?? const <String>[])
        if (s.isNotEmpty && s != drama.cover && seen.add(s)) s,
    ];
    if (stills.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const ValueKey('detail-stills-section'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('剧照', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (stills.length > 3)
                InkWell(
                  key: const ValueKey('detail-stills-all'),
                  onTap: () => Navigator.of(context).push(
                    appPageRoute<void>(
                      settings: const RouteSettings(name: 'stills'),
                      builder: (_) => _StillsAllPage(stills: stills),
                    ),
                  ),
                  child: Text(
                    '全部 ${stills.length} >',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 104,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: stills.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.only(right: 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: AspectRatio(
                    aspectRatio: 16 / 10,
                    child: _detailStillImage(stills[index]),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 标签行：演员行已显示时，把演员标签藏掉（不与头像行重复显示
  /// 同一个人）。标签名常把多人用“、”拼成一个（如“佐佐木明希、岸和水”），
  /// 拆开后任一部分对上演员名即算演员标签。名字比对先把“々”展开
  /// （佐々木 → 佐佐木）。
  List<DetailTag> _visibleTags(Drama drama) {
    final tags = _effectiveTags(drama);
    final meta = _codeMeta;
    if (meta == null || meta.cast.isEmpty) return tags;
    final castNames = meta.cast.map(_normalizeName).toSet();
    return tags.where((tag) {
      final parts = tag.name
          .split(RegExp(r'[、，,;；\s]+'))
          .where((s) => s.isNotEmpty);
      return !parts.any((p) => castNames.contains(_normalizeName(p)));
    }).toList();
  }

  /// 名字归一：去首尾空白；“々”展开成前一字。
  String _normalizeName(String name) {
    final out = StringBuffer();
    var prev = '';
    for (final ch in name.trim().split('')) {
      if (ch == '々' && prev.isNotEmpty) {
        out.write(prev);
      } else {
        out.write(ch);
        prev = ch;
      }
    }
    return out.toString();
  }

  Widget _overview(Drama drama) {
    final colors = Theme.of(context).colorScheme;
    final shown = _tmdbPosterDrama(drama);
    final visibleTags = _visibleTags(drama);
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
        if (_showCastRow(drama)) _castChipsRow(drama),
        const SizedBox(height: 12),
        _sourceSwitcher(drama),
        if (drama.onlineDate.isNotEmpty ||
            drama.heat.isNotEmpty ||
            drama.views.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              [
                if (drama.onlineDate.isNotEmpty) '${drama.onlineDate} 上线',
                if (drama.heat.isNotEmpty) heatDisplayText(drama.heat),
                if (drama.views.isNotEmpty) '播放 ${drama.views}',
              ].join(' · '),
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          ),
        if (visibleTags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 相关分类（2026-11-26 照 AvPlay 详情页 GenreSection
                // 的标题文案与分区摆法）：标题 + 胶囊横排，点胶囊
                // 进对应标签列表（原 _onTagPressed 行为不变）。
                const Text(
                  '相关分类',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in visibleTags.take(12))
                      ActionChip(
                        key: ValueKey('detail-tag-${tag.id}'),
                        label: Text(tag.name),
                        onPressed: () => _onTagPressed(drama, tag),
                      ),
                  ],
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
}

/// 一张剧照的显示组件：JavDB 图床的图字节带 XOR 加密，走
/// JavdbImage 的解密路径（与 JavDB 封面/头像同一条，见
/// javdb_image.dart）；其余来源的剧照维持普通网络图（失败
/// 给深色占位，与此前一致）。
Widget _detailStillImage(String url) {
  if (javdbIsImageUrl(url)) {
    return JavdbImage(url: url, fit: BoxFit.cover);
  }
  return Image.network(
    url,
    fit: BoxFit.cover,
    errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26),
  );
}

/// 全部剧照页（详情页剧照区「全部 N >」的落点）：两列网格
/// 列全这部作品的剧照。
class _StillsAllPage extends StatelessWidget {
  const _StillsAllPage({required this.stills});

  final List<String> stills;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('剧照（${stills.length}）')),
      body: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 16 / 10,
        ),
        itemCount: stills.length,
        itemBuilder: (context, index) => ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _detailStillImage(stills[index]),
        ),
      ),
    );
  }
}
