import 'dart:async';
import 'dart:convert';

/// 站点健康学习（第 3 点，学 easytv 思路、按魔蚁架构原创实现）：
/// 按站记录搜索 / 详情 / 播放三类事件的成败计数、搜索结果数与
/// 耗时、最近成败时间，算「最近成功率」总分供搜索调度、搜索
/// 结果组序与选站弹窗排序 / 状态点使用。只存聚合计数不存逐条
/// 日志；打点只改内存，延迟异步落盘（经 LocalStore 的
/// `site_health_v1` 键），不堵 UI、不持续轮询。

/// 健康记录保留期：超过未更新的记录在加载 / 清理时整条丢弃；
/// 打点时若距上次活动已超过保留期，先把旧计数减半再累加
/// （一次性老化，不做指数衰减、无定时器）。
const Duration siteHealthRetention = Duration(days: 90);

/// 单类样本数低于此值时，该类成功率按中性计（信息不足不奖不罚）。
const int siteHealthMinSamples = 3;

/// 中性成功率（未知站 / 样本不足时的口径）。
const double siteHealthNeutralRate = 0.5;

/// 总分权重：搜索 0.4 + 详情 0.3 + 播放 0.3。耗时只作展示与
/// 同分时的次序参考，不进主分。
const double siteHealthSearchWeight = 0.4;
const double siteHealthDetailWeight = 0.3;
const double siteHealthPlayWeight = 0.3;

/// 状态档阈值：总分 ≥ [siteHealthGreenThreshold] 为绿，
/// ≥ [siteHealthYellowThreshold] 为黄，以下为红；最近连续失败
/// 达到 [siteHealthRedStreak] 次直接判红。
const double siteHealthGreenThreshold = 0.7;
const double siteHealthYellowThreshold = 0.4;
const int siteHealthRedStreak = 5;

/// 站点健康状态档（选站弹窗四色点：绿 / 黄 / 红 / 灰）。
enum SiteHealthTier { good, fair, bad, unknown }

/// 单站健康记录：三类事件的聚合计数 + 最近成败时间。
class SiteHealthRecord {
  SiteHealthRecord({
    this.searchOk = 0,
    this.searchFail = 0,
    this.searchItemsTotal = 0,
    this.searchMsTotal = 0,
    this.detailOk = 0,
    this.detailFail = 0,
    this.detailMsTotal = 0,
    this.playOk = 0,
    this.playFail = 0,
    this.lastOkAtMs = 0,
    this.lastFailAtMs = 0,
    this.consecutiveFails = 0,
  });

  int searchOk;
  int searchFail;
  int searchItemsTotal;
  int searchMsTotal;
  int detailOk;
  int detailFail;
  int detailMsTotal;
  int playOk;
  int playFail;

  /// 最近一次成功 / 失败的毫秒时间戳（0 = 从无）。
  int lastOkAtMs;
  int lastFailAtMs;

  /// 最近连续失败次数（任一成功清零）：判红用。
  int consecutiveFails;

  int get totalSamples =>
      searchOk + searchFail + detailOk + detailFail + playOk + playFail;

  /// 最近活动时间（成功 / 失败取晚者），0 = 无活动。
  int get lastActivityMs =>
      lastOkAtMs > lastFailAtMs ? lastOkAtMs : lastFailAtMs;

  static double _rate(int ok, int fail) {
    final samples = ok + fail;
    if (samples < siteHealthMinSamples) return siteHealthNeutralRate;
    return ok / samples;
  }

  double get searchRate => _rate(searchOk, searchFail);
  double get detailRate => _rate(detailOk, detailFail);
  double get playRate => _rate(playOk, playFail);

  /// 总分（0–1）：三类成功率加权；无记录 / 样本全不足时为中性。
  double get score =>
      siteHealthSearchWeight * searchRate +
      siteHealthDetailWeight * detailRate +
      siteHealthPlayWeight * playRate;

  /// 状态档：无样本 = 未知（灰）；连续失败达阈值 = 红；其余按总分。
  SiteHealthTier get tier {
    if (totalSamples == 0) return SiteHealthTier.unknown;
    if (consecutiveFails >= siteHealthRedStreak) return SiteHealthTier.bad;
    final value = score;
    if (value >= siteHealthGreenThreshold && lastOkAtMs > 0) {
      return SiteHealthTier.good;
    }
    if (value >= siteHealthYellowThreshold) return SiteHealthTier.fair;
    return SiteHealthTier.bad;
  }

  /// 一次性老化：距最近活动超过保留期时计数整体减半（时间戳与
  /// 连续失败不动，减半后由新打点刷新时间戳）。未超期原样返回。
  SiteHealthRecord aged(DateTime now) {
    final last = lastActivityMs;
    if (last == 0) return this;
    if (now.millisecondsSinceEpoch - last <=
        siteHealthRetention.inMilliseconds) {
      return this;
    }
    int half(int value) => value ~/ 2;
    return SiteHealthRecord(
      searchOk: half(searchOk),
      searchFail: half(searchFail),
      searchItemsTotal: half(searchItemsTotal),
      searchMsTotal: half(searchMsTotal),
      detailOk: half(detailOk),
      detailFail: half(detailFail),
      detailMsTotal: half(detailMsTotal),
      playOk: half(playOk),
      playFail: half(playFail),
      lastOkAtMs: lastOkAtMs,
      lastFailAtMs: lastFailAtMs,
      consecutiveFails: consecutiveFails,
    );
  }

  Map<String, Object> toJson() => {
    'so': searchOk,
    'sf': searchFail,
    'si': searchItemsTotal,
    'sm': searchMsTotal,
    'do': detailOk,
    'df': detailFail,
    'dm': detailMsTotal,
    'po': playOk,
    'pf': playFail,
    'lo': lastOkAtMs,
    'lf': lastFailAtMs,
    'cf': consecutiveFails,
  };

  static SiteHealthRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    int read(String key) {
      final value = raw[key];
      return value is num ? value.toInt() : 0;
    }

    return SiteHealthRecord(
      searchOk: read('so'),
      searchFail: read('sf'),
      searchItemsTotal: read('si'),
      searchMsTotal: read('sm'),
      detailOk: read('do'),
      detailFail: read('df'),
      detailMsTotal: read('dm'),
      playOk: read('po'),
      playFail: read('pf'),
      lastOkAtMs: read('lo'),
      lastFailAtMs: read('lf'),
      consecutiveFails: read('cf'),
    );
  }
}

/// 丢弃超过保留期未更新的记录（加载 / 落盘前调用，纯函数口径：
/// 返回新表，不改入参）。
Map<String, SiteHealthRecord> pruneExpiredSiteHealth(
  Map<String, SiteHealthRecord> records,
  DateTime now,
) {
  final cutoff = now.millisecondsSinceEpoch - siteHealthRetention.inMilliseconds;
  return {
    for (final entry in records.entries)
      if (entry.value.lastActivityMs == 0 || entry.value.lastActivityMs >= cutoff)
        entry.key: entry.value,
  };
}

/// 按健康分降序稳定排序（同分保持原顺序）：未知站为中性分，
/// 自然落在已知好站之后、已知坏站之前。
List<T> stableHealthSort<T>(List<T> items, double Function(T item) scoreOf) {
  final decorated = <({int index, T item, double score})>[
    for (var i = 0; i < items.length; i++)
      (index: i, item: items[i], score: scoreOf(items[i])),
  ];
  decorated.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : a.index.compareTo(b.index);
  });
  return [for (final entry in decorated) entry.item];
}

/// 健康度存储门面：内存表 + 延迟落盘。LocalStore 构造时把已存
/// JSON 载入单例并挂上落盘回调；仓储层打点、搜索页组序、选站
/// 弹窗都只认这个单例。总开关关时打点与排序全部短路，行为与
/// 未接入健康学习时一致。
class SiteHealthStore {
  SiteHealthStore({this.saveDelay = const Duration(seconds: 2)});

  /// 全局单例（测试可整体替换）。
  static SiteHealthStore instance = SiteHealthStore();

  /// 落盘防抖时长：打点只置脏，延迟合并写一次。
  final Duration saveDelay;

  /// 总开关（设置页「启用健康排序」，默认开）：关时不打点、
  /// 不重排，`scoreOf` 恒回中性分。
  bool enabled = true;

  /// 落盘回调（LocalStore 挂）：收到编码后的 JSON 全量写一次。
  void Function(String json)? onSave;

  final Map<String, SiteHealthRecord> _records = {};
  Timer? _saveTimer;
  bool _dirty = false;

  Map<String, SiteHealthRecord> get records => Map.unmodifiable(_records);

  SiteHealthRecord? recordOf(String siteId) => _records[siteId];

  double scoreOf(String siteId) {
    if (!enabled) return siteHealthNeutralRate;
    return _records[siteId]?.score ?? siteHealthNeutralRate;
  }

  SiteHealthTier tierOf(String siteId) =>
      _records[siteId]?.tier ?? SiteHealthTier.unknown;

  void recordSearch(
    String siteId, {
    required bool ok,
    int items = 0,
    int elapsedMs = 0,
    DateTime? at,
  }) {
    if (!enabled || siteId.isEmpty) return;
    final record = _touch(siteId, at);
    if (ok) {
      record.searchOk++;
      record.searchItemsTotal += items < 0 ? 0 : items;
      record.searchMsTotal += elapsedMs < 0 ? 0 : elapsedMs;
    } else {
      record.searchFail++;
    }
    _afterEvent(record, ok, at);
  }

  void recordDetail(
    String siteId, {
    required bool ok,
    int elapsedMs = 0,
    DateTime? at,
  }) {
    if (!enabled || siteId.isEmpty) return;
    final record = _touch(siteId, at);
    if (ok) {
      record.detailOk++;
      record.detailMsTotal += elapsedMs < 0 ? 0 : elapsedMs;
    } else {
      record.detailFail++;
    }
    _afterEvent(record, ok, at);
  }

  void recordPlay(String siteId, {required bool ok, DateTime? at}) {
    if (!enabled || siteId.isEmpty) return;
    final record = _touch(siteId, at);
    if (ok) {
      record.playOk++;
    } else {
      record.playFail++;
    }
    _afterEvent(record, ok, at);
  }

  /// 取（或建）记录；建 / 取前先做一次性老化（超保留期减半）。
  SiteHealthRecord _touch(String siteId, DateTime? at) {
    final now = at ?? DateTime.now();
    final existing = _records[siteId];
    if (existing == null) {
      final fresh = SiteHealthRecord();
      _records[siteId] = fresh;
      return fresh;
    }
    final aged = existing.aged(now);
    if (!identical(aged, existing)) _records[siteId] = aged;
    return _records[siteId]!;
  }

  void _afterEvent(SiteHealthRecord record, bool ok, DateTime? at) {
    final stamp = (at ?? DateTime.now()).millisecondsSinceEpoch;
    if (ok) {
      record.lastOkAtMs = stamp;
      record.consecutiveFails = 0;
    } else {
      record.lastFailAtMs = stamp;
      record.consecutiveFails++;
    }
    _markDirty();
  }

  /// 按健康分降序重排站 id 列表（稳定排序）；总开关关时原样返回。
  List<String> orderSources(List<String> sources) {
    if (!enabled) return List.of(sources);
    return stableHealthSort(sources, scoreOf);
  }

  String encode({DateTime? at}) {
    final pruned = pruneExpiredSiteHealth(_records, at ?? DateTime.now());
    return jsonEncode({
      'v': 1,
      'sites': {
        for (final entry in pruned.entries) entry.key: entry.value.toJson(),
      },
    });
  }

  /// 载入已存 JSON：坏 JSON / 结构不对一律回空表不抛错；载入时
  /// 顺手丢弃超保留期未更新的记录。
  void loadFromJson(String? raw, {DateTime? at}) {
    _records.clear();
    _dirty = false;
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final sites = decoded['sites'];
      if (sites is! Map) return;
      final loaded = <String, SiteHealthRecord>{};
      for (final entry in sites.entries) {
        final record = SiteHealthRecord.fromJson(entry.value);
        if (record != null && entry.key is String) {
          loaded[entry.key as String] = record;
        }
      }
      _records.addAll(pruneExpiredSiteHealth(loaded, at ?? DateTime.now()));
    } catch (_) {
      _records.clear();
    }
  }

  /// 清空全部学习记录并立即落盘一次（设置页「清空健康记录」）。
  void clear() {
    _records.clear();
    _saveTimer?.cancel();
    _saveTimer = null;
    _dirty = false;
    onSave?.call(encode());
  }

  /// 立即把待落盘的脏数据写出（测试 / 退出路径用）。
  void flush() {
    if (!_dirty) return;
    _saveTimer?.cancel();
    _saveTimer = null;
    _dirty = false;
    onSave?.call(encode());
  }

  void _markDirty() {
    _dirty = true;
    final save = onSave;
    if (save == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelay, () {
      _saveTimer = null;
      if (!_dirty) return;
      _dirty = false;
      save(encode());
    });
  }
}
