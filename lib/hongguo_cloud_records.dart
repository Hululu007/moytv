import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core_bridge.dart';
import 'hongguo_account_store.dart';
import 'local_store.dart';
import 'models.dart';

/// 云端收藏 / 历史 / 预约 / 相关季 + 续播决策 + 进度上传队列。
/// 只读 Go 桥接的 17 个 hongguoAccount* / hongguoLogin* 动作里与
/// 云端记录相关的 7 个；登录本身在 hongguo_account_store.dart。

// ---------------------------------------------------------------- 模型

class HongguoCloudFavorite {
  const HongguoCloudFavorite({
    required this.seriesId,
    required this.title,
    this.cover = '',
    this.badge = '',
  });

  factory HongguoCloudFavorite.fromJson(Map<String, dynamic> json) =>
      HongguoCloudFavorite(
        seriesId: json['seriesId']?.toString() ?? '',
        title: json['title'] as String? ?? '',
        cover: json['cover'] as String? ?? '',
        badge: json['badge'] as String? ?? '',
      );

  final String seriesId;
  final String title;
  final String cover;
  final String badge;
}

class HongguoCloudHistoryItem {
  const HongguoCloudHistoryItem({
    required this.seriesId,
    required this.title,
    this.cover = '',
    this.episodeId = '',
    this.episodeIndex = 0,
    this.positionMs = 0,
    this.durationMs = 0,
    this.updatedAtMs = 0,
    this.episodeCount = 0,
  });

  factory HongguoCloudHistoryItem.fromJson(Map<String, dynamic> json) =>
      HongguoCloudHistoryItem(
        seriesId: json['seriesId']?.toString() ?? '',
        title: json['title'] as String? ?? '',
        cover: json['cover'] as String? ?? '',
        episodeId: json['episodeId']?.toString() ?? '',
        episodeIndex: intValue(json['episodeIndex']),
        positionMs: intValue(json['positionMs']),
        durationMs: intValue(json['durationMs']),
        updatedAtMs: intValue(json['updatedAtMs']),
        episodeCount: intValue(json['episodeCount']),
      );

  final String seriesId;
  final String title;
  final String cover;
  final String episodeId;
  final int episodeIndex;
  final int positionMs;
  final int durationMs;
  final int updatedAtMs;
  final int episodeCount;

  double get positionSeconds => positionMs / 1000;
}

class HongguoCloudReservation {
  const HongguoCloudReservation({
    required this.seriesId,
    required this.title,
    this.cover = '',
    required this.online,
    this.badge = '',
  });

  factory HongguoCloudReservation.fromJson(Map<String, dynamic> json) =>
      HongguoCloudReservation(
        seriesId: json['seriesId']?.toString() ?? '',
        title: json['title'] as String? ?? '',
        cover: json['cover'] as String? ?? '',
        online: json['online'] == true,
        badge: json['badge'] as String? ?? '',
      );

  final String seriesId;
  final String title;
  final String cover;
  final bool online;
  final String badge;

  /// 未上线项的 seriesId 是 reservation:{item_id} 命名空间键，
  /// 不可当播放 ID 用；只有已上线项能播。
  bool get isPlayable => online && !seriesId.startsWith('reservation:');

  /// 预约写后读回确认时，比对用的键：已上线用剧 ID，未上线用
  /// reservation:{item_id} 全键。
  String get reserveKey => seriesId;
}

class HongguoRelatedWork {
  const HongguoRelatedWork({
    required this.seriesId,
    required this.title,
    this.cover = '',
    this.description = '',
    this.badge = '',
    this.season = 0,
    this.seasonIndex = 0,
    this.upcoming = false,
  });

  factory HongguoRelatedWork.fromJson(Map<String, dynamic> json) =>
      HongguoRelatedWork(
        seriesId: json['seriesId']?.toString() ?? '',
        title: json['title'] as String? ?? '',
        cover: json['cover'] as String? ?? '',
        description: json['description'] as String? ?? '',
        badge: json['badge'] as String? ?? '',
        season: intValue(json['season']),
        seasonIndex: intValue(json['seasonIndex']),
        upcoming: json['upcoming'] == true,
      );

  final String seriesId;
  final String title;
  final String cover;
  final String description;
  final String badge;
  final int season;
  final int seasonIndex;
  final bool upcoming;

  String get seasonLabel => season > 0 ? '第 $season 季' : '';
}

/// 预约写的结果：ok 只表示写操作被服务端确认，不代表已预约成功；
/// [confirmedInList] 才是读回账号预约列表后确认已在列表里。
class HongguoReserveResult {
  const HongguoReserveResult({
    required this.requested,
    required this.confirmedInList,
  });

  final bool requested;
  final bool confirmedInList;

  /// 界面只许在 confirmedInList 为真时写“已预约”。
  bool get confirmed => requested && confirmedInList;
}

// ---------------------------------------------------------------- 拉取

class HongguoCloudRecords {
  HongguoCloudRecords(this.repository);

  final AppRepository repository;

  static List<Map<String, dynamic>> _items(Map<String, dynamic> json) => [
    for (final row in json['items'] as List? ?? const [])
      if (row is Map) Map<String, dynamic>.from(row),
  ];

  Future<List<HongguoCloudFavorite>> fetchFavorites() async {
    final result = await repository.hongguoAccountFavorites();
    return [
      for (final row in _items(result))
        HongguoCloudFavorite.fromJson(row),
    ].where((item) => item.seriesId.isNotEmpty).toList();
  }

  /// 写收藏后桥接已回读确认，返回刷新后的账号收藏列表。
  Future<List<HongguoCloudFavorite>> setFavorite(
    String seriesId,
    bool add,
  ) async {
    final result = await repository.hongguoAccountSetFavorite(seriesId, add);
    return [
      for (final row in _items(result))
        HongguoCloudFavorite.fromJson(row),
    ].where((item) => item.seriesId.isNotEmpty).toList();
  }

  Future<List<HongguoCloudHistoryItem>> fetchHistory() async {
    final result = await repository.hongguoAccountHistory();
    return [
      for (final row in _items(result))
        HongguoCloudHistoryItem.fromJson(row),
    ].where((item) => item.seriesId.isNotEmpty).toList();
  }

  Future<List<HongguoCloudReservation>> fetchReservations({
    required bool online,
  }) async {
    final result = await repository.hongguoAccountReservations(online);
    return [
      for (final row in _items(result))
        HongguoCloudReservation.fromJson(row),
    ].where((item) => item.seriesId.isNotEmpty).toList();
  }

  /// 预约写：先调写接口，再读回待上线预约列表确认是否在列。
  Future<HongguoReserveResult> reserve(String seriesId) async {
    final result = await repository.hongguoAccountReserve(seriesId);
    final requested = result['ok'] == true;
    if (!requested) {
      return const HongguoReserveResult(
        requested: false,
        confirmedInList: false,
      );
    }
    final offline = await fetchReservations(online: false);
    final confirmed = offline.any(
      (item) =>
          item.seriesId == seriesId ||
          item.seriesId == 'reservation:$seriesId',
    );
    return HongguoReserveResult(
      requested: true,
      confirmedInList: confirmed,
    );
  }

  Future<List<HongguoRelatedWork>> fetchRelated(String seriesId) async {
    final result = await repository.hongguoAccountRelated(seriesId);
    return [
      for (final row in _items(result)) HongguoRelatedWork.fromJson(row),
    ].where((item) => item.seriesId.isNotEmpty).toList();
  }
}

// ---------------------------------------------------------------- 续播决策

enum HongguoResumeSource { local, cloud, none }

class HongguoResumeDecision {
  const HongguoResumeDecision({
    required this.source,
    this.episodeIndex = 0,
    this.positionMs = 0,
  });

  final HongguoResumeSource source;
  final int episodeIndex;
  final int positionMs;

  double get positionSeconds => positionMs / 1000;
}

/// 续播决策（对照仓 Watching.ResumePlayback.progress）：
/// 云端较新用云端；时间相同优先本机；用户明确点账号历史时优先云端。
HongguoResumeDecision decideHongguoResume({
  WatchEntry? local,
  HongguoCloudHistoryItem? cloud,
  bool preferCloud = false,
}) {
  if (local == null && cloud == null) {
    return const HongguoResumeDecision(source: HongguoResumeSource.none);
  }
  if (cloud == null) {
    return HongguoResumeDecision(
      source: HongguoResumeSource.local,
      episodeIndex: local!.episode,
      positionMs: (local.position * 1000).round(),
    );
  }
  if (local == null || preferCloud) {
    return HongguoResumeDecision(
      source: HongguoResumeSource.cloud,
      episodeIndex: cloud.episodeIndex,
      positionMs: cloud.positionMs,
    );
  }
  final localMs = local.updatedAt.millisecondsSinceEpoch;
  if (cloud.updatedAtMs > localMs) {
    return HongguoResumeDecision(
      source: HongguoResumeSource.cloud,
      episodeIndex: cloud.episodeIndex,
      positionMs: cloud.positionMs,
    );
  }
  return HongguoResumeDecision(
    source: HongguoResumeSource.local,
    episodeIndex: local.episode,
    positionMs: (local.position * 1000).round(),
  );
}

// ---------------------------------------------------------------- 上传队列

class HongguoCloudProgressItem {
  const HongguoCloudProgressItem({
    required this.accountId,
    required this.seriesId,
    required this.itemId,
    required this.episodeIndex,
    required this.episodeCount,
    required this.progressMs,
    required this.totalMs,
    required this.updatedAtMs,
    this.attempts = 0,
  });

  factory HongguoCloudProgressItem.fromJson(Map<String, dynamic> json) =>
      HongguoCloudProgressItem(
        accountId: json['accountId'] as String? ?? '',
        seriesId: json['seriesId']?.toString() ?? '',
        itemId: json['itemId']?.toString() ?? '',
        episodeIndex: intValue(json['episodeIndex']),
        episodeCount: intValue(json['episodeCount']),
        progressMs: intValue(json['progressMs']),
        totalMs: intValue(json['totalMs']),
        updatedAtMs: intValue(json['updatedAtMs']),
        attempts: intValue(json['attempts']),
      );

  final String accountId;
  final String seriesId;
  final String itemId;
  final int episodeIndex;
  final int episodeCount;
  final int progressMs;
  final int totalMs;
  final int updatedAtMs;
  final int attempts;

  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'seriesId': seriesId,
    'itemId': itemId,
    'episodeIndex': episodeIndex,
    'episodeCount': episodeCount,
    'progressMs': progressMs,
    'totalMs': totalMs,
    'updatedAtMs': updatedAtMs,
    'attempts': attempts,
  };

  Map<String, dynamic> toBridgeJson() => {
    'seriesId': seriesId,
    'itemId': itemId,
    'episodeIndex': episodeIndex,
    'episodeCount': episodeCount,
    'progressMs': progressMs,
    'totalMs': totalMs,
    'updatedAtMs': updatedAtMs,
  };

  HongguoCloudProgressItem withAttempt() => HongguoCloudProgressItem(
    accountId: accountId,
    seriesId: seriesId,
    itemId: itemId,
    episodeIndex: episodeIndex,
    episodeCount: episodeCount,
    progressMs: progressMs,
    totalMs: totalMs,
    updatedAtMs: updatedAtMs,
    attempts: attempts + 1,
  );
}

const hongguoCloudUploadQueueKey = 'hongguoCloudUploadQueue';

/// 云端进度上传队列：播完 / 切集 / 退出时攒着发。
/// 单条最多发 3 次，失败留在队里等下一次 drain；换号时旧账号的
/// 旧队列整批丢弃（按 accountId + generation 双重判定）。
class HongguoCloudUploadQueue {
  HongguoCloudUploadQueue({
    required this.repository,
    required this.preferences,
    required this.accountId,
    required this.generation,
  });

  final AppRepository repository;
  final SharedPreferences preferences;
  final String accountId;
  final int generation;

  static const int maxAttemptsPerItem = 3;

  List<HongguoCloudProgressItem> get pending => _load();

  List<HongguoCloudProgressItem> _load() {
    final raw = preferences.getString(hongguoCloudUploadQueueKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final row in decoded)
          if (row is Map)
            HongguoCloudProgressItem.fromJson(
              Map<String, dynamic>.from(row),
            ),
      ].where((item) => item.accountId == accountId).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _save(List<HongguoCloudProgressItem> items) async {
    await preferences.setString(
      hongguoCloudUploadQueueKey,
      jsonEncode([for (final item in items) item.toJson()]),
    );
  }

  /// 入队并立刻试发一次；未登录或账号为空时直接丢弃，不攒旧账。
  Future<void> enqueue(HongguoCloudProgressItem item) async {
    if (accountId.isEmpty || item.accountId != accountId) return;
    final items = _load();
    final deduped = [
      for (final old in items)
        if (old.seriesId != item.seriesId ||
            old.episodeIndex != item.episodeIndex)
          old,
      item,
    ];
    await _save(deduped);
    await drain();
  }

  /// 顺序发队里全部条目；单条失败记一次尝试，满 3 次才丢弃。
  /// 换号后 generation 变化时调用方应重建队列，旧队不再 drain。
  Future<void> drain({int? generation}) async {
    if (generation != null && generation != this.generation) return;
    if (accountId.isEmpty) return;
    var items = _load();
    while (items.isNotEmpty) {
      final head = items.first;
      try {
        await repository.hongguoAccountUploadProgress(head.toBridgeJson());
        items = items.sublist(1);
        await _save(items);
      } catch (_) {
        final retried = head.withAttempt();
        if (retried.attempts >= maxAttemptsPerItem) {
          items = items.sublist(1);
        } else {
          items = [retried, ...items.sublist(1)];
        }
        await _save(items);
        return;
      }
    }
  }

  Future<void> discardAll() async {
    await preferences.remove(hongguoCloudUploadQueueKey);
  }
}

// ---------------------------------------------------------------- 预约按钮

/// 相关季“预约”按钮：只对未上线季显示；写后读回确认才显示“已预约”，
/// 只拿到写确认时显示“已提交，待账号列表确认”。
class HongguoReserveButton extends StatefulWidget {
  const HongguoReserveButton({
    super.key,
    required this.repository,
    required this.accountStore,
    required this.seriesId,
    this.label = '预约',
  });

  final AppRepository repository;
  final HongguoAccountStore accountStore;
  final String seriesId;
  final String label;

  @override
  State<HongguoReserveButton> createState() => _HongguoReserveButtonState();
}

class _HongguoReserveButtonState extends State<HongguoReserveButton> {
  bool _busy = false;
  bool _confirmed = false;
  bool _submitted = false;
  String? _error;

  Future<void> _reserve() async {
    if (!widget.accountStore.loggedIn) {
      setState(() => _error = '请先登录红果账号');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await HongguoCloudRecords(
        widget.repository,
      ).reserve(widget.seriesId);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _confirmed = result.confirmed;
        _submitted = result.requested && !result.confirmed;
        if (!result.requested) _error = '预约未提交成功，请重试';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_confirmed) {
      return const Chip(label: Text('已预约'));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton(
          onPressed: _busy ? null : _reserve,
          child: Text(
            _busy
                ? '提交中…'
                : _submitted
                ? '已提交，待确认'
                : widget.label,
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 记录页

/// 本机与账号记录分开展示的记录页。
/// 未登录时账号区只显示登录提示，不拿本机数据冒充账号数据。
class HongguoCloudRecordsView extends StatefulWidget {
  const HongguoCloudRecordsView({
    super.key,
    required this.repository,
    required this.accountStore,
    required this.store,
    this.onOpenDrama,
    this.onResumeCloud,
  });

  final AppRepository repository;
  final HongguoAccountStore accountStore;
  final LocalStore store;
  final void Function(Drama drama)? onOpenDrama;
  final void Function(HongguoCloudHistoryItem item)? onResumeCloud;

  @override
  State<HongguoCloudRecordsView> createState() =>
      _HongguoCloudRecordsViewState();
}

class _HongguoCloudRecordsViewState extends State<HongguoCloudRecordsView> {
  late final HongguoCloudRecords _records = HongguoCloudRecords(
    widget.repository,
  );
  List<HongguoCloudFavorite>? _cloudFavorites;
  List<HongguoCloudHistoryItem>? _cloudHistory;
  List<HongguoCloudReservation>? _onlineReservations;
  List<HongguoCloudReservation>? _offlineReservations;
  bool _loading = false;
  String? _error;

  bool get _loggedIn => widget.accountStore.loggedIn;

  @override
  void initState() {
    super.initState();
    if (_loggedIn) _refresh();
  }

  Future<void> _refresh() async {
    if (!_loggedIn) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final favorites = await _records.fetchFavorites();
      final history = await _records.fetchHistory();
      final online = await _records.fetchReservations(online: true);
      final offline = await _records.fetchReservations(online: false);
      if (!mounted) return;
      setState(() {
        _cloudFavorites = favorites;
        _cloudHistory = history;
        _onlineReservations = online;
        _offlineReservations = offline;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final localFavorites = widget.store.favorites
        .where((drama) => drama.source == 'hongguo')
        .toList();
    final localHistory = widget.store.history
        .where((entry) => entry.drama.source == 'hongguo')
        .toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionTitle('本机收藏（${localFavorites.length}）'),
        if (localFavorites.isEmpty)
          const Text('本机暂无红果收藏')
        else
          for (final drama in localFavorites)
            ListTile(
              title: Text(drama.title),
              onTap: () => widget.onOpenDrama?.call(drama),
            ),
        const SizedBox(height: 16),
        _sectionTitle('账号收藏'),
        if (!_loggedIn)
          _loginHint()
        else if (_loading && _cloudFavorites == null)
          const LinearProgressIndicator()
        else if ((_cloudFavorites ?? const []).isEmpty)
          const Text('账号暂无收藏')
        else
          for (final item in _cloudFavorites ?? const [])
            ListTile(
              title: Text(item.title),
              subtitle: item.badge.isEmpty ? null : Text(item.badge),
              onTap: () => widget.onOpenDrama?.call(
                Drama(id: item.seriesId, source: 'hongguo', title: item.title),
              ),
            ),
        const SizedBox(height: 16),
        _sectionTitle('本机历史（${localHistory.length}）'),
        if (localHistory.isEmpty)
          const Text('本机暂无观看记录')
        else
          for (final entry in localHistory)
            ListTile(
              title: Text(entry.drama.title),
              subtitle: Text('第 ${entry.episode} 集'),
              onTap: () => widget.onOpenDrama?.call(entry.drama),
            ),
        const SizedBox(height: 16),
        _sectionTitle('云端历史'),
        if (!_loggedIn)
          _loginHint()
        else if (_loading && _cloudHistory == null)
          const LinearProgressIndicator()
        else if ((_cloudHistory ?? const []).isEmpty)
          const Text('云端暂无观看记录')
        else
          for (final item in _cloudHistory ?? const [])
            ListTile(
              title: Text(item.title),
              subtitle: Text(
                '第 ${item.episodeIndex + 1} 集 · ${item.positionSeconds.round()} 秒',
              ),
              trailing: const Icon(Icons.cloud_done_outlined),
              onTap: () => widget.onResumeCloud?.call(item),
            ),
        const SizedBox(height: 16),
        _sectionTitle('预约 · 已上线'),
        if (!_loggedIn)
          _loginHint()
        else if ((_onlineReservations ?? const []).isEmpty)
          const Text('已上线预约暂无')
        else
          for (final item in _onlineReservations ?? const [])
            ListTile(
              title: Text(item.title),
              subtitle: item.badge.isEmpty ? null : Text(item.badge),
              onTap: item.isPlayable
                  ? () => widget.onOpenDrama?.call(
                      Drama(
                        id: item.seriesId,
                        source: 'hongguo',
                        title: item.title,
                      ),
                    )
                  : null,
            ),
        const SizedBox(height: 16),
        _sectionTitle('预约 · 待上线'),
        if (!_loggedIn)
          _loginHint()
        else if ((_offlineReservations ?? const []).isEmpty)
          const Text('待上线预约暂无')
        else
          for (final item in _offlineReservations ?? const [])
            ListTile(
              title: Text(item.title),
              subtitle: Text(
                item.badge.isEmpty ? '待上线，只有预约项，不可播放' : item.badge,
              ),
            ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '云端记录拉取失败：$_error',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_loggedIn)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton(
              onPressed: _loading ? null : _refresh,
              child: const Text('刷新云端记录'),
            ),
          ),
      ],
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
  );

  Widget _loginHint() => const ListTile(
    leading: Icon(Icons.account_circle_outlined),
    title: Text('未登录红果账号'),
    subtitle: Text('登录后这里显示账号收藏、云端历史与预约'),
  );
}
