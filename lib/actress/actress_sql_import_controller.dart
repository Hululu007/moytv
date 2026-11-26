import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'actress_db_export.dart';
import 'actress_db_meta.dart';
import 'actress_spreadsheet.dart';
import 'actress_sql_import.dart';
import 'actress_table_update.dart';

/// 演员库数据库任务控制器（应用级常驻，2026-11-25 用户令：
/// 导入能离开页面在后台慢慢导）。
///
/// 管三类任务的运行状态：.sql 导入、表格导入更新、导出。三者
/// 共用一个互斥：任一任务在跑时，其它任务与删库/恢复备份都被
/// 拦下（见 [busy]），不许写一半打架。
///
/// 状态不绑任何页面生命周期：页面关掉任务照跑；页面回来从这里
/// 读进度与结果。[swapGeneration] 每成功换一次库 +1，页面用它
/// 判断要不要重读列表；导完的结果通过 [consumeImportNotice]
/// 一次性消费（活着的页面立刻弹提示，没活着的页面下次打开补弹）。
///
/// 诚实边界：这是「应用内后台」——App 进程活着时切页面没问题；
/// 系统把 App 整个杀掉（鸿蒙 NEXT + 卓易通杀后台严）导入会
/// 中断，但中断是安全的：导入写的是临时库，旧库完好无损，
/// 重新导即可。本控制器不承诺进程被杀还能续导。
class ActressDbTaskController extends ChangeNotifier {
  ActressDbTaskController();

  /// 应用级单例：列表页、数据库管理页共用这一个。
  static final ActressDbTaskController instance = ActressDbTaskController();

  // ---------------------------------------------------------------------
  // 可替换的构造口（测试注入假执行器/假存储用，生产走默认）。
  // ---------------------------------------------------------------------
  ActressSqlImporter Function() importerFactory = () => ActressSqlImporter();
  Future<ActressTableStore> Function(String dbPath) tableStoreOpener =
      (dbPath) => SqfliteActressTableStore.openPath(dbPath);
  Future<ActressExportStore> Function(String dbPath) exportStoreOpener =
      (dbPath) => SqfliteActressExportStore.openPath(dbPath);
  Future<void> Function(ActressDbImportMeta meta) saveMeta =
      saveActressDbImportMeta;

  // ---------------------------------------------------------------------
  // .sql 导入状态
  // ---------------------------------------------------------------------
  bool sqlImportRunning = false;
  ActressSqlImportProgress? sqlImportProgress;
  ActressSqlImportResult? sqlImportResult;
  String? sqlImportSourceName;
  bool _sqlCancelRequested = false;

  /// 选中的 .sql 文件转存到应用文档目录后的路径（安卓兼容批
  /// 2026-11-26）：file_picker 在安卓上先把所选文件整份拷进应用
  /// 缓存目录再回路径，导入要流式读几分钟，期间系统清缓存、
  /// 用户清空间都会让源文件消失、导入半路断掉。开始导入前先
  /// 把文件转存到文档目录（与工作库同目录）再导，源文件就不
  /// 受缓存清理影响。导入成功后删掉；失败/取消时保留并置
  /// [stagedSqlAvailable]，管理页可一键用它重试，不用重新选
  /// 文件（也不用再等选择器拷一遍大文件）。
  String? stagedSqlPath;
  bool stagedSqlAvailable = false;

  /// 成功换库次数（页面据此判断要不要重读列表）。
  int swapGeneration = 0;

  /// 数据代次：任何会改库/换库的动作（导入换库、表格更新、管理页
  /// 恢复/删除）成功后 +1。列表页监听它自动清缓存重读，不用用户
  /// 重启或手动重进（2026-11-25 用户令：导入数据库自动刷新）。
  int dataGeneration = 0;

  /// 外部动作（管理页删除/恢复）改完库后调：代次 +1 并通知监听方
  /// 自动刷新。控制器自管的导入/表格更新成功时内部也会调。
  void notifyDbMutated() {
    dataGeneration++;
    notifyListeners();
  }

  ActressSqlImportResult? _pendingImportNotice;

  // ---------------------------------------------------------------------
  // 表格导入更新状态
  // ---------------------------------------------------------------------
  bool tableUpdateRunning = false;
  int tableUpdateDone = 0;
  int tableUpdateTotal = 0;
  ActressTableUpdateResult? tableUpdateResult;
  bool _tableCancelRequested = false;

  // ---------------------------------------------------------------------
  // 导出状态
  // ---------------------------------------------------------------------
  bool exportRunning = false;
  int exportDone = 0;
  int exportTotal = 0;
  ActressExportFormat? exportFormat;
  ActressExportResult? exportResult;
  bool _exportCancelRequested = false;

  /// 任一任务在跑（删库/恢复/开新任务的拦截口径）。
  bool get busy => sqlImportRunning || tableUpdateRunning || exportRunning;

  String get busyLabel {
    if (sqlImportRunning) return '正在导入数据库';
    if (tableUpdateRunning) return '正在用表格更新数据库';
    if (exportRunning) return '正在导出数据库';
    return '';
  }

  /// 取走待弹的导入完成提示（只消费一次）。
  ActressSqlImportResult? consumeImportNotice() {
    final notice = _pendingImportNotice;
    _pendingImportNotice = null;
    return notice;
  }

  bool get hasPendingImportNotice => _pendingImportNotice != null;

  // ---------------------------------------------------------------------
  // .sql 导入（后台）
  // ---------------------------------------------------------------------

  /// 开始 .sql 导入。已有任务在跑时返回 null（调用方提示即可）。
  /// [onSwapped] 在换库成功后调（页面清缓存/重读列表用）；页面
  /// 已销毁时传进来的回调自己负责守卫，控制器照调不误。
  Future<ActressSqlImportResult?> startSqlImport({
    required String sqlPath,
    required String dbPath,
    required Future<void> Function() closeDatabase,
    Future<void> Function(ActressSqlImportResult result)? onSwapped,
  }) async {
    if (busy) return null;
    sqlImportRunning = true;
    sqlImportProgress = null;
    sqlImportResult = null;
    sqlImportSourceName = path.basename(sqlPath);
    _sqlCancelRequested = false;
    notifyListeners();
    // 转存暂存（见 stagedSqlPath 说明）：转存失败（空间不够等）
    // 不拦导入，退回原路径照常导、失败口径不变。
    var effectiveSqlPath = sqlPath;
    String? stagedPath;
    try {
      final lower = sqlPath.toLowerCase();
      final ext = lower.endsWith('.sql.gz')
          ? '.sql.gz'
          : lower.endsWith('.gz')
          ? '.gz'
          : '.sql';
      final candidate = path.join(path.dirname(dbPath), '女优库待导入$ext');
      if (path.normalize(sqlPath) == path.normalize(candidate)) {
        stagedPath = candidate; // 重试的就是暂存文件本身，不自拷。
      } else {
        await File(sqlPath).copy(candidate);
        stagedPath = candidate;
      }
      effectiveSqlPath = candidate;
      stagedSqlPath = candidate;
      stagedSqlAvailable = true;
    } catch (_) {
      // 转存失败：用原路径导。
    }
    var result = await importerFactory().importFile(
      sqlPath: effectiveSqlPath,
      dbPath: dbPath,
      closeDatabase: closeDatabase,
      onProgress: (progress) {
        sqlImportProgress = progress;
        notifyListeners();
      },
      isCancelled: () => _sqlCancelRequested,
    );
    result = _withFriendlyError(result);
    // 暂存收尾：成功删掉清状态；失败/取消留着供一键重试（文件
    // 已不在了就把状态清掉，别让管理页给出点了必死的重试）。
    if (stagedPath != null) {
      if (result.ok) {
        try {
          await File(stagedPath).delete();
        } catch (_) {}
        if (stagedSqlPath == stagedPath) {
          stagedSqlPath = null;
          stagedSqlAvailable = false;
        }
      } else {
        stagedSqlAvailable = await File(stagedPath).exists();
        if (!stagedSqlAvailable && stagedSqlPath == stagedPath) {
          stagedSqlPath = null;
        }
      }
    }
    sqlImportRunning = false;
    sqlImportProgress = null;
    sqlImportResult = result;
    if (result.ok) {
      swapGeneration++;
      dataGeneration++;
      _pendingImportNotice = result;
      await saveMeta(
        ActressDbImportMeta(
          sourceName: sqlImportSourceName ?? '',
          importedAtMillis: DateTime.now().millisecondsSinceEpoch,
          videos: result.videos,
          actresses: result.actresses,
          playUrls: result.playUrls,
        ),
      );
      if (onSwapped != null) {
        try {
          await onSwapped(result);
        } catch (_) {
          // 页面侧收尾失败不改导入已成功的事实。
        }
      }
    } else if (result.error != null &&
        !result.error!.startsWith('已取消')) {
      _pendingImportNotice = result;
    }
    notifyListeners();
    return result;
  }

  void cancelSqlImport() {
    if (sqlImportRunning) _sqlCancelRequested = true;
  }

  /// 导入失败原因的用户话术（安卓兼容批 2026-11-26）：底层错误
  /// 里认得出是基础设施故障的两类（存储空间不足、源文件读不到）
  /// 翻成能照着做的中文；其余原样——导入器给的原因本身已是
  /// 中文结论（缺表、没作品之类），不许在这层改写掉。
  static String friendlySqlImportError(String error) {
    final text = error.toLowerCase();
    if (text.contains('no space left') ||
        text.contains('disk full') ||
        text.contains('sqlite_full') ||
        text.contains('code 28')) {
      return '手机存储空间不足，导入没能完成。先清出空间再重试，原数据库没有改动';
    }
    if (text.contains('no such file') || text.contains('file not found')) {
      return '读取所选文件失败（文件可能被移动、删除或缓存被清理）。重新选一次文件再导入';
    }
    return error;
  }

  ActressSqlImportResult _withFriendlyError(ActressSqlImportResult result) {
    final error = result.error;
    if (result.ok || error == null) return result;
    final friendly = friendlySqlImportError(error);
    if (friendly == error) return result;
    return ActressSqlImportResult(
      ok: false,
      error: friendly,
      videos: result.videos,
      actresses: result.actresses,
      playUrls: result.playUrls,
      covers: result.covers,
      avatars: result.avatars,
      skipped: result.skipped,
      skippedStatements: result.skippedStatements,
      skippedStatementTables: result.skippedStatementTables,
      skippedStatementSample: result.skippedStatementSample,
      warnings: result.warnings,
      needsReload: result.needsReload,
    );
  }

  // ---------------------------------------------------------------------
  // 表格导入更新
  // ---------------------------------------------------------------------

  Future<ActressTableUpdateResult?> startTableUpdate({
    required String filePath,
    required String dbPath,
  }) async {
    if (busy) return null;
    tableUpdateRunning = true;
    tableUpdateDone = 0;
    tableUpdateTotal = 0;
    tableUpdateResult = null;
    _tableCancelRequested = false;
    notifyListeners();
    ActressTableUpdateResult result;
    ActressTableStore? store;
    try {
      if (!await File(dbPath).exists()) {
        result = const ActressTableUpdateResult(
          ok: false,
          error: '还没有数据库：先导入 .sql 数据库再用表格更新',
        );
      } else {
        final bytes = await File(filePath).readAsBytes();
        final isXlsx = filePath.toLowerCase().endsWith('.xlsx');
        final rows = spreadsheetRowsFromBytes(bytes, isXlsx: isXlsx);
        tableUpdateTotal = rows.length;
        store = await tableStoreOpener(dbPath);
        result = await const ActressTableUpdater().apply(
          store: store,
          rows: rows,
          onProgress: (done, total) {
            tableUpdateDone = done;
            tableUpdateTotal = total;
            notifyListeners();
          },
          isCancelled: () => _tableCancelRequested,
        );
      }
    } catch (e) {
      result = ActressTableUpdateResult(
        ok: false,
        error: e.toString().split('\n').first,
      );
    } finally {
      try {
        final opened = store;
        if (opened is SqfliteActressTableStore) await opened.close();
      } catch (_) {}
      tableUpdateRunning = false;
      notifyListeners();
    }
    tableUpdateResult = result;
    if (result.ok) dataGeneration++;
    notifyListeners();
    return result;
  }

  void cancelTableUpdate() {
    if (tableUpdateRunning) _tableCancelRequested = true;
  }

  // ---------------------------------------------------------------------
  // 导出
  // ---------------------------------------------------------------------

  /// 开始导出。.db 是直接拷库文件：先 [closeDatabase] 关库再拷、
  /// 拷完 [reloadDatabase] 重开；其余格式走只读连接流式写。
  /// 文件落在 [outDir]，文件名带时间戳；结果里有完整路径。
  Future<ActressExportResult?> startExport({
    required ActressExportFormat format,
    required String dbPath,
    required String outDir,
    required Future<void> Function() closeDatabase,
    required Future<void> Function() reloadDatabase,
  }) async {
    if (busy) return null;
    exportRunning = true;
    exportDone = 0;
    exportTotal = 0;
    exportFormat = format;
    exportResult = null;
    _exportCancelRequested = false;
    notifyListeners();
    ActressExportResult result;
    try {
      final dbFile = File(dbPath);
      if (!await dbFile.exists() || await dbFile.length() == 0) {
        result = const ActressExportResult(
          ok: false,
          error: '还没有数据库：先导入 .sql 数据库再导出',
        );
      } else {
        final stamp = DateTime.now();
        final name =
            '女优库导出_'
            '${stamp.year}${_pad(stamp.month)}${_pad(stamp.day)}_'
            '${_pad(stamp.hour)}${_pad(stamp.minute)}${_pad(stamp.second)}'
            '${format.extension}';
        final outPath = path.join(outDir, name);
        if (format == ActressExportFormat.db) {
          result = await _exportDbFile(
            dbPath: dbPath,
            outPath: outPath,
            closeDatabase: closeDatabase,
            reloadDatabase: reloadDatabase,
          );
        } else {
          final store = await exportStoreOpener(dbPath);
          try {
            const exporter = ActressDbExporter();
            if (format == ActressExportFormat.sql ||
                format == ActressExportFormat.sqlGz) {
              result = await exporter.exportSql(
                store: store,
                outPath: outPath,
                compressed: format == ActressExportFormat.sqlGz,
                onProgress: _onExportProgress,
                isCancelled: () => _exportCancelRequested,
              );
            } else {
              result = await exporter.exportSpreadsheet(
                store: store,
                outPath: outPath,
                xlsx: format == ActressExportFormat.xlsx,
                onProgress: _onExportProgress,
                isCancelled: () => _exportCancelRequested,
              );
            }
          } finally {
            try {
              await store.close();
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      result = ActressExportResult(
        ok: false,
        error: e.toString().split('\n').first,
      );
    }
    exportRunning = false;
    exportResult = result;
    notifyListeners();
    return result;
  }

  Future<ActressExportResult> _exportDbFile({
    required String dbPath,
    required String outPath,
    required Future<void> Function() closeDatabase,
    required Future<void> Function() reloadDatabase,
  }) async {
    final outFile = File(outPath);
    try {
      await closeDatabase();
      await File(dbPath).copy(outPath);
      return ActressExportResult(
        ok: true,
        path: outPath,
        bytes: await outFile.length(),
        rows: 0,
      );
    } catch (e) {
      try {
        if (await outFile.exists()) await outFile.delete();
      } catch (_) {}
      return ActressExportResult(
        ok: false,
        error: e.toString().split('\n').first,
      );
    } finally {
      try {
        await reloadDatabase();
      } catch (_) {}
    }
  }

  void _onExportProgress(int done, int total) {
    exportDone = done;
    exportTotal = total;
    notifyListeners();
  }

  void cancelExport() {
    if (exportRunning) _exportCancelRequested = true;
  }

  static String _pad(int value) => value.toString().padLeft(2, '0');
}
