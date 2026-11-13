import 'package:flutter/material.dart';

import '../core_bridge.dart';
import '../local_store.dart';
import '../models.dart';
import '../player_picker.dart';
import 'torrent_engine.dart';
import 'torrent_playback_source.dart';

/// 把一个已取到流地址的种子文件送进现有播放器（与普通视频同一套播放页）。
///
/// 只播选中的这一个文件：多文件种子先在种子页选文件再播，播放器内
/// 不切种子内其它文件（迅雷侧每个文件要单独建任务取地址，无法预拼）。
Future<void> playTorrentFile(
  BuildContext context, {
  required AppRepository repository,
  required LocalStore store,
  required TorrentSession session,
  required EngineFile file,
  required Uri streamUrl,
}) async {
  final title = file.name.isEmpty ? session.name : file.name;
  final drama = Drama(
    id: 'torrent:${session.id}:${file.index}',
    source: torrentPlaybackSourceId,
    title: title,
  );
  final detail = DramaDetail(drama, [
    Episode({
      'id': '${session.id}:${file.index}',
      'title': title,
      'currentEpisode': 1,
      torrentStreamUrlKey: streamUrl.toString(),
    }, 1),
  ]);
  await pushPlayer<void>(
    context,
    detail: detail,
    initialIndex: 0,
    repository: repository,
    store: store,
  );
}

/// 从文件列表里挑默认播放文件：优先最大的视频文件，其次第一个视频文件，
/// 没有视频文件时取第一个文件；空列表返回 null。
EngineFile? defaultPlayableFile(List<EngineFile> files) {
  if (files.isEmpty) return null;
  final videos = [for (final file in files) if (file.isVideo) file];
  final pool = videos.isEmpty ? files : videos;
  var best = pool.first;
  for (final file in pool) {
    if (file.size > best.size) best = file;
  }
  return best;
}
