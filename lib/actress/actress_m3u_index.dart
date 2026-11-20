import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'actress_json_fallback.dart';
import 'actress_models.dart';

/// whos m3u 分片索引读取器：用户 2026-11-19 发来的 9 个女优合集 m3u
///（310,028 条，约 100MB raw）转成的紧凑索引。
///
/// 存储形态（不直接随包带 raw 100MB）：按 md5(女优名) % 32 分 32 个
/// shard，每 shard `{"a": {女优名: [[hash, code, title], ...]}}` 再 gzip；
/// 另附 manifest（女优→分片、归一化番号→分片、总数）。gzip 合计
/// 约 24MB（24,213,597 字节），随包进 assets/actress_json/whos_m3u/。
///
/// 查询只解需要的分片：按女优名查只解该女优所在分片（一般 1 个），
/// 按番号查只解 manifest 指出的分片；分片缓存最多留 4 个，超了
/// 丢最旧的。manifest 只解一次。整库 224,456 部去重后作品绝不
/// 一次全读进内存。
///
/// 行转条目：播 `https://v.hersav.me/<hash>/<hash>.m3u8`、
/// 图 `https://v.hersav.me/images/av/<hash>.jpg`，与 whos.json
/// 同一套 hash 编址；vod_play_url 仍是 `正片$地址`，parse=0 直链播。

/// 读 asset 字节用：默认走 rootBundle；测试可注入假字节。
typedef WhosM3uBytesReader = Future<Uint8List> Function(String assetPath);

Future<Uint8List> _defaultM3uReader(String assetPath) async {
  final data = await rootBundle.load(assetPath);
  return data.buffer.asUint8List();
}

class WhosM3uIndex {
  WhosM3uIndex({WhosM3uBytesReader? bytesReader})
      : _bytesReader = bytesReader ?? _defaultM3uReader;

  static const manifestAsset =
      'assets/actress_json/whos_m3u/whos_m3u_manifest.json.gz';

  /// 分片数（与转换脚本 build_m3u_index.py 的 SHARDS=32 一致）。
  static const shardCount = 32;

  /// 内存里最多留几个解开的分片。
  static const maxCachedShards = 4;

  final WhosM3uBytesReader _bytesReader;
  Future<Map<String, dynamic>>? _manifestFuture;
  final _shardCache = <int, Map<String, dynamic>>{};
  final _shardOrder = <int>[];

  static String shardAsset(int idx) =>
      'assets/actress_json/whos_m3u/shard_${idx.toString().padLeft(2, '0')}.json.gz';

  Future<Map<String, dynamic>> _manifest() {
    return _manifestFuture ??= _loadManifest();
  }

  Future<Map<String, dynamic>> _loadManifest() async {
    final bytes = await _bytesReader(manifestAsset);
    final doc = jsonDecode(utf8.decode(gzip.decode(bytes)));
    if (doc is! Map<String, dynamic>) {
      throw const FormatException('m3u manifest 不是对象');
    }
    return doc;
  }

  Future<Map<String, dynamic>> _shard(int idx) async {
    final cached = _shardCache[idx];
    if (cached != null) return cached;
    final bytes = await _bytesReader(shardAsset(idx));
    final doc = jsonDecode(utf8.decode(gzip.decode(bytes)));
    if (doc is! Map<String, dynamic>) {
      throw FormatException('m3u shard $idx 不是对象');
    }
    _shardCache[idx] = doc;
    _shardOrder.add(idx);
    while (_shardOrder.length > maxCachedShards) {
      _shardCache.remove(_shardOrder.removeAt(0));
    }
    return doc;
  }

  /// 行 [hash, code, title] → ActressJsonEntry（站 whos）。
  ActressJsonEntry _rowToEntry(String actress, List row) {
    final hash = row[0].toString();
    final code = row.length > 1 ? row[1].toString() : '';
    final title = row.length > 2 ? row[2].toString() : '';
    final pic = 'https://v.hersav.me/images/av/$hash.jpg';
    return ActressJsonEntry(
      site: 'whos',
      vodId: hash,
      vodName: title,
      vodPic: pic,
      vodActor: actress,
      vodDirector: '',
      vodRemarks: '高清',
      vodPubdate: '',
      vodArea: '',
      vodYear: '',
      vodContent: '',
      vodPlayFrom: 'whos',
      vodPlayUrl: '正片\$https://v.hersav.me/$hash/$hash.m3u8',
      typeName: '日本AV',
      vodCode: code,
      vodActressPic: pic,
    );
  }

  /// manifest 里分片号的两种写法都认：女优值是单个 int（每女优
  /// 只落一个分片），番号值是 int 数组（同一番号可跨多分片）。
  static List<int> _shardIdxs(dynamic value) {
    if (value is int) return [value];
    if (value is List) {
      return [for (final e in value) if (e is int) e];
    }
    return const [];
  }

  /// 按女优名取 m3u 条目：manifest 里女优→分片，先精确名，
  /// 再按归一化名扫一遍键（3,183 个键，内存里扫一次很快）。
  Future<List<ActressJsonEntry>> entriesForActress(String name) async {
    if (name.isEmpty) return const [];
    final manifest = await _manifest();
    final actressMap = manifest['actress'];
    if (actressMap is! Map) return const [];
    List<int>? shardIdxs;
    var key = name;
    if (actressMap.containsKey(name)) {
      shardIdxs = _shardIdxs(actressMap[name]);
    } else {
      final want = normalizeActressJsonName(name);
      for (final k in actressMap.keys) {
        if (normalizeActressJsonName(k.toString()) == want) {
          shardIdxs = _shardIdxs(actressMap[k]);
          key = k.toString();
          break;
        }
      }
    }
    if (shardIdxs == null) return const [];
    final out = <ActressJsonEntry>[];
    for (final idx in shardIdxs) {
      final shard = await _shard(idx);
      final a = shard['a'];
      if (a is! Map) continue;
      final rows = a[key];
      if (rows is List) {
        for (final row in rows) {
          if (row is List && row.isNotEmpty) {
            out.add(_rowToEntry(key, row));
          }
        }
      }
    }
    return out;
  }

  /// 按归一化番号取 m3u 条目：只解 manifest 指出的分片，
  /// 再在分片里扫出番号相同的行（同一部片在多女优名下各留一条，
  /// 与全站叠加“按（站，番号）去重”的口径一致，调用方按
  /// 站|mergeKey 去重）。
  Future<List<ActressJsonEntry>> entriesForCode(String codeKey) async {
    final key = normalizeAvCode(codeKey);
    if (key.isEmpty) return const [];
    final manifest = await _manifest();
    final codeMap = manifest['code'];
    if (codeMap is! Map || !codeMap.containsKey(key)) return const [];
    final shardIdxs = _shardIdxs(codeMap[key]);
    final out = <ActressJsonEntry>[];
    for (final idx in shardIdxs) {
      final shard = await _shard(idx);
      final a = shard['a'];
      if (a is! Map) continue;
      for (final kv in a.entries) {
        final actress = kv.key.toString();
        final rows = kv.value;
        if (rows is! List) continue;
        for (final row in rows) {
          if (row is List &&
              row.length > 1 &&
              normalizeAvCode(row[1].toString()) == key) {
            out.add(_rowToEntry(actress, row));
          }
        }
      }
    }
    return out;
  }

  /// 某人（名字 + 本地作品番号集合）在 m3u 里有没有条目：
  /// 只查 manifest，不解分片。
  Future<bool> hasEntriesForPerson({
    required List<String> names,
    required Set<String> codeKeys,
  }) async {
    final manifest = await _manifest();
    final actressMap = manifest['actress'];
    if (actressMap is Map) {
      for (final name in names) {
        if (actressMap.containsKey(name)) return true;
        final want = normalizeActressJsonName(name);
        for (final k in actressMap.keys) {
          if (normalizeActressJsonName(k.toString()) == want) return true;
        }
      }
    }
    final codeMap = manifest['code'];
    if (codeMap is Map) {
      for (final codeKey in codeKeys) {
        if (codeMap.containsKey(normalizeAvCode(codeKey))) return true;
      }
    }
    return false;
  }

  /// 索引总数（与转换脚本输出一致：videos 224,456、
  /// appearances 309,716、actresses 3,183、codes 86,720）。
  Future<
      ({
        int videos,
        int appearances,
        int actresses,
        int codes,
        int entries,
      })> stats() async {
    final manifest = await _manifest();
    int n(String k) =>
        manifest[k] is num ? (manifest[k] as num).toInt() : 0;
    return (
      videos: n('videos'),
      appearances: n('appearances'),
      actresses: n('actresses'),
      codes: n('codes'),
      entries: n('entries'),
    );
  }
}
