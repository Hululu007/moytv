import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:moyi/actress/actress_db_info.dart';
import 'package:moyi/actress/actress_sql_import.dart';
import 'package:moyi/actress/actress_sql_import_controller.dart';

/// 安卓兼容批（2026-11-26）控制器侧回归：
/// - 选中的 .sql 先转存到应用文档目录再导（选择器给的是缓存
///   副本，长导入中途可能被清掉）；
/// - 导入失败保留暂存文件、可一键重试；成功删掉；
/// - 基础设施类失败（空间不足/文件读不到）翻成中文提示。
class _RecordingImporter extends ActressSqlImporter {
  _RecordingImporter({this.result});

  final ActressSqlImportResult? result;
  String? lastSqlPath;
  String? lastSqlContent;

  @override
  Future<ActressSqlImportResult> importFile({
    required String sqlPath,
    required String dbPath,
    required Future<void> Function() closeDatabase,
    void Function(ActressSqlImportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    lastSqlPath = sqlPath;
    try {
      lastSqlContent = await File(sqlPath).readAsString();
    } catch (_) {
      lastSqlContent = null; // 读不到也照常回预设结果（真导入器同口径）。
    }
    return result ??
        const ActressSqlImportResult(
          ok: true,
          videos: 3,
          actresses: 2,
          playUrls: 4,
        );
  }
}

void main() {
  group('ActressDbTaskController 安卓兼容批', () {
    late Directory tmp;
    late String dbPath;
    late File sourceFile;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('nvku_compat_test');
      dbPath = path.join(tmp.path, '女优库.db');
      sourceFile = File(path.join(tmp.path, 'picked_cache_copy.sql'))
        ..writeAsStringSync('CREATE TABLE videos(x);');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    ActressDbTaskController newController(ActressSqlImporter importer) {
      final controller = ActressDbTaskController();
      controller.importerFactory = () => importer;
      controller.saveMeta = (_) async {};
      return controller;
    }

    test('导入前先转存到工作库同目录，导入器读的是暂存文件', () async {
      final importer = _RecordingImporter();
      final controller = newController(importer);
      final result = await controller.startSqlImport(
        sqlPath: sourceFile.path,
        dbPath: dbPath,
        closeDatabase: () async {},
      );
      expect(result?.ok, isTrue);
      final staged = path.join(tmp.path, '女优库待导入.sql');
      expect(importer.lastSqlPath, staged);
      expect(importer.lastSqlContent, 'CREATE TABLE videos(x);');
      // 来源名仍是用户选的原文件名，不是暂存名。
      expect(controller.sqlImportSourceName, 'picked_cache_copy.sql');
    });

    test('导入成功后暂存文件删掉、重试状态清零', () async {
      final controller = newController(_RecordingImporter());
      await controller.startSqlImport(
        sqlPath: sourceFile.path,
        dbPath: dbPath,
        closeDatabase: () async {},
      );
      final staged = File(path.join(tmp.path, '女优库待导入.sql'));
      expect(staged.existsSync(), isFalse);
      expect(controller.stagedSqlAvailable, isFalse);
      expect(controller.stagedSqlPath, isNull);
    });

    test('导入失败保留暂存文件，用暂存路径重试可成功', () async {
      final failing = _RecordingImporter(
        result: const ActressSqlImportResult(ok: false, error: '缺表：videos'),
      );
      final controller = newController(failing);
      final first = await controller.startSqlImport(
        sqlPath: sourceFile.path,
        dbPath: dbPath,
        closeDatabase: () async {},
      );
      expect(first?.ok, isFalse);
      expect(controller.stagedSqlAvailable, isTrue);
      final stagedPath = controller.stagedSqlPath;
      expect(stagedPath, isNotNull);
      expect(File(stagedPath!).existsSync(), isTrue);

      // 重试：导入器换成成功的那个，路径直接用暂存路径。
      final succeeding = _RecordingImporter();
      controller.importerFactory = () => succeeding;
      final second = await controller.startSqlImport(
        sqlPath: stagedPath,
        dbPath: dbPath,
        closeDatabase: () async {},
      );
      expect(second?.ok, isTrue);
      expect(succeeding.lastSqlPath, stagedPath);
      expect(controller.stagedSqlAvailable, isFalse);
      expect(File(stagedPath).existsSync(), isFalse);
    });

    test('源文件不存在时退回原路径导，失败口径不变', () async {
      final importer = _RecordingImporter(
        result: const ActressSqlImportResult(ok: false, error: '缺表：videos'),
      );
      final controller = newController(importer);
      // 导入器是假的（不真读文件），这里只验转存失败不炸控制器、
      // 且暂存状态不置起。
      final missing = path.join(tmp.path, 'not_there.sql');
      final result = await controller.startSqlImport(
        sqlPath: missing,
        dbPath: dbPath,
        closeDatabase: () async {},
      );
      expect(result?.ok, isFalse);
      expect(importer.lastSqlPath, missing);
      expect(controller.stagedSqlAvailable, isFalse);
    });

    test('空间不足的底层错误翻成中文提示', () async {
      final importer = _RecordingImporter(
        result: const ActressSqlImportResult(
          ok: false,
          error: 'DatabaseException(Error Domain=Sqflite Code=28 '
              '"disk full (code 28 SQLITE_FULL)")',
        ),
      );
      final controller = newController(importer);
      final result = await controller.startSqlImport(
        sqlPath: sourceFile.path,
        dbPath: dbPath,
        closeDatabase: () async {},
      );
      expect(result?.error, contains('存储空间不足'));
      expect(result?.error, contains('原数据库没有改动'));
    });

    test('文件读不到的底层错误翻成中文提示', () async {
      final importer = _RecordingImporter(
        result: const ActressSqlImportResult(
          ok: false,
          error: 'FileSystemException: Cannot open file '
              '(OS Error: No such file or directory, errno = 2)',
        ),
      );
      final controller = newController(importer);
      final result = await controller.startSqlImport(
        sqlPath: sourceFile.path,
        dbPath: dbPath,
        closeDatabase: () async {},
      );
      expect(result?.error, contains('读取所选文件失败'));
    });

    test('删库：主库与边文件都删掉且不抛错', () async {
      final db = File(dbPath)..writeAsStringSync('db');
      File('$dbPath-wal').writeAsStringSync('wal');
      File('$dbPath-shm').writeAsStringSync('shm');
      await deleteActressDbFiles(dbPath);
      expect(db.existsSync(), isFalse);
      expect(File('$dbPath-wal').existsSync(), isFalse);
      expect(File('$dbPath-shm').existsSync(), isFalse);
    });

    test('恢复备份：.bak 拷回主库；没备份时报中文原因', () async {
      File('$dbPath.bak').writeAsStringSync('backup-bytes');
      await restoreActressDbBackup(dbPath);
      expect(File(dbPath).readAsStringSync(), 'backup-bytes');
      // 备份保留不删。
      expect(File('$dbPath.bak').existsSync(), isTrue);

      final noBakPath = path.join(tmp.path, 'other.db');
      await expectLater(
        restoreActressDbBackup(noBakPath),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('备份文件不存在'),
          ),
        ),
      );
    });

    test('业务类失败原因原样保留，不被改写', () {
      expect(
        ActressDbTaskController.friendlySqlImportError('缺表：videos，不是女优库'),
        '缺表：videos，不是女优库',
      );
      expect(
        ActressDbTaskController.friendlySqlImportError('已取消，数据库未改动'),
        '已取消，数据库未改动',
      );
    });
  });
}
