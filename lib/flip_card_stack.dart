import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'models.dart';
import 'widgets.dart';

/// 3D 翻页卡堆：层叠卡片（透视 + 扇形偏移），左右滑动翻页，点卡进详情。
///
/// 零新依赖。卡上没有任何“马上看/立即播放”按钮：点卡只调 [onOpen]
/// （进详情页），绝不直接播。手势只认横滑，不与竖滑冲突；数据为空时
/// 父级直接不渲染本区（本组件自身也回空盒，不留空壳）。
class FlipCardStack extends StatefulWidget {
  const FlipCardStack({
    super.key,
    required this.items,
    required this.repository,
    required this.onOpen,
    this.height = 232,
  });

  final List<Drama> items;
  final AppRepository repository;
  final void Function(Drama drama) onOpen;
  final double height;

  @override
  State<FlipCardStack> createState() => _FlipCardStackState();
}

class _FlipCardStackState extends State<FlipCardStack> {
  int _index = 0;
  double _dragDx = 0;

  @override
  void didUpdateWidget(covariant FlipCardStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = oldWidget.items.isEmpty ? null : oldWidget.items.first.id;
    final newId = widget.items.isEmpty ? null : widget.items.first.id;
    if (oldId != newId) {
      _index = 0;
      _dragDx = 0;
    } else if (widget.items.isNotEmpty) {
      _index %= widget.items.length;
    }
  }

  void _finishDrag() {
    final count = widget.items.length;
    if (count > 1) {
      if (_dragDx < -48) {
        _index = (_index + 1) % count;
      } else if (_dragDx > 48) {
        _index = (_index - 1 + count) % count;
      }
    }
    _dragDx = 0;
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.isEmpty) return const SizedBox.shrink();
    final cardHeight = math.max(120.0, widget.height - 8);
    final cardWidth = cardHeight * 2 / 3;
    final visible = math.min(3, items.length);
    return SizedBox(
      height: widget.height,
      child: GestureDetector(
        // 只认横滑翻页：竖向手势不认领，不与页面竖滑抢。
        onHorizontalDragUpdate: (details) {
          setState(() {
            _dragDx = (_dragDx + details.delta.dx).clamp(-120.0, 120.0);
          });
        },
        onHorizontalDragEnd: (_) => setState(_finishDrag),
        onHorizontalDragCancel: () => setState(() => _dragDx = 0),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 先画深层卡、后画顶卡，顶卡在最上。
            for (var depth = visible - 1; depth >= 0; depth--)
              _positionedCard(
                items[(_index + depth) % items.length],
                depth: depth,
                cardWidth: cardWidth,
                cardHeight: cardHeight,
                front: depth == 0,
              ),
          ],
        ),
      ),
    );
  }

  Widget _positionedCard(
    Drama drama, {
    required int depth,
    required double cardWidth,
    required double cardHeight,
    required bool front,
  }) {
    // 顶卡跟手横移一小段并微转；深层卡向右扇开、缩小、变暗。
    final dx = front ? _dragDx * 0.6 : depth * 18.0;
    final dy = front ? 0.0 : depth * 5.0;
    final rotateY = front
        ? (_dragDx / 900).clamp(-0.25, 0.25)
        : -0.16 * depth;
    final scale = 1 - depth * 0.07;
    final card = SizedBox(
      width: cardWidth,
      height: cardHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DramaCover(
              drama: drama,
              repository: widget.repository,
              radius: 0,
              // 标题由本卡底部自画，封面不再叠集数标，避免重影。
              showEpisodeLabel: false,
            ),
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black54,
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Text(
                drama.title,
                maxLines: 2,
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
      ),
    );
    final positioned = Align(
      alignment: Alignment.center,
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0012)
          ..translate(dx, dy)
          ..rotateY(rotateY)
          ..scale(scale),
        child: front
            // 只有顶卡可点：点卡进详情，不直接播，卡上无任何播放按钮。
            ? GestureDetector(
                key: const ValueKey('flip-card-top'),
                onTap: () => widget.onOpen(drama),
                child: Opacity(opacity: 1 - depth * 0.22, child: card),
              )
            : IgnorePointer(
                child: Opacity(opacity: 1 - depth * 0.22, child: card),
              ),
      ),
    );
    return positioned;
  }
}
