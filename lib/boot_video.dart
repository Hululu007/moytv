import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 开机视频资源：竖屏版 XP 开机动画（1080x1920、10.5 秒、无声）。
const String bootVideoAsset = 'assets/xp_boot_video.mp4';

/// 开机视频：冷启动时全屏循环播放 [bootVideoAsset]，初始化完成、
/// 启动屏消失时随树一起销毁，不强制播完。
///
/// 失败即透明回落：播放器建不起来、开流失败、播放中出错，
/// 一律退成透明占位，底下的动画启动屏（文字标识 + 加载条）
/// 照常显示，绝不把用户困在黑屏上。测试环境里 media_kit
/// 未初始化，Player() 必然抛错，走的正是这条回落路。
class BootVideo extends StatefulWidget {
  const BootVideo({super.key, this.asset = bootVideoAsset});

  final String asset;

  @override
  State<BootVideo> createState() => _BootVideoState();
}

class _BootVideoState extends State<BootVideo> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<String>? _errorSubscription;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final player = Player(
        configuration: const PlayerConfiguration(
          logLevel: MPVLogLevel.error,
        ),
      );
      _player = player;
      _controller = VideoController(player);
      _errorSubscription = player.stream.error.listen((_) => _markFailed());
      await player.setPlaylistMode(PlaylistMode.loop);
      await player.setVolume(0);
      await player.open(Media('asset:///${widget.asset}'), play: true);
      if (mounted) setState(() {});
    } catch (_) {
      _markFailed();
    }
  }

  void _markFailed() {
    if (_failed) return;
    _failed = true;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _errorSubscription?.cancel();
    // 播放器只在创建成功时存在；销毁是异步收尾，不阻塞卸树。
    unawaited(_player?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return const SizedBox.shrink();
    final controller = _controller;
    if (controller == null) {
      // 播放器还在起：先给纯黑，等画面出来再盖上去，
      // 不让底下的动画屏闪一下。
      return const ColoredBox(color: Colors.black);
    }
    return Video(
      key: const ValueKey('boot-video'),
      controller: controller,
      fit: BoxFit.cover,
      fill: Colors.black,
      controls: null,
      wakelock: false,
    );
  }
}
