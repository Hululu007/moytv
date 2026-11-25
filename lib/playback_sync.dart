import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'models.dart';

/// 观影记录同步协议（形态对齐 webhtv.playback.v1，代码自写）。
///
/// 本文件是协议记录层：协议记录 [PlaybackRecord]、删除墓碑
/// [PlaybackTombstone] 与 [WatchEntry] 之间的全部换算都集中在这里——
/// 秒(double) <-> 毫秒(int)、DateTime <-> epoch 毫秒、`Drama.id` 拆/合
/// siteKey + vodId。各调用点不许再自行换算。
const String kPlaybackSchema = 'webhtv.playback.v1';

/// 墓碑保留期：90 天（App 与服务端一致）。
const int kTombstoneRetentionMs = 90 * 24 * 60 * 60 * 1000;

/// 接口稳定身份：接口 URL 的 SHA256（小写 hex）。
String playbackConfigKeyOf(String configUrl) =>
    sha256.convert(utf8.encode(configUrl.trim())).toString();

/// 本地历史主键：`siteKey@@@vodId` 或带 cid 的 `siteKey@@@vodId@@@cid`。
String playbackHistoryKey(String siteKey, String vodId, {int? cid}) {
  final base = '$siteKey@@@$vodId';
  return cid == null ? base : '$base@@@$cid';
}

/// 生成事件幂等键（UUID v4 形态，失败重试必须复用同一个）。
String newPlaybackEventId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int i) => bytes[i].toRadixString(16).padLeft(2, '0');
  final b = StringBuffer();
  for (var i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) b.write('-');
    b.write(hex(i));
  }
  return b.toString();
}

int _intOf(Object? value, [int fallback = 0]) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

double _doubleOf(Object? value, [double fallback = 0]) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

bool _boolOf(Object? value, [bool fallback = false]) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value == 'true' || value == '1';
  return fallback;
}

String _strOf(Object? value, [String fallback = '']) =>
    value == null ? fallback : value.toString();

/// 协议记录：webhtv.playback.v1 的本地形态，字段与协议 1.1 表一一对应。
class PlaybackRecord {
  const PlaybackRecord({
    this.cid = 0,
    this.configKey = '',
    this.configName = '',
    required this.historyKey,
    required this.siteKey,
    this.siteName = '',
    required this.vodId,
    this.vodName = '',
    this.vodPic = '',
    this.flag = '',
    this.episodeName = '',
    this.episodeUrl = '',
    this.episodeIndex = 0,
    this.positionMs = 0,
    this.durationMs = 0,
    this.speed = 1.0,
    this.speedOverride = false,
    this.completed = false,
    this.updatedAt = 0,
  });

  final int cid;
  final String configKey;
  final String configName;
  final String historyKey;
  final String siteKey;
  final String siteName;
  final String vodId;
  final String vodName;
  final String vodPic;
  final String flag;
  final String episodeName;
  final String episodeUrl;
  final int episodeIndex;
  final int positionMs;
  final int durationMs;
  final double speed;

  /// true = 本片显式覆盖默认倍速（连显式 1.0 也保留）；false = 继承默认值。
  final bool speedOverride;
  final bool completed;

  /// epoch 毫秒，冲突裁决的唯一比较键。
  final int updatedAt;

  double get progress =>
      durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0;

  /// 去重键：由接口/站点/影片/剧集计算，不含 token。
  String get dedupeKey {
    final raw = [
      configKey,
      siteKey,
      vodId,
      flag,
      episodeUrl.isNotEmpty ? episodeUrl : episodeName,
    ].join('|');
    return sha256.convert(utf8.encode(raw)).toString();
  }

  /// 写入最小必填校验（协议 1.1）：siteKey / vodId / vodName /
  /// episodeName / positionMs > 0 / durationMs > 0。
  bool get isWritable =>
      siteKey.isNotEmpty &&
      vodId.isNotEmpty &&
      vodName.isNotEmpty &&
      episodeName.isNotEmpty &&
      positionMs > 0 &&
      durationMs > 0;

  PlaybackRecord copyWith({
    int? cid,
    String? configKey,
    String? configName,
    String? historyKey,
    String? siteKey,
    String? siteName,
    String? vodId,
    String? vodName,
    String? vodPic,
    String? flag,
    String? episodeName,
    String? episodeUrl,
    int? episodeIndex,
    int? positionMs,
    int? durationMs,
    double? speed,
    bool? speedOverride,
    bool? completed,
    int? updatedAt,
  }) => PlaybackRecord(
    cid: cid ?? this.cid,
    configKey: configKey ?? this.configKey,
    configName: configName ?? this.configName,
    historyKey: historyKey ?? this.historyKey,
    siteKey: siteKey ?? this.siteKey,
    siteName: siteName ?? this.siteName,
    vodId: vodId ?? this.vodId,
    vodName: vodName ?? this.vodName,
    vodPic: vodPic ?? this.vodPic,
    flag: flag ?? this.flag,
    episodeName: episodeName ?? this.episodeName,
    episodeUrl: episodeUrl ?? this.episodeUrl,
    episodeIndex: episodeIndex ?? this.episodeIndex,
    positionMs: positionMs ?? this.positionMs,
    durationMs: durationMs ?? this.durationMs,
    speed: speed ?? this.speed,
    speedOverride: speedOverride ?? this.speedOverride,
    completed: completed ?? this.completed,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'schema': kPlaybackSchema,
    'cid': cid,
    'configKey': configKey,
    'configName': configName,
    'historyKey': historyKey,
    'siteKey': siteKey,
    'siteName': siteName.isNotEmpty ? siteName : siteKey,
    'vodId': vodId,
    'vodName': vodName,
    'vodPic': vodPic,
    'flag': flag,
    'episodeName': episodeName,
    'episodeUrl': episodeUrl,
    'episodeIndex': episodeIndex,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'progress': progress,
    'speed': speed,
    'speedOverride': speedOverride,
    'completed': completed,
    'updatedAt': updatedAt,
    'dedupeKey': dedupeKey,
  };

  factory PlaybackRecord.fromJson(Map<String, dynamic> json) {
    final siteKey = _strOf(json['siteKey']);
    final vodId = _strOf(json['vodId']);
    var positionMs = _intOf(json['positionMs']);
    final durationMs = _intOf(json['durationMs']);
    // 写入侧可用 progress 辅助推导 positionMs。
    if (positionMs <= 0 && durationMs > 0 && json['progress'] != null) {
      positionMs = (_doubleOf(json['progress']) * durationMs).round();
    }
    final speed = _doubleOf(json['speed'], 1.0);
    // 旧请求缺 speedOverride 字段：非 1.0 按覆盖、1.0 按继承。
    final speedOverride = json.containsKey('speedOverride')
        ? _boolOf(json['speedOverride'])
        : speed != 1.0;
    final cid = _intOf(json['cid']);
    var configKey = _strOf(json['configKey']);
    if (configKey.isEmpty && _strOf(json['configUrl']).isNotEmpty) {
      configKey = playbackConfigKeyOf(_strOf(json['configUrl']));
    }
    final historyKey = _strOf(json['historyKey']).isNotEmpty
        ? _strOf(json['historyKey'])
        : playbackHistoryKey(siteKey, vodId, cid: cid == 0 ? null : cid);
    final completed =
        _boolOf(json['completed']) ||
        (durationMs > 1000 && positionMs >= durationMs - 1000);
    return PlaybackRecord(
      cid: cid,
      configKey: configKey,
      configName: _strOf(json['configName']),
      historyKey: historyKey,
      siteKey: siteKey,
      siteName: _strOf(json['siteName']),
      vodId: vodId,
      vodName: _strOf(json['vodName']),
      vodPic: _strOf(json['vodPic']),
      flag: _strOf(json['flag']),
      episodeName: _strOf(json['episodeName']),
      episodeUrl: _strOf(json['episodeUrl']),
      episodeIndex: _intOf(json['episodeIndex']),
      positionMs: positionMs,
      durationMs: durationMs,
      speed: speed,
      speedOverride: speedOverride,
      completed: completed,
      updatedAt: _intOf(json['updatedAt']),
    );
  }

  /// WatchEntry -> 协议记录：全部单位/主键换算集中于此。
  ///
  /// WatchEntry 只有集号没有集名/线路/单片倍速，缺失字段按协议缺省补：
  /// episodeName 用集号字符串、speed 1.0 且不覆盖。调用方有更准的
  /// 上下文（集名、线路、configKey 等）时经参数传入。
  factory PlaybackRecord.fromWatchEntry(
    WatchEntry entry, {
    int cid = 0,
    String configKey = '',
    String configName = '',
    String siteName = '',
    String flag = '',
    String episodeName = '',
    String episodeUrl = '',
    double speed = 1.0,
    bool speedOverride = false,
  }) {
    final drama = entry.drama;
    final siteKey = drama.source;
    // Drama.id 常是 'source:sourceId' 拼成：优先取 sourceId，
    // 为空时从 id 拆掉 'siteKey:' 前缀，再不行用整个 id。
    var vodId = drama.sourceId;
    if (vodId.isEmpty) {
      final prefix = '$siteKey:';
      vodId = drama.id.startsWith(prefix)
          ? drama.id.substring(prefix.length)
          : drama.id;
    }
    return PlaybackRecord(
      cid: cid,
      configKey: configKey,
      configName: configName,
      historyKey: playbackHistoryKey(
        siteKey,
        vodId,
        cid: cid == 0 ? null : cid,
      ),
      siteKey: siteKey,
      siteName: siteName,
      vodId: vodId,
      vodName: drama.title,
      vodPic: drama.cover,
      flag: flag,
      episodeName: episodeName.isNotEmpty
          ? episodeName
          : (entry.episode > 0 ? '${entry.episode}' : ''),
      episodeUrl: episodeUrl,
      episodeIndex: entry.episode,
      positionMs: (entry.position * 1000).round(),
      durationMs: (entry.duration * 1000).round(),
      speed: speed,
      speedOverride: speedOverride,
      completed: entry.finished,
      updatedAt: entry.updatedAt.millisecondsSinceEpoch,
    );
  }

  /// 协议记录 -> WatchEntry：毫秒转回 double 秒、epoch ms 转 DateTime、
  /// siteKey + vodId 合回 Drama.id（'source:sourceId' 形态）。
  WatchEntry toWatchEntry() {
    final episode = episodeIndex > 0
        ? episodeIndex
        : (int.tryParse(episodeName) ?? 0);
    return WatchEntry(
      drama: Drama(
        id: vodId.isEmpty ? siteKey : '$siteKey:$vodId',
        source: siteKey,
        sourceId: vodId,
        title: vodName.isNotEmpty ? vodName : '短剧',
        cover: vodPic,
      ),
      episode: episode,
      position: positionMs / 1000,
      duration: durationMs / 1000,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        updatedAt == 0 ? 1 : updatedAt,
      ),
    );
  }
}

/// 删除墓碑：删除不物理消失，靠 deletedAt 阻止旧进度复活，保留 90 天。
class PlaybackTombstone {
  const PlaybackTombstone({
    this.configKey = '',
    this.historyKey = '',
    this.siteKey = '',
    this.vodId = '',
    this.scope = 'item',
    required this.deletedAt,
  });

  final String configKey;
  final String historyKey;
  final String siteKey;
  final String vodId;

  /// item | site | all
  final String scope;

  /// epoch 毫秒。
  final int deletedAt;

  bool get expired =>
      DateTime.now().millisecondsSinceEpoch - deletedAt > kTombstoneRetentionMs;

  /// 这条墓碑是否罩得住该记录（同 configKey 分区内判定）。
  bool covers(PlaybackRecord record) {
    if (configKey.isNotEmpty &&
        record.configKey.isNotEmpty &&
        configKey != record.configKey) {
      return false;
    }
    return switch (scope) {
      'all' => true,
      'site' => siteKey.isNotEmpty && record.siteKey == siteKey,
      _ =>
        (historyKey.isNotEmpty && record.historyKey == historyKey) ||
            (siteKey.isNotEmpty &&
                record.siteKey == siteKey &&
                vodId.isNotEmpty &&
                record.vodId == vodId),
    };
  }

  Map<String, dynamic> toJson() => {
    'configKey': configKey,
    'historyKey': historyKey,
    'siteKey': siteKey,
    'vodId': vodId,
    'scope': scope,
    'deletedAt': deletedAt,
  };

  factory PlaybackTombstone.fromJson(Map<String, dynamic> json) =>
      PlaybackTombstone(
        configKey: _strOf(json['configKey']),
        historyKey: _strOf(json['historyKey']),
        siteKey: _strOf(json['siteKey']),
        vodId: _strOf(json['vodId']),
        scope: _strOf(json['scope'], 'item'),
        deletedAt: _intOf(json['deletedAt']),
      );
}

/// 一次合并的结果动作（与本机写入 API 的响应 action 同名）。
enum MergeAction { created, updated, skipped, deleted, failed }

class MergeOutcome {
  const MergeOutcome(this.action, {this.historyKey = '', this.message = ''});

  final MergeAction action;
  final String historyKey;
  final String message;

  String get actionName => action.name;
  bool get applied =>
      action == MergeAction.created ||
      action == MergeAction.updated ||
      action == MergeAction.deleted;
}
