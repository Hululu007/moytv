import 'dart:async';

import 'actress_database.dart';
import 'actress_models.dart';
import 'actress_roster_sources.dart';

/// 同步进度：只含数字与阶段，不含任何来源名（界面不显示来源）。
class ActressSyncProgress {
  const ActressSyncProgress({
    required this.phase,
    required this.sourceIndex,
    required this.sourceCount,
    required this.done,
    required this.total,
    required this.failed,
    required this.running,
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
  });

  final int persons;
  final int works;
  final List<ActressRosterSourceId> failedSources;
  final bool cancelled;

  bool get hasFailures => failedSources.isNotEmpty;
}

/// 一次性修复检查点的阶段名：每源一条，修复跑完即记完成。
const _filmsRepairPhase = 'films_repair_v1';

/// 一次性全量同步服务：名册 + 全部作品清单存本地，断点续跑。
///
/// - 顺序：潮流 → whos → MissAV（潮流最可靠，先落库为合并打底）；
/// - 每源三阶段：名册 → 作品 → 排行（排行主链 MissAV；whos 日榜
///   作后备信号，开关打开时才拉，名次写入 whos_rank 列）；
/// - 断点：名册/排行记下一页页码，作品记已完成人物（整人取完再记点，
///   失败重取靠 upsert 幂等，不会重复入库）；
/// - 空作品清单不是成功：拉回空列表记失败等刷新补，绝不记 ok；
/// - 一次性修复：已记 ok 但作品为 0 的人（旧版空结果记 ok 的中毒
///   状态），修复检查点未完成时重取一次，跑完即记完成；
/// - 单源整体失败（被盾挡、域名不通）只记失败，不拖垮其余源；
/// - 手动刷新（refresh: true）重拉名册与排行拾取新人/新名次，作品
///   只补未完成与失败的人物，永不全量重拉；
/// - 打开模块只读本地；列表页在库空或没同步完时自动断点续跑，跑完
///   仍未完自动再续（有次数上限），手动点的也是断点续跑、不重拉。
class ActressSyncService {
  ActressSyncService({
    required this.db,
    required this.sources,
    required this.fetch,
    this.filmsConcurrency = 4,
    this.maxAttempts = 3,
  });

  final ActressDatabase db;
  final List<ActressRosterSource> sources;
  final ActressHttpFetch fetch;
  final int filmsConcurrency;
  final int maxAttempts;

  final _progressController = StreamController<ActressSyncProgress>.broadcast();

  Stream<ActressSyncProgress> get progress => _progressController.stream;

  bool _running = false;
  bool _cancelled = false;
  Future<ActressSyncResult>? _currentRun;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isRunning => _running;

  void cancel() {
    _cancelled = true;
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
    final failedSources = <ActressRosterSourceId>[];
    try {
      for (var i = 0; i < sources.length; i++) {
        if (_cancelled) break;
        final source = sources[i];
        final sourceFailed = await _syncSource(
          source,
          sourceIndex: i + 1,
          refresh: refresh,
        );
        if (sourceFailed) failedSources.add(source.id);
      }
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
      );
    } finally {
      _running = false;
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
        await Future<void>.delayed(Duration(milliseconds: 600 * attempt));
      }
    }
  }

  Future<bool> _syncRosterPhase(
    ActressRosterSource source,
    int sourceIndex,
    bool refresh,
  ) async {
    final checkpoint = await db.checkpoint(source.id, 'roster');
    if (!refresh && checkpoint != null && checkpoint.finished) return true;
    var page = 1;
    if (!refresh && checkpoint != null) {
      page = int.tryParse(checkpoint.cursor) ?? 1;
      if (page < 1) page = 1;
    }
    var stored = 0;
    try {
      while (!_cancelled) {
        final result = await _withRetry(
          () => source.fetchRosterPage(page, fetch: fetch),
        );
        for (final person in result.persons) {
          await db.upsertRosterPerson(person);
        }
        stored += result.persons.length;
        _emit(
          ActressSyncProgress(
            phase: 'roster',
            sourceIndex: sourceIndex,
            sourceCount: sources.length,
            done: page,
            total: 0,
            failed: 0,
            running: true,
          ),
        );
        if (!result.hasMore || result.persons.isEmpty) {
          await db.saveCheckpoint(
            ActressSyncCheckpoint(
              source: source.id.name,
              phase: 'roster',
              cursor: '${page + 1}',
              total: stored,
              finished: true,
            ),
          );
          return true;
        }
        await db.saveCheckpoint(
          ActressSyncCheckpoint(
            source: source.id.name,
            phase: 'roster',
            cursor: '${page + 1}',
            total: stored,
            finished: false,
          ),
        );
        page++;
      }
      return false;
    } catch (error) {
      await db.saveCheckpoint(
        ActressSyncCheckpoint(
          source: source.id.name,
          phase: 'roster',
          cursor: '$page',
          total: stored,
          finished: false,
          error: error.toString(),
        ),
      );
      return false;
    }
  }

  Future<void> _syncFilmsPhase(
    ActressRosterSource source,
    int sourceIndex,
  ) async {
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

    Future<void> worker() async {
      while (!_cancelled) {
        if (nextIndex >= pending.length) return;
        final person = pending[nextIndex++];
        final ok = await _syncOnePersonFilms(source, person);
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
        // 还有没跑完/失败的人，下次刷新继续补，不记完成。
        finished: remaining.isEmpty && !_cancelled,
      ),
    );
    if (repairOpen && !_cancelled) {
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

  Future<bool> _syncOnePersonFilms(
    ActressRosterSource source,
    ActressPerson person,
  ) async {
    final sourceId = person.sourceIdFor(source.id);
    if (sourceId.isEmpty) return true;
    try {
      final films = await _withRetry(
        () => source.fetchFilms(sourceId, fetch: fetch),
      );
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
      await db.markFilmsState(person.localId, source.id, ok: false);
      return false;
    }
  }

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
    try {
      while (!_cancelled) {
        final result = await _withRetry(
          () => source.fetchRankingPage(page, fetch: fetch),
        );
        for (var i = 0; i < result.persons.length; i++) {
          final stored = await db.upsertRosterPerson(result.persons[i]);
          if (stored != null) {
            // 名次写入各自的列：MissAV 主链与 whos 后备互不覆盖。
            if (source.id == ActressRosterSourceId.whos) {
              await db.setWhosRank(stored.localId, ranked + i + 1);
            } else {
              await db.setMissavRank(stored.localId, ranked + i + 1);
            }
          }
        }
        ranked += result.persons.length;
        _emit(
          ActressSyncProgress(
            phase: 'ranking',
            sourceIndex: sourceIndex,
            sourceCount: sources.length,
            done: page,
            total: 0,
            failed: 0,
            running: true,
          ),
        );
        if (!result.hasMore || result.persons.isEmpty) {
          await db.saveCheckpoint(
            ActressSyncCheckpoint(
              source: source.id.name,
              phase: 'ranking',
              cursor: '${page + 1}',
              total: ranked,
              finished: true,
            ),
          );
          return true;
        }
        await db.saveCheckpoint(
          ActressSyncCheckpoint(
            source: source.id.name,
            phase: 'ranking',
            cursor: '${page + 1}',
            total: ranked,
            finished: false,
          ),
        );
        page++;
      }
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
