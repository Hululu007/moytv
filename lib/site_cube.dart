import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 一个站点的 3D 方块：六个面取该站首页海报，横向拖动旋转，点按进站。
///
/// 零新依赖，只用 [Matrix4] 透视变换。旋转角只存在本 widget 的 state 里，
/// 拖动只转当前方块，不影响其它方块。封面取不到的面显示站名 + 图标占位，
/// 绝不编假图。
///
/// [covers] 是已解析的封面地址（本地文件路径或 http(s) 地址），按
/// 前、后、右、左、上、下的顺序对应六个面；不足 6 张或加载失败的面
/// 显示占位。点按与拖动用距离区分：一次手势里横向拖动累计超过
/// [_tapDragThreshold] 就不触发 [onTap]。
class SiteCube extends StatefulWidget {
  const SiteCube({
    super.key,
    required this.siteName,
    this.covers = const [],
    this.size = 120,
    this.onTap,
  });

  /// 站名：显示在占位面上，六个面都没有封面时也看得到是哪个站。
  final String siteName;

  /// 封面地址列表，最多取前 6 张。
  final List<String> covers;

  /// 方块边长（逻辑像素）。
  final double size;

  /// 点按方块（非拖动）的回调。
  final VoidCallback? onTap;

  @override
  State<SiteCube> createState() => _SiteCubeState();
}

enum _FaceAxis { none, x, y }

class _FaceSpec {
  const _FaceSpec(this.nx, this.ny, this.nz, this.axis, this.angle);

  /// 该面朝外的法线（方块局部坐标，y 向下）。
  final double nx;
  final double ny;
  final double nz;

  /// 该面从正面（朝 +z）转到位的旋转轴与角度。
  final _FaceAxis axis;
  final double angle;
}

class _SiteCubeState extends State<SiteCube> {
  /// 六个面的规格，顺序即 covers 的对应顺序：前、后、右、左、上、下。
  static const _faces = <_FaceSpec>[
    _FaceSpec(0, 0, 1, _FaceAxis.none, 0),
    _FaceSpec(0, 0, -1, _FaceAxis.y, math.pi),
    _FaceSpec(1, 0, 0, _FaceAxis.y, math.pi / 2),
    _FaceSpec(-1, 0, 0, _FaceAxis.y, -math.pi / 2),
    _FaceSpec(0, -1, 0, _FaceAxis.x, math.pi / 2),
    _FaceSpec(0, 1, 0, _FaceAxis.x, -math.pi / 2),
  ];

  /// 固定俯仰角：略露出顶面，让人一眼看出是方块。
  static const _tilt = -0.3;

  /// 点按与拖动的区分阈值（逻辑像素）：累计横向拖动超过它就不算点按。
  static const _tapDragThreshold = 10.0;

  /// 当前绕 Y 轴的旋转角（弧度），初始略带角度。
  double _angleY = 0.35;

  /// 本次手势累计的横向拖动距离（逻辑像素）。
  double _dragDistance = 0;

  /// 某面法线经方块旋转后朝向观察者的程度（z 分量）：越大越靠前。
  /// 旋转链是 rotateX(_tilt) 后 rotateY(_angleY)，只取 z 分量排序用。
  double _faceDepth(_FaceSpec face) {
    final sinA = math.sin(_angleY);
    final cosA = math.cos(_angleY);
    final sinT = math.sin(_tilt);
    final cosT = math.cos(_tilt);
    return face.ny * sinT + (-face.nx * sinA + face.nz * cosA) * cosT;
  }

  @override
  Widget build(BuildContext context) {
    // Flutter 的 Transform 不做深度缓冲：按法线 z 从远到近画，
    // 后画的面盖住前面的面，旋转时前后关系才正确。
    final order = List<int>.generate(_faces.length, (i) => i)
      ..sort((a, b) => _faceDepth(_faces[a]).compareTo(_faceDepth(_faces[b])));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => _dragDistance = 0,
      onHorizontalDragUpdate: (details) {
        setState(() {
          _dragDistance += details.delta.dx.abs();
          _angleY += details.delta.dx * 0.01;
        });
      },
      onHorizontalDragEnd: (_) => _dragDistance = 0,
      onTap: () {
        if (_dragDistance > _tapDragThreshold) return;
        widget.onTap?.call();
      },
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Stack(
          // 转动时角会短暂超出正方形 bounds，允许溢出绘制，
          // 落点行留了上下边距接住它。
          clipBehavior: Clip.none,
          children: [
            for (final index in order) _face(index),
          ],
        ),
      ),
    );
  }

  Widget _face(int index) {
    final spec = _faces[index];
    final half = widget.size / 2;
    final matrix = Matrix4.identity()
      ..setEntry(3, 2, 0.0015)
      ..rotateX(_tilt)
      ..rotateY(_angleY);
    switch (spec.axis) {
      case _FaceAxis.x:
        matrix.rotateX(spec.angle);
      case _FaceAxis.y:
        matrix.rotateY(spec.angle);
      case _FaceAxis.none:
        break;
    }
    matrix.translate(0.0, 0.0, half);
    final cover = index < widget.covers.length ? widget.covers[index] : '';
    return Transform(
      transform: matrix,
      alignment: Alignment.center,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: _faceContent(cover),
      ),
    );
  }

  /// 单个面：占位打底（站名 + 图标），有封面时封面盖在上面；
  /// 封面加载失败时 errorBuilder 交出空白，露出占位。
  Widget _faceContent(String cover) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.22),
        ),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.surfaceContainerHighest, colors.surfaceContainer],
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: const EdgeInsets.all(6),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.dns_outlined,
                      size: 26,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.siteName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (cover.isNotEmpty) _coverImage(cover),
          ],
        ),
      ),
    );
  }

  Widget _coverImage(String cover) {
    const fit = BoxFit.cover;
    Widget onError(BuildContext _, Object __, StackTrace? ___) =>
        const SizedBox.shrink();
    if (cover.startsWith('http://') || cover.startsWith('https://')) {
      return Image.network(cover, fit: fit, errorBuilder: onError);
    }
    return Image.file(File(cover), fit: fit, errorBuilder: onError);
  }
}
