import 'dart:async';

import 'torrent_bridge.dart';
import 'torrent_engine.dart';
import 'torrent_magnet.dart';
import 'torrserver_client.dart';

typedef TorrServerClientBuilder =
    TorrServerClient Function(String baseUrl);

/// 安卓原生种子引擎：TorrServer（P2P 边下边播）为主，迅雷为辅。
///
/// 路由规则：
/// - magnet / .torrent：先走 TorrServer；服务起不来或加种失败时回落迅雷。
/// - thunder:// / ed2k://：只能走迅雷（TorrServer 不认这两种协议）。
/// - 两个后端都不可用时抛 TorrentEngineUnavailable，带真实原因，绝不冒充可用。
class NativeTorrentEngine implements TorrentEngine {
  NativeTorrentEngine({
    TorrentBridge? bridge,
    TorrServerClientBuilder? clientBuilder,
    this.metadataTimeout = const Duration(seconds: 60),
  }) : _bridge = bridge ?? TorrentBridge(),
       _clientBuilder =
           clientBuilder ?? ((baseUrl) => TorrServerClient(baseUrl: baseUrl));

  final TorrentBridge _bridge;
  final TorrServerClientBuilder _clientBuilder;
  final Duration metadataTimeout;

  TorrentEngineStatus _status = TorrentEngineStatus.stopped;
  TorrServerClient? _serverClient;
  String _serverError = '';
  bool _thunderAvailable = false;
  String _thunderError = '';
  bool _started = false;

  final Map<String, String> _backends = {};
  final Map<String, String> _thunderTaskKeys = {};
  final Map<String, ThunderResolved> _thunderResolved = {};

  @override
  TorrentEngineKind get kind => TorrentEngineKind.torrServer;

  @override
  String get name => 'TorrServer + 迅雷';

  @override
  TorrentEngineStatus get status => _status;

  /// 上次启动时 TorrServer 失败的真实原因（空表示服务正常）。
  String get serverError => _serverError;

  bool get thunderAvailable => _thunderAvailable;

  String get thunderError => _thunderError;

  @override
  Future<void> start() async {
    if (_started && _status == TorrentEngineStatus.running) return;
    _status = TorrentEngineStatus.starting;
    _serverError = '';
    _thunderError = '';
    var serverUp = false;
    try {
      final status = await _bridge.torrServerStatus();
      final running = status['running'] == true;
      final port = (status['port'] as num?)?.toInt() ?? 8090;
      if (running) {
        _serverClient = _clientBuilder('http://127.0.0.1:$port');
        serverUp = true;
      } else {
        final started = await _bridge.torrServerStart(port: port);
        final startedPort = (started['port'] as num?)?.toInt() ?? port;
        if (started['running'] == true) {
          _serverClient = _clientBuilder('http://127.0.0.1:$startedPort');
          serverUp = true;
        } else {
          _serverError = started['error'] as String? ?? 'TorrServer 启动失败';
        }
      }
    } on TorrentEngineUnavailable catch (error) {
      _serverError = error.message;
    }
    try {
      final thunder = await _bridge.thunderStatus();
      _thunderAvailable = thunder['available'] == true;
      if (!_thunderAvailable) {
        _thunderError = thunder['reason'] as String? ?? '迅雷引擎不可用';
      }
    } on TorrentEngineUnavailable catch (error) {
      _thunderAvailable = false;
      _thunderError = error.message;
    }
    if (!serverUp && !_thunderAvailable) {
      _status = TorrentEngineStatus.error;
      throw TorrentEngineUnavailable(
        '种子引擎都不可用：TorrServer（$_serverError）、迅雷（$_thunderError）',
      );
    }
    _started = true;
    _status = TorrentEngineStatus.running;
  }

  @override
  Future<void> stop() async {
    for (final taskKey in _thunderTaskKeys.values) {
      try {
        await _bridge.thunderStop(taskKey: taskKey);
      } catch (_) {}
    }
    _thunderTaskKeys.clear();
    _thunderResolved.clear();
    _backends.clear();
    try {
      await _bridge.torrServerStop();
    } catch (_) {}
    _serverClient?.close();
    _serverClient = null;
    _started = false;
    _status = TorrentEngineStatus.stopped;
  }

  Future<void> _ensureStarted() async {
    if (!_started) await start();
  }

  @override
  Future<EngineTorrent> addTorrent(TorrentMagnet magnet) async {
    await _ensureStarted();
    final linkKind = torrentLinkKind(magnet.uri);
    if (linkKind == TorrentLinkKind.thunder ||
        linkKind == TorrentLinkKind.ed2k) {
      return _addViaThunder(magnet);
    }
    if (_serverClient != null) {
      try {
        return await _addViaTorrServer(magnet);
      } on TorrentEngineUnavailable catch (error) {
        if (!_thunderAvailable) rethrow;
        _serverError = error.message;
        return _addViaThunder(magnet);
      }
    }
    if (!_thunderAvailable) {
      throw TorrentEngineUnavailable(
        'TorrServer 不可用（$_serverError），迅雷也不可用（$_thunderError）',
      );
    }
    return _addViaThunder(magnet);
  }

  Future<EngineTorrent> _addViaTorrServer(TorrentMagnet magnet) async {
    final client = _serverClient;
    if (client == null) {
      throw const TorrentEngineUnavailable('TorrServer 客户端未初始化');
    }
    final added = await client.add(
      link: magnet.uri,
      title: magnet.displayName,
    );
    final hash = added.hash.isNotEmpty ? added.hash : magnet.infoHash;
    if (added.hasMetadata) {
      _backends[hash] = 'torrserver';
      return added.toEngineTorrent();
    }
    final deadline = DateTime.now().add(metadataTimeout);
    TorrServerTorrent current = added;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 1));
      current = await client.get(hash);
      if (current.hasMetadata) {
        _backends[hash] = 'torrserver';
        return current.toEngineTorrent();
      }
      if (current.stat == 4) {
        throw const TorrentEngineUnavailable('TorrServer 已关闭该种子');
      }
    }
    throw const TorrentEngineUnavailable(
      '种子元数据还没取到：可能没有 Peer 或 Tracker 不可达，请稍后重试',
    );
  }

  Future<EngineTorrent> _addViaThunder(TorrentMagnet magnet) async {
    final key = magnet.infoHash.isNotEmpty
        ? magnet.infoHash
        : magnet.uri.hashCode.toRadixString(16);
    final resolved = ThunderResolved.fromJson(
      await _bridge.thunderResolve(url: magnet.uri, key: key),
    );
    final hash = resolved.infoHash.isNotEmpty
        ? resolved.infoHash
        : magnet.infoHash;
    _backends[hash] = 'thunder';
    _thunderTaskKeys[hash] = resolved.taskKey;
    _thunderResolved[hash] = resolved;
    return resolved.toEngineTorrent();
  }

  @override
  Future<List<EngineFile>> files(String infoHash) async {
    await _ensureStarted();
    final backend = _backends[infoHash];
    if (backend == 'thunder') {
      final resolved = _thunderResolved[infoHash];
      if (resolved == null) {
        throw StateError('该种子需先解析才能取文件列表');
      }
      return resolved.files;
    }
    final client = _serverClient;
    if (client == null) {
      throw const TorrentEngineUnavailable('TorrServer 客户端未初始化');
    }
    final current = await client.get(infoHash);
    return current.toEngineTorrent().files;
  }

  @override
  Future<Uri> streamUrl(String infoHash, int fileIndex) async {
    await _ensureStarted();
    final backend = _backends[infoHash];
    if (backend == 'thunder') {
      final taskKey = _thunderTaskKeys[infoHash];
      if (taskKey == null || taskKey.isEmpty) {
        throw StateError('该种子需先解析才能取流');
      }
      final url = await _bridge.thunderStreamUrl(
        taskKey: taskKey,
        index: fileIndex,
      );
      return Uri.parse(url);
    }
    final client = _serverClient;
    if (client == null) {
      throw const TorrentEngineUnavailable('TorrServer 客户端未初始化');
    }
    return client.streamUri(infoHash, fileIndex);
  }

  @override
  Future<TorrentStats> stats(String infoHash) async {
    final backend = _backends[infoHash];
    if (backend == 'thunder') {
      final taskKey = _thunderTaskKeys[infoHash];
      if (taskKey == null || taskKey.isEmpty) return TorrentStats.empty;
      try {
        final raw = await _bridge.thunderStats(taskKey: taskKey);
        final total = (raw['total'] as num?)?.toInt();
        final downloaded = (raw['downloaded'] as num?)?.toInt();
        double? progress;
        if (total != null && total > 0 && downloaded != null) {
          progress = (downloaded / total).clamp(0.0, 1.0);
        }
        return TorrentStats(
          downloadBytesPerSec: (raw['downloadSpeed'] as num?)?.toInt(),
          progress: progress,
          totalBytes: total,
          downloadedBytes: downloaded,
        );
      } catch (_) {
        return TorrentStats.empty;
      }
    }
    final client = _serverClient;
    if (client == null) return TorrentStats.empty;
    try {
      final current = await client.get(infoHash);
      return current.toStats();
    } catch (_) {
      return TorrentStats.empty;
    }
  }
}
