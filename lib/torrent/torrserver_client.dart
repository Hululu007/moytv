import 'dart:convert';

import 'package:http/http.dart' as http;

import 'torrent_engine.dart';

/// TorrServer 本地服务 HTTP 客户端（纯 Dart，可注入 http.Client 做测试）。
///
/// 接口以 TorrServer 官方 swagger（MatriX.150，server/docs/swagger.yaml）为准：
/// POST /torrents，action: add/get/set/rem/list/drop/wipe；取流走
/// GET /stream?link=`<hash>`&index=`<n>`&play。
class TorrServerClient {
  TorrServerClient({required this.baseUrl, http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  Uri get _torrentsUri => Uri.parse('$baseUrl/torrents');

  /// 加种并返回种子状态。link 可以是 magnet 链接、哈希或 .torrent 地址。
  Future<TorrServerTorrent> add({
    required String link,
    String title = '',
    bool saveToDb = false,
  }) async {
    final body = await _post({
      'action': 'add',
      'link': link,
      if (title.isNotEmpty) 'title': title,
      'save_to_db': saveToDb,
    });
    return TorrServerTorrent.fromJson(body);
  }

  /// 取种子当前状态（含文件列表与速度）。
  Future<TorrServerTorrent> get(String hash) async {
    final body = await _post({'action': 'get', 'hash': hash});
    return TorrServerTorrent.fromJson(body);
  }

  /// 列出服务上全部种子。
  Future<List<TorrServerTorrent>> list() async {
    final body = await _post({'action': 'list'});
    if (body is List) {
      return [
        for (final row in body)
          if (row is Map) TorrServerTorrent.fromJson(Map<String, dynamic>.from(row)),
      ];
    }
    return const [];
  }

  /// 从服务上移除种子（不断本地缓存清理语义，按官方 rem 动作）。
  Future<void> remove(String hash) async {
    await _post({'action': 'rem', 'hash': hash});
  }

  /// 拼出某文件的播放流地址。link 用哈希，play=1 让服务开始预加载播流。
  Uri streamUri(String hash, int fileIndex) {
    return Uri.parse('$baseUrl/stream').replace(
      queryParameters: {'link': hash, 'index': '$fileIndex', 'play': '1'},
    );
  }

  Future<dynamic> _post(Map<String, dynamic> payload) async {
    http.Response response;
    try {
      response = await _http
          .post(
            _torrentsUri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 30));
    } on Exception catch (error) {
      throw TorrentEngineUnavailable(
        '连不上本地 TorrServer 服务（$baseUrl）：$error',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TorrentEngineUnavailable(
        'TorrServer 返回 HTTP ${response.statusCode}：${_shortBody(response.body)}',
      );
    }
    final trimmed = response.body.trim();
    if (trimmed.isEmpty) {
      throw const TorrentEngineUnavailable('TorrServer 返回了空响应');
    }
    try {
      return jsonDecode(trimmed);
    } catch (_) {
      throw TorrentEngineUnavailable(
        'TorrServer 返回的不是 JSON：${_shortBody(trimmed)}',
      );
    }
  }

  static String _shortBody(String body) =>
      body.length > 200 ? '${body.substring(0, 200)}…' : body;

  void close() => _http.close();
}

/// TorrServer 的种子状态（state.TorrentStatus 的 Dart 映射，字段缺失时容忍）。
class TorrServerTorrent {
  TorrServerTorrent({
    required this.hash,
    required this.name,
    required this.stat,
    required this.files,
    this.downloadSpeed,
    this.activePeers,
    this.pendingPeers,
    this.connectedSeeders,
    this.loadedSize,
    this.preloadedBytes,
    this.preloadSize,
    this.totalSize,
  });

  final String hash;
  final String name;

  /// 0 已添加，1 取信息中，2 预加载，3 工作中，4 已关闭，5 在库中。
  final int stat;
  final List<TorrServerFile> files;
  final double? downloadSpeed;
  final int? activePeers;
  final int? pendingPeers;
  final int? connectedSeeders;
  final int? loadedSize;
  final int? preloadedBytes;
  final int? preloadSize;
  final int? totalSize;

  bool get hasMetadata => files.isNotEmpty;

  factory TorrServerTorrent.fromJson(Map<String, dynamic> json) {
    final rawFiles = json['file_stats'];
    final files = <TorrServerFile>[];
    if (rawFiles is List) {
      for (final row in rawFiles) {
        if (row is! Map) continue;
        final file = TorrServerFile.fromJson(Map<String, dynamic>.from(row));
        files.add(file);
      }
    }
    files.sort((a, b) => a.id.compareTo(b.id));
    var total = 0;
    for (final file in files) {
      total += file.length;
    }
    return TorrServerTorrent(
      hash: (json['hash'] as String? ?? '').toLowerCase(),
      name: json['name'] as String? ?? '',
      stat: _asInt(json['stat']) ?? 0,
      files: files,
      downloadSpeed: _asDouble(json['download_speed']),
      activePeers: _asInt(json['active_peers']),
      pendingPeers: _asInt(json['pending_peers']),
      connectedSeeders: _asInt(json['connected_seeders']),
      loadedSize: _asInt(json['loaded_size']),
      preloadedBytes: _asInt(json['preloaded_bytes']),
      preloadSize: _asInt(json['preload_size']),
      totalSize: total > 0 ? total : null,
    );
  }

  EngineTorrent toEngineTorrent() {
    return EngineTorrent(
      infoHash: hash,
      name: name,
      size: totalSize ?? 0,
      files: [
        for (final file in files)
          EngineFile(
            index: file.id,
            name: file.displayName,
            size: file.length,
            isVideo: isVideoFileName(file.displayName),
          ),
      ],
      backendLabel: 'TorrServer',
    );
  }

  TorrentStats toStats() {
    double? progress;
    if (totalSize != null && totalSize! > 0 && loadedSize != null) {
      progress = (loadedSize! / totalSize!).clamp(0.0, 1.0);
    }
    return TorrentStats(
      peers: activePeers,
      seeds: connectedSeeders,
      downloadBytesPerSec: downloadSpeed?.round(),
      progress: progress,
      totalBytes: totalSize,
      downloadedBytes: loadedSize,
    );
  }
}

class TorrServerFile {
  TorrServerFile({required this.id, required this.path, required this.length});

  final int id;
  final String path;
  final int length;

  String get displayName {
    final clean = path.replaceAll('\\', '/');
    final slash = clean.lastIndexOf('/');
    return slash >= 0 ? clean.substring(slash + 1) : clean;
  }

  factory TorrServerFile.fromJson(Map<String, dynamic> json) =>
      TorrServerFile(
        id: _asInt(json['id']) ?? 0,
        path: json['path'] as String? ?? '',
        length: _asInt(json['length']) ?? 0,
      );
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

final _videoExtensions = <String>{
  'mp4',
  'm4v',
  'mkv',
  'avi',
  'mov',
  'wmv',
  'flv',
  'webm',
  'ts',
  'm2ts',
  'rmvb',
  'rm',
  '3gp',
  'mpg',
  'mpeg',
  'm4s',
};

bool isVideoFileName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return false;
  return _videoExtensions.contains(name.substring(dot + 1).toLowerCase());
}
