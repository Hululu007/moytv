import 'dart:io';

import 'native_torrent_engine.dart';
import 'torrent_magnet.dart';

enum TorrentEngineKind { torrServer, thunder, none }

String torrentEngineKindLabel(TorrentEngineKind kind) => switch (kind) {
  TorrentEngineKind.torrServer => 'TorrServer',
  TorrentEngineKind.thunder => '迅雷',
  TorrentEngineKind.none => '未接入',
};

enum TorrentEngineStatus { stopped, starting, running, unavailable, error }

class TorrentEngineUnavailable implements Exception {
  const TorrentEngineUnavailable(this.message, {this.whatIsNeeded = const []});

  final String message;
  final List<String> whatIsNeeded;

  @override
  String toString() => message;
}

class EngineFile {
  const EngineFile({
    required this.index,
    required this.name,
    required this.size,
    this.isVideo = false,
  });

  final int index;
  final String name;
  final int size;
  final bool isVideo;

  Map<String, dynamic> toJson() => {
    'index': index,
    'name': name,
    'size': size,
    'isVideo': isVideo,
  };

  factory EngineFile.fromJson(Map<String, dynamic> json) => EngineFile(
    index: json['index'] as int? ?? 0,
    name: json['name'] as String? ?? '',
    size: json['size'] as int? ?? 0,
    isVideo: json['isVideo'] == true,
  );
}

class EngineTorrent {
  const EngineTorrent({
    required this.infoHash,
    required this.name,
    this.size = 0,
    this.files = const [],
    this.backendLabel = '',
  });

  final String infoHash;
  final String name;
  final int size;
  final List<EngineFile> files;

  /// 实际承接的后端（TorrServer/迅雷），空表示未知。
  final String backendLabel;
}

class TorrentStats {
  const TorrentStats({
    this.peers,
    this.seeds,
    this.downloadBytesPerSec,
    this.uploadBytesPerSec,
    this.progress,
    this.totalBytes,
    this.downloadedBytes,
  });

  final int? peers;
  final int? seeds;
  final int? downloadBytesPerSec;
  final int? uploadBytesPerSec;
  final double? progress;
  final int? totalBytes;
  final int? downloadedBytes;

  static const TorrentStats empty = TorrentStats();

  bool get hasLiveData =>
      peers != null ||
      seeds != null ||
      downloadBytesPerSec != null ||
      uploadBytesPerSec != null ||
      progress != null ||
      totalBytes != null ||
      downloadedBytes != null;
}

enum TorrentSessionState {
  saved,
  resolvingMetadata,
  ready,
  streaming,
  stopped,
  failed,
}

String torrentSessionStateLabel(TorrentSessionState state) => switch (state) {
  TorrentSessionState.saved => '已保存',
  TorrentSessionState.resolvingMetadata => '正在解析',
  TorrentSessionState.ready => '可播放',
  TorrentSessionState.streaming => '播放中',
  TorrentSessionState.stopped => '已停止',
  TorrentSessionState.failed => '失败',
};

class TorrentSession {
  TorrentSession({
    required this.magnet,
    this.state = TorrentSessionState.saved,
    this.files = const [],
    this.stats = TorrentStats.empty,
    this.error = '',
    DateTime? addedAt,
    DateTime? updatedAt,
  }) : addedAt = addedAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final TorrentMagnet magnet;
  TorrentSessionState state;
  List<EngineFile> files;
  TorrentStats stats;
  String error;
  final DateTime addedAt;
  DateTime updatedAt;

  String get id => magnet.infoHash;
  String get name => magnet.nameOrHash;

  static const Map<TorrentSessionState, Set<TorrentSessionState>>
  allowedTransitions = {
    TorrentSessionState.saved: {TorrentSessionState.resolvingMetadata},
    TorrentSessionState.resolvingMetadata: {
      TorrentSessionState.ready,
      TorrentSessionState.failed,
      TorrentSessionState.stopped,
    },
    TorrentSessionState.ready: {
      TorrentSessionState.streaming,
      TorrentSessionState.stopped,
      TorrentSessionState.failed,
    },
    TorrentSessionState.streaming: {
      TorrentSessionState.stopped,
      TorrentSessionState.failed,
    },
    TorrentSessionState.stopped: {TorrentSessionState.resolvingMetadata},
    TorrentSessionState.failed: {TorrentSessionState.resolvingMetadata},
  };

  static const Set<TorrentSessionState> engineRequiredStates = {
    TorrentSessionState.resolvingMetadata,
    TorrentSessionState.streaming,
  };

  void transitionTo(
    TorrentSessionState next, {
    required bool engineAvailable,
  }) {
    final allowed = allowedTransitions[state] ?? const {};
    if (!allowed.contains(next)) {
      throw StateError(
        '种子会话不能从 ${torrentSessionStateLabel(state)} 到 ${torrentSessionStateLabel(next)}',
      );
    }
    if (engineRequiredStates.contains(next) && !engineAvailable) {
      throw const TorrentEngineUnavailable(
        '种子引擎未接入，无法解析或播放',
        whatIsNeeded: TorrentEngineFactory.missingPieces,
      );
    }
    state = next;
    updatedAt = DateTime.now();
    if (next == TorrentSessionState.failed && error.isEmpty) {
      error = '未知失败';
    }
    if (next != TorrentSessionState.failed) error = '';
  }

  void markFailed(String message) {
    state = TorrentSessionState.failed;
    error = message;
    updatedAt = DateTime.now();
  }

  Map<String, dynamic> toJson() => {
    'magnet': magnet.toJson(),
    'state': state.name,
    'addedAt': addedAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  factory TorrentSession.fromJson(Map<String, dynamic> json) {
    final stateName = json['state'] as String? ?? 'saved';
    final state = TorrentSessionState.values.firstWhere(
      (value) => value.name == stateName,
      orElse: () => TorrentSessionState.saved,
    );
    return TorrentSession(
      magnet: TorrentMagnet.fromJson(
        Map<String, dynamic>.from(json['magnet'] as Map? ?? const {}),
      ),
      state: state == TorrentSessionState.resolvingMetadata ||
              state == TorrentSessionState.streaming
          ? TorrentSessionState.saved
          : state,
      addedAt: DateTime.fromMillisecondsSinceEpoch(
        json['addedAt'] as int? ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        json['updatedAt'] as int? ?? 0,
      ),
    );
  }
}

abstract class TorrentEngine {
  TorrentEngineKind get kind;
  String get name;
  TorrentEngineStatus get status;
  Future<void> start();
  Future<void> stop();
  Future<EngineTorrent> addTorrent(TorrentMagnet magnet);
  Future<List<EngineFile>> files(String infoHash);
  Future<Uri> streamUrl(String infoHash, int fileIndex);
  Future<TorrentStats> stats(String infoHash);
}

class UnavailableTorrentEngine implements TorrentEngine {
  const UnavailableTorrentEngine([this.unavailable = _defaultUnavailable]);

  static const TorrentEngineUnavailable _defaultUnavailable =
      TorrentEngineUnavailable(
        '种子引擎未接入：TorrServer 可执行文件与插件桥未接、迅雷 SDK 未接',
        whatIsNeeded: TorrentEngineFactory.missingPieces,
      );

  final TorrentEngineUnavailable unavailable;

  @override
  TorrentEngineKind get kind => TorrentEngineKind.none;

  @override
  String get name => '未接入';

  @override
  TorrentEngineStatus get status => TorrentEngineStatus.unavailable;

  @override
  Future<void> start() async => throw unavailable;

  @override
  Future<void> stop() async {}

  @override
  Future<EngineTorrent> addTorrent(TorrentMagnet magnet) async =>
      throw unavailable;

  @override
  Future<List<EngineFile>> files(String infoHash) async => throw unavailable;

  @override
  Future<Uri> streamUrl(String infoHash, int fileIndex) async =>
      throw unavailable;

  @override
  Future<TorrentStats> stats(String infoHash) async => TorrentStats.empty;
}

class TorrentEngineFactory {
  const TorrentEngineFactory._();

  static const List<String> missingPieces = [
    'TorrServer：64M 的 Go 服务端可执行文件仅随安卓包下发，无法在当前平台以子进程启动',
    '迅雷 SDK：libxl_thunder_sdk.so 是安卓闭源商业 SDK，当前平台没有对应模块',
    '种子播放仅支持安卓：当前平台没有原生种子引擎',
  ];

  /// 安卓造原生引擎（TorrServer + 迅雷）；其它平台造诚实不可用引擎。
  static TorrentEngine create() {
    if (Platform.isAndroid) return NativeTorrentEngine();
    return const UnavailableTorrentEngine(
      TorrentEngineUnavailable(
        '种子播放仅支持安卓：当前平台没有原生种子引擎',
        whatIsNeeded: missingPieces,
      ),
    );
  }

  static bool get isEngineAvailable => Platform.isAndroid;
}
