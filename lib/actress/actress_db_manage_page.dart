import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'actress_db_export.dart';
import 'actress_db_info.dart';
import 'actress_db_meta.dart';
import 'actress_sql_import.dart';
import 'actress_sql_import_controller.dart';

/// 数据库管理页（2026-11-25 用户令：「能导入就要能删除数据库，
/// 要添加一个数据库管理」）。
///
/// 只管演员库内部工作库这一个文件：看信息（作品/女优/地址数、
/// 文件大小、最近导入来源）、导入 .sql、表格导入更新、导出
/// （五种格式选）、备份恢复/删除、删除数据库。
///
/// 与后台任务的协调（同控制器口径）：任一任务在跑时，删除/
/// 恢复/开新任务一律先拦下提示，不许导入写一半和删除打架
/// ——选「拦下」而不是自动取消：删库是不可逆动作，让用户先
/// 自己取消导入或等导完，再回来删，口径更稳。
class ActressDbManagePage extends StatefulWidget {
  const ActressDbManagePage({
    super.key,
    required this.dbPath,
    required this.closeDatabase,
    required this.reloadDatabase,
    this.controller,
    this.infoLoader,
    this.metaLoader,
    this.deleteFiles,
    this.restoreBackupFile,
    this.deleteBackupFile,
    this.clearMeta,
    this.pickSqlFile,
    this.pickTableFile,
  });

  /// 内部工作库路径。
  final String dbPath;

  /// 关当前库连接（删库/恢复/换库前调，列表页提供）。
  final Future<void> Function() closeDatabase;

  /// 重读列表（库文件变了之后调，列表页提供）。
  final Future<void> Function() reloadDatabase;

  // 以下为可注入接缝（测试用假实现，生产走默认）。
  final ActressDbTaskController? controller;
  final Future<ActressDbInfo> Function(String dbPath)? infoLoader;
  final Future<ActressDbImportMeta?> Function()? metaLoader;
  final Future<void> Function(String dbPath)? deleteFiles;
  final Future<void> Function(String dbPath)? restoreBackupFile;
  final Future<void> Function(String dbPath)? deleteBackupFile;
  final Future<void> Function()? clearMeta;
  final Future<String?> Function()? pickSqlFile;
  final Future<String?> Function()? pickTableFile;

  @override
  State<ActressDbManagePage> createState() => _ActressDbManagePageState();
}

class _ActressDbManagePageState extends State<ActressDbManagePage> {
  late final ActressDbTaskController _controller =
      widget.controller ?? ActressDbTaskController.instance;

  ActressDbInfo? _info;
  ActressDbImportMeta? _meta;
  var _loadingInfo = true;
  var _acting = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    _refresh();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    // 任务刚结束时计数可能变了（导入换库/表格更新），刷一次信息。
    if (!_controller.busy) _refresh();
  }

  Future<void> _refresh() async {
    final loader = widget.infoLoader ?? loadActressDbInfo;
    final metaLoader = widget.metaLoader ?? loadActressDbImportMeta;
    try {
      final info = await loader(widget.dbPath);
      final meta = await metaLoader();
      if (!mounted) return;
      setState(() {
        _info = info;
        _meta = meta;
        _loadingInfo = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingInfo = false);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// 有任务在跑时的统一拦截：返回 true = 已拦下，调用方直接停。
  bool _blockedByBusy() {
    if (!_controller.busy) return false;
    _snack('${_controller.busyLabel}，先取消任务或等它完成再操作');
    return true;
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('再想想'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  // ---------------------------------------------------------------------
  // 动作
  // ---------------------------------------------------------------------

  Future<void> _deleteDatabase() async {
    if (_blockedByBusy() || _acting) return;
    final ok = await _confirm(
      title: '删除数据库？',
      body: '删完演员库就空了，作品、女优、播放地址全没，'
          '要重新导入 .sql 数据库才能用。\n（备份文件不会跟着删，'
          '后悔了还能在下面恢复备份。）',
      action: '删除',
    );
    if (!ok) return;
    setState(() => _acting = true);
    try {
      await widget.closeDatabase();
      await (widget.deleteFiles ?? deleteActressDbFiles)(widget.dbPath);
      await (widget.clearMeta ?? clearActressDbImportMeta)();
      await widget.reloadDatabase();
      // 通知全 App 自动刷新（列表页监听数据代次，删完回空态/
      // JSON 顶上，不用重启）。
      _controller.notifyDbMutated();
      _snack('已删除数据库，演员库已清空');
    } catch (e) {
      _snack('删除失败：${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _acting = false);
      _refresh();
    }
  }

  Future<void> _restoreBackup() async {
    if (_blockedByBusy() || _acting) return;
    final ok = await _confirm(
      title: '恢复备份？',
      body: '把上次导入时留下的备份顶回成当前数据库，'
          '现在的库内容会被换掉。',
      action: '恢复',
    );
    if (!ok) return;
    setState(() => _acting = true);
    try {
      await widget.closeDatabase();
      await (widget.restoreBackupFile ?? restoreActressDbBackup)(
        widget.dbPath,
      );
      await widget.reloadDatabase();
      _controller.notifyDbMutated();
      _snack('已恢复备份');
    } catch (e) {
      _snack('恢复失败：${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _acting = false);
      _refresh();
    }
  }

  Future<void> _deleteBackup() async {
    if (_acting) return;
    final ok = await _confirm(
      title: '删除备份？',
      body: '备份删了就没了，当前数据库不受影响。',
      action: '删除备份',
    );
    if (!ok) return;
    try {
      await (widget.deleteBackupFile ?? deleteActressDbBackup)(widget.dbPath);
      _snack('已删除备份');
    } catch (e) {
      _snack('删除备份失败：${e.toString().split('\n').first}');
    }
    _refresh();
  }

  Future<void> _startSqlImport() async {
    if (_blockedByBusy()) return;
    final picker = widget.pickSqlFile ?? _pickSqlFile;
    final picked = await picker();
    if (picked == null || picked.isEmpty) return;
    await _controller.startSqlImport(
      sqlPath: picked,
      dbPath: widget.dbPath,
      closeDatabase: widget.closeDatabase,
      onSwapped: (_) async {
        await widget.reloadDatabase();
        _refresh();
      },
    );
  }

  Future<void> _startTableUpdate() async {
    if (_blockedByBusy()) return;
    if (_info != null && !_info!.exists) {
      _snack('还没有数据库：先导入 .sql 数据库再用表格更新');
      return;
    }
    final picker = widget.pickTableFile ?? _pickTableFile;
    final picked = await picker();
    if (picked == null || picked.isEmpty) return;
    final result = await _controller.startTableUpdate(
      filePath: picked,
      dbPath: widget.dbPath,
    );
    if (result != null && result.ok) {
      await widget.reloadDatabase();
      _refresh();
    }
  }

  Future<void> _startExport() async {
    if (_blockedByBusy()) return;
    if (_info != null && !_info!.exists) {
      _snack('还没有数据库：先导入 .sql 数据库再导出');
      return;
    }
    final format = await showDialog<ActressExportFormat>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('导出格式'),
        children: [
          for (final format in ActressExportFormat.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(format),
              child: Text(_formatLabel(format)),
            ),
        ],
      ),
    );
    if (format == null) return;
    await _controller.startExport(
      format: format,
      dbPath: widget.dbPath,
      outDir: path.dirname(widget.dbPath),
      closeDatabase: widget.closeDatabase,
      reloadDatabase: widget.reloadDatabase,
    );
    _refresh();
  }

  String _formatLabel(ActressExportFormat format) => switch (format) {
    ActressExportFormat.sql => 'SQL 文件（.sql，全库，可导回）',
    ActressExportFormat.sqlGz => 'SQL 压缩文件（.sql.gz，全库，可导回）',
    ActressExportFormat.csv => 'CSV 表格（作品表，可改后导回更新）',
    ActressExportFormat.xlsx => 'Excel 表格（.xlsx，作品表）',
    ActressExportFormat.db => '数据库原文件（.db，整库拷贝）',
  };

  /// 导出文件另存到系统位置（小文件才给：saveFile 要整份字节，
  /// 大文件直接给路径，用户用文件管理器拷走）。
  Future<void> _saveExportCopy(ActressExportResult result) async {
    final filePath = result.path;
    if (filePath == null) return;
    try {
      final bytes = await File(filePath).readAsBytes();
      final saved = await FilePicker.saveFile(
        dialogTitle: '保存导出文件',
        fileName: path.basename(filePath),
        bytes: bytes,
      );
      _snack(saved == null ? '已取消保存' : '已保存到所选位置');
    } catch (e) {
      _snack('保存失败：${e.toString().split('\n').first}');
    }
  }

  Future<String?> _pickSqlFile() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['sql', 'gz'],
      );
      if (files.isEmpty) return null;
      return files.first.path;
    } catch (e) {
      _snack('打不开文件选择器：${e.toString().split('\n').first}');
      return null;
    }
  }

  Future<String?> _pickTableFile() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['csv', 'xlsx'],
      );
      if (files.isEmpty) return null;
      return files.first.path;
    } catch (e) {
      _snack('打不开文件选择器：${e.toString().split('\n').first}');
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // 界面
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('数据库管理')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (_controller.busy) _busyBanner(colors, textStyle),
          _sectionTitle(textStyle, '当前数据库'),
          if (_loadingInfo)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            )
          else if (_info == null || !_info!.exists)
            Text(
              '还没有导入数据库。\n演员库现在是空的，导入一份 .sql 数据库后就能用。',
              style: textStyle.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            )
          else
            _currentDbInfo(colors, textStyle),
          const SizedBox(height: 20),
          _sectionTitle(textStyle, '导入与更新'),
          _actionRow(
            colors: colors,
            textStyle: textStyle,
            title: '导入 .sql 数据库',
            subtitle: '整库替换；导的过程中旧库照常能看能播，'
                '离开这个页面也会继续导',
            buttonText: '导入',
            onPressed: _controller.busy ? null : _startSqlImport,
          ),
          if (_controller.sqlImportResult != null)
            _resultText(
              colors,
              textStyle,
              _sqlImportResultText(_controller.sqlImportResult!),
            ),
          _actionRow(
            colors: colors,
            textStyle: textStyle,
            title: '表格导入更新',
            subtitle: 'CSV / Excel 按番号更新：有的改、没有的加，'
                '表格里没出现的作品不动',
            buttonText: '选表格',
            onPressed: _controller.busy ? null : _startTableUpdate,
          ),
          if (_controller.tableUpdateResult != null)
            _resultText(
              colors,
              textStyle,
              _controller.tableUpdateResult!.summary,
            ),
          const SizedBox(height: 20),
          _sectionTitle(textStyle, '导出'),
          _actionRow(
            colors: colors,
            textStyle: textStyle,
            title: '导出数据库',
            subtitle: '选格式导出：SQL / SQL 压缩 / CSV / Excel / 数据库原文件',
            buttonText: '导出',
            onPressed: _controller.busy ? null : _startExport,
          ),
          if (_controller.exportResult != null)
            _exportResultArea(colors, textStyle, _controller.exportResult!),
          const SizedBox(height: 20),
          _sectionTitle(textStyle, '备份'),
          if (_info?.bakExists ?? false) ...[
            Text(
              '有一份备份：${formatDbBytes(_info!.bakBytes)}'
              '${_info!.bakModified == null ? '' : ' · ${_formatTime(_info!.bakModified!)}'}'
              '（导入替换时自动留下的上一个库）',
              style: textStyle.bodyMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton(
                  onPressed: _controller.busy || _acting
                      ? null
                      : _restoreBackup,
                  child: const Text('恢复备份'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: _acting ? null : _deleteBackup,
                  child: const Text('删除备份'),
                ),
              ],
            ),
          ] else
            Text(
              '暂无备份。下次导入替换数据库时会自动留一份。',
              style: textStyle.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 20),
          _sectionTitle(textStyle, '危险操作'),
          _actionRow(
            colors: colors,
            textStyle: textStyle,
            title: '删除数据库',
            subtitle: '删完演员库变空，要重新导入 .sql 才能用；备份不会跟着删',
            buttonText: '删除',
            danger: true,
            onPressed: _controller.busy || _acting ? null : _deleteDatabase,
          ),
        ],
      ),
    );
  }

  Widget _busyBanner(ColorScheme colors, TextTheme textStyle) {
    final controller = _controller;
    String detail = controller.busyLabel;
    VoidCallback? onCancel;
    double? fraction;
    if (controller.sqlImportRunning) {
      final progress = controller.sqlImportProgress;
      if (progress != null) {
        detail = '正在导入数据库…已导入 ${progress.statements} 条'
            '（${(progress.fraction * 100).toStringAsFixed(0)}%）';
        fraction = progress.fraction;
      }
      onCancel = controller.cancelSqlImport;
    } else if (controller.tableUpdateRunning) {
      detail = '正在用表格更新数据库…'
          '${controller.tableUpdateDone}/${controller.tableUpdateTotal} 行';
      if (controller.tableUpdateTotal > 0) {
        fraction = controller.tableUpdateDone / controller.tableUpdateTotal;
      }
      onCancel = controller.cancelTableUpdate;
    } else if (controller.exportRunning) {
      detail = '正在导出数据库…'
          '${controller.exportDone}/${controller.exportTotal} 行';
      if (controller.exportTotal > 0) {
        fraction = controller.exportDone / controller.exportTotal;
      }
      onCancel = controller.cancelExport;
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(detail, style: textStyle.bodyMedium)),
                if (onCancel != null)
                  TextButton(onPressed: onCancel, child: const Text('取消')),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: fraction?.clamp(0, 1)),
            const SizedBox(height: 6),
            Text(
              '任务在后台进行，可以离开这个页面去用别的功能；'
              '但删除/恢复要等任务结束（或先取消）。',
              style: textStyle.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _currentDbInfo(ColorScheme colors, TextTheme textStyle) {
    final info = _info!;
    final meta = _meta;
    final lines = <String>[
      '作品 ${info.videos} 部 · 女优 ${info.actresses} 人 · '
          '播放地址 ${info.playUrls} 条',
      '库文件大小 ${formatDbBytes(info.fileBytes)}',
      if (meta == null)
        '最近一次导入：未知（没有导入记录）'
      else
        '最近一次导入：${_formatTime(meta.importedAt)}'
            ' · 来源 ${meta.sourceName.isEmpty ? '未知' : meta.sourceName}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(line, style: textStyle.bodyMedium),
          ),
      ],
    );
  }

  String _sqlImportResultText(ActressSqlImportResult result) {
    if (!result.ok) return '导入失败：${result.error ?? '未知原因'}';
    final base =
        '已导入：${result.videos} 部作品 · ${result.actresses} 人'
        ' · 播放地址 ${result.playUrls} 条';
    if (result.warnings.isEmpty) return base;
    return '$base\n${result.warnings.join('\n')}';
  }

  Widget _exportResultArea(
    ColorScheme colors,
    TextTheme textStyle,
    ActressExportResult result,
  ) {
    if (!result.ok) {
      return _resultText(colors, textStyle, '导出失败：${result.error ?? '未知原因'}');
    }
    final canSaveCopy = result.bytes <= 32 * 1024 * 1024;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '已导出：${path.basename(result.path ?? '')}'
            '（${formatDbBytes(result.bytes)}）\n保存位置：${result.path}',
            style: textStyle.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          if (canSaveCopy)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => _saveExportCopy(result),
                child: const Text('另存到…'),
              ),
            )
          else
            Text(
              '文件较大，用文件管理器到上面的位置拷走即可。',
              style: textStyle.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionTitle(TextTheme textStyle, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(title, style: textStyle.titleMedium),
    );
  }

  Widget _resultText(
    ColorScheme colors,
    TextTheme textStyle,
    String text,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: Text(
        text,
        style: textStyle.bodySmall?.copyWith(color: colors.onSurfaceVariant),
      ),
    );
  }

  Widget _actionRow({
    required ColorScheme colors,
    required TextTheme textStyle,
    required String title,
    required String subtitle,
    required String buttonText,
    required VoidCallback? onPressed,
    bool danger = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: textStyle.titleSmall),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: textStyle.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          danger
              ? OutlinedButton(
                  onPressed: onPressed,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colors.error,
                    side: BorderSide(color: colors.error),
                  ),
                  child: Text(buttonText),
                )
              : OutlinedButton(
                  onPressed: onPressed,
                  child: Text(buttonText),
                ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime time) {
    String pad(int v) => v.toString().padLeft(2, '0');
    return '${time.year}-${pad(time.month)}-${pad(time.day)} '
        '${pad(time.hour)}:${pad(time.minute)}';
  }
}
