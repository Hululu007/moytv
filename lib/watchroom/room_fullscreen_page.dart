import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'player.dart';

class RoomFullscreenPage extends StatefulWidget {
  const RoomFullscreenPage({
    super.key,
    required this.handle,
    required this.viewType,
    required this.onCompleted,
    required this.onError,
    required this.onRetry,
  });

  final RoomPlayerHandle handle;
  final String viewType;
  final VoidCallback onCompleted;
  final ValueChanged<String> onError;
  final VoidCallback onRetry;

  @override
  State<RoomFullscreenPage> createState() => _RoomFullscreenPageState();
}

class _RoomFullscreenPageState extends State<RoomFullscreenPage> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          RoomPlayerView(
            handle: widget.handle,
            viewType: widget.viewType,
            onCompleted: widget.onCompleted,
            onError: widget.onError,
            onRetry: widget.onRetry,
            onFullscreen: () => Navigator.of(context).pop(),
            isFullscreen: true,
          ),
          Positioned(
            top: 8,
            left: 8,
            child: SafeArea(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .36),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: IconButton(
                  tooltip: '退出全屏',
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.white,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
