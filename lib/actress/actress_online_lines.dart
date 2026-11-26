import 'dart:async';

import 'package:flutter/material.dart';

import '../core_bridge.dart';
import '../models.dart';
import 'actress_online_detail.dart';
import 'actress_online_parse.dart';
import 'actress_online_sources.dart';

/// 一条在线线路的搜索状态。
enum ActressOnlineLineStatus { searching, found, empty, failed }

class _LineState {
  const _LineState(this.status, {this.card});

  final ActressOnlineLineStatus status;
  final OnlineVideoCard? card;
}

/// 详情页「在线线路」区（2026-11-26 用户令）：打开作品详情时
/// 自动按番号去 123AV / PH 搜这部片，搜到的追加成可点的线
/// 路行——点行现取流、连请求头递给正式播放器起播（嗅探/解
/// 析只取链，绝不在网页里播，16:59 令）。搜不到标「未找
/// 到」、失败标「搜索失败 · 点按重试」，不编线路、不挡数据
/// 库线路出画（本区与库线路并行，库线路先到先播）。
/// who's py 链走既有的跨站选线路区，本区只管这两个 Dart
/// 直连源。在线播放未经本机出口验通，区头如实标「未验」。
class ActressOnlineLinesSection extends StatefulWidget {
  const ActressOnlineLinesSection({
    super.key,
    required this.code,
    required this.onPlay,
    this.fetch,
    this.sources = kActressOnlineSources,
  });

  /// 归一化番号（如 SSIS-001），按它搜索与匹配。
  final String code;

  /// 点中一条已找到的线路、取流成功后回调（调用方走正式
  /// 播放器起播）。
  final void Function(DramaDetail detail) onPlay;

  /// 取数注入（测试/预览用），默认走应用取数客户端。
  final ActressOnlineFetch? fetch;

  final List<ActressOnlineSource> sources;

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

  @override
  void initState() {
    super.initState();
    for (final source in widget.sources) {
      _states[source.id] = const _LineState(ActressOnlineLineStatus.searching);
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
      for (final source in widget.sources) _search(source),
    ]);
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
    if (state.status == ActressOnlineLineStatus.failed) {
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
        ],
      ),
    );
  }

  Widget _lineRow(ActressOnlineSource source, ColorScheme colors) {
    final state =
        _states[source.id] ??
        const _LineState(ActressOnlineLineStatus.searching);
    final (icon, statusText) = switch (state.status) {
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
        state.status == ActressOnlineLineStatus.failed;
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
