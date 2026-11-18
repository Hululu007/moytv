import 'dart:async';

import 'package:flutter/material.dart';

import 'actress_database.dart';
import 'actress_models.dart';
import 'actress_play.dart';
import 'actress_search.dart';
import 'actress_widgets.dart';
import '../core_bridge.dart';
import '../local_store.dart';
import '../player_picker.dart';
import '../widgets.dart';

/// 人物详情页：头像、名、标签、作品数 + 作品卡片网格。
///
/// - 作品一律视频卡片（DramaTile，与站内卡片同一形态）：有封面显示
///   封面 + 标题/番号，无封面用占位卡片 + 番号，点卡片才播；
/// - 打开即后台跑双键合流补封面（缓存优先：已补过且全部作品已有
///   封面时下次不再跑；仍有无封面作品时重新补），退出页即停，
///   不挡列表显示；
/// - 点卡走静默换线链：探活 + 预检 + 播放中途回调换线，全程不显示
///   任何站点来源信息，全部候选失败才报“暂无可播片源”。
class ActressDetailPage extends StatefulWidget {
  const ActressDetailPage({
    super.key,
    required this.localId,
    required this.repository,
    required this.store,
    required this.database,
    this.enrichment,
    this.playChainFactory,
  });

  final int localId;
  final AppRepository repository;
  final LocalStore store;
  final ActressDatabase database;

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
    _startEnrichment();
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
    await _pushCandidate(chain, candidate);
  }

  Future<void> _pushCandidate(
    ActressPlayChain chain,
    ActressPlayCandidate candidate,
  ) async {
    await pushPlayer<void>(
      context,
      detail: candidate.detail,
      initialIndex: candidate.episodeIndex,
      repository: widget.repository,
      store: widget.store,
      onPlaybackExhausted: (playerContext) =>
          _onPlaybackExhausted(chain, playerContext),
    );
    if (mounted) setState(() {});
  }

  /// 播放中途恢复耗尽：弹掉当前播放页，换链上下一个候选；链耗尽
  /// 时什么都不做，播放器原错误界面留着（不弹“暂无可播片源”，
  /// 避免与播放器自身的错误提示打架）。
  Future<void> _onPlaybackExhausted(
    ActressPlayChain chain,
    BuildContext playerContext,
  ) async {
    if (!mounted) return;
    final route = ModalRoute.of(playerContext);
    if (route == null || !route.isCurrent) return;
    final candidate = await chain.nextPlayable(
      profileEpoch: widget.store.profileEpoch,
    );
    if (!mounted) return;
    if (candidate == null) return;
    // 换线等待期间用户可能已手动退出：再验一次路由仍在最上层，
    // 且播放器 context 仍挂载。
    if (!route.isCurrent || !playerContext.mounted) return;
    Navigator.of(playerContext).pop();
    if (!mounted) return;
    await _pushCandidate(chain, candidate);
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
                    if (_works.isEmpty)
                      const SliverFillRemaining(
                        child: Center(child: Text('暂无作品')),
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
