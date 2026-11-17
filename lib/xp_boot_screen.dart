import 'package:flutter/material.dart';

/// XP 启动屏最短显示时长：冷启动初始化再快，启动屏也至少显示
/// 这么久；初始化慢时以初始化完成为准（不阻塞初始化，取两者较晚者）。
const Duration xpBootMinDisplay = Duration(milliseconds: 1000);

/// XP 启动屏：每次冷启动都显示（不限于 XP 主题）。黑底 + 居中文字
/// 标识（只用文字排版，不用任何品牌标志图、不写任何公司版权行）
/// + 下方经典分段加载条（描边轨道 + 3 段蓝色块来回滚动）。
///
/// 加载条动画用 AnimationController 循环：测试里用 pump(Duration)
/// 可推进；出错分支不转加载条，只显示错误文案 + “重新打开”按钮，
/// 绝不把用户困在黑屏上。
class XpBootScreen extends StatefulWidget {
  const XpBootScreen({
    super.key,
    required this.appName,
    this.error,
    this.onRetry,
    this.video,
  });

  final String appName;

  /// 初始化错误文案；非空时显示出错分支（不转加载条）。
  final String? error;
  final VoidCallback? onRetry;

  /// 开机视频覆盖层：加载分支时全屏盖在动画屏之上，视频起不来
  /// 时它自己退成透明，动画屏照常显示；出错分支不显示视频。
  /// null 时只有动画屏。
  final Widget? video;

  @override
  State<XpBootScreen> createState() => _XpBootScreenState();
}

class _XpBootScreenState extends State<XpBootScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    duration: const Duration(milliseconds: 1400),
    vsync: this,
  );

  @override
  void initState() {
    super.initState();
    if (widget.error == null) _controller.repeat();
  }

  @override
  void didUpdateWidget(XpBootScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.error == null && !_controller.isAnimating) {
      _controller.repeat();
    } else if (widget.error != null && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = widget.error;
    final video = widget.video;
    final body = Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 文字标识：应用名 + XP 字样，纯文字排版。
            Text(
              widget.appName,
              key: const ValueKey('xp-boot-app-name'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 40,
                fontWeight: FontWeight.w300,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'XP',
              key: ValueKey('xp-boot-xp-mark'),
              style: TextStyle(
                color: Color(0xFF3A93FF),
                fontSize: 40,
                fontWeight: FontWeight.bold,
                letterSpacing: 6,
              ),
            ),
            const SizedBox(height: 48),
            if (error == null) ...[
              _XpLoadBar(animation: _controller),
              const SizedBox(height: 24),
              const Text(
                '正在启动…',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ] else ...[
              Text(
                error,
                key: const ValueKey('xp-boot-error'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: widget.onRetry,
                child: const Text('重新打开'),
              ),
            ],
          ],
        ),
      ),
    );
    return Scaffold(
      backgroundColor: Colors.black,
      // 加载分支有视频层时，视频全屏盖在动画屏之上；视频回落
      // 透明时动画屏透出来。出错分支只有动画屏（错误文案）。
      body: error == null && video != null
          ? Stack(
              key: const ValueKey('xp-boot-video-stack'),
              children: [body, Positioned.fill(child: video)],
            )
          : body,
    );
  }
}

/// 分段加载条：描边轨道 + 3 段蓝色块自左向右滚动、循环往复。
class _XpLoadBar extends StatelessWidget {
  const _XpLoadBar({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('xp-boot-load-bar'),
      width: 180,
      height: 16,
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFF8A8A8A), width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final track = constraints.maxWidth;
                const segCount = 3;
                final segWidth = track / 7;
                const gap = 4.0;
                final groupWidth = segCount * segWidth + (segCount - 1) * gap;
                final travel = track + groupWidth;
                final x = animation.value * travel - groupWidth;
                return Stack(
                  children: [
                    for (var i = 0; i < segCount; i++)
                      Positioned(
                        left: x + i * (segWidth + gap),
                        top: 2,
                        bottom: 2,
                        width: segWidth,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0xFF7DB3E8), Color(0xFF245EDC)],
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}
