import 'dart:async';

import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'models.dart';
import 'widgets.dart';

/// 首页轮播选片口径：取目录第一页头部条目，优先有封面的
/// （列表模型只有封面图，无 backdrop 时即用封面），最多 8 条；
/// 文件夹条目不进轮播。无图或为空时返回空，整区隐藏。
List<Drama> carouselItems(List<Drama> items) {
  final out = <Drama>[];
  for (final drama in items) {
    if (drama.isFolder || drama.cover.trim().isEmpty) continue;
    out.add(drama);
    if (out.length >= 8) break;
  }
  return out;
}

/// 短剧/影视目录页顶部轮播：约 4 秒自动翻页 + 手动滑 + 圆点指示，
/// 点一张进对应详情。数据由父级按当前站源传入并以站源 id 作 key，
/// 切换站源时组件整体重建——不会出现 A 站轮播挂在 B 站列表上。
class HomeCarousel extends StatefulWidget {
  const HomeCarousel({
    super.key,
    required this.items,
    required this.repository,
    required this.onOpen,
  });

  final List<Drama> items;
  final AppRepository repository;
  final void Function(Drama drama) onOpen;

  @override
  State<HomeCarousel> createState() => _HomeCarouselState();
}

class _HomeCarouselState extends State<HomeCarousel> {
  final _controller = PageController();
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _armTimer();
  }

  @override
  void didUpdateWidget(HomeCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = oldWidget.items.firstOrNull?.id;
    final newId = widget.items.firstOrNull?.id;
    if (oldId != newId && _controller.hasClients) {
      _controller.jumpToPage(0);
      _page = 0;
    }
    _armTimer();
  }

  void _armTimer() {
    _timer?.cancel();
    if (widget.items.length < 2) return;
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || !_controller.hasClients) return;
      final next = (_page + 1) % widget.items.length;
      _controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Column(
      key: const ValueKey('home-carousel'),
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: PageView.builder(
              controller: _controller,
              itemCount: items.length,
              onPageChanged: (page) => setState(() => _page = page),
              itemBuilder: (context, index) {
                final drama = items[index];
                return GestureDetector(
                  key: ValueKey('home-carousel-item-${drama.id}'),
                  onTap: () => widget.onOpen(drama),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      DramaCover(
                        drama: drama,
                        repository: widget.repository,
                        radius: 0,
                      ),
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.55),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 14,
                        right: 14,
                        bottom: 10,
                        child: Text(
                          drama.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        if (items.length > 1) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < items.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _page ? 16 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _page
                        ? colors.primary
                        : colors.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// 切站/首拉时轮播位置的占位骨架（新数据到即被真轮播替换）。
class HomeCarouselSkeleton extends StatelessWidget {
  const HomeCarouselSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AspectRatio(
      key: const ValueKey('home-carousel-skeleton'),
      aspectRatio: 16 / 9,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Center(
          child: Icon(
            Icons.image_outlined,
            color: colors.onSurfaceVariant,
            size: 36,
          ),
        ),
      ),
    );
  }
}
