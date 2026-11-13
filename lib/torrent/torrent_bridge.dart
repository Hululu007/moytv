import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'torrent_engine.dart';

/// 原生种子桥的 Dart 侧：通道 moyi/torrent。
///
/// 安卓侧由 TorrentBridge.kt 实现：TorrServer 子进程管理 + 迅雷 SDK 调用。
/// iOS 上没有原生实现，调用会抛 MissingPluginException，这里统一转成
/// TorrentEngineUnavailable（诚实不可用），绝不编假数据。
class TorrentBridge {
  TorrentBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('moyi/torrent');

  final MethodChannel _channel;

  Future<Map<String, dynamic>> torrServerStatus() async {
    final result = await _invoke('torrserverStatus', const {});
    return result;
  }

  Future<Map<String, dynamic>> torrServerStart({int port = 8090}) async {
    final result = await _invoke('torrserverStart', {'port': port});
    return result;
  }

  Future<void> torrServerStop() async {
    await _invoke('torrserverStop', const {});
  }

  Future<Map<String, dynamic>> thunderStatus() async {
    final result = await _invoke('thunderStatus', const {});
    return result;
  }

  /// 解析一条种子链接（magnet/thunder/ed2k/.torrent 地址或本地 .torrent 路径）。
  ///
  /// 返回：infoHash、name、size、files（index/name/size/isVideo）、
  /// taskKey（后续取流/状态/停止用）、singleFile（是否单文件直链任务）。
  Future<Map<String, dynamic>> thunderResolve({
    required String url,
    required String key,
  }) async {
    final result = await _invoke('thunderResolve', {'url': url, 'key': key});
    return result;
  }

  /// 取某文件的本地播流地址（迅雷内部 HTTP 服务地址）。
  Future<String> thunderStreamUrl({
    required String taskKey,
    required int index,
  }) async {
    final result = await _invoke('thunderStreamUrl', {
      'taskKey': taskKey,
      'index': index,
    });
    final url = result['url'] as String? ?? '';
    if (url.isEmpty) {
      throw const TorrentEngineUnavailable('迅雷未返回可播放地址');
    }
    return url;
  }

  Future<Map<String, dynamic>> thunderStats({required String taskKey}) async {
    final result = await _invoke('thunderStats', {'taskKey': taskKey});
    return result;
  }

  Future<void> thunderStop({required String taskKey}) async {
    await _invoke('thunderStop', {'taskKey': taskKey});
  }

  Future<Map<String, dynamic>> _invoke(
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        method,
        args,
      );
      if (result == null) return const {};
      return Map<String, dynamic>.from(result);
    } on MissingPluginException {
      throw const TorrentEngineUnavailable(
        '种子播放仅支持安卓：当前设备没有原生种子引擎',
      );
    } on PlatformException catch (error) {
      throw TorrentEngineUnavailable(
        error.message ?? '原生种子引擎调用失败（$method）',
      );
    }
  }
}

/// 迅雷任务解析结果（thunderResolve 返回的 Dart 映射）。
class ThunderResolved {
  ThunderResolved({
    required this.infoHash,
    required this.name,
    required this.size,
    required this.files,
    required this.taskKey,
    required this.singleFile,
  });

  final String infoHash;
  final String name;
  final int size;
  final List<EngineFile> files;
  final String taskKey;
  final bool singleFile;

  factory ThunderResolved.fromJson(Map<String, dynamic> json) {
    final rawFiles = json['files'];
    final files = <EngineFile>[];
    if (rawFiles is List) {
      for (final row in rawFiles) {
        if (row is! Map) continue;
        files.add(EngineFile.fromJson(Map<String, dynamic>.from(row)));
      }
    }
    return ThunderResolved(
      infoHash: (json['infoHash'] as String? ?? '').toLowerCase(),
      name: json['name'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      files: files,
      taskKey: json['taskKey'] as String? ?? '',
      singleFile: json['singleFile'] == true,
    );
  }

  EngineTorrent toEngineTorrent() {
    return EngineTorrent(
      infoHash: infoHash,
      name: name,
      size: size,
      files: files,
      backendLabel: '迅雷',
    );
  }
}

@visibleForTesting
TorrentEngineUnavailable thunderMissingMessage() =>
    const TorrentEngineUnavailable('迅雷引擎不可用');
