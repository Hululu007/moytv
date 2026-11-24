import 'dart:async';

import 'actress_database.dart';
import 'actress_models.dart';
import 'actress_roster_sources.dart';
import 'actress_site_crawl.dart';

/// 同步进度：只含数字与阶段，不含任何来源名（界面不显示来源）。
/// [detail] 是当前阶段的真实进度文案（如爬虫腿的“现爬 中文字幕
/// （2/10）第 3 页 · 1234 条”），横幅优先显示它；空时横幅回落到
/// 阶段名 + done/total。
class ActressSyncProgress {
  const ActressSyncProgress({
    required this.phase,
    required this.sourceIndex,
    required this.sourceCount,
    required this.done,
    required this.total,
    required this.failed,
    required this.running,
    this.detail = '',
  });

  /// 'roster' | 'films' | 'ranking' | 'done' | 'idle'。
  final String phase;
  final int sourceIndex;
  final int sourceCount;

  /// 本阶段已完成单位数（页数/人数）；total 为 0 表示总量未知。
  final int done;
  final int total;
  final int failed;
  final bool running;

  /// 真实进度文案（爬虫腿现爬分类/页/条数）；空表示没有更细的信息。
  final String detail;

  String get phaseLabel => switch (phase) {
    'roster' => '同步名册',
    'films' => '同步作品',
    'ranking' => '同步排行',
    'done' => '同步完成',
    _ => '准备同步',
  };

  static const idle = ActressSyncProgress(
    phase: 'idle',
    sourceIndex: 0,
    sourceCount: 0,
    done: 0,
    total: 0,
    failed: 0,
    running: false,
  );
}

/// 同步结果：供列表页横幅与手动刷新后提示用。
class ActressSyncResult {
  const ActressSyncResult({
    required this.persons,
    required this.works,
    required this.failedSources,
    required this.cancelled,
    this.budgetExpired = false,
  });

  final int persons;
  final int works;
  final List<ActressRosterSourceId> failedSources;
  final bool cancelled;

  /// 本轮是否因阶段总预算到时停下（不是用户取消）：断点已记，
  /// 下次继续跑，未跑完的人仍在待取清单里。
  final bool budgetExpired;

  bool get hasFailures => failedSources.isNotEmpty;
}

/// 取消中断：在途取数不等它超时、立刻停等（见 [_raceCancel]）。
/// 只表示“不等了”，底层的取数 future 本身停不下来（Dart future
/// 不可撤），它的结果被丢弃、不再写库。
class _SyncCancelled implements Exception {
  const _SyncCancelled();

  @override
  String toString() => '同步已取消';
}

/// 一次性修复检查点的阶段名：每源一条，修复跑完即记完成。
const _filmsRepairPhase = 'films_repair_v1';

/// 一次性全量同步服务：名册 + 全部作品清单存本地，断点续跑。
///
/// - 顺序：潮流 → whos（潮流最可靠，先落库为合并打底；MissAV
///   已从同步移除，不再拉取）；
/// - 每源三阶段：名册 → 作品 → 排行（排行主链 whos 日榜，开关
///   已开，名次写入 whos_rank 列；MissAV 排行的旧名次仍留在
///   missav_rank 列，显示时作回落）；
/// - 断点：名册/排行记下一页页码，作品记已完成人物（整人取完再记点，
///   失败重取靠 upsert 幂等，不会重复入库）；
/// - 空作品清单不是成功：拉回空列表记失败等刷新补，绝不记 ok；
/// - 一次性修复：已记 ok 但作品为 0 的人（旧版空结果记 ok 的中毒
///   状态），修复检查点未完成时重取一次，跑完即记完成；
/// - 单源整体失败（被盾挡、域名不通）只记失败，不拖垮其余源；
///   MissAV 已从同步移除（2026-11-20 用户手机侧实况：MissAV
///   爬不了，站没死、是 Cloudflare 403 被盾挡；MissAV 的内容以
///   mjv json 兜底为主，不把同步成败押在 MissAV 直爬上）；
/// - 手动刷新（refresh: true）重拉名册与排行拾取新人/新名次，作品
///   只补未完成与失败的人物，永不全量重拉；
/// - 打开模块只读本地；同步只在用户点了刷新/重试、或检测到新版
///   json 时才跑（2026-11-20 用户令：不自动爬取网站），绝不在
///   打开演员库时自动起爬、后台自动续爬；触发的闸在列表页，不在
///   本服务里（本服务只管跑起来以后的事）；
/// - 并发（2026-11-20 用户令：爬取必须多进程/多并发，不许单进程
///   顺序爬；数字写死在代码里）：两源并行跑（源与源之间不互相等，
///   一个慢源不拖垮整轮）；名册阶段 3 个取页工人并行取页
///   （rosterPageConcurrency）；排行阶段每 2 页一组并行取、按页
///   顺序提交、名次不错位（rankingPageConcurrency）；作品阶段
///   4 个工人（filmsConcurrency，潮流源走爬虫腿时由爬虫服务的
///   3 个分类工人并行爬分类）；在途请求有界：每源每阶段不超过
///   对应工人数，两源并行时全轮在途不超过 8 路、每站不超过 4 路；
///   失败重试是各工人自己的事（_withRetry 最多 3 次、600ms 起
///   指数退避），不堵住其他工人；作品旧路按页重试（2026-11-24
///   同步卡顿修复：一页失败只重试这一页，不把整人全部页重取；
///   旧的整人重试是一页失败就把整人多页全重取 3 遍，作品多的
///   演员单人最坏 300 秒以上）；名册按名合并是读-改-写，入库
///   写操作串在一条互斥链上（取页仍并行），不并出重名。
/// - 取消真中断（2026-11-24 同步卡顿修复）：cancel() 完成一次
///   run 内有效的取消信号，在途取数用 [_raceCancel] 与信号竞跑，
///   点取消后不等在途单元超时（最长 70 秒 py 调用、140 秒补流）
///   立刻停等；在途请求本身停不下来，只是不再等它，结果丢弃
///   不写库；重试退避的等待同样可撤。
/// - 进度（2026-11-24 同步卡顿修复）：名册每存一人、作品每取一页
///   都报一次真实 detail（面板 600ms 轮询看到的数字会动）；名册/
///   排行取页单元最长 60–135 秒无新进度时，每秒发一次“第 X 页
///   取数中，已等 N 秒”心跳，只报存活、不伪造进度。
/// - 阶段总预算（2026-11-24 同步卡顿修复）：作品阶段一轮最多
///   [filmsPhaseBudget]（默认 60 分钟），到时停下、断点记未完成，
///   下次继续跑，不把一轮拖成几小时到几天；爬虫腿走同一预算。
class ActressSyncService {
  ActressSyncService({
    required this.db,
    required this.sources,
    required this.fetch,
    this.filmsConcurrency = 4,
    this.maxAttempts = 3,
    this.crawlService,
    this.filmsPhaseBudget = const Duration(minutes: 60),
  });

  /// 名册阶段取页工人数（页与页之间并行；页码靠 hasMore 探知，
  /// 工人从共享计数器领页号，某页报无更多时不再领新页）。
  static const rosterPageConcurrency = 3;

  /// 排行阶段并行取页的窗口大小（每组并行取，提交时按页顺序，
  /// 名次按提交顺序写，不错位）。
  static const rankingPageConcurrency = 2;

  final ActressDatabase db;
  final List<ActressRosterSource> sources;
  final ActressHttpFetch fetch;
  final int filmsConcurrency;
  final int maxAttempts;

  /// 作品阶段一轮的总预算：到时停下记断点，下次继续跑。
  final Duration filmsPhaseBudget;

  /// 潮流源作品阶段的爬虫腿（不传时潮流作品走旧的逐人取流；
  /// 列表页必传——同步作品改为爬虫逻辑就靠它）。
  final ActressSiteCrawlService? crawlService;

  final _progressController = StreamController<ActressSyncProgress>.broadcast();

  Stream<ActressSyncProgress> get progress => _progressController.stream;

  bool _running = false;
  bool _cancelled = false;

  /// 本轮是否因作品阶段总预算到时停下（不是用户取消）。
  bool _budgetExpired = false;

  /// 一次 run() 内有效的取消信号：cancel() 完成它，[_raceCancel]
  /// 听到就立刻停等。run 开始时重建，跑完不复用。
  Completer<void>? _cancelSignal;

  Future<ActressSyncResult>? _currentRun;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  /// 名册入库互斥链：按名合并是读-改-写，多工人并行取页时，
  /// 入库写操作串在这条链上依次跑，不并出重名；取页本身不串。
  Future<void> _rosterWriteQueue = Future.value();

  Future<T> _withRosterWriteLock<T>(Future<T> Function() action) {
    final run = _rosterWriteQueue.then((_) => action());
    // 链上一次写失败不能毒死整条队列：错误仍经 run 抛给调用方
    // （工人按人 catch），但队列本身回到已完成态，下一次写照常跑。
    // 旧写法 `_rosterWriteQueue = run.then((_) {})` 会把错误传进链里，
    // 此后所有名册入库直接跳过 action、静默丢数据（2026-11-24
    // 同步卡顿顺查发现：一次写库失败后同步照常走进度、但再无新人入库）。
    _rosterWriteQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  bool get isRunning => _running;

  void cancel() {
    _cancelled = true;
    // 完成本次 run 的取消信号：在途的取数听到就立刻停等，不用
    // 等它超时；信号只完成一次，重复点取消不抛错。
    final signal = _cancelSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
    // 取消透传给爬虫腿：同步停了，现爬也要停，不留后台继续爬。
    crawlService?.cancel();
  }

  /// 等一个取数 future，但取消时不等它超时、立刻抛 [_SyncCancelled]。
  /// 底层的取数本身停不下来（Dart future 不可撤）：竞跑输了的那
  /// 一方结果被丢弃——取数晚回来时它的完成/错误回调都已挂上，
  /// 不会变成未处理异常；写库在 await 之后，抛错即跳过，不写库。
  Future<T> _raceCancel<T>(Future<T> future) {
    if (_cancelled) throw const _SyncCancelled();
    final signal = _cancelSignal;
    if (signal == null) return future;
    final completer = Completer<T>();
    var settled = false;
    future.then(
      (value) {
        if (!settled) {
          settled = true;
          completer.complete(value);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!settled) {
          settled = true;
          completer.completeError(error, stack);
        }
      },
    );
    // 取消信号只完成一次；没取消时这个监听永不触发，run 结束
    // 信号被替换后随旧信号一起回收。
    unawaited(
      signal.future.then((_) {
        if (!settled) {
          settled = true;
          completer.completeError(const _SyncCancelled());
        }
      }),
    );
    return completer.future;
  }

  void dispose() {
    _progressController.close();
  }

  /// 跑一次同步。已在跑时返回同一份结果（不重复跑）。
  Future<ActressSyncResult> run({bool refresh = false}) {
    final current = _currentRun;
    if (current != null) return current;
    final run = _run(refresh: refresh);
    _currentRun = run;
    return run.whenComplete(() {
      _currentRun = null;
    });
  }

  Future<ActressSyncResult> _run({required bool refresh}) async {
    _running = true;
    _cancelled = false;
    _budgetExpired = false;
    _cancelSignal = Completer<void>();
    try {
      // 两源并行：源与源之间不互相等，一个慢源不把整轮拖成串行；
      // 各源的三阶段仍按名册→作品→排行顺序跑；单源失败只记进
      // failedSources，不拖垮其余源。
      final results = await Future.wait([
        for (var i = 0; i < sources.length; i++)
          _syncSourceGuarded(sources[i], sourceIndex: i + 1, refresh: refresh),
      ]);
      final failedSources = <ActressRosterSourceId>[
        for (var i = 0; i < sources.length; i++)
          if (results[i]) sources[i].id,
      ];
      final overview = await db.overview();
      _emit(
        ActressSyncProgress(
          phase: 'done',
          sourceIndex: sources.length,
          sourceCount: sources.length,
          done: overview.persons,
          total: overview.persons,
          failed: failedSources.length,
          running: false,
        ),
        force: true,
      );
      return ActressSyncResult(
        persons: overview.persons,
        works: overview.works,
        failedSources: failedSources,
        cancelled: _cancelled,
        budgetExpired: _budgetExpired,
      );
    } finally {
      _running = false;
    }
  }

  /// 单源三阶段，包一层兜底：阶段里没接住的异常只记该源失败，
  /// 不掀翻整轮（其余源继续跑完）。
  Future<bool> _syncSourceGuarded(
    ActressRosterSource source, {
    required int sourceIndex,
    required bool refresh,
  }) async {
    try {
      return await _syncSource(source, sourceIndex: sourceIndex, refresh: refresh);
    } catch (_) {
      return true;
    }
  }

  /// 单源三阶段。返回 true 表示该源有阶段整体失败。
  Future<bool> _syncSource(
    ActressRosterSource source, {
    required int sourceIndex,
    required bool refresh,
  }) async {
    var failed = false;
    if (!await _syncRosterPhase(source, sourceIndex, refresh)) {
      failed = true;
    }
    if (_cancelled) return failed;
    await _syncFilmsPhase(source, sourceIndex);
    if (_cancelled) return failed;
    if (!await _syncRankingPhase(source, sourceIndex, refresh)) {
      failed = true;
    }
    return failed;
  }

  Future<T> _withRetry<T>(Future<T> Function() action) async {
    var attempt = 0;
    while (true) {
      try {
        return await action();
      } catch (_) {
        attempt++;
        if (attempt >= maxAttempts || _cancelled) rethrow;
        // 退避等待也可撤：取消时不等完这几百毫秒。
        await _raceCancel(
          Future<void>.delayed(Duration(milliseconds: 600 * attempt)),
        );
      }
    }
  }

  /// 名册阶段（3 个取页工人并行取页，rosterPageConcurrency）。
  /// 页码靠 hasMore 探知：工人从共享计数器领页号，某页报无更多
  /// （或空页）时不再领新页；已领到手的页取完照常入库（真实数据，
  /// 不丢）。断点只记“最早没完成的页”（重跑时从最早缺口续爬，
  /// 已完成的页靠 upsert 幂等不重复入库）。单人入库写操作串在
  /// 互斥链上（取页并行、写库串行），不并出重名；单页异常只记
  /// 该页失败，不掀翻其他工人。
  Future<bool> _syncRosterPhase(
    ActressRosterSource source,
    int sourceIndex,
    bool refresh,
  ) async {
    final checkpoint = await db.checkpoint(source.id, 'roster');
    if (!refresh && checkpoint != null && checkpoint.finished) return true;
    var startPage = 1;
    if (!refresh && checkpoint != null) {
      startPage = int.tryParse(checkpoint.cursor) ?? 1;
      if (startPage < 1) startPage = 1;
    }
    var stored = 0;
    if (!refresh && checkpoint != null) stored = checkpoint.total;
    var nextPage = startPage;
    var stopPage = -1;
    final completed = <int>{};
    var pagesDone = 0;
    var failed = 0;
    String? phaseError;

    Future<void> worker() async {
      while (!_cancelled) {
        // 领页：已有页报无更多时，不再领比它大的页。
        final page = nextPage;
        if (stopPage >= 0 && page > stopPage) return;
        nextPage++;
        ActressRosterPage result;
        try {
          // 取消时不等这页取完（最坏 3 次重试 × 45 秒）立刻停等。
          result = await _raceCancel(
            _withRetry(() => source.fetchRosterPage(page, fetch: fetch)),
          );
        } on _SyncCancelled {
          return;
        } catch (error) {
          // 取消竞跑赢了但信号还没来得及置位时同样直接停，
          // 不把取消记成页失败。
          if (_cancelled) return;
          // 单页取失败（重试 3 次仍失败）：记失败，不再领新页，
          // 其他工人把手头的页跑完就停；本页下次断点续跑。
          failed++;
          phaseError ??= error.toString();
          stopPage = page;
          continue;
        }
        var pageStored = 0;
        for (final person in result.persons) {
          try {
            await _withRosterWriteLock(() => db.upsertRosterPerson(person));
            pageStored++;
          } catch (_) {
            // 单人入库失败只跳过这一个人，不掀翻整页。
          }
          // 每存一人报一次：慢站取一页要几十秒时，面板在存库
          // 期间也能看到数字在走。不走 _emit 的 300ms 限流：
          // 存库是成批爆发的（几人连续入库），限流会把整批
          // “已存”全吞掉，面板反而看不到存库进度；面板本身
          // 600ms 才轮询一次，多报几条无害。
          _emit(
            ActressSyncProgress(
              phase: 'roster',
              sourceIndex: sourceIndex,
              sourceCount: sources.length,
              done: pagesDone,
              total: 0,
              failed: failed,
              running: true,
              detail: '第 $page 页 · 已存 ${stored + pageStored} 人',
            ),
            force: true,
          );
        }
        stored += pageStored;
        completed.add(page);
        pagesDone++;
        _emit(
          ActressSyncProgress(
            phase: 'roster',
            sourceIndex: sourceIndex,
            sourceCount: sources.length,
            done: pagesDone,
            total: 0,
            failed: failed,
            running: true,
          ),
        );
        if (!result.hasMore || result.persons.isEmpty) {
          // 该页就是最后一页：比它大的页号都不用再取。
          if (stopPage < 0 || page < stopPage) stopPage = page;
        }
        // 断点写最早缺口：重跑从缺口续爬，不丢已完成的页。
        var cursor = startPage;
        while (completed.contains(cursor)) {
          cursor++;
        }
        if (stopPage >= 0 && cursor > stopPage) cursor = stopPage + 1;
        await db.saveCheckpoint(
          ActressSyncCheckpoint(
            source: source.id.name,
            phase: 'roster',
            cursor: '$cursor',
            total: stored,
            finished: false,
          ),
        );
      }
    }

    // 取数心跳：单页最坏 3 次重试 × 45 秒无新进度时，面板每秒
    // 刷新一次“第 X 页取数中，已等 N 秒”，只报存活、不伪造进度；
    // 阶段一结束就停，不留定时器。
    final phaseStarted = DateTime.now();
    final heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_cancelled) return;
      _emit(
        ActressSyncProgress(
          phase: 'roster',
          sourceIndex: sourceIndex,
          sourceCount: sources.length,
          done: pagesDone,
          total: 0,
          failed: failed,
          running: true,
          detail:
              '第 ${pagesDone + 1} 页取数中，已等 '
              '${DateTime.now().difference(phaseStarted).inSeconds} 秒',
        ),
      );
    });
    final workers = List.generate(
      rosterPageConcurrency,
      (_) => worker(),
    );
    try {
      await Future.wait(workers);
    } finally {
      heartbeat.cancel();
    }
    final finished = !_cancelled && phaseError == null && stopPage >= 0;
    if (finished) {
      await db.saveCheckpoint(
        ActressSyncCheckpoint(
          source: source.id.name,
          phase: 'roster',
          cursor: '${stopPage + 1}',
          total: stored,
          finished: true,
        ),
      );
      return true;
    }
    // 没跑完：断点留在最早缺口（worker 里每页已写过一次，
    // 这里再写一次收口，保证取消/失败后游标是最早缺口）。
    var cursor = startPage;
    while (completed.contains(cursor)) {
      cursor++;
    }
    await db.saveCheckpoint(
      ActressSyncCheckpoint(
        source: source.id.name,
        phase: 'roster',
        cursor: '$cursor',
        total: stored,
        finished: false,
        error: phaseError ?? '',
      ),
    );
    return false;
  }

  Future<void> _syncFilmsPhase(
    ActressRosterSource source,
    int sourceIndex,
  ) async {
    // 潮流源作品阶段改走爬虫腿（2026-11-20 用户令：同步改为爬虫
    // 逻辑）：不再逐人调 films 接口，调现爬服务按分类爬 mjv，
    // 爬到的数据先落单文件 mjv011.json、再进库镜像；进度用爬虫
    // 的真实分类/页/条数显示。没接爬虫服务时回落旧的逐人取流。
    if (source.id == ActressRosterSourceId.chaoliu &&
        crawlService != null) {
      await _syncCrawlFilmsPhase(source, sourceIndex);
      return;
    }
    // 一次性修复（films_repair_v1）：旧版把空结果记成 ok，中毒的人
    // 作品为 0 却永不再取；修复检查点未完成时，把这类人并入本次
    // 待取清单重取一次，阶段跑完即记完成（取消时不记，下次继续修）。
    final repairCheckpoint = await db.checkpoint(
      source.id,
      _filmsRepairPhase,
    );
    final repairOpen = repairCheckpoint == null || !repairCheckpoint.finished;
    var pending = await db.personsPendingFilms(source.id);
    var repairCount = 0;
    if (repairOpen) {
      final repair = await db.personsNeedingFilmsRepair(source.id);
      if (repair.isNotEmpty) {
        final seen = <int>{for (final person in pending) person.localId};
        final merged = [...pending];
        for (final person in repair) {
          if (seen.add(person.localId)) {
            merged.add(person);
            repairCount++;
          }
        }
        merged.sort((a, b) => a.localId.compareTo(b.localId));
        pending = merged;
      }
    }
    if (pending.isEmpty) {
      await db.saveCheckpoint(
        ActressSyncCheckpoint(
          source: source.id.name,
          phase: 'films',
          finished: true,
        ),
      );
      if (repairOpen) await _saveRepairCheckpoint(source, repairCount);
      return;
    }
    final progress = await db.filmsProgress(source.id);
    final total = progress.total;
    // 修复候选人已计入已完成数，重取期间先扣掉，进度不超总数。
    var done = progress.done - repairCount;
    var failed = 0;
    var nextIndex = 0;
    var lastCompletedId = 0;
    // 阶段总预算：本阶段一轮最多 filmsPhaseBudget，到时停下、
    // 断点记未完成，下次继续跑，不把一轮拖成几小时到几天。
    final deadline = DateTime.now().add(filmsPhaseBudget);

    Future<void> worker() async {
      while (!_cancelled) {
        // 预算到时停下：不领新人，断点留在最后完成的人。
        if (DateTime.now().isAfter(deadline)) {
          _budgetExpired = true;
          return;
        }
        if (nextIndex >= pending.length) return;
        final person = pending[nextIndex++];
        // 单人异常绝不掀翻工人：取流/写库抛错只记这一个人失败，
        // 继续下一个人（旧版这里没兜底，catch 里再写库一旦抛错，
        // 整个工人死掉、Future.wait 抛错、整轮同步悄悄停掉，
        // 横幅冻在最后一次进度——12:45 截图 4612/5403 冻住的
        // 疑似链路之一）。
        var ok = false;
        try {
          ok = await _syncOnePersonFilms(
            source,
            person,
            deadline: deadline,
            // 每取完一页报一次：作品多的演员单人要翻几十页时，
            // 面板能看到“某人 第 X 页 · 已取 N 部”在走，而不是
            // 几分钟只跳一个“已完成人数”。
            onPage: (page, films) {
              _emit(
                ActressSyncProgress(
                  phase: 'films',
                  sourceIndex: sourceIndex,
                  sourceCount: sources.length,
                  done: done,
                  total: total,
                  failed: failed,
                  running: true,
                  detail: '${person.displayName} 第 $page 页 · 已取 $films 部',
                ),
              );
            },
          );
        } catch (_) {
          ok = false;
        }
        if (ok) {
          done++;
          lastCompletedId = person.localId;
        } else {
          failed++;
        }
        _emit(
          ActressSyncProgress(
            phase: 'films',
            sourceIndex: sourceIndex,
            sourceCount: sources.length,
            done: done,
            total: total,
            failed: failed,
            running: true,
          ),
        );
      }
    }

    final workers = List.generate(
      filmsConcurrency < 1 ? 1 : filmsConcurrency,
      (_) => worker(),
    );
    await Future.wait(workers);
    final remaining = await db.personsPendingFilms(source.id);
    await db.saveCheckpoint(
      ActressSyncCheckpoint(
        source: source.id.name,
        phase: 'films',
        cursor: '$lastCompletedId',
        total: total,
        // 还有没跑完/失败的人，下次刷新继续补，不记完成；
        // 预算到时同样不记完成，下次从断点续跑。
        finished: remaining.isEmpty && !_cancelled && !_budgetExpired,
      ),
    );
    if (repairOpen && !_cancelled && !_budgetExpired) {
      await _saveRepairCheckpoint(source, repairCount);
    }
  }

  Future<void> _saveRepairCheckpoint(
    ActressRosterSource source,
    int repairCount,
  ) async {
    await db.saveCheckpoint(
      ActressSyncCheckpoint(
        source: source.id.name,
        phase: _filmsRepairPhase,
        total: repairCount,
        finished: true,
      ),
    );
  }

  /// 单人作品清单（2026-11-24 同步卡顿修复：按页取、按页重试）。
  ///
  /// 旧写法整人重试：`fetchFilms` 内部翻完全部页，一页失败就把
  /// 整人全部页重取 3 遍，作品多的演员单人最坏 300 秒以上、进度
  /// 几分钟不动；新写法每次只取一页，某一页 3 次重试仍失败时只
  /// 记这个人失败、不重取已取到的页，下次断点续跑再补这个人。
  /// 每取完一页调一次 [onPage]（页码，累计部数），面板按页推进。
  /// [deadline] 是本阶段总预算的截止点，到时停下（不记这个人失败，
  /// 下次继续）；取消时同样停下不等在途页取完。
  ///
  /// 跨轮边界：本轮只记“整人完成/失败”，不记“取到第几页”——
  /// 下次续跑失败的人从第 1 页重取（页内重试已保证单轮内不重复
  /// 拉已取到的页；入库 upsert 幂等，重取不重复入库）。
  static const maxFilmsPagesPerPerson = 5000;

  Future<bool> _syncOnePersonFilms(
    ActressRosterSource source,
    ActressPerson person, {
    required DateTime deadline,
    required void Function(int page, int films) onPage,
  }) async {
    final sourceId = person.sourceIdFor(source.id);
    if (sourceId.isEmpty) return true;
    final films = <RosterFilm>[];
    try {
      for (var page = 1; page <= maxFilmsPagesPerPerson; page++) {
        // 取消/预算到时：停下，不记这个人失败，下次继续。
        if (_cancelled) return false;
        if (DateTime.now().isAfter(deadline)) {
          _budgetExpired = true;
          return false;
        }
        late final List<RosterFilm> pageFilms;
        try {
          // 这一页单独重试 3 次：重试的只是这一页，已取到的页
          // 不重取；取消时不等这页超时立刻停等。
          pageFilms = await _raceCancel(
            _withRetry(
              () => source.fetchFilmsPage(sourceId, page, fetch: fetch),
            ),
          );
        } on _SyncCancelled {
          return false;
        } catch (_) {
          // 这一页 3 次重试仍失败：只记这个人失败，不重取已取到
          // 的页，下次断点续跑再补这个人。
          try {
            await db.markFilmsState(person.localId, source.id, ok: false);
          } catch (_) {
            // 写失败状态失败：下次刷新靠 films 检查点未完成继续补。
          }
          return false;
        }
        // 空页即到头（与旧 fetchFilms 的循环同义）。
        if (pageFilms.isEmpty) break;
        films.addAll(pageFilms);
        onPage(page, films.length);
      }
      if (films.isEmpty) {
        // 拉回来了但为空：不是成功，记失败等下次刷新补。空结果
        // 绝不能记 ok，否则断点与刷新永不再重取，中毒永久化。
        // 空判定放在重试之外：已拉回空结果，重试无意义。
        await db.markFilmsState(person.localId, source.id, ok: false);
        return false;
      }
      await db.upsertWorks(
        person.localId,
        films,
        coverSource: actressRosterCoverSource(source.id),
        site: source.id.name,
      );
      await db.markFilmsState(person.localId, source.id, ok: true);
      return true;
    } catch (_) {
      // 失败状态写库本身也可能抛错（多工人并发写库）：再兜一层，
      // 只记失败不抛错，不让失败路径掀翻工人。
      try {
        await db.markFilmsState(person.localId, source.id, ok: false);
      } catch (_) {
        // 写失败状态失败：下次刷新靠 films 检查点未完成继续补，
        // 不在这里抛错。
      }
      return false;
    }
  }

  /// 潮流源作品阶段的爬虫腿：调现爬服务按分类爬 mjv（10 分类 ×
  /// 每分类 50 页、断点续跑，爬虫服务内 3 个分类工人并行）。
  /// 爬到的视频行先落单文件 mjv011.json、再进库镜像（json-first，
  /// 库是派生索引）；进度直接透传爬虫的真实分类/页/条数
  /// （detail 字段），横幅一眼能看到爬了多少；跑完按结果写
  /// films 检查点（完成/未完成），取消时不记完成。
  Future<void> _syncCrawlFilmsPhase(
    ActressRosterSource source,
    int sourceIndex,
  ) async {
    final crawl = crawlService;
    if (crawl == null) return;
    final sub = crawl.progress.listen((crawlProgress) {
      // 透传不走 _emit 的 300ms 限流：爬虫腿本身逐条报进度
      // （每页/每条补流各一次），假源快跑时整轮不到 300ms，
      // 限流会把全部“现爬…”文案吞掉，面板在作品阶段看不到
      // 任何进度（与名册每存一人报数的 force:true 同一毛病）；
      // 面板本身 600ms 才轮询一次，多报几条无害。
      _emit(
        ActressSyncProgress(
          phase: 'films',
          sourceIndex: sourceIndex,
          sourceCount: sources.length,
          done: crawlProgress.items,
          total: 0,
          failed: 0,
          running: true,
          detail: crawlProgress.label,
        ),
        force: true,
      );
      if (_cancelled) crawl.cancel();
    });
    try {
      // 爬虫腿走作品阶段同一总预算：到时停下、断点记未完成，
      // 下次继续跑。
      await crawl.start(site: 'mjv', timeBudget: filmsPhaseBudget);
    } catch (_) {
      // 现爬内部已把失败写进 progress.error；这里不抛错，
      // films 检查点按未完成记，下次刷新断点续跑。
    } finally {
      await sub.cancel();
    }
    if (crawl.budgetExpired) _budgetExpired = true;
    final current = crawl.current;
    final done = current.done && current.error.isEmpty;
    await db.saveCheckpoint(
      ActressSyncCheckpoint(
        source: source.id.name,
        phase: 'films',
        cursor: '',
        total: current.items,
        finished: done && !_cancelled && !_budgetExpired,
      ),
    );
    if (done && !_cancelled && !_budgetExpired) {
      // 爬虫腿不产生逐人 films 状态，旧的逐人修复检查点一并
      // 收口（不留永远未完成的修复态）。
      await _saveRepairCheckpoint(source, 0);
    }
  }

  /// 排行阶段（每 rankingPageConcurrency 页一组并行取、按页顺序
  /// 提交）：名次按提交顺序写，取页并行、写名次串行，不错位。
  /// 某页取失败（重试 3 次仍失败）时本阶段失败，断点留在该页，
  /// 下次刷新续跑；已取到的页按顺序提交入库，不丢。
  Future<bool> _syncRankingPhase(
    ActressRosterSource source,
    int sourceIndex,
    bool refresh,
  ) async {
    final checkpoint = await db.checkpoint(source.id, 'ranking');
    if (!refresh && checkpoint != null && checkpoint.finished) return true;
    var page = 1;
    var ranked = 0;
    if (!refresh && checkpoint != null) {
      page = int.tryParse(checkpoint.cursor) ?? 1;
      if (page < 1) page = 1;
      ranked = checkpoint.total;
    }
    var failed = false;
    String? phaseError;
    // 取数心跳（与名册阶段同一口径）：一组并行取最坏 2 页 × 3 次
    // 重试 × 20 秒无新进度时，面板每秒刷新一次存活文案。
    final phaseStarted = DateTime.now();
    final heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_cancelled) return;
      _emit(
        ActressSyncProgress(
          phase: 'ranking',
          sourceIndex: sourceIndex,
          sourceCount: sources.length,
          done: page,
          total: 0,
          failed: 0,
          running: true,
          detail:
              '排行 第 $page 页取数中，已等 '
              '${DateTime.now().difference(phaseStarted).inSeconds} 秒',
        ),
      );
    });
    try {
      while (!_cancelled && !failed) {
        // 一组并行取（窗口内页码连续），取完按页顺序提交。
        final window = <int>[
          for (var i = 0; i < rankingPageConcurrency; i++) page + i,
        ];
        final results = await Future.wait([
          for (final p in window)
            _raceCancel(
                  _withRetry(() => source.fetchRankingPage(p, fetch: fetch)),
                )
                .then<({int page, ActressRosterPage result})>(
                  (r) => (page: p, result: r),
                )
                .catchError(
                  (Object e) => (page: -1, result: const ActressRosterPage(persons: [], hasMore: false)),
                  // 取消不记成页失败：直接抛给外层按取消收口。
                  test: (Object e) => e is! _SyncCancelled,
                ),
        ]);
        // 按页顺序提交：窗口里某页失败时，只提交它之前的页，
        // 失败页及之后的页下次续跑（已取到的后页结果丢弃重取，
        // 名次不错位）。
        var committedPages = 0;
        var lastPage = false;
        for (final entry in results) {
          if (entry.page < 0) {
            failed = true;
            phaseError ??= 'ranking page ${page + committedPages} 取失败';
            break;
          }
          final result = entry.result;
          for (var i = 0; i < result.persons.length; i++) {
            final stored = await _withRosterWriteLock(
              () => db.upsertRosterPerson(result.persons[i]),
            );
            if (stored != null) {
              // 名次写入各自的列：whos 写 whos_rank，其余源写
              // missav_rank（MissAV 已从同步移除，生产环境只剩
              // whos 写排行）。
              if (source.id == ActressRosterSourceId.whos) {
                await db.setWhosRank(stored.localId, ranked + i + 1);
              } else {
                await db.setMissavRank(stored.localId, ranked + i + 1);
              }
            }
          }
          ranked += result.persons.length;
          committedPages++;
          _emit(
            ActressSyncProgress(
              phase: 'ranking',
              sourceIndex: sourceIndex,
              sourceCount: sources.length,
              done: entry.page,
              total: 0,
              failed: 0,
              running: true,
            ),
          );
          if (!result.hasMore || result.persons.isEmpty) {
            lastPage = true;
            break;
          }
        }
        await db.saveCheckpoint(
          ActressSyncCheckpoint(
            source: source.id.name,
            phase: 'ranking',
            cursor: '${page + committedPages}',
            total: ranked,
            finished: false,
          ),
        );
        if (lastPage) {
          await db.saveCheckpoint(
            ActressSyncCheckpoint(
              source: source.id.name,
              phase: 'ranking',
              cursor: '${page + committedPages}',
              total: ranked,
              finished: true,
            ),
          );
          return true;
        }
        if (failed) break;
        page += committedPages;
      }
      if (failed) {
        await db.saveCheckpoint(
          ActressSyncCheckpoint(
            source: source.id.name,
            phase: 'ranking',
            cursor: '$page',
            total: ranked,
            finished: false,
            error: phaseError ?? '',
          ),
        );
      }
      return false;
    } on _SyncCancelled {
      // 取消：本组已提交的页检查点已在循环内写过，直接收口，
      // 不记成阶段失败、不写失败检查点。
      return false;
    } catch (error) {
      await db.saveCheckpoint(
        ActressSyncCheckpoint(
          source: source.id.name,
          phase: 'ranking',
          cursor: '$page',
          total: ranked,
          finished: false,
          error: error.toString(),
        ),
      );
      return false;
    } finally {
      heartbeat.cancel();
    }
  }

  void _emit(ActressSyncProgress progress, {bool force = false}) {
    if (_progressController.isClosed) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastEmit).inMilliseconds < 300) return;
    _lastEmit = now;
    _progressController.add(progress);
  }
}
