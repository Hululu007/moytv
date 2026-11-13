import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'haikuo_clipboard.dart';
import 'haikuo_codec.dart';
import 'haikuo_program.dart';
import 'haikuo_runner_page.dart';
import 'haikuo_store.dart';

/// 导入时发现同名站点，问用户怎么处理：替换旧的 / 保留两者
/// （新导入的改名 _2）/ 取消整批导入。点遮罩或返回键关掉也算取消。
Future<HaikuoDuplicateDecision> showHaikuoDuplicateDialog(
  BuildContext context,
  List<HaikuoDuplicate> duplicates,
) async {
  if (duplicates.isEmpty) return HaikuoDuplicateDecision.cancel;
  final names = duplicates.map((d) => d.incoming.name).toSet().toList();
  final choice = await showDialog<HaikuoDuplicateDecision>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('发现同名站点'),
      content: Text(
        '以下站点已经存在：\n${names.join('、')}\n\n'
        '替换会用新导入的覆盖旧的；保留两者会把新导入的改名'
        '（如“${names.first}_2”）后留下；取消则这次什么都不导入。',
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, HaikuoDuplicateDecision.cancel),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, HaikuoDuplicateDecision.keepBoth),
          child: const Text('保留两者'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, HaikuoDuplicateDecision.replace),
          child: const Text('替换'),
        ),
      ],
    ),
  );
  return choice ?? HaikuoDuplicateDecision.cancel;
}

/// 海阔小程序面板：导入、管理、打开。
///
/// 入口在小程序模块里：小程序页「海阔」标签，右上角「+」菜单里也有
/// 快捷入口。支持三种导入方式：JSON 文件、剪贴板口令、直链。
class HaikuoHomePage extends StatefulWidget {
  const HaikuoHomePage({
    super.key,
    this.store,
    this.embedded = false,
    this.tabIndex,
    this.clipboardSeenStore,
  });

  /// 测试时注入临时目录用的仓库。
  final HaikuoStore? store;

  /// 嵌进小程序页「海阔」标签时为 true：不带自己的 AppBar / Scaffold，
  /// 直接复用同一份列表与导入入口。
  final bool embedded;

  /// 嵌进小程序页标签页时，海阔 tab 在 TabBarView 里的下标；
  /// 用于“回到前台时只在海阔页可见才检测剪贴板”。
  final int? tabIndex;

  /// 已处理过的剪贴板摘要存取（测试注入内存版；默认走 SharedPreferences）。
  final HaikuoClipboardSeenStore? clipboardSeenStore;

  @override
  State<HaikuoHomePage> createState() => _HaikuoHomePageState();
}

class _HaikuoHomePageState extends State<HaikuoHomePage>
    with WidgetsBindingObserver {
  late final HaikuoStore _store = widget.store ?? HaikuoStore();
  late final HaikuoClipboardSeenStore _seenStore =
      widget.clipboardSeenStore ?? SharedPrefsHaikuoClipboardSeenStore();
  List<HaikuoProgram> _programs = const [];
  bool _loading = true;
  bool _busy = false;
  String? _seenDigest;
  late final Future<void> _seenReady = _loadSeenDigest();
  bool _clipboardChecking = false;
  bool _clipboardPromptActive = false;
  TabController? _tabController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_checkClipboard()),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.embedded && widget.tabIndex != null) {
      final controller = DefaultTabController.maybeOf(context);
      if (controller != _tabController) {
        _tabController?.removeListener(_onTabChanged);
        _tabController = controller;
        _tabController?.addListener(_onTabChanged);
      }
    } else if (_tabController != null) {
      _tabController?.removeListener(_onTabChanged);
      _tabController = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController?.removeListener(_onTabChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isHaikuoVisible()) {
      unawaited(_checkClipboard());
    }
  }

  void _onTabChanged() {
    final controller = _tabController;
    if (controller != null && controller.indexIsChanging) return;
    if (_isHaikuoVisible()) unawaited(_checkClipboard());
  }

  /// 海阔页当前是否可见：独立路由看路由是否在栈顶；嵌进标签页时
  /// 还要看选中的是不是海阔 tab，避免在别的 tab 上弹导入窗。
  bool _isHaikuoVisible() {
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    if (widget.embedded) {
      final tabIndex = widget.tabIndex;
      if (tabIndex == null) return false;
      final controller = DefaultTabController.maybeOf(context);
      if (controller == null || controller.index != tabIndex) return false;
    }
    return true;
  }

  Future<void> _loadSeenDigest() async {
    _seenDigest = await _seenStore.readDigest();
  }

  /// 剪贴板自动检测：海阔页打开、切回海阔标签、从后台回到前台时各查一次。
  /// 只认现有导入已支持的口令形态；同一内容只弹一次（摘要比对 + 持久化），
  /// 取消与导入失败都算处理过，内容不变不再骚扰。
  Future<void> _checkClipboard() async {
    if (!mounted || _clipboardChecking || _clipboardPromptActive || _busy) {
      return;
    }
    _clipboardChecking = true;
    try {
      await _seenReady;
      String? text;
      try {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        text = data?.text;
      } catch (_) {
        return;
      }
      if (!mounted) return;
      final digest = HaikuoClipboardScan.digestOf(text);
      if (digest == _seenDigest) return;
      // 先记下来再弹窗：取消、导入失败都算处理过，内容不变不再弹。
      _seenDigest = digest;
      await _seenStore.writeDigest(digest);
      final candidates = HaikuoClipboardScan.extract(text);
      if (candidates.isEmpty || !mounted) return;
      _clipboardPromptActive = true;
      try {
        if (candidates.length == 1) {
          await _promptSingleClipboardCandidate(candidates.single);
        } else {
          await _promptMultipleClipboardCandidates(candidates);
        }
      } finally {
        _clipboardPromptActive = false;
      }
    } finally {
      _clipboardChecking = false;
    }
  }

  /// 单个口令：温馨提示对话框，点空白处或取消都能退出，不困住用户。
  Future<void> _promptSingleClipboardCandidate(
    HaikuoClipboardCandidate candidate,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('温馨提示'),
        content: const Text('剪贴板检测到小程序规则，是否立即导入？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('立即导入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(
      () => _store.importText(
        candidate.text,
        origin: '剪贴板',
        onDuplicates: _askDuplicates,
      ),
    );
  }

  /// 多个口令：底部列表，点一项导一项，也可全部导入；划掉或点取消即退出。
  Future<void> _promptMultipleClipboardCandidates(
    List<HaikuoClipboardCandidate> candidates,
  ) async {
    final pick = await showModalBottomSheet<_ClipboardPick>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final maxHeight = MediaQuery.sizeOf(context).height * 0.6;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '从剪贴板检测到多个导入口令',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: candidates.length,
                    itemBuilder: (context, index) {
                      final candidate = candidates[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(candidate.label),
                        subtitle: Text(
                          candidate.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: const Icon(Icons.download_rounded),
                        onTap: () => Navigator.pop(
                          context,
                          _ClipboardPick(index: index),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(
                          context,
                          const _ClipboardPick(index: -1),
                        ),
                        child: const Text('全部导入'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    if (pick == null || !mounted) return;
    if (pick.index < 0) {
      await _importClipboardBatch(candidates);
      return;
    }
    final candidate = candidates[pick.index];
    await _run(
      () => _store.importText(
        candidate.text,
        origin: '剪贴板',
        onDuplicates: _askDuplicates,
      ),
    );
  }

  /// 全部导入：逐个走现有导入流程，某条失败只记该条原因、继续其余，
  /// 最后统一汇报一次。
  Future<void> _importClipboardBatch(
    List<HaikuoClipboardCandidate> candidates,
  ) async {
    setState(() => _busy = true);
    var added = 0;
    var updated = 0;
    final failed = <String>[];
    try {
      for (final candidate in candidates) {
        if (!mounted) break;
        try {
          final result = await _store.importText(
            candidate.text,
            origin: '剪贴板',
            onDuplicates: _askDuplicates,
          );
          if (result.cancelled) {
            failed.add('${candidate.label}：已取消');
          } else {
            added += result.added.length;
            updated += result.updated.length;
          }
        } on HaikuoFormatException catch (error) {
          failed.add('${candidate.label}：${error.message}');
        } catch (error) {
          failed.add('${candidate.label}：$error');
        }
      }
      await _load();
      if (!mounted) return;
      final parts = <String>[
        if (added > 0) '新增 $added 个',
        if (updated > 0) '更新 $updated 个',
      ];
      final summary = parts.isEmpty ? '没有新增条目' : parts.join('，');
      _snack(
        failed.isEmpty
            ? summary
            : '$summary；${failed.length} 条失败：${failed.join('；')}',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() async {
    // 生产上页面用默认仓库：先播种 App 自带的海阔规则，再列出本地库。
    // 测试注入的仓库不自动播种（保持空库断言可测，播种由单测直接调方法验）。
    if (widget.store == null) {
      await _store.ensureBuiltinRules();
    }
    final programs = await _store.list();
    if (!mounted) return;
    setState(() {
      _programs = programs;
      _loading = false;
    });
  }

  Future<HaikuoDuplicateDecision> _askDuplicates(
    List<HaikuoDuplicate> duplicates,
  ) {
    return showHaikuoDuplicateDialog(context, duplicates);
  }

  Future<void> _importFile() async {
    if (_busy) return;
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json', 'txt', 'zip', 'hiker', 'hk'],
      dialogTitle: '选择海阔小程序 JSON',
    );
    if (files.isEmpty) return;
    final picked = files.first;
    // file_picker 13.x 的 PlatformFile 只有 file:// 的 Uri 才有本地路径；
    // 从下载器 / SAF 选到的 content:// 文件 path 是 null，
    // 这就是手机上“选了文件却导不进去”的根因：以前这里直接报
    // “没拿到文件路径”就退了。现在先走路径（快），拿不到路径就用
    // readAsBytes() 按 Uri 读字节兜底，只有两者都拿不到才报错。
    final path = picked.path;
    if (path != null) {
      await _run(
        () => _store.importFile(File(path), onDuplicates: _askDuplicates),
      );
      return;
    }
    try {
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) {
        _snack('选到的文件是空的');
        return;
      }
      await _run(
        () => _store.importBytes(
          bytes,
          origin: '文件：${picked.name}',
          onDuplicates: _askDuplicates,
        ),
      );
    } catch (error) {
      _snack('没拿到文件路径，也读不出文件内容：$error');
    }
  }

  Future<void> _importCommand() async {
    if (_busy) return;
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('口令导入'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '粘贴海阔视界的小程序口令、JSON 内容或分享链接都可以。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              minLines: 4,
              maxLines: 8,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '海阔视界小程序口令：……',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              final value = data?.text ?? '';
              if (value.isNotEmpty) controller.text = value;
            },
            child: const Text('从剪贴板粘贴'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    await _run(
      () => _store.importText(text, origin: '口令', onDuplicates: _askDuplicates),
    );
  }

  Future<void> _importLink() async {
    if (_busy) return;
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从链接导入'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://…… 小程序 JSON 地址',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    await _run(() => _store.importUrl(url, onDuplicates: _askDuplicates));
  }

  /// 内置示例：格式参考自公开的海阔规则仓库（hikerViewRules 等）。
  Future<void> _importSamples() async {
    if (_busy) return;
    await _run(() async {
      final raw = await rootBundle.loadString('assets/haikuo_samples.json');
      final programs = HaikuoCodecBridge.parseSample(raw);
      return _store.addAll(
        programs,
        origin: '内置示例',
        onDuplicates: _askDuplicates,
      );
    });
  }

  /// 手动恢复内置规则：忽略版本标记，重新播种（补回被删的内置规则、
  /// 同名旧版替换为新版）。用户导入的规则不受影响。
  Future<void> _restoreBuiltins() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final count = await _store.ensureBuiltinRules(force: true);
      await _load();
      if (!mounted) return;
      _snack(count > 0 ? '已恢复 $count 条内置规则' : '内置规则已是最新，无需恢复');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(Future<HaikuoImportResult> Function() action) async {
    setState(() => _busy = true);
    try {
      final result = await action();
      await _load();
      if (!mounted) return;
      _snack(result.summary);
    } on HaikuoFormatException catch (error) {
      _snack(error.message);
    } catch (error) {
      _snack('导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String text) {
    if (!mounted || text.isEmpty) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _open(HaikuoProgram program) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => HaikuoRunnerPage(program: program),
      ),
    );
  }

  Future<void> _showInfo(HaikuoProgram program) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(program.name),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('类型：${haikuoKindLabel(program.kind)}'),
              if (program.author.isNotEmpty) Text('作者：${program.author}'),
              if (program.version.isNotEmpty) Text('版本：${program.version}'),
              if (program.origin.isNotEmpty) Text('来源：${program.origin}'),
              if (program.url.isNotEmpty) Text('入口：${program.url}'),
              if (program.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(program.description),
              ],
              const SizedBox(height: 10),
              Text(
                '脚本长度：${program.script.length} 字符',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(HaikuoProgram program) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除小程序'),
        content: Text('确定删除「${program.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _store.remove(program.id);
    await _load();
    _snack('已删除');
  }

  Future<void> _export(HaikuoProgram program) async {
    // 复制完整规则 JSON（含 class/sort 等声明），不是重建的子集，
    // 否则粘回去再导入会丢分类。能格式化就格式化，方便人读。
    final raw = HaikuoCodec.shareJson(program);
    var text = raw;
    try {
      text = const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } on FormatException {
      // 原始文本不是合法 JSON，原样复制。
    }
    await Clipboard.setData(ClipboardData(text: text));
    _snack('已复制「${program.name}」的 JSON 到剪贴板');
  }

  /// 生成口令分享：把规则编成官方 ￥ 口令，弹窗展示、可一键复制。
  /// 对方在口令导入里粘贴即可认回（往返已由编解码测试覆盖）。
  /// 云剪贴板 6 的上传接口未公开，这里不出假短码，只出本地口令。
  Future<void> _shareCode(HaikuoProgram program) async {
    final code = HaikuoCodec.buildShareCode(program);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('分享「${program.name}」'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '把下面这段口令发给对方，对方在海阔页点“导入口令”粘贴即可。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 10),
              SelectableText(
                code,
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (context.mounted) Navigator.pop(context);
              _snack('口令已复制到剪贴板');
            },
            child: const Text('复制口令'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator.adaptive(
            onRefresh: _load,
            child: _programs.isEmpty ? _empty() : _grid(),
          );
    // 嵌进小程序页「海阔」标签时不带自己的 AppBar / Scaffold。
    if (widget.embedded) {
      return Column(
        children: [
          Expanded(child: body),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('海阔小程序'),
        actions: [
          IconButton(
            tooltip: '导入 JSON 文件',
            icon: const Icon(Icons.file_open_outlined),
            onPressed: _busy ? null : _importFile,
          ),
          IconButton(
            tooltip: '口令导入',
            icon: const Icon(Icons.key_rounded),
            onPressed: _busy ? null : _importCommand,
          ),
          PopupMenuButton<String>(
            tooltip: '更多导入方式',
            onSelected: (value) {
              switch (value) {
                case 'link':
                  _importLink();
                case 'samples':
                  _importSamples();
                case 'restore':
                  _restoreBuiltins();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'link', child: Text('从链接导入')),
              PopupMenuItem(value: 'samples', child: Text('导入内置示例')),
              PopupMenuItem(value: 'restore', child: Text('恢复内置规则')),
            ],
          ),
        ],
      ),
      body: body,
      bottomNavigationBar: _busy
          ? const LinearProgressIndicator(minHeight: 2)
          : null,
    );
  }

  Widget _empty() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 24),
      children: [
        const Icon(Icons.extension_rounded, size: 56),
        const SizedBox(height: 14),
        const Text(
          '还没有导入海阔小程序',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          '支持导入海阔视界的 JSON 小程序文件、剪贴板口令，也可以直接贴分享链接。',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 22),
        FilledButton.icon(
          onPressed: _busy ? null : _importFile,
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('导入 JSON 文件'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _busy ? null : _importCommand,
          icon: const Icon(Icons.key_rounded),
          label: const Text('口令导入'),
        ),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: _busy ? null : _importSamples,
          icon: const Icon(Icons.auto_awesome_rounded),
          label: const Text('导入内置示例'),
        ),
      ],
    );
  }

  /// 平铺网格：与小程序页「已安装」tab 同一样式（图标块 + 站名在下），
  /// 四列。角标 ⋮ 打开操作表（打开/详情/复制 JSON/删除），长按仍直接弹详情。
  Widget _grid() {
    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 28),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 18,
        crossAxisSpacing: 8,
        childAspectRatio: 0.74,
      ),
      itemCount: _programs.length,
      itemBuilder: (context, index) {
        final program = _programs[index];
        return _ProgramTile(
          program: program,
          onTap: () => _open(program),
          onLongPress: () => _showActions(program),
        );
      },
    );
  }

  Future<void> _showActions(HaikuoProgram program) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: const Text('打开'),
              onTap: () => Navigator.pop(context, 'open'),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('详情'),
              onTap: () => Navigator.pop(context, 'info'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('复制 JSON'),
              onTap: () => Navigator.pop(context, 'export'),
            ),
            ListTile(
              leading: const Icon(Icons.share_rounded),
              title: const Text('生成口令分享'),
              onTap: () => Navigator.pop(context, 'share'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('删除'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'open':
        _open(program);
      case 'info':
        _showInfo(program);
      case 'export':
        _export(program);
      case 'share':
        _shareCode(program);
      case 'delete':
        _delete(program);
    }
  }
}

/// 平铺图标块：与「已安装」tab 的 _MiniAppTile 同一样式（58 圆角块 +
/// 站名在下），另加一行小字副标题（作者 · 版本 · 类型）。点按打开，
/// 长按弹出操作（打开/详情/复制 JSON/生成口令分享/删除），图标上
/// 不再放 ⋮ 角标按钮。
class _ProgramTile extends StatelessWidget {
  const _ProgramTile({
    required this.program,
    required this.onTap,
    required this.onLongPress,
  });

  final HaikuoProgram program;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = _haikuoIconColor(program.id);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [color, Color.lerp(color, Colors.black, 0.28)!],
              ),
              borderRadius: BorderRadius.circular(15),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.28),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              _haikuoIconGlyph(program.name),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            program.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.25,
              fontWeight: FontWeight.w500,
              color: colors.onSurface,
            ),
          ),
          Text(
            program.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 9.5, color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

// 与 mini_app_home_page.dart 的色板/取色保持一致（那文件反向依赖本页，
// 直接 import 会循环，故在此镜像一份）。
const List<Color> _kHaikuoIconPalette = [
  Color(0xFFFF8A3D),
  Color(0xFF3B82F6),
  Color(0xFFA855F7),
  Color(0xFF22C55E),
  Color(0xFFEF4444),
  Color(0xFF14B8A6),
  Color(0xFFF59E0B),
  Color(0xFF6366F1),
];

Color _haikuoIconColor(String seed) {
  if (seed.isEmpty) return _kHaikuoIconPalette.first;
  var hash = 0;
  for (final unit in seed.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return _kHaikuoIconPalette[hash % _kHaikuoIconPalette.length];
}

final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// 站名首字：跳过开头的表情/符号（如 🔞），取第一个字母或数字；
/// 全是符号时退回第一个字符，空名时用“海”。
/// 注意不能用 substring(0, 1)：🔞 是代理对，截一半会显示成“?”。
String _haikuoIconGlyph(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '海';
  for (final rune in trimmed.runes) {
    final ch = String.fromCharCode(rune);
    if (_letterOrDigit.hasMatch(ch)) return ch;
  }
  return String.fromCharCode(trimmed.runes.first);
}

/// 多口令底部列表的选择结果：index >= 0 导入指定的一条，-1 全部导入。
class _ClipboardPick {
  const _ClipboardPick({required this.index});

  final int index;
}

/// 供示例资源解析使用的小桥接，避免页面层直接依赖编解码细节。
abstract final class HaikuoCodecBridge {
  static List<HaikuoProgram> parseSample(String raw) {
    return HaikuoCodec.parseText(raw, origin: '内置示例');
  }
}
