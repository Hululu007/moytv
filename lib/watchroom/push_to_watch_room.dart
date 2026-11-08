import 'package:flutter/material.dart';

import '../app_page_route.dart';

import '../core_bridge.dart';
import '../follow_state.dart';
import '../local_store.dart';
import '../models.dart';
import 'controller.dart';
import 'models.dart';
import 'room_screen.dart';

Future<void> pushDramaToWatchRoom(
  BuildContext context, {
  required AppRepository repository,
  required LocalStore store,
  required Drama drama,
  required List<Episode> episodes,
  int? episodeIndex,
}) async {
  if (episodes.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('暂无可推送的剧集')));
    return;
  }
  if (!store.allowsSource(drama.source)) {
    return;
  }
  final room = WatchRoomController.instance;
  try {
    if (room.inRoom && !room.isHost) {
      throw StateError('只有房主可以更换房间视频');
    }
    if (!room.inRoom) {
      await room.createRoom(preferences: store.preferences);
    }
    final index =
        (episodeIndex ?? resumeEpisodeIndex(episodes, store.watched(drama.id)))
            .clamp(0, episodes.length - 1);
    room.setVideo(
      RoomVideo(
        source: drama.source,
        dramaId: drama.id,
        title: drama.title,
        cover: drama.cover,
        sourceId: drama.sourceId,
        episodeIndex: index,
        episodeTitle: episodes[index].title,
      ),
    );
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
    return;
  }
  if (!context.mounted) {
    return;
  }
  await Navigator.of(context).push<void>(
    appPageRoute<void>(
      builder: (_) => WatchRoomScreen(repository: repository, store: store),
    ),
  );
}
