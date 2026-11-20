import 'dart:async';

import 'package:flutter/material.dart';

import 'actress_database.dart';
import 'actress_json_fallback.dart';
import 'actress_models.dart';
import 'actress_play.dart';
import 'actress_search.dart';
import 'actress_widgets.dart';
import '../app_page_route.dart';
import '../core_bridge.dart';
import '../detail_screen.dart';
import '../local_store.dart';
import '../models.dart';
import '../player_picker.dart';
import '../widgets.dart';

/// 人物详情页：头像、名、标签、作品数 + 作品卡片网格。
///
/// - 作品一律视频卡片（DramaTile，与站内卡片同一形态）：有封面显示
///   封面 + 标题/番号，无封面用占位卡片 + 番号，点卡片才播；
/// - 打开即后台跑双键合流补封面（缓存优先：已补过且全部作品已有
///   封面时下次不再跑；仍有无封面作品时重新补），退出页即停，
///   不挡列表显示；
/// - 点卡先走快路径：作品已有封面时直接向封面站取一次详情，成功
///   就进详情页（不直播，海报/选集点按才播）；取详情失败再落回
///   探活链：按番号先探 MJV 系（jar/py/Go 槽）与 18AV 双生站，
///   命中立即进详情页并播放（MJV 作首选线路），不等全站探完；
///   无果回落全站探查；其余站的结果由详情页跨站线路区挂线路，
///   播耗尽时自动向同一条链换下一条线；全部候选失败才报
///   “暂无可播片源”。
class ActressDetailPage extends StatefulWidget {
  const ActressDetailPage({
    super.key,
    required this.localId,
    required this.repository,
    required this.store,
    required this.database,
    this.enrichment,
    this.playChainFactory,
    this.siteFilter = ActressSiteFilter.all,
    this.fallback,
  });

  final int localId;
  final AppRepository repository;
  final LocalStore store;
  final ActressDatabase database;

  /// 列表页传来的站点筛选：兜底区只显示该站的条目（默认全部）。
  final ActressSiteFilter siteFilter;

  /// 测试注入：JSON 兜底加载器；不传时现建。
  @visibleForTesting
  final ActressJsonFallback? fallback;

  /// 测试注入：不传时按 repository/store/database 现建。
  @visibleForTesting
  final ActressEnrichment? enrichment;

  /// 测试注入：按番号/标题建播放链；不传时用默认链。
  @visibleForTesting
  final ActressPlayChain Function({
    required String avId,
    required String titleQuery,
  })?
  playChainFactory;

  @override
  State<ActressDetailPage> createState() => _ActressDetailPageState();
}

class _ActressDetailPageState extends State<ActressDetailPage> {
  static const _pageSize = 60;

  final _scrollController = ScrollController();
  ActressPerson? _person;
  var _works = <ActressWork>[];
  var _totalWorks = 0;
  var _loading = true;
  var _loadingMore = false;
  var _hasMore = true;
  var _generation = 0;
  var _enrichmentStarted = false;
  var _playGeneration = 0;
  var _findingSource = false;
  Completer<void>? _playCancel;

  /// JSON 兜底区：本地库没有的作品才补（同番号已有卡的不重复占位）。
  var _fallbackEntries = <ActressJsonEntry>[];

  ActressEnrichment get _enrichment =>
      widget.enrichment ??
      ActressEnrichment(
        repository: widget.repository,
        store: widget.store,
        db: widget.database,
      );

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void dispose() {
    _generation++;
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final generation = ++_generation;
    final person = await widget.database.personById(widget.localId);
    if (!mounted || generation != _generation) return;
    if (person == null) {
      setState(() {
        _person = null;
        _loading = false;
      });
      return;
    }
    setState(() => _person = person);
    await _loadPage(reset: true);
    if (!mounted || generation != _generation) return;
    await _loadFallback();
    if (!mounted || generation != _generation) return;
    _startEnrichment();
  }

  /// 兜底：按女优名 + 已加载作品番号对条目，只补本地没有的；
  /// 列表页选了站时只取该站的。本地作品翻页外的番号可能对不上，
  /// 同部多占一位卡不影响播（点哪张都是同一部）。
  /// 两阶段上屏：JSON 行是同步的，先画出来；m3u 行要解 manifest
  /// 与分片，随后补上，不让 JSON 行等 m3u。
  Future<void> _loadFallback() async {
    final person = _person;
    if (person == null) return;
    final fallback = widget.fallback ?? ActressJsonFallback();
    if (!fallback.loaded) await fallback.load();
    final site = widget.siteFilter == ActressSiteFilter.all
        ? null
        : widget.siteFilter.siteId;
    final localCodes = {
      for (final work in _works)
        if (work.codeKey.isNotEmpty) work.codeKey,
    };
    final seen = <String>{};
    final merged = <ActressJsonEntry>[];
    void addAll(List<ActressJsonEntry> rows) {
      for (final entry in rows) {
        final dedup = '${entry.site}|${entry.mergeKey}';
        if (seen.contains(dedup)) continue;
        seen.add(dedup);
        if (entry.codeKey.isNotEmpty && localCodes.contains(entry.codeKey)) {
          continue;
        }
        merged.add(entry);
      }
    }

    for (final name in [person.displayName, ...person.aliases]) {
      addAll(fallback.entriesForActress(name, site: site));
    }
    for (final codeKey in localCodes) {
      addAll(fallback.entriesForCode(codeKey, site: site));
    }
    if (!mounted) return;
    setState(() => _fallbackEntries = merged);
    // m3u 只有 whos 一路；只有全部/whos 才查，选片库站时不查
    // （否则 whos 的 m3u 行会混进该站的兜底）。
    if (site != null && site != 'whos') return;
    var changed = false;
    for (final name in [person.displayName, ...person.aliases]) {
      final before = merged.length;
      addAll(await fallback.m3uEntriesForActress(name));
      if (merged.length != before) changed = true;
    }
    for (final codeKey in localCodes) {
      final before = merged.length;
      addAll(await fallback.m3uEntriesForCode(codeKey));
      if (merged.length != before) changed = true;
    }
    if (!mounted || !changed) return;
    setState(() => _fallbackEntries = merged);
  }

  /// 兜底卡点播：直链地址就是一条线路，单集“正片”parse=0 直播；
  /// 还没直链的条目先提示，等现爬补流。
  Future<void> _playFallbackEntry(ActressJsonEntry entry) async {
    if (!entry.playable) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这条还没取到直链，等现爬补流')));
      return;
    }
    await pushPlayer<void>(
      context,
      detail: entry.toDramaDetail(),
      initialIndex: 0,
      repository: widget.repository,
      store: widget.store,
    );
    if (mounted) setState(() {});
  }

  void _startEnrichment() {
    final person = _person;
    if (_enrichmentStarted || person == null) return;
    _enrichmentStarted = true;
    final generation = _generation;
    unawaited(
      _enrichment
          .enrichPerson(
            person,
            isCancelled: () => !mounted || generation != _generation,
            onChanged: () {
              if (mounted && generation == _generation) {
                unawaited(_reloadWorks());
              }
            },
          )
          .then((completed) async {
            if (!mounted || generation != _generation) return;
            if (completed) {
              await widget.database.markEnriched(person.localId);
            }
            if (mounted && generation == _generation) {
              await _reloadWorks();
            }
          }),
    );
  }

  /// 原地刷新已加载的作品（封面补上后网格实时更新，不动滚动位置）。
  Future<void> _reloadWorks() async {
    final person = _person;
    if (person == null) return;
    final generation = _generation;
    final count = _works.length;
    if (count == 0) return;
    final works = await widget.database.worksForPerson(
      person.localId,
      offset: 0,
      limit: count,
    );
    final total = await widget.database.countWorks(person.localId);
    final freshPerson = await widget.database.personById(person.localId);
    if (!mounted || generation != _generation) return;
    setState(() {
      _works = works;
      _totalWorks = total;
      _hasMore = works.length < total;
      if (freshPerson != null) _person = freshPerson;
    });
  }

  void _onScroll() {
    if (_loadingMore || !_hasMore || _loading) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 600) {
      unawaited(_loadPage());
    }
  }

  Future<void> _loadPage({bool reset = false}) async {
    final person = _person;
    if (person == null) return;
    if (reset) {
      final generation = _generation;
      setState(() {
        _loading = true;
        _works = [];
        _hasMore = true;
      });
      final works = await widget.database.worksForPerson(
        person.localId,
        offset: 0,
        limit: _pageSize,
      );
      final total = await widget.database.countWorks(person.localId);
      if (!mounted || generation != _generation) return;
      setState(() {
        _works = works;
        _totalWorks = total;
        _hasMore = works.length < total;
        _loading = false;
      });
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    final works = await widget.database.worksForPerson(
      person.localId,
      offset: _works.length,
      limit: _pageSize,
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _works = [..._works, ...works];
      _hasMore = _works.length < _totalWorks;
      _loadingMore = false;
    });
  }

  Future<void> _playWork(ActressWork work) async {
    if (_findingSource) return;
    // 快路径：作品已有封面（同步/补全时已记下原站详情身份），
    // 直接向封面站取一次详情，成功就进详情页（不直播，海报/
    // 选集点按才播）；取详情失败、取回无集数、封面站不可见时
    // 落回现有探活链。“正在找可播片源…”遮罩只在探活链才出现。
    if (work.hasCover && widget.store.allowsSource(work.coverSource)) {
      try {
        final detail = await widget.repository
            .detail(
              Drama(
                id: work.coverDramaId,
                source: work.coverSource,
                cover: work.coverUrl,
                title: work.displayTitle,
              ),
            )
            .timeout(const Duration(seconds: 15));
        if (detail.episodes.isNotEmpty && mounted) {
          await _openDetailDirect(detail);
          return;
        }
      } catch (_) {
        // 取详情失败：落回探活链，不弹错。
      }
    }
    final playGeneration = ++_playGeneration;
    final cancel = Completer<void>();
    setState(() {
      _findingSource = true;
      _playCancel = cancel;
    });
    final avId = actressPlayAvId(work);
    final chain =
        widget.playChainFactory?.call(
          avId: avId,
          titleQuery: avId.isEmpty ? work.displayTitle : '',
        ) ??
        ActressPlayChain(
          repository: widget.repository,
          store: widget.store,
          avId: avId,
          titleQuery: avId.isEmpty ? work.displayTitle : '',
        );
    ActressPlayCandidate? candidate;
    try {
      // 取消竞速：点取消立即收遮罩，在途探活结果由代次守卫丢弃。
      candidate = await Future.any([
        chain.nextPlayable(
          profileEpoch: widget.store.profileEpoch,
          shouldStop: () =>
              cancel.isCompleted || playGeneration != _playGeneration,
        ),
        cancel.future.then<ActressPlayCandidate?>((_) => null),
      ]);
    } finally {
      if (mounted && playGeneration == _playGeneration) {
        setState(() {
          _findingSource = false;
          _playCancel = null;
        });
      }
    }
    if (!mounted || cancel.isCompleted || playGeneration != _playGeneration) {
      return;
    }
    if (candidate == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无可播片源')));
      return;
    }
    await _openDetailWithChain(chain, candidate);
  }

  /// 快路径进详情页：点卡进详情、不直播；海报/选集点按才播。
  Future<void> _openDetailDirect(DramaDetail detail) async {
    await Navigator.of(context).push(
      appPageRoute<void>(
        settings: const RouteSettings(name: 'detail'),
        builder: (_) => DetailScreen(
          drama: detail.drama,
          repository: widget.repository,
          store: widget.store,
          autoPlayOnOpen: false,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// 兜底命中直进详情页：首选线路进页即播；详情页跨站线路区继续
  /// 挂其余站的线路；播耗尽时详情页向同一条链要下一条线路。
  Future<void> _openDetailWithChain(
    ActressPlayChain chain,
    ActressPlayCandidate candidate,
  ) async {
    await Navigator.of(context).push(
      appPageRoute<void>(
        settings: const RouteSettings(name: 'detail'),
        builder: (_) => DetailScreen(
          drama: candidate.detail.drama,
          repository: widget.repository,
          store: widget.store,
          autoPlayOnOpen: true,
          autoPlayEpisodeIndex: candidate.episodeIndex,
          nextLineOnExhausted: () async {
            final next = await chain.nextPlayable(
              profileEpoch: widget.store.profileEpoch,
            );
            if (next == null) return null;
            return (detail: next.detail, episodeIndex: next.episodeIndex);
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final person = _person;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(person?.displayName ?? '女优详情')),
      body: Stack(
        children: [
          _loading
              ? const Center(child: CircularProgressIndicator())
              : person == null
              ? const Center(child: Text('人物不存在'))
              : CustomScrollView(
                  controller: _scrollController,
                  slivers: [
                    SliverToBoxAdapter(child: _buildHeader(person, colors)),
                    // 注意：SliverFillRemaining 会占满剩余视口、挡住它
                    // 后面的 sliver（兜底区进不了树）。本地零作品但有
                    // 兜底时，“暂无作品”改普通 sliver，兜底区跟在后面；
                    // 两边都空时才用 FillRemaining 撑满屏。
                    if (_works.isEmpty && _fallbackEntries.isEmpty)
                      const SliverFillRemaining(
                        child: Center(child: Text('暂无作品')),
                      )
                    else if (_works.isEmpty)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(16, 24, 16, 4),
                          child: Center(child: Text('暂无作品')),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        sliver: SliverGrid(
                          gridDelegate: dramaGridDelegate(
                            context,
                            MediaQuery.sizeOf(context).width - 24,
                          ),
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            if (index >= _works.length) {
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            }
                            final work = _works[index];
                            return DramaTile(
                              key: ValueKey('actress-work-${work.id}'),
                              drama: actressWorkDrama(work),
                              repository: widget.repository,
                              subtitle: actressWorkSubtitle(work),
                              onTap: () => _playWork(work),
                            );
                          }, childCount: _works.length + (_hasMore ? 1 : 0)),
                        ),
                      ),
                    if (_fallbackEntries.isNotEmpty) ...[
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        sliver: SliverGrid(
                          gridDelegate: dramaGridDelegate(
                            context,
                            MediaQuery.sizeOf(context).width - 24,
                            // 兜底卡带 tagText（站名）多一行标签，格高要补
                            // 上间距 4 + 一行副标题高，否则 Column 溢出。
                            extraExtent:
                                4 + DramaTile.subtitleHeight(context),
                          ),
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            final entry = _fallbackEntries[index];
                            return DramaTile(
                              key: ValueKey(
                                'actress-fallback-${entry.site}-${entry.vodId}',
                              ),
                              drama: Drama(
                                id: 'json:${entry.site}:${entry.vodId}',
                                source: ActressJsonFallback.playSource,
                                title: entry.vodName,
                                cover: entry.vodPic,
                              ),
                              repository: widget.repository,
                              subtitle: entry.vodCode.isNotEmpty
                                  ? entry.vodCode
                                  : entry.typeName,
                              tagText: entry.site,
                              onTap: () => _playFallbackEntry(entry),
                            );
                          }, childCount: _fallbackEntries.length),
                        ),
                      ),
                    ],
                  ],
                ),
          if (_findingSource) ...[
            const ModalBarrier(dismissible: false, color: Colors.black54),
            Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      const Text('正在找可播片源…'),
                      const SizedBox(height: 8),
                      TextButton(
                        key: const ValueKey('cancel-find-source'),
                        onPressed: () {
                          final cancel = _playCancel;
                          if (cancel != null && !cancel.isCompleted) {
                            cancel.complete();
                          }
                        },
                        child: const Text('取消'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader(ActressPerson person, ColorScheme colors) {
    final sexLabel = actressSexLabel(person.sex);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ActressAvatar(
            avatarUrl: person.avatarUrl,
            name: person.displayName,
            radius: 36,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  person.displayName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  '作品 ${person.displayWorks} 部'
                  '${sexLabel.isEmpty ? '' : ' · $sexLabel'}',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                if (person.aliases.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '别名：${person.aliases.join(' / ')}',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
                if (person.tags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tag in person.tags)
                        Chip(
                          label: Text(tag),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
