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
    final result = await importerFactory().importFile(
      sqlPath: sqlPath,
      dbPath: dbPath,
      closeDatabase: closeDatabase,
      onProgress: (progress) {
        sqlImportProgress = progress;
        notifyListeners();
      },
      isCancelled: () => _sqlCancelRequested,
    );
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
