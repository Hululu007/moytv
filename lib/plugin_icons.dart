import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 插件类型图标：jar 用咖啡杯、py 用爬虫，均为代码原创绘制，
/// 不使用任何第三方商标图。
enum PluginIconKind { jar, py }

class PluginTypeIcon extends StatelessWidget {
  const PluginTypeIcon({
    super.key,
    required this.kind,
    this.size = 20,
    this.color,
  });

  final PluginIconKind kind;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved =
        color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: kind == PluginIconKind.jar
            ? _CoffeeCupPainter(resolved)
            : _SpiderPainter(resolved),
      ),
    );
  }
}

/// 咖啡杯：杯身 + 右侧杯耳 + 杯托 + 两道热气。
class _CoffeeCupPainter extends CustomPainter {
  const _CoffeeCupPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = unit * 0.07
      ..strokeCap = StrokeCap.round;

    // 杯身：上宽下窄的圆角梯形。
    final body = Path()
      ..moveTo(unit * 0.18, unit * 0.36)
      ..lineTo(unit * 0.62, unit * 0.36)
      ..lineTo(unit * 0.56, unit * 0.70)
      ..quadraticBezierTo(
        unit * 0.54,
        unit * 0.76,
        unit * 0.48,
        unit * 0.76,
      )
      ..lineTo(unit * 0.32, unit * 0.76)
      ..quadraticBezierTo(
        unit * 0.26,
        unit * 0.76,
        unit * 0.24,
        unit * 0.70,
      )
      ..close();
    canvas.drawPath(body, fill);

    // 杯耳：右侧一圈弧线。
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(unit * 0.70, unit * 0.54),
        width: unit * 0.24,
        height: unit * 0.24,
      ),
      -math.pi * 0.45,
      math.pi * 0.9,
      false,
      stroke,
    );

    // 杯托。
    canvas.drawLine(
      Offset(unit * 0.14, unit * 0.84),
      Offset(unit * 0.78, unit * 0.84),
      stroke,
    );

    // 两道热气：S 形波浪线。
    for (final x in [0.32, 0.50]) {
      final steam = Path()
        ..moveTo(unit * x, unit * 0.28)
        ..cubicTo(
          unit * (x - 0.06),
          unit * 0.22,
          unit * (x + 0.06),
          unit * 0.16,
          unit * x,
          unit * 0.08,
        );
      final steamPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = unit * 0.055
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(steam, steamPaint);
    }
  }

  @override
  bool shouldRepaint(_CoffeeCupPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 爬虫：圆头 + 椭圆身 + 两侧各四条折腿 + 两只眼。
class _SpiderPainter extends CustomPainter {
  const _SpiderPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final legPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = unit * 0.055
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 八条腿：每侧四条，起于身体边缘，先斜上/斜下再折向外。
    const legs = [
      (0.34, 0.40, 0.16, 0.26, 0.04, 0.14),
      (0.30, 0.52, 0.12, 0.46, 0.02, 0.40),
      (0.30, 0.66, 0.12, 0.72, 0.02, 0.80),
      (0.34, 0.78, 0.16, 0.88, 0.06, 0.96),
    ];
    for (final (x1, y1, x2, y2, x3, y3) in legs) {
      for (final mirror in [false, true]) {
        double mx(double v) => mirror ? 1.0 - v : v;
        canvas.drawPath(
          Path()
            ..moveTo(unit * mx(x1), unit * y1)
            ..lineTo(unit * mx(x2), unit * y2)
            ..lineTo(unit * mx(x3), unit * y3),
          legPaint,
        );
      }
    }

    // 身体：椭圆。
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(unit * 0.5, unit * 0.60),
        width: unit * 0.44,
        height: unit * 0.52,
      ),
      fill,
    );
    // 头：圆。
    canvas.drawCircle(Offset(unit * 0.5, unit * 0.28), unit * 0.11, fill);

    // 眼睛：头上两个浅色小点。
    final eyePaint = Paint()
      ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(unit * 0.46, unit * 0.27), unit * 0.025, eyePaint);
    canvas.drawCircle(Offset(unit * 0.54, unit * 0.27), unit * 0.025, eyePaint);
  }

  @override
  bool shouldRepaint(_SpiderPainter oldDelegate) => oldDelegate.color != color;
}
