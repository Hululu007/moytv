import 'dart:async';

import 'package:flutter/material.dart';

import '../core_bridge.dart';
import '../models.dart';
import 'actress_online_detail.dart';
import 'actress_online_parse.dart';
import 'actress_online_sources.dart';
import 'actress_py_lines.dart';

/// 一条在线线路的搜索状态。idle = 懒查询源还没查（点按才
/// 查）。
enum ActressOnlineLineStatus { idle, searching, found, empty, failed }

class _LineState {
  const _LineState(this.status, {this.card, this.pyDetail});

  final ActressOnlineLineStatus status;
  final OnlineVideoCard? card;

  /// py 复用源命中时预组装好的直链详情（点行直接播）。
  final DramaDetail? pyDetail;
}

/// 详情页「在线线路」区（2026-11-26 用户令）：打开作品详情时
/// 自动按番号去各在线源搜这部片，搜到的追加成可点的线路
/// 行——点行现取流、连请求头递给正式播放器起播（嗅探/解
/// 析只取链，绝不在网页里播，16:59 令）。搜不到标「未找
/// 到」、失败标「搜索失败 · 点按重试」，不编线路、不挡数据
/// 库线路出画（本区与库线路并行）。
/// 源构成（六源扩线后）：Dart 直连源（123AV / PH / AV01 /
/// Jable，见 [kActressLineSources]）+ py 复用源（AVDB /
/// JavMenu / MemoJav / MissAV，走既有 py 蜘蛛链、要仓库
/// 在场才查，见 actress_py_lines.dart）。重源默认懒查询
/// （Jable / MissAV）：行里标「点击查询」，点了才查。
/// who's py 链走既有的跨站选线路区，不在本区重复。
/// 在线播放未经本机出口验通，区头如实标「未验」。
class ActressOnlineLinesSection extends StatefulWidget {
  const ActressOnlineLinesSection({
    super.key,
    required this.code,
    required this.onPlay,
    this.fetch,
    this.sources = kActressOnlineSources,
    this.repository,
    this.pySources = kActressPyLineSources,
  });

  /// 归一化番号（如 SSIS-001），按它搜索与匹配。
  final String code;

  /// 点中一条已找到的线路、取流成功后回调（调用方走正式
  /// 播放器起播）。
  final void Function(DramaDetail detail) onPlay;

  /// 取数注入（测试/预览用），默认走应用取数客户端。
  final ActressOnlineFetch? fetch;

  final List<ActressOnlineSource> sources;

  /// py 复用源要走的仓库；不在场时 py 线路行不出现（测试/
  /// 预览不传就只剩 Dart 直连源，与扩线前行为一致）。
  final AppRepository? repository;

  final List<ActressPyLineSource> pySources;

  @override
  State<ActressOnlineLinesSection> createState() =>
      _ActressOnlineLinesSectionState();
}

class _ActressOnlineLinesSectionState
    extends State<ActressOnlineLinesSection> {
  late final ActressOnlineFetch _fetch =
      widget.fetch ?? ActressOnlineClient().get;
  final _states = <String, _LineState>{};
  var _generation = 0;
  var _resolving = false;

  List<ActressPyLineSource> get _pySources =>
      widget.repository == null ? const [] : widget.pySources;

  @override
  void initState() {
    super.initState();
    for (final source in widget.sources) {
      _states[source.id] = _LineState(
        source.lazySearch
            ? ActressOnlineLineStatus.idle
            : ActressOnlineLineStatus.searching,
      );
    }
    for (final source in _pySources) {
      _states[source.id] = _LineState(
        source.lazy
            ? ActressOnlineLineStatus.idle
            : ActressOnlineLineStatus.searching,
      );
    }
    unawaited(_searchAll());
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _searchAll() async {
    await Future.wait([
      for (final source in widget.sources)
        if (!source.lazySearch) _search(source),
      for (final source in _pySources)
        if (!source.lazy) _searchPy(source),
    ]);
  }

  Future<void> _searchPy(ActressPyLineSource source) async {
    final generation = _generation;
    final repository = widget.repository;
    if (repository == null) return;
    try {
      final hit = await actressPyLineHit(
        repository: repository,
        sourceId: source.id,
        code: widget.code,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _states[source.id] = hit == null
            ? const _LineState(ActressOnlineLineStatus.empty)
            : _LineState(
                ActressOnlineLineStatus.found,
                pyDetail: actressPyLineDetail(
                  source: source,
                  code: widget.code,
                  hit: hit,
                ),
              );
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _states[source.id] = const _LineState(ActressOnlineLineStatus.failed);
      });
    }
  }

  Future<void> _tapPyLine(ActressPyLineSource source) async {
    final state = _states[source.id];
    if (state == null) return;
    if (state.status == ActressOnlineLineStatus.idle ||
        state.status == ActressOnlineLineStatus.failed) {
      setState(() {
        _states[source.id] =
            const _LineState(ActressOnlineLineStatus.searching);
      });
      await _searchPy(source);
      return;
    }
    if (state.status != ActressOnlineLineStatus.found ||
        state.pyDetail == null ||
        _resolving) {
      return;
    }
    widget.onPlay(state.pyDetail!);
  }

  Future<void> _search(ActressOnlineSource source) async {
    final generation = _generation;
    try {
      final cards = await source.fetchCards(
        primaryId: source.defaultPrimaryId,
        secondaryId: source.defaultSecondaryId,
        query: widget.code,
        page: 1,
        fetch: _fetch,
      );
      if (!mounted || generation != _generation) return;
      OnlineVideoCard? hit;
      for (final card in cards) {
        if (actressOnlineCardMatches(
          source: source,
          card: card,
          code: widget.code,
        )) {
          hit = card;
          break;
        }
      }
      setState(() {
        _states[source.id] = hit == null
            ? const _LineState(ActressOnlineLineStatus.empty)
            : _LineState(ActressOnlineLineStatus.found, card: hit);
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _states[source.id] = const _LineState(ActressOnlineLineStatus.failed);
      });
    }
  }

  Future<void> _tapLine(ActressOnlineSource source) async {
    final state = _states[source.id];
    if (state == null) return;
    if (state.status == ActressOnlineLineStatus.idle ||
        state.status == ActressOnlineLineStatus.failed) {
      setState(() {
        _states[source.id] = const _LineState(
          ActressOnlineLineStatus.searching,
        );
      });
      await _search(source);
      return;
    }
    if (state.status != ActressOnlineLineStatus.found ||
        state.card == null ||
        _resolving) {
      return;
    }
    setState(() => _resolving = true);
    try {
      final play = await source.resolvePlay(state.card!, fetch: _fetch);
      if (!mounted) return;
      final built = actressOnlinePlayDetail(
        source: source,
        card: state.card!,
        play: play,
      );
      widget.onPlay(built.detail);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is AppFailure ? error.message : '取播放地址失败，请稍后再试',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      key: const ValueKey('actress-online-lines'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '在线线路',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              Text(
                '按番号自动搜索 · 未验',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final source in widget.sources) _lineRow(source, colors),
          for (final source in _pySources) _pyLineRow(source, colors),
        ],
      ),
    );
  }

  Widget _pyLineRow(ActressPyLineSource source, ColorScheme colors) {
    final state =
        _states[source.id] ??
        const _LineState(ActressOnlineLineStatus.searching);
    final (icon, statusText) = switch (state.status) {
      ActressOnlineLineStatus.idle => (Icons.search, '点击查询'),
      ActressOnlineLineStatus.searching => (Icons.search, '搜索中…'),
      ActressOnlineLineStatus.found => (Icons.play_circle_fill, '已找到 · 点播'),
      ActressOnlineLineStatus.empty => (Icons.remove_circle_outline, '未找到'),
      ActressOnlineLineStatus.failed => (
        Icons.refresh,
        '搜索失败 · 点按重试',
      ),
    };
    final tappable = state.status != ActressOnlineLineStatus.searching;
    return InkWell(
      key: ValueKey('actress-online-line-${source.id}'),
      onTap: tappable ? () => unawaited(_tapPyLine(source)) : null,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: state.status == ActressOnlineLineStatus.found
                  ? colors.primary
                  : colors.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Text(
              source.label,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                statusText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 12.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lineRow(ActressOnlineSource source, ColorScheme colors) {
    final state =
        _states[source.id] ??
        const _LineState(ActressOnlineLineStatus.searching);
    final (icon, statusText) = switch (state.status) {
      ActressOnlineLineStatus.idle => (Icons.search, '点击查询'),
      ActressOnlineLineStatus.searching => (
        Icons.search,
        _resolving ? '取地址中…' : '搜索中…',
      ),
      ActressOnlineLineStatus.found => (Icons.play_circle_fill, '已找到 · 点播'),
      ActressOnlineLineStatus.empty => (Icons.remove_circle_outline, '未找到'),
      ActressOnlineLineStatus.failed => (
        Icons.refresh,
        '搜索失败 · 点按重试',
      ),
    };
    final tappable =
        state.status == ActressOnlineLineStatus.found ||
        state.status == ActressOnlineLineStatus.failed ||
        state.status == ActressOnlineLineStatus.idle;
    return InkWell(
      key: ValueKey('actress-online-line-${source.id}'),
      onTap: tappable ? () => unawaited(_tapLine(source)) : null,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: state.status == ActressOnlineLineStatus.found
                  ? colors.primary
                  : colors.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Text(
              source.label,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                state.status == ActressOnlineLineStatus.found &&
                        state.card != null
                    ? '$statusText · ${state.card!.title}'
                    : statusText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 12.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
