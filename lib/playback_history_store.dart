import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'app_database.dart';
import 'playback_sync.dart';

/// 同步层本地存储后端：记录、墓碑、同步游标三类数据的落盘口。
/// 生产实现走 app.db 的新表（[SqlitePlaybackBackend]），测试用内存实现。
abstract class PlaybackStoreBackend {
  Future<List<PlaybackRecord>> loadRecords(String profile);
  Future<void> putRecord(String profile, PlaybackRecord record);
  Future<void> removeRecord(String profile, String historyKey);
  Future<List<PlaybackTombstone>> loadTombstones(String profile);
  Future<void> putTombstone(String profile, PlaybackTombstone tombstone);
  Future<void> removeTombstone(String profile, PlaybackTombstone tombstone);
  Future<int> loadCursor(String profile, String sourceKey, String configKey);
  Future<void> saveCursor(
    String profile,
    String sourceKey,
    String configKey,
    int sinceMs,
  );
}

/// 内存后端：联调测试与无盘环境用，语义与 SQLite 后端一致。
class InMemoryPlaybackBackend implements PlaybackStoreBackend {
  final Map<String, Map<String, PlaybackRecord>> _records = {};
  final Map<String, List<PlaybackTombstone>> _tombstones = {};
  final Map<String, int> _cursors = {};

  Map<String, PlaybackRecord> _space(String profile) =>
      _records.putIfAbsent(profile, () => {});

  @override
  Future<List<PlaybackRecord>> loadRecords(String profile) async =>
      _space(profile).values.toList();

  @override
  Future<void> putRecord(String profile, PlaybackRecord record) async {
    _space(profile)[record.historyKey] = record;
  }

  @override
  Future<void> removeRecord(String profile, String historyKey) async {
    _space(profile).remove(historyKey);
  }

  @override
  Future<List<PlaybackTombstone>> loadTombstones(String profile) async =>
      List.of(_tombstones.putIfAbsent(profile, () => []));

  @override
  Future<void> putTombstone(String profile, PlaybackTombstone tombstone) async {
    final list = _tombstones.putIfAbsent(profile, () => []);
    list.removeWhere(
      (t) =>
          t.configKey == tombstone.configKey &&
          t.scope == tombstone.scope &&
          t.historyKey == tombstone.historyKey &&
          t.siteKey == tombstone.siteKey &&
          t.vodId == tombstone.vodId,
    );
    list.add(tombstone);
  }

  @override
  Future<void> removeTombstone(
    String profile,
    PlaybackTombstone tombstone,
  ) async {
    _tombstones[profile]?.removeWhere(
      (t) =>
          t.configKey == tombstone.configKey &&
          t.scope == tombstone.scope &&
          t.historyKey == tombstone.historyKey &&
          t.deletedAt == tombstone.deletedAt,
    );
  }

  @override
  Future<int> loadCursor(
    String profile,
    String sourceKey,
    String configKey,
  ) async => _cursors['$profile|$sourceKey|$configKey'] ?? 0;

  @override
  Future<void> saveCursor(
    String profile,
    String sourceKey,
    String configKey,
    int sinceMs,
  ) async {
    _cursors['$profile|$sourceKey|$configKey'] = sinceMs;
  }
}

/// app.db 后端：表由 [AppDatabase] 建（playback_records /
/// playback_tombstones / playback_sync_state），记录整条存协议 JSON，
/// 同步层是这三张表的唯一出入境。
class SqlitePlaybackBackend implements PlaybackStoreBackend {
  SqlitePlaybackBackend([Future<Database> Function()? open])
    : _open = open ?? (() => AppDatabase.instance.database());

  final Future<Database> Function() _open;

  @override
  Future<List<PlaybackRecord>> loadRecords(String profile) async {
    final db = await _open();
    final rows = await db.query(
      'playback_records',
      columns: ['record_json'],
      where: 'profile = ?',
      whereArgs: [profile],
    );
    final records = <PlaybackRecord>[];
    for (final row in rows) {
      try {
        records.add(
          PlaybackRecord.fromJson(
            jsonDecode(row['record_json'] as String) as Map<String, dynamic>,
          ),
        );
      } catch (_) {}
    }
    return records;
  }

  @override
  Future<void> putRecord(String profile, PlaybackRecord record) async {
    final db = await _open();
    await db.insert('playback_records', {
      'profile': profile,
      'config_key': record.configKey,
      'history_key': record.historyKey,
      'record_json': jsonEncode(record.toJson()),
      'updated_at': record.updatedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> removeRecord(String profile, String historyKey) async {
    final db = await _open();
    await db.delete(
      'playback_records',
      where: 'profile = ? AND history_key = ?',
      whereArgs: [profile, historyKey],
    );
  }

  @override
  Future<List<PlaybackTombstone>> loadTombstones(String profile) async {
    final db = await _open();
    final rows = await db.query(
      'playback_tombstones',
      where: 'profile = ?',
      whereArgs: [profile],
    );
    return [
      for (final row in rows)
        PlaybackTombstone(
          configKey: row['config_key'] as String? ?? '',
          historyKey: row['history_key'] as String? ?? '',
          siteKey: row['site_key'] as String? ?? '',
          vodId: row['vod_id'] as String? ?? '',
          scope: row['scope'] as String? ?? 'item',
          deletedAt: (row['deleted_at'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  @override
  Future<void> putTombstone(String profile, PlaybackTombstone tombstone) async {
    final db = await _open();
    await db.insert('playback_tombstones', {
      'profile': profile,
      'config_key': tombstone.configKey,
      'history_key': tombstone.historyKey,
      'site_key': tombstone.siteKey,
      'vod_id': tombstone.vodId,
      'scope': tombstone.scope,
      'deleted_at': tombstone.deletedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> removeTombstone(
    String profile,
    PlaybackTombstone tombstone,
  ) async {
    final db = await _open();
    await db.delete(
      'playback_tombstones',
      where: 'profile = ? AND config_key = ? AND history_key = ? AND scope = ?',
      whereArgs: [
        profile,
        tombstone.configKey,
        tombstone.historyKey,
        tombstone.scope,
      ],
    );
  }

  @override
  Future<int> loadCursor(
    String profile,
    String sourceKey,
    String configKey,
  ) async {
    final db = await _open();
    final rows = await db.query(
      'playback_sync_state',
      columns: ['since_ms'],
      where: 'profile = ? AND source_key = ? AND config_key = ?',
      whereArgs: [profile, sourceKey, configKey],
    );
    if (rows.isEmpty) return 0;
    return (rows.first['since_ms'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<void> saveCursor(
    String profile,
    String sourceKey,
    String configKey,
    int sinceMs,
  ) async {
    final db = await _open();
    await db.insert('playback_sync_state', {
      'profile': profile,
      'source_key': sourceKey,
      'config_key': configKey,
      'since_ms': sinceMs,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

/// 本地记录读写：同步层只调这一组，不直接碰 LocalStore 内部 Map。
/// 合并规则完全照协议：只比 updatedAt / deletedAt；剧集匹配优先级
/// episodeUrl > flag+episodeName > episodeName；删除必落墓碑不物理消失
/// （记录行删除 + 墓碑行保留，同步语义上不是物理删）。
class PlaybackHistoryStore {
  PlaybackHistoryStore(this.backend, {this.profile = 'default'});

  final PlaybackStoreBackend backend;
  final String profile;

  PlaybackRecord? _current;

  /// 当前播放快照（只读 API 用）：由播放侧在起播/切集时更新，不落盘。
  void setCurrent(PlaybackRecord? record) => _current = record;
  Future<PlaybackRecord?> readCurrent() async => _current;

  Future<List<PlaybackRecord>> listRecords({
    String? siteKey,
    String? configKey,
    int limit = 1000,
  }) async {
    final all = await backend.loadRecords(profile);
    final filtered = all.where(
      (r) =>
          (siteKey == null || r.siteKey == siteKey) &&
          (configKey == null || r.configKey == configKey),
    );
    final sorted = filtered.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sorted.take(limit).toList();
  }

  Future<PlaybackRecord?> readRecord(String historyKey) async {
    final all = await backend.loadRecords(profile);
    for (final record in all) {
      if (record.historyKey == historyKey) return record;
    }
    return null;
  }

  Future<List<PlaybackTombstone>> listTombstones({int sinceMs = 0}) async {
    final all = await backend.loadTombstones(profile);
    return all.where((t) => t.deletedAt > sinceMs && !t.expired).toList();
  }

  Future<int> cursorOf(String sourceKey, String configKey) =>
      backend.loadCursor(profile, sourceKey, configKey);

  Future<void> saveCursor(String sourceKey, String configKey, int sinceMs) =>
      backend.saveCursor(profile, sourceKey, configKey, sinceMs);

  /// 找罩得住该记录的最新墓碑（deletedAt 最大的一条），没有返回 null。
  Future<PlaybackTombstone?> _coveringTombstone(PlaybackRecord record) async {
    PlaybackTombstone? best;
    for (final t in await backend.loadTombstones(profile)) {
      if (t.covers(record) && (best == null || t.deletedAt > best.deletedAt)) {
        best = t;
      }
    }
    return best;
  }

  /// 按剧集匹配优先级在同片候选里挑合并目标：
  /// episodeUrl 命中 > flag+episodeName 命中 > episodeName 命中 >
  /// historyKey 相同。都对不上返回 null（新建）。
  PlaybackRecord? _matchTarget(
    List<PlaybackRecord> all,
    PlaybackRecord incoming,
  ) {
    final sameFilm = all
        .where(
          (r) =>
              r.configKey == incoming.configKey &&
              r.siteKey == incoming.siteKey &&
              r.vodId == incoming.vodId,
        )
        .toList();
    if (incoming.episodeUrl.isNotEmpty) {
      for (final r in sameFilm) {
        if (r.episodeUrl.isNotEmpty && r.episodeUrl == incoming.episodeUrl) {
          return r;
        }
      }
    }
    for (final r in sameFilm) {
      if (r.flag == incoming.flag && r.episodeName == incoming.episodeName) {
        return r;
      }
    }
    for (final r in sameFilm) {
      if (r.episodeName == incoming.episodeName) return r;
    }
    for (final r in all) {
      if (r.historyKey == incoming.historyKey) return r;
    }
    return null;
  }

  /// 按协议合并规则写入一条进度：
  /// 旧于/等于墓碑 deletedAt 的进度跳过（防复活）；不新于本地的跳过；
  /// 倍速覆盖语义：speedOverride=false 清除单片覆盖回继承（落盘即
  /// speed 归 1.0 标记不覆盖），true 时连显式 1.0 也原样保留。
  Future<MergeOutcome> upsertProgress(PlaybackRecord record) async {
    if (!record.isWritable) {
      return MergeOutcome(
        MergeAction.failed,
        historyKey: record.historyKey,
        message: 'missing required fields',
      );
    }
    final tombstone = await _coveringTombstone(record);
    if (tombstone != null && record.updatedAt <= tombstone.deletedAt) {
      return MergeOutcome(
        MergeAction.skipped,
        historyKey: record.historyKey,
        message: 'blocked by tombstone',
      );
    }
    final all = await backend.loadRecords(profile);
    final target = _matchTarget(all, record);
    var normalized = record;
    if (!record.speedOverride) {
      normalized = record.copyWith(speed: 1.0, speedOverride: false);
    }
    if (target == null) {
      await backend.putRecord(profile, normalized);
      return MergeOutcome(
        MergeAction.created,
        historyKey: normalized.historyKey,
      );
    }
    if (record.updatedAt <= target.updatedAt) {
      return MergeOutcome(
        MergeAction.skipped,
        historyKey: target.historyKey,
        message: 'not newer than local',
      );
    }
    // 合并进命中的本地记录（保留其 historyKey/configKey 分区）。
    final merged = normalized.copyWith(
      historyKey: target.historyKey,
      configKey: target.configKey,
    );
    await backend.putRecord(profile, merged);
    return MergeOutcome(MergeAction.updated, historyKey: target.historyKey);
  }

  /// 批量写入：单条失败不拖垮整批，逐条回结果。
  Future<List<MergeOutcome>> upsertBatch(List<PlaybackRecord> records) async {
    final outcomes = <MergeOutcome>[];
    for (final record in records) {
      try {
        outcomes.add(await upsertProgress(record));
      } catch (e) {
        outcomes.add(
          MergeOutcome(
            MergeAction.failed,
            historyKey: record.historyKey,
            message: '$e',
          ),
        );
      }
    }
    return outcomes;
  }

  /// 删记录并落墓碑，返回实际删除条数。
  /// scope=all 必须显式 confirm=true，否则一条不删（防误清全量）。
  Future<int> deleteRecords({
    String? historyKey,
    String? siteKey,
    String? vodId,
    String configKey = '',
    String scope = 'item',
    bool confirm = false,
    required int deletedAt,
  }) async {
    if (scope == 'all' && !confirm) return 0;
    final all = await backend.loadRecords(profile);
    final targets = all.where((r) {
      if (configKey.isNotEmpty && r.configKey != configKey) return false;
      return switch (scope) {
        'all' => true,
        'site' => siteKey != null && r.siteKey == siteKey,
        _ =>
          (historyKey != null && r.historyKey == historyKey) ||
              (siteKey != null && r.siteKey == siteKey && r.vodId == vodId),
      };
    }).toList();
    // 全局/站点删除也要为每条实际删掉的底层记录各落一份 item 墓碑，
    // 再加一份范围墓碑罩住「本地还没有、远端可能推回来」的同范围记录。
    for (final record in targets) {
      await backend.removeRecord(profile, record.historyKey);
      await backend.putTombstone(
        profile,
        PlaybackTombstone(
          configKey: record.configKey,
          historyKey: record.historyKey,
          siteKey: record.siteKey,
          vodId: record.vodId,
          scope: 'item',
          deletedAt: deletedAt,
        ),
      );
    }
    if (scope != 'item' || targets.isEmpty) {
      await backend.putTombstone(
        profile,
        PlaybackTombstone(
          configKey: configKey,
          historyKey: scope == 'item' ? (historyKey ?? '') : '',
          siteKey: siteKey ?? '',
          vodId: vodId ?? '',
          scope: scope,
          deletedAt: deletedAt,
        ),
      );
    }
    if (_current != null &&
        targets.any((r) => r.historyKey == _current!.historyKey)) {
      _current = null;
    }
    return targets.length;
  }

  /// 收到远端墓碑：删掉被罩住且不新于墓碑的本地记录，并回收墓碑本身。
  /// 返回实际删除条数。新于墓碑的本地记录保留（允许重建语义）。
  Future<int> applyTombstone(PlaybackTombstone tombstone) async {
    await backend.putTombstone(profile, tombstone);
    var removed = 0;
    for (final record in await backend.loadRecords(profile)) {
      if (tombstone.covers(record) && record.updatedAt <= tombstone.deletedAt) {
        await backend.removeRecord(profile, record.historyKey);
        removed++;
      }
    }
    return removed;
  }

  /// 清理过期墓碑（超过 90 天），返回清理条数。
  Future<int> pruneExpiredTombstones() async {
    var pruned = 0;
    for (final t in await backend.loadTombstones(profile)) {
      if (t.expired) {
        await backend.removeTombstone(profile, t);
        pruned++;
      }
    }
    return pruned;
  }
}

/// 本机写入/只读 API 的处理逻辑（端点形态对齐协议 1.2(a)(b)）。
/// 只做逻辑与门控，不自起 HTTP 服务——宿主把请求转进来即可，
/// 这样联调测试可进程内直调。返回 (状态码, JSON 体)。
class PlaybackLocalApi {
  PlaybackLocalApi(
    this.store, {
    required this.syncEnabled,
    required this.allowModify,
    this.knownConfigKeys = const {},
    this.currentConfigKey = '',
  });

  final PlaybackHistoryStore store;

  /// 总开关。
  final bool syncEnabled;

  /// 「允许本机 API 修改」子开关：关掉只读仍可用、写全部拒绝。
  final bool allowModify;

  /// 本机已知的 configKey -> cid 映射（定落库空间用）。
  final Map<String, int> knownConfigKeys;
  final String currentConfigKey;

  Future<(int, Map<String, dynamic>)> current({String? siteKey}) async {
    if (!syncEnabled) return (404, {'success': false, 'message': 'disabled'});
    if (siteKey == null || siteKey.isEmpty) {
      return (400, {'success': false, 'message': 'siteKey required'});
    }
    final record = await store.readCurrent();
    if (record == null || record.siteKey != siteKey) {
      return (404, {'success': false, 'message': 'no current playback'});
    }
    // 安全快照：不含真实播放 URL / headers / 配置地址 / 设备标识。
    final json = record.toJson()
      ..remove('episodeUrl')
      ..remove('dedupeKey');
    return (200, {'success': true, 'item': json});
  }

  /// configKey 映射不到本机接口时返回 null（调用方回 skipped）。
  PlaybackRecord? _mapIncoming(Map<String, dynamic> json) {
    final record = PlaybackRecord.fromJson(json);
    if (record.configKey.isNotEmpty &&
        knownConfigKeys.isNotEmpty &&
        !knownConfigKeys.containsKey(record.configKey)) {
      return null;
    }
    final cid = record.configKey.isNotEmpty
        ? (knownConfigKeys[record.configKey] ?? record.cid)
        : record.cid;
    return record.copyWith(cid: cid);
  }

  Map<String, dynamic> _outcomeJson(MergeOutcome outcome, {int? affected}) => {
    'success': outcome.action != MergeAction.failed,
    'action': outcome.actionName,
    'message': outcome.message,
    'historyKey': outcome.historyKey,
    'affected': ?affected,
  };

  Future<(int, Map<String, dynamic>)> progress(
    Map<String, dynamic> body,
  ) async {
    if (!syncEnabled || !allowModify) {
      return (403, {'success': false, 'message': 'modify not allowed'});
    }
    final mapped = _mapIncoming(body);
    if (mapped == null) {
      return (
        200,
        {
          'success': true,
          'action': 'skipped',
          'message': 'unknown configKey',
          'historyKey': _strKey(body),
        },
      );
    }
    final outcome = await store.upsertProgress(mapped);
    return (
      outcome.action == MergeAction.failed ? 400 : 200,
      _outcomeJson(outcome),
    );
  }

  Future<(int, Map<String, dynamic>)> progressBatch(Object? body) async {
    if (!syncEnabled || !allowModify) {
      return (403, {'success': false, 'message': 'modify not allowed'});
    }
    final items = _extractItems(body);
    final records = <PlaybackRecord>[];
    var failed = 0;
    for (final item in items) {
      final mapped = _mapIncoming(item);
      if (mapped == null) {
        failed++;
      } else {
        records.add(mapped);
      }
    }
    final outcomes = await store.upsertBatch(records);
    var created = 0, updated = 0, skipped = 0;
    for (final o in outcomes) {
      switch (o.action) {
        case MergeAction.created:
          created++;
        case MergeAction.updated:
          updated++;
        case MergeAction.skipped:
          skipped++;
        case MergeAction.failed:
          failed++;
        case MergeAction.deleted:
          break;
      }
    }
    return (
      200,
      {
        'success': true,
        'total': items.length,
        'applied': created + updated,
        'created': created,
        'updated': updated,
        'deleted': 0,
        'skipped': skipped,
        'failed': failed,
        'items': [for (final o in outcomes) _outcomeJson(o)],
      },
    );
  }

  Future<(int, Map<String, dynamic>)> delete(Map<String, dynamic> body) async {
    if (!syncEnabled || !allowModify) {
      return (403, {'success': false, 'message': 'modify not allowed'});
    }
    final scope = body['scope']?.toString() ?? 'item';
    final deletedAt =
        (body['deletedAt'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    final affected = await store.deleteRecords(
      historyKey: body['historyKey']?.toString(),
      siteKey: body['siteKey']?.toString(),
      vodId: body['vodId']?.toString(),
      configKey: body['configKey']?.toString() ?? '',
      scope: scope,
      confirm: scope == 'all',
      deletedAt: deletedAt,
    );
    return (
      200,
      {
        'success': true,
        'action': 'deleted',
        'affected': affected,
        'historyKey': body['historyKey']?.toString() ?? '',
      },
    );
  }

  String _strKey(Map<String, dynamic> body) =>
      body['historyKey']?.toString() ?? '';

  List<Map<String, dynamic>> _extractItems(Object? body) {
    Object? list;
    if (body is List) {
      list = body;
    } else if (body is Map) {
      list = body['items'] ?? body['records'] ?? body['data'] ?? body['list'];
    }
    if (list is! List) return const [];
    return [
      for (final item in list)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }
}
