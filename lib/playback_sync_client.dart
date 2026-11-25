import 'dart:convert';
import 'dart:io';

import 'playback_history_store.dart';
import 'playback_sync.dart';

/// 同步配置：推拉共用同一地址与同一 token（协议「同一地址承接」）。
/// token 只进请求头，不落记录、不进主键/dedupeKey。
class PlaybackSyncConfig {
  const PlaybackSyncConfig({
    required this.url,
    this.token = '',
    this.configKey = '',
    this.configName = '',
    this.siteKeys = const {},
    this.syncOnStartup = false,
    this.intervalMinutes = 0,
    this.maxItems = 200,
    this.webhookPreset = 'standard',
    this.appVersion = '',
    this.client = 'mobile',
    this.knownConfigKeys = const {},
  });

  final String url;
  final String token;

  /// 本机当前接口的 configKey（拉取请求头与分区判定用）。
  final String configKey;
  final String configName;

  /// 空 = 不限站点。
  final Set<String> siteKeys;
  final bool syncOnStartup;

  /// 0 = 不周期拉。
  final int intervalMinutes;

  /// 单轮拉取上限（协议上限 1000）；返回条数达上限时不推进游标。
  final int maxItems;

  /// basic | standard | full（匿名为同步禁用，不在此列）。
  final String webhookPreset;
  final String appVersion;
  final String client;

  /// 本机能映射的 configKey 集合（值无意义，只用键）：
  /// 拉到的带 configKey 且不在此集合内的项跳过并计数；
  /// 集合为空表示不做映射过滤（兼容旧服务端/单接口场景）。
  final Map<String, int> knownConfigKeys;

  int get effectiveMaxItems =>
      maxItems <= 0 ? 200 : (maxItems > 1000 ? 1000 : maxItems);

  /// 拉取游标的来源键：同一地址即同一来源。
  String get sourceKey => url;
}

/// HTTP 传输层抽象：联调测试可打桩，生产用 [HttpPlaybackTransport]。
abstract class PlaybackTransport {
  Future<(int, String)> post(
    String url, {
    required Map<String, String> headers,
    required String body,
  });
  Future<(int, String)> get(String url, {required Map<String, String> headers});
}

class HttpPlaybackTransport implements PlaybackTransport {
  HttpPlaybackTransport({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;

  @override
  Future<(int, String)> post(
    String url, {
    required Map<String, String> headers,
    required String body,
  }) async {
    final client = _clientFactory();
    try {
      final request = await client.postUrl(Uri.parse(url));
      headers.forEach((k, v) => request.headers.set(k, v));
      // body 是 UTF-8 JSON（含中文名）：write() 默认 latin1 会抛错，必须走字节。
      request.add(utf8.encode(body));
      final response = await request.close();
      return (response.statusCode, await utf8.decoder.bind(response).join());
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<(int, String)> get(
    String url, {
    required Map<String, String> headers,
  }) async {
    final client = _clientFactory();
    try {
      final request = await client.getUrl(Uri.parse(url));
      headers.forEach((k, v) => request.headers.set(k, v));
      final response = await request.close();
      return (response.statusCode, await utf8.decoder.bind(response).join());
    } finally {
      client.close(force: true);
    }
  }
}

class SyncReport {
  const SyncReport({
    this.received = 0,
    this.created = 0,
    this.updated = 0,
    this.skipped = 0,
    this.deleted = 0,
    this.unmapped = 0,
    this.cursorAdvanced = false,
    this.since = 0,
    this.nextSince = 0,
  });

  final int received;
  final int created;
  final int updated;
  final int skipped;
  final int deleted;

  /// configKey 映射不到本机接口被跳过的条数。
  final int unmapped;
  final bool cursorAdvanced;
  final int since;
  final int nextSince;
}

class _PendingEvent {
  _PendingEvent(this.body, {required this.isDelete, required this.dedupeKey});

  final Map<String, dynamic> body;
  final bool isDelete;
  final String dedupeKey;
}

/// 同步客户端骨架：推（Webhook 上报）与拉（增量合并）共用一个类。
/// 推失败进本地待发队列：按 dedupeKey 只留最新一条进度事件，
/// 删除事件优先级高、永不被进度事件挤出（队列上限只裁进度事件）。
class PlaybackSyncClient {
  PlaybackSyncClient(
    this.store, {
    required this.config,
    PlaybackTransport? transport,
    this.maxAttempts = 2,
    this.pendingLimit = 100,
    String Function()? eventIdFactory,
  }) : transport = transport ?? HttpPlaybackTransport(),
       _eventIdFactory = eventIdFactory ?? newPlaybackEventId;

  final PlaybackHistoryStore store;
  final PlaybackSyncConfig config;
  final PlaybackTransport transport;

  /// 单次推送尝试次数（含首次）；重试复用同一 eventId 保证幂等。
  final int maxAttempts;
  final int pendingLimit;
  final String Function() _eventIdFactory;

  final List<_PendingEvent> _pending = [];
  int get pendingCount => _pending.length;

  Map<String, String> _pushHeaders(
    Map<String, dynamic> body, {
    required String eventId,
  }) => {
    'Content-Type': 'application/json',
    'X-WebHTV-Timestamp': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    if (config.token.isNotEmpty) 'X-WebHTV-Token': config.token,
    'X-WebHTV-Webhook-Id': eventId,
    'X-WebHTV-Dedupe-Key': body['dedupeKey']?.toString() ?? '',
    'X-WebHTV-Config-Key': body['configKey']?.toString() ?? '',
    if (config.configName.isNotEmpty) 'X-WebHTV-Config-Name': config.configName,
    'Idempotency-Key': eventId,
  };

  /// 按预设组装事件体：基础=核心定位+进度；标准加 appVersion/client；
  /// 完整再加 episodeUrl/episodeIndex。删除事件不带进度字段。
  Map<String, dynamic> buildEventBody(
    PlaybackRecord record, {
    required String event,
    required String eventId,
    String sessionId = '',
  }) {
    final body = <String, dynamic>{
      'schema': kPlaybackSchema,
      'event': event,
      'eventId': eventId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      if (sessionId.isNotEmpty) 'sessionId': sessionId,
      'dedupeKey': record.dedupeKey,
      'cid': record.cid,
      'configKey': record.configKey,
      'configName': record.configName,
      'historyKey': record.historyKey,
      'siteKey': record.siteKey,
      'siteName': record.siteName.isNotEmpty ? record.siteName : record.siteKey,
      'vodId': record.vodId,
      'vodName': record.vodName,
      'vodPic': record.vodPic,
      'flag': record.flag,
      'episodeName': record.episodeName,
      'positionMs': record.positionMs,
      'durationMs': record.durationMs,
      'progress': record.progress,
      'speed': record.speed,
      'speedOverride': record.speedOverride,
      'completed': record.completed,
      'updatedAt': record.updatedAt,
    };
    if (config.webhookPreset == 'standard' || config.webhookPreset == 'full') {
      body['appVersion'] = config.appVersion;
      body['client'] = config.client;
    }
    if (config.webhookPreset == 'full') {
      body['episodeUrl'] = record.episodeUrl;
      body['episodeIndex'] = record.episodeIndex;
    }
    return body;
  }

  Map<String, dynamic> buildDeleteBody(
    PlaybackTombstone tombstone, {
    required String eventId,
  }) => {
    'schema': kPlaybackSchema,
    'event': 'playback.deleted',
    'eventId': eventId,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    'scope': tombstone.scope,
    'deletedAt': tombstone.deletedAt,
    'configKey': tombstone.configKey,
    'historyKey': tombstone.historyKey,
    'siteKey': tombstone.siteKey,
    'vodId': tombstone.vodId,
    'dedupeKey': tombstone.historyKey.isNotEmpty
        ? tombstone.historyKey
        : '${tombstone.siteKey}@@@${tombstone.vodId}',
  };

  Future<bool> _send(Map<String, dynamic> body, String eventId) async {
    final headers = _pushHeaders(body, eventId: eventId);
    final payload = jsonEncode(body);
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final (status, _) = await transport.post(
          config.url,
          headers: headers,
          body: payload,
        );
        if (status >= 200 && status < 300) return true;
        if (status >= 400 && status < 500) return false;
      } catch (_) {
        // 网络失败同样走重试/入队。
      }
    }
    return false;
  }

  void _enqueue(_PendingEvent event) {
    if (!event.isDelete) {
      _pending.removeWhere(
        (p) => !p.isDelete && p.dedupeKey == event.dedupeKey,
      );
    }
    _pending.add(event);
    // 只裁进度事件，删除事件永不挤出。
    while (_pending.where((p) => !p.isDelete).length > pendingLimit) {
      final idx = _pending.indexWhere((p) => !p.isDelete);
      if (idx < 0) break;
      _pending.removeAt(idx);
    }
  }

  /// 推进度/完播事件。event: 'playback.progress' | 'playback.ended'。
  /// 返回是否直达服务端；失败入待发队列（不阻塞播放）。
  Future<bool> pushProgress(
    PlaybackRecord record, {
    required String event,
    String sessionId = '',
  }) async {
    final eventId = _eventIdFactory();
    final body = buildEventBody(
      record,
      event: event,
      eventId: eventId,
      sessionId: sessionId,
    );
    if (await _send(body, eventId)) return true;
    _enqueue(_PendingEvent(body, isDelete: false, dedupeKey: record.dedupeKey));
    return false;
  }

  /// 推删除事件（单删/站点删/清空都走这里，带 scope + deletedAt）。
  Future<bool> pushDeleted(PlaybackTombstone tombstone) async {
    final eventId = _eventIdFactory();
    final body = buildDeleteBody(tombstone, eventId: eventId);
    if (await _send(body, eventId)) return true;
    _enqueue(
      _PendingEvent(
        body,
        isDelete: true,
        dedupeKey: body['dedupeKey'] as String,
      ),
    );
    return false;
  }

  /// 补发待发队列（删除事件优先），返回成功条数。
  Future<int> flushPending() async {
    var sent = 0;
    final ordered = [
      ..._pending.where((p) => p.isDelete),
      ..._pending.where((p) => !p.isDelete),
    ];
    for (final event in ordered) {
      final eventId = event.body['eventId']?.toString() ?? '';
      if (await _send(event.body, eventId)) {
        _pending.remove(event);
        sent++;
      }
    }
    return sent;
  }

  /// 拉增量并合并：带 Since 游标；返回条数达 maxItems 不推进游标，
  /// 防未处理变更丢失。拉到的进度只写历史、永不 seek 正在播的条目。
  Future<SyncReport> pullAndMerge() async {
    final since = await store.cursorOf(config.sourceKey, config.configKey);
    final headers = <String, String>{
      'Accept': 'application/json',
      if (config.token.isNotEmpty) 'X-WebHTV-Token': config.token,
      'X-WebHTV-Config-Key': config.configKey,
      if (config.configName.isNotEmpty)
        'X-WebHTV-Config-Name': config.configName,
      if (since > 0) 'X-WebHTV-Since': '$since',
      'X-WebHTV-Limit': '${config.effectiveMaxItems}',
    };
    final (status, raw) = await transport.get(config.url, headers: headers);
    if (status < 200 || status >= 300) {
      return SyncReport(since: since, nextSince: since);
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return SyncReport(since: since, nextSince: since);
    final root = Map<String, dynamic>.from(decoded);
    final items = _extractRecords(root);
    final tombstones = _extractTombstones(root);
    final nextSince = (root['nextSince'] as num?)?.toInt() ?? since;

    var created = 0, updated = 0, skipped = 0, deleted = 0, unmapped = 0;
    // 先落墓碑再合并进度：同批里「先删后到」的旧进度也挡得住。
    for (final tombstone in tombstones) {
      deleted += await store.applyTombstone(tombstone);
    }
    for (final record in items) {
      if (config.siteKeys.isNotEmpty &&
          !config.siteKeys.contains(record.siteKey)) {
        skipped++;
        continue;
      }
      if (record.configKey.isNotEmpty &&
          config.knownConfigKeys.isNotEmpty &&
          !config.knownConfigKeys.containsKey(record.configKey)) {
        unmapped++;
        continue;
      }
      final outcome = await store.upsertProgress(record);
      switch (outcome.action) {
        case MergeAction.created:
          created++;
        case MergeAction.updated:
          updated++;
        default:
          skipped++;
      }
    }
    final received = items.length + tombstones.length;
    final advance = received < config.effectiveMaxItems && nextSince > since;
    if (advance) {
      await store.saveCursor(config.sourceKey, config.configKey, nextSince);
    }
    return SyncReport(
      received: received,
      created: created,
      updated: updated,
      skipped: skipped,
      deleted: deleted,
      unmapped: unmapped,
      cursorAdvanced: advance,
      since: since,
      nextSince: advance ? nextSince : since,
    );
  }

  List<PlaybackRecord> _extractRecords(Map<String, dynamic> root) {
    final rawItems = root['items'] ?? root['changes'] ?? root['records'];
    if (rawItems is! List) return const [];
    final records = <PlaybackRecord>[];
    for (final item in rawItems) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final isDelete =
          map['action'] == 'delete' ||
          map['deleted'] == true ||
          map['event'] == 'playback.deleted';
      if (isDelete) continue; // 删除形态的项在 _extractTombstones 里处理。
      records.add(PlaybackRecord.fromJson(map));
    }
    return records;
  }

  List<PlaybackTombstone> _extractTombstones(Map<String, dynamic> root) {
    final tombstones = <PlaybackTombstone>[];
    void collect(Object? raw) {
      if (raw is! List) return;
      for (final item in raw) {
        if (item is Map) {
          tombstones.add(
            PlaybackTombstone.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }

    collect(root['deleted']);
    collect(root['deletions']);
    collect(root['tombstones']);
    collect(root['removed']);
    collect(root['deletedItems']);
    // 混在 items/changes 里以删除形态标记的项。
    for (final key in ['items', 'changes']) {
      final raw = root[key];
      if (raw is! List) continue;
      for (final item in raw) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        if (map['action'] == 'delete' ||
            map['deleted'] == true ||
            map['event'] == 'playback.deleted') {
          tombstones.add(PlaybackTombstone.fromJson(map));
        }
      }
    }
    return tombstones;
  }
}
