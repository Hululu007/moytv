import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';
import 'tmdb/tmdb_config.dart';
import 'tmdb/tmdb_metadata.dart';
import 'widgets.dart';

/// 播放页横排选集里单张预览卡的固定宽度。详情页网格卡按列宽
/// 自适应；滚回当前集的估算步长也按它加间距算。
const double episodePreviewCardWidth = 148;

/// 预览卡总高度 = 16:9 图高 + 56 文字区，字号缩放钳制在 1.0–1.4。
/// 详情页网格与播放页横排共用同一公式。
double episodePreviewCardExtent(BuildContext context, double width) {
  final factor = MediaQuery.textScalerOf(context).scale(14) / 14;
  final textScale = math.min(1.4, math.max(1.0, factor));
  return width * 9 / 16 + 56 * textScale;
}

/// 一集的预览图数据：TMDB 匹配结果 + 实际要显示的 still/海报地址。
/// 匹配与兜底规则集中在 [episodePreviewData]，详情页与播放页共用，
/// 保证两页行为一致；规则见 episode_preview_data_test。
class EpisodePreviewData {
  const EpisodePreviewData({
    required this.tmdb,
    required this.stillUrl,
    required this.posterUrl,
  });

  final TmdbEpisode? tmdb;
  final String stillUrl;
  final String posterUrl;
}

/// 按全集标题顺序算出每集的预览图数据，返回列表与 [titles] 等长、
///
/// 顺序一致。still 取 TMDB 集剧照（w500），没有匹配时为空，卡片改
/// 显示海报兜底；海报兜底优先 TMDB 海报、其次本剧封面。调用方在
/// 全集列表上算一次、按真实集号下标取，不要逐页/逐屏重算，避免
/// 倒序或分页时错位。
List<EpisodePreviewData> episodePreviewData({
  required List<String> titles,
  required List<TmdbEpisode> tmdbEpisodes,
  required TmdbConfig config,
  required String tmdbPosterUrl,
  required String dramaCover,
}) {
  final matched = matchTmdbEpisodes(titles, tmdbEpisodes);
  final posterUrl = tmdbPosterUrl.isNotEmpty ? tmdbPosterUrl : dramaCover;
  return [
    for (var i = 0; i < titles.length; i++)
      EpisodePreviewData(
        tmdb: matched[i],
        stillUrl: matched[i] == null
            ? ''
            : config.imageUrl(matched[i]!.stillPath, size: 'w500'),
        posterUrl: posterUrl,
      ),
  ];
}

/// 选集区的预览图卡片：16:9 剧照（TMDB still 优先、本剧海报
/// 兜底、都没有时显示带集号的占位块）+ 左上角集号角标 + 可播标题
/// + TMDB 集名/播出日期副标题。点按播放该集；图片加载失败时只显示
/// 占位块，不闪退、不留空白。无时长字段，卡片上不显示时长。
class EpisodePreviewCard extends StatelessWidget {
  const EpisodePreviewCard({
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
      if (tmdb != null && tmdb!.name.isNotEmpty && tmdb!.name != episode.title)
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
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
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
