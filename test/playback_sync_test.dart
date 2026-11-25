import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/models.dart';
import 'package:moyi/playback_history_store.dart';
import 'package:moyi/playback_sync.dart';
import 'package:moyi/playback_sync_client.dart';

/// 进程内假服务端：同一地址 POST 收事件 / GET 回增量，
/// 按 eventId 幂等去重，请求头与 body 全量留痕供断言。
class FakeSyncServer {
  HttpServer? _server;
  final List<Map<String, dynamic>> postBodies = [];
  final List<Map<String, String>> postHeaders = [];
  final List<Map<String, String>> getHeaders = [];
  final Map<String, PlaybackRecord> records = {};
  final List<PlaybackTombstone> tombstones = [];
  final Set<String> _seenEventIds = {};
  int failNextPosts = 0;
  int storedEvents = 0;

  String get url => 'http://127.0.0.1:${_server!.port}/api/playback/sync';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> stop() async => _server?.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name] = values.join(','));
    if (request.method == 'POST') {
      final raw = await utf8.decoder.bind(request).join();
      final body = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      postBodies.add(body);
      postHeaders.add(headers);
      if (failNextPosts > 0) {
        failNextPosts--;
        request.response.statusCode = 500;
        await request.response.close();
        return;
      }
      final eventId = body['eventId']?.toString() ?? '';
      if (_seenEventIds.contains(eventId)) {
        request.response
          ..statusCode = 200
          ..write(jsonEncode({'success': true, 'deduped': true}));
        await request.response.close();
        return;
      }
      _seenEventIds.add(eventId);
      storedEvents++;
      if (body['event'] == 'playback.deleted') {
        tombstones.add(PlaybackTombstone.fromJson(body));
      } else {
        final record = PlaybackRecord.fromJson(body);
        final existing = records[record.dedupeKey];
        if (existing == null || record.updatedAt > existing.updatedAt) {
          records[record.dedupeKey] = record;
        }
      }
      request.response
        ..statusCode = 200
        ..write(jsonEncode({'success': true, 'applied': 1}));
      await request.response.close();
      return;
    }
    if (request.method == 'GET') {
      getHeaders.add(headers);
      final since = int.tryParse(headers['x-webhtv-since'] ?? '') ?? 0;
      final items = records.values.where((r) => r.updatedAt > since).toList();
      final deleted = tombstones.where((t) => t.deletedAt > since).toList();
      var nextSince = since;
      for (final r in items) {
        if (r.updatedAt > nextSince) nextSince = r.updatedAt;
      }
      for (final t in deleted) {
        if (t.deletedAt > nextSince) nextSince = t.deletedAt;
      }
      request.response
        ..statusCode = 200
        ..write(
          jsonEncode({
            'items': [for (final r in items) r.toJson()],
            'deleted': [for (final t in deleted) t.toJson()],
            'nextSince': nextSince,
          }),
        );
      await request.response.close();
      return;
    }
    request.response.statusCode = 405;
    await request.response.close();
  }
}

const int t0 = 1795500000000;

PlaybackRecord makeRecord({
  String configKey = 'ck1',
  String? historyKey,
  String siteKey = 'siteA',
  String vodId = 'vod1',
  String vodName = '测试剧',
  String flag = '线路1',
  String episodeName = '第1集',
  String episodeUrl = 'https://cdn.example/ep1.m3u8',
  int positionMs = 60000,
  int durationMs = 120000,
  double speed = 1.0,
  bool speedOverride = false,
  int updatedAt = 1000,
}) => PlaybackRecord(
  configKey: configKey,
  configName: '接口一',
  historyKey: historyKey ?? playbackHistoryKey(siteKey, vodId),
  siteKey: siteKey,
  siteName: '站点甲',
  vodId: vodId,
  vodName: vodName,
  vodPic: 'https://img.example/cover.jpg',
  flag: flag,
  episodeName: episodeName,
  episodeUrl: episodeUrl,
  episodeIndex: 1,
  positionMs: positionMs,
  durationMs: durationMs,
  speed: speed,
  speedOverride: speedOverride,
  updatedAt: updatedAt,
);

PlaybackHistoryStore newStore() =>
    PlaybackHistoryStore(InMemoryPlaybackBackend());

void main() {
  group('协议记录层', () {
    test('record_codec_roundtrip', () {
      final record = makeRecord(
        speed: 1.5,
        speedOverride: true,
        positionMs: 61234,
        durationMs: 98765,
        updatedAt: 1760000000123,
      );
      final back = PlaybackRecord.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(record.toJson())) as Map,
        ),
      );
      expect(back.configKey, record.configKey);
      expect(back.historyKey, record.historyKey);
      expect(back.siteKey, record.siteKey);
      expect(back.vodId, record.vodId);
      expect(back.vodName, record.vodName);
      expect(back.vodPic, record.vodPic);
      expect(back.flag, record.flag);
      expect(back.episodeName, record.episodeName);
      expect(back.episodeUrl, record.episodeUrl);
      expect(back.positionMs, 61234);
      expect(back.durationMs, 98765);
      expect(back.speed, 1.5);
      expect(back.speedOverride, isTrue);
      expect(back.updatedAt, 1760000000123);
      expect(back.dedupeKey, record.dedupeKey);
      expect(back.progress, closeTo(61234 / 98765, 1e-9));
      // WatchEntry 桥往返：秒 <-> 毫秒只在取整内误差。
      final entry = record.toWatchEntry();
      expect(entry.position, closeTo(61.234, 1e-9));
      expect(entry.duration, closeTo(98.765, 1e-9));
      expect(entry.updatedAt.millisecondsSinceEpoch, record.updatedAt);
      final again = PlaybackRecord.fromWatchEntry(entry);
      expect(again.positionMs, record.positionMs);
      expect(again.durationMs, record.durationMs);
      expect(again.updatedAt, record.updatedAt);
    });

    test('watch_entry_bridge_fields', () {
      final entry = WatchEntry(
        drama: const Drama(
          id: 'siteA:vod9',
          source: 'siteA',
          sourceId: 'vod9',
          title: '桥接剧',
          cover: 'https://img.example/9.jpg',
        ),
        episode: 3,
        position: 61.5,
        duration: 120,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1760000000000),
      );
      final record = PlaybackRecord.fromWatchEntry(entry);
      expect(record.siteKey, 'siteA');
      expect(record.vodId, 'vod9');
      expect(record.vodName, '桥接剧');
      expect(record.vodPic, 'https://img.example/9.jpg');
      expect(record.positionMs, 61500);
      expect(record.durationMs, 120000);
      expect(record.updatedAt, 1760000000000);
      expect(record.historyKey, 'siteA@@@vod9');
      // 缺失字段按协议缺省：集名回退集号字符串、倍速 1.0 不覆盖。
      expect(record.episodeName, '3');
      expect(record.speed, 1.0);
      expect(record.speedOverride, isFalse);
      // sourceId 为空时从 Drama.id 拆 vodId。
      final entry2 = WatchEntry(
        drama: const Drama(id: 'siteB:vod7', source: 'siteB', title: '乙剧'),
        episode: 1,
        position: 10,
        duration: 100,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      expect(PlaybackRecord.fromWatchEntry(entry2).vodId, 'vod7');
    });

    test('speed_override_semantics', () async {
      final store = newStore();
      // 显式 1.0 + override=true：原样保留为单片设置。
      await store.upsertProgress(
        makeRecord(speed: 1.0, speedOverride: true, updatedAt: t0 + 100),
      );
      var stored = await store.readRecord('siteA@@@vod1');
      expect(stored!.speed, 1.0);
      expect(stored.speedOverride, isTrue);
      // override=false：清除单片覆盖，回继承（speed 归 1.0 且不覆盖）。
      final outcome = await store.upsertProgress(
        makeRecord(speed: 2.0, speedOverride: false, updatedAt: t0 + 200),
      );
      expect(outcome.action, MergeAction.updated);
      stored = await store.readRecord('siteA@@@vod1');
      expect(stored!.speedOverride, isFalse);
      expect(stored.speed, 1.0);
      // 旧请求缺 speedOverride 字段：非 1.0 按覆盖、1.0 按继承。
      final legacyFast = PlaybackRecord.fromJson({
        'siteKey': 's',
        'vodId': 'v',
        'speed': 1.75,
      });
      expect(legacyFast.speedOverride, isTrue);
      final legacyNormal = PlaybackRecord.fromJson({
        'siteKey': 's',
        'vodId': 'v',
        'speed': 1.0,
      });
      expect(legacyNormal.speedOverride, isFalse);
    });
  });

  group('本地读写与合并规则', () {
    test('merge_newer_wins_older_skipped', () async {
      final store = newStore();
      await store.upsertProgress(
        makeRecord(updatedAt: t0 + 100, positionMs: 1000),
      );
      // episodeUrl 命中优先：集名变了也并到同一条，且更新时间新者胜。
      final byUrl = await store.upsertProgress(
        makeRecord(
          episodeName: '第1集（改名）',
          positionMs: 5000,
          updatedAt: t0 + 200,
        ),
      );
      expect(byUrl.action, MergeAction.updated);
      expect((await store.listRecords()).length, 1);
      expect((await store.readRecord('siteA@@@vod1'))!.positionMs, 5000);
      // 更旧与相等都 skipped 且本地不变。
      final older = await store.upsertProgress(
        makeRecord(positionMs: 9000, updatedAt: t0 + 150),
      );
      expect(older.action, MergeAction.skipped);
      final equal = await store.upsertProgress(
        makeRecord(positionMs: 9000, updatedAt: t0 + 200),
      );
      expect(equal.action, MergeAction.skipped);
      expect((await store.readRecord('siteA@@@vod1'))!.positionMs, 5000);
      // flag+集名命中（URL 不同也能并）。
      final byFlag = await store.upsertProgress(
        makeRecord(
          episodeUrl: 'https://cdn.example/other.m3u8',
          episodeName: '第1集（改名）',
          positionMs: 7000,
          updatedAt: t0 + 300,
        ),
      );
      expect(byFlag.action, MergeAction.updated);
      expect((await store.listRecords()).length, 1);
      // 仅集名命中（线路也不同）仍能并。
      final byName = await store.upsertProgress(
        makeRecord(
          flag: '线路2',
          episodeUrl: '',
          episodeName: '第1集（改名）',
          positionMs: 8000,
          updatedAt: t0 + 400,
        ),
      );
      expect(byName.action, MergeAction.updated);
      expect((await store.listRecords()).length, 1);
      expect((await store.readRecord('siteA@@@vod1'))!.positionMs, 8000);
    });

    test('tombstone_blocks_stale_progress', () async {
      final store = newStore();
      await store.upsertProgress(makeRecord(updatedAt: t0 + 100));
      final removed = await store.deleteRecords(
        historyKey: 'siteA@@@vod1',
        deletedAt: t0 + 500,
      );
      expect(removed, 1);
      expect(await store.readRecord('siteA@@@vod1'), isNull);
      // 旧于墓碑的进度不许复活。
      final stale = await store.upsertProgress(makeRecord(updatedAt: t0 + 400));
      expect(stale.action, MergeAction.skipped);
      expect(await store.readRecord('siteA@@@vod1'), isNull);
      // 新于墓碑的进度允许重新创建。
      final fresh = await store.upsertProgress(makeRecord(updatedAt: t0 + 600));
      expect(fresh.action, MergeAction.created);
      expect(await store.readRecord('siteA@@@vod1'), isNotNull);
    });

    test('config_key_partition_isolation', () async {
      final store = newStore();
      await store.upsertProgress(
        makeRecord(configKey: 'ckA', updatedAt: t0 + 100),
      );
      await store.upsertProgress(
        makeRecord(
          configKey: 'ckB',
          historyKey: 'siteA@@@vod1@@@2',
          updatedAt: t0 + 100,
        ),
      );
      expect((await store.listRecords()).length, 2);
      // 更新 ckA 分区不碰 ckB 分区的同名记录。
      await store.upsertProgress(
        makeRecord(configKey: 'ckA', positionMs: 42000, updatedAt: t0 + 200),
      );
      final list = await store.listRecords();
      expect(list.length, 2);
      final a = list.firstWhere((r) => r.configKey == 'ckA');
      final b = list.firstWhere((r) => r.configKey == 'ckB');
      expect(a.positionMs, 42000);
      expect(b.positionMs, 60000);
    });
  });

  group('本机 API 逻辑', () {
    test('current_api_requires_matching_site', () async {
      final store = newStore();
      store.setCurrent(makeRecord());
      final api = PlaybackLocalApi(
        store,
        syncEnabled: true,
        allowModify: false,
      );
      final missing = await api.current();
      expect(missing.$1, 400);
      final mismatch = await api.current(siteKey: 'siteB');
      expect(mismatch.$1, 404);
      final ok = await api.current(siteKey: 'siteA');
      expect(ok.$1, 200);
      final item = ok.$2['item'] as Map<String, dynamic>;
      expect(item['siteKey'], 'siteA');
      // 安全快照不含真实播放 URL 与去重键。
      expect(item.containsKey('episodeUrl'), isFalse);
      expect(item.containsKey('dedupeKey'), isFalse);
    });

    test('write_api_gated_by_switches', () async {
      final store = newStore();
      final body = makeRecord(updatedAt: t0 + 100).toJson()
        ..remove('dedupeKey')
        ..remove('schema');
      final readOnly = PlaybackLocalApi(
        store,
        syncEnabled: true,
        allowModify: false,
      );
      final denied = await readOnly.progress(body);
      expect(denied.$1, 403);
      expect(await store.listRecords(), isEmpty);
      final deniedDelete = await readOnly.delete({
        'historyKey': 'siteA@@@vod1',
      });
      expect(deniedDelete.$1, 403);
      // 只读仍可用。
      store.setCurrent(makeRecord());
      expect((await readOnly.current(siteKey: 'siteA')).$1, 200);
      // 两开关都开：单条写入成功回 created。
      final writable = PlaybackLocalApi(
        store,
        syncEnabled: true,
        allowModify: true,
      );
      final created = await writable.progress(body);
      expect(created.$1, 200);
      expect(created.$2['action'], 'created');
      expect((await store.listRecords()).length, 1);
    });

    test('batch_partial_failure_isolated', () async {
      final store = newStore();
      final api = PlaybackLocalApi(store, syncEnabled: true, allowModify: true);
      Map<String, dynamic> item(String vodId, {bool bad = false}) =>
          makeRecord(vodId: vodId, updatedAt: t0 + 100).toJson()
            ..remove('dedupeKey')
            ..remove('schema')
            ..['vodName'] = bad ? '' : '剧$vodId';
      final (status, result) = await api.progressBatch({
        'items': [item('v1'), item('v2', bad: true), item('v3')],
      });
      expect(status, 200);
      expect(result['total'], 3);
      expect(result['applied'], 2);
      expect(result['failed'], 1);
      expect((await store.listRecords()).length, 2);
    });
  });

  group('与假服务端联调（同一地址双向承接）', () {
    late FakeSyncServer server;
    setUp(() async {
      server = FakeSyncServer();
      await server.start();
    });
    tearDown(() async => server.stop());

    PlaybackSyncClient clientFor(
      PlaybackHistoryStore store, {
      String token = 'tok-abc',
      int maxItems = 200,
      Map<String, int> knownConfigKeys = const {},
    }) => PlaybackSyncClient(
      store,
      config: PlaybackSyncConfig(
        url: server.url,
        token: token,
        maxItems: maxItems,
        knownConfigKeys: knownConfigKeys,
      ),
    );

    test('fake_server_same_url_both_directions', () async {
      final storeA = newStore();
      final pushed = await clientFor(storeA).pushProgress(
        makeRecord(updatedAt: t0 + 1000),
        event: 'playback.progress',
      );
      expect(pushed, isTrue);
      // 紧接着从同一地址 GET 增量，能拉回同一条。
      final storeB = newStore();
      final report = await clientFor(storeB).pullAndMerge();
      expect(report.created, 1);
      final pulled = await storeB.readRecord('siteA@@@vod1');
      expect(pulled, isNotNull);
      expect(pulled!.positionMs, 60000);
      expect(pulled.updatedAt, t0 + 1000);
    });

    test('webhook_retry_reuses_event_id', () async {
      server.failNextPosts = 1;
      final store = newStore();
      var seq = 0;
      final client = PlaybackSyncClient(
        store,
        config: PlaybackSyncConfig(url: server.url, token: 'tok-abc'),
        eventIdFactory: () => 'evt-fixed-${seq++}',
      );
      final ok = await client.pushProgress(
        makeRecord(updatedAt: t0 + 1000),
        event: 'playback.progress',
      );
      expect(ok, isTrue);
      expect(server.postBodies.length, 2);
      final first = server.postBodies[0];
      final second = server.postBodies[1];
      expect(first['eventId'], second['eventId']);
      expect(
        server.postHeaders[0]['idempotency-key'],
        server.postHeaders[1]['idempotency-key'],
      );
      expect(server.postHeaders[0]['idempotency-key'], first['eventId']);
      // 服务端按幂等只记一条。
      expect(server.storedEvents, 1);
      expect(server.records.length, 1);
    });

    test('delete_generates_tombstone_and_webhook', () async {
      final store = newStore();
      await store.upsertProgress(makeRecord(updatedAt: t0 + 100));
      await store.upsertProgress(
        makeRecord(vodId: 'vod2', updatedAt: t0 + 100),
      );
      final client = clientFor(store);
      // 单删：scope=item 墓碑 + playback.deleted 上报。
      await store.deleteRecords(
        historyKey: 'siteA@@@vod1',
        deletedAt: t0 + 900,
      );
      final itemTomb = (await store.listTombstones()).firstWhere(
        (t) => t.scope == 'item' && t.historyKey == 'siteA@@@vod1',
      );
      expect(await client.pushDeleted(itemTomb), isTrue);
      var lastBody = server.postBodies.last;
      expect(lastBody['event'], 'playback.deleted');
      expect(lastBody['scope'], 'item');
      expect(lastBody['deletedAt'], t0 + 900);
      var lastHeaders = server.postHeaders.last;
      expect(lastHeaders['x-webhtv-token'], 'tok-abc');
      expect(lastHeaders['x-webhtv-config-key'], 'ck1');
      expect(lastHeaders['x-webhtv-webhook-id'], lastBody['eventId']);
      // 站点删：scope=site。
      await store.deleteRecords(
        siteKey: 'siteA',
        scope: 'site',
        deletedAt: t0 + 950,
      );
      final siteTomb = (await store.listTombstones()).firstWhere(
        (t) => t.scope == 'site',
      );
      expect(await client.pushDeleted(siteTomb), isTrue);
      expect(server.postBodies.last['scope'], 'site');
      // 清空：scope=all 必须显式确认才落墓碑。
      await store.upsertProgress(
        makeRecord(siteKey: 'siteB', vodId: 'vod3', updatedAt: t0 + 100),
      );
      final notConfirmed = await store.deleteRecords(
        scope: 'all',
        deletedAt: t0 + 990,
      );
      expect(notConfirmed, 0);
      final cleared = await store.deleteRecords(
        scope: 'all',
        confirm: true,
        deletedAt: t0 + 990,
      );
      expect(cleared, 1);
      final allTomb = (await store.listTombstones()).firstWhere(
        (t) => t.scope == 'all',
      );
      expect(await client.pushDeleted(allTomb), isTrue);
      expect(server.postBodies.last['scope'], 'all');
    });

    test('pull_applies_items_and_tombstones', () async {
      final store = newStore();
      await store.upsertProgress(makeRecord(updatedAt: t0 + 100));
      // 假服务端预置：一条新记录 + 一条罩住本地记录的墓碑。
      final fresh = makeRecord(vodId: 'vodNew', updatedAt: t0 + 250);
      server.records[fresh.dedupeKey] = fresh;
      server.tombstones.add(
        const PlaybackTombstone(
          configKey: 'ck1',
          historyKey: 'siteA@@@vod1',
          siteKey: 'siteA',
          vodId: 'vod1',
          scope: 'item',
          deletedAt: t0 + 200,
        ),
      );
      final report = await clientFor(store).pullAndMerge();
      expect(report.created, 1);
      expect(report.deleted, 1);
      expect(await store.readRecord('siteA@@@vod1'), isNull);
      expect(await store.readRecord('siteA@@@vodNew'), isNotNull);
      // 游标推进到 nextSince（本批最大时间戳 250）。
      expect(report.cursorAdvanced, isTrue);
      expect(await store.cursorOf(server.url, ''), t0 + 250);
    });

    test('pull_respects_max_items_cursor', () async {
      for (var i = 1; i <= 3; i++) {
        final r = makeRecord(vodId: 'vod$i', updatedAt: t0 + 100 * i);
        server.records[r.dedupeKey] = r;
      }
      final store = newStore();
      // 返回条数（3）达 maxItems（3）：不推进游标，下一轮不丢条目。
      final report = await clientFor(store, maxItems: 3).pullAndMerge();
      expect(report.received, 3);
      expect(report.cursorAdvanced, isFalse);
      expect(await store.cursorOf(server.url, ''), 0);
      final again = await clientFor(store, maxItems: 3).pullAndMerge();
      expect(again.received, 3);
      // 放宽上限后游标正常推进到 300。
      final widened = await clientFor(store, maxItems: 10).pullAndMerge();
      expect(widened.cursorAdvanced, isTrue);
      expect(await store.cursorOf(server.url, ''), t0 + 300);
    });

    test('pull_skips_unmapped_config_key', () async {
      final mine = makeRecord(configKey: 'ckMine', updatedAt: t0 + 100);
      final alien = makeRecord(
        configKey: 'ckAlien',
        vodId: 'vodX',
        historyKey: 'siteA@@@vodX',
        updatedAt: t0 + 200,
      );
      server.records[mine.dedupeKey] = mine;
      server.records[alien.dedupeKey] = alien;
      final store = newStore();
      final report = await clientFor(
        store,
        knownConfigKeys: const {'ckMine': 1},
      ).pullAndMerge();
      expect(report.created, 1);
      expect(report.unmapped, 1);
      expect(await store.readRecord('siteA@@@vodX'), isNull);
      expect(await store.readRecord('siteA@@@vod1'), isNotNull);
    });
  });
}
