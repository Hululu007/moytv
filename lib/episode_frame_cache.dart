import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 播过留帧的磁盘缓存：某集播放时截一帧存为 JPEG，选集卡优先
/// 显示缓存帧（缓存帧 > TMDB 剧照 > 海报）。没播过的集没有帧，
/// 仍显示剧照/海报——帧是渐进积累的，绝不拿裁切海报冒充。
///
/// 缓存放在应用缓存目录下的 episode_frames/，有数量与总字节
/// 两个上限，超了按“最旧先删”清理，不会无限胀。
class EpisodeFrameCache {
  EpisodeFrameCache({
    Future<Directory> Function()? directoryProvider,
    this.maxFiles = maxFilesDefault,
    this.maxBytes = maxBytesDefault,
  }) : _directoryProvider =
           directoryProvider ?? EpisodeFrameCache._defaultDirectory;

  static final EpisodeFrameCache instance = EpisodeFrameCache();

  static const int maxFilesDefault = 200;
  static const int maxBytesDefault = 40 * 1024 * 1024;
  static const String _dirName = 'episode_frames';

  final int maxFiles;
  final int maxBytes;

  final Future<Directory> Function() _directoryProvider;
  Directory? _dir;

  static Future<Directory> _defaultDirectory() async {
    final cache = await getApplicationCacheDirectory();
    final dir = Directory(p.join(cache.path, _dirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 帧文件的稳定键：同一站、同一部剧、同一集号永远对应同一个
  /// 文件名。集号取自 Episode.number，与卡片下标无关，倒序、
  /// 分页都不会错位。
  static String frameKey({
    required String source,
    required String dramaId,
    required int episodeNumber,
  }) {
    final raw = '$source|$dramaId|$episodeNumber';
    return '${sha1.convert(utf8.encode(raw))}.jpg';
  }

  /// 列出已缓存的全部键（文件名）。调用方在进页时调一次，
  /// 结果进 State，卡片按集合成员关系决定显不显示帧图。
  Future<Set<String>> warmUp() async {
    final dir = await _directory();
    final keys = <String>{};
    try {
      await for (final entry in dir.list()) {
        if (entry is File && entry.path.endsWith('.jpg')) {
          keys.add(p.basename(entry.path));
        }
      }
    } catch (_) {
      // 缓存目录读失败时当作空缓存，卡片回落剧照/海报。
    }
    return keys;
  }

  /// 已初始化后返回 [key] 对应的文件路径；未 warmUp/未存帧时
  /// 返回 null。调用方只在键已在 warmUp 集合里时才用它。
  String? pathForKey(String key) {
    final dir = _dir;
    if (dir == null) return null;
    return p.join(dir.path, key);
  }

  /// 存一帧。写成功后顺手清理超上限的旧文件。任何失败都只
  /// 返回 false，不抛——截帧是锦上添花，不能影响播放。
  Future<bool> saveFrame(String key, List<int> bytes) async {
    if (bytes.isEmpty) return false;
    try {
      final dir = await _directory();
      final file = File(p.join(dir.path, key));
      await file.writeAsBytes(bytes, flush: true);
      await _prune(dir);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Directory> _directory() async {
    final existing = _dir;
    if (existing != null) return existing;
    final dir = await _directoryProvider();
    _dir = dir;
    return dir;
  }

  Future<void> _prune(Directory dir) async {
    try {
      final entries = <EpisodeFrameEntry>[];
      await for (final entry in dir.list()) {
        if (entry is! File || !entry.path.endsWith('.jpg')) continue;
        final stat = await entry.stat();
        entries.add(
          EpisodeFrameEntry(
            name: p.basename(entry.path),
            size: stat.size,
            modified: stat.modified,
          ),
        );
      }
      final doomed = episodeFramePrunePlan(
        entries,
        maxFiles: maxFiles,
        maxBytes: maxBytes,
      );
      for (final name in doomed) {
        try {
          await File(p.join(dir.path, name)).delete();
        } catch (_) {
          // 单个删失败不影响其它。
        }
      }
    } catch (_) {
      // 清理失败不影响存帧本身。
    }
  }
}

class EpisodeFrameEntry {
  const EpisodeFrameEntry({
    required this.name,
    required this.size,
    required this.modified,
  });

  final String name;
  final int size;
  final DateTime modified;
}

/// 纯函数：按“最旧先删”算出要删的文件名，直到数量与总字节
/// 都回到上限内；未超上限返回空。清理决策集中在此处以便单测。
List<String> episodeFramePrunePlan(
  List<EpisodeFrameEntry> entries, {
  int maxFiles = EpisodeFrameCache.maxFilesDefault,
  int maxBytes = EpisodeFrameCache.maxBytesDefault,
}) {
  var total = 0;
  for (final entry in entries) {
    total += entry.size;
  }
  if (entries.length <= maxFiles && total <= maxBytes) return const [];
  final ordered = List<EpisodeFrameEntry>.of(entries)
    ..sort((a, b) => a.modified.compareTo(b.modified));
  final doomed = <String>[];
  var remaining = entries.length;
  for (final entry in ordered) {
    if (remaining <= maxFiles && total <= maxBytes) break;
    doomed.add(entry.name);
    remaining -= 1;
    total -= entry.size;
  }
  return doomed;
}
