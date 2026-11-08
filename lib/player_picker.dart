import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'lan_models.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_queue.dart';
import 'player_route.dart';
import 'player_screen.dart';

import 'package:moyi/xigua/xigua_player_screen.dart';

/// 用户选定的播放器：guo（内置）或 xigua（移植自西瓜版）。
/// 持久化在 LocalStore 的 `player` 键（缺失时默认 guo），App 四端可随时切换。
enum AppPlayer {
  guo('guo', 'guo 播放器'),
  xigua('xigua', 'xigua 播放器');

  const AppPlayer(this.id, this.label);
  final String id;
  final String label;

  static AppPlayer parse(String? value) => AppPlayer.values.firstWhere(
    (player) => player.id == value,
    orElse: () => AppPlayer.guo,
  );
}

AppPlayer selectedPlayer(LocalStore store) => AppPlayer.parse(store.player);

Future<void> setSelectedPlayer(LocalStore store, AppPlayer player) =>
    store.setPlayer(player.id);

/// 按当前播放器偏好构建播放页路由。所有 VOD 播放跳转点统一走这里，
/// 保证 guo / xigua 随时可切换且互不影响。
Route<T> buildPlayerRoute<T>(
  BuildContext context, {
  required DramaDetail detail,
  required int initialIndex,
  required AppRepository repository,
  required LocalStore store,
  double initialPosition = 0,
  bool localOnly = false,
  bool allowOnlineFallback = true,
  String? mediaId,
  LanIncomingPlayback? handoff,
  String searchKeyword = '',
  PlaybackQueue? queue,
  bool startFullscreen = false,
}) {
  if (selectedPlayer(store) == AppPlayer.xigua) {
    // TODO(xigua): xigua 播放器暂未接 PlaybackQueue，单集上下滑切条目仅 guo 播放器生效。
    return playerRoute(
          XiguaPlayerScreen(
            detail: detail,
            initialIndex: initialIndex,
            initialPosition: initialPosition,
            localOnly: localOnly,
            allowOnlineFallback: allowOnlineFallback,
            mediaId: mediaId,
            handoff: handoff,
            repository: repository,
            store: store,
            searchKeyword: searchKeyword,
            startFullscreen: startFullscreen,
          ),
        )
        as Route<T>;
  }
  return playerRoute(
        PlayerScreen(
          detail: detail,
          initialIndex: initialIndex,
          initialPosition: initialPosition,
          localOnly: localOnly,
          allowOnlineFallback: allowOnlineFallback,
          mediaId: mediaId,
          handoff: handoff,
          repository: repository,
          store: store,
          queue: queue,
          startFullscreen: startFullscreen,
        ),
      )
      as Route<T>;
}

Future<T?> pushPlayer<T>(
  BuildContext context, {
  required DramaDetail detail,
  required int initialIndex,
  required AppRepository repository,
  required LocalStore store,
  double initialPosition = 0,
  bool localOnly = false,
  bool allowOnlineFallback = true,
  String? mediaId,
  LanIncomingPlayback? handoff,
  String searchKeyword = '',
  PlaybackQueue? queue,
  bool startFullscreen = false,
}) => Navigator.of(context).push<T>(
  buildPlayerRoute<T>(
    context,
    detail: detail,
    initialIndex: initialIndex,
    initialPosition: initialPosition,
    localOnly: localOnly,
    allowOnlineFallback: allowOnlineFallback,
    mediaId: mediaId,
    handoff: handoff,
    repository: repository,
    store: store,
    searchKeyword: searchKeyword,
    queue: queue,
    startFullscreen: startFullscreen,
  ),
);

/// 播放器选择页：在两个卡片式选项间单选，点「立即生效」持久化。
class PlayerPickerScreen extends StatefulWidget {
  const PlayerPickerScreen({super.key, required this.store});

  final LocalStore store;

  @override
  State<PlayerPickerScreen> createState() => _PlayerPickerScreenState();
}

class _PlayerPickerScreenState extends State<PlayerPickerScreen> {
  late AppPlayer _selected = selectedPlayer(widget.store);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('播放器选择')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final player in AppPlayer.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: _selected == player
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                leading: Icon(
                  _selected == player
                      ? Icons.play_circle_fill
                      : Icons.play_circle_outline,
                ),
                title: Text(player.label),
                subtitle: Text(
                  player == AppPlayer.guo
                      ? '内置播放器，轻量稳定，支持弹幕与线路切换'
                      : '移植自西瓜版，支持玻璃面板、睡眠定时、观看统计与推荐',
                ),
                trailing: _selected == player
                    ? const Icon(Icons.check_circle)
                    : null,
                onTap: () async {
                  setState(() => _selected = player);
                  await setSelectedPlayer(widget.store, player);
                },
              ),
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () async {
              await setSelectedPlayer(widget.store, _selected);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('立即生效'),
          ),
        ],
      ),
    );
  }
}
