import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'haikuo_helpers.dart';
import 'haikuo_home_page.dart';
import 'haikuo_program.dart';
import 'haikuo_store.dart';

/// 海阔规则仓库索引地址（皇帝影院海阔规则仓库，`main` 分支根目录）。
///
/// 改仓库名 / 分支只改这一处：单条规则的下载地址按索引所在目录拼
/// [HaikuoRuleIndexEntry.file] 相对路径得出，见
/// [HaikuoRuleIndexEntry.downloadUri]。
const String haikuoRulesIndexUrl =
    'https://raw.githubusercontent.com/hoyittvggfh45/haikuo-rules/main/index.json';

/// 仓库拉取失败（网络 / HTTP / 内容不合法）时抛出的异常，消息可直接
/// 展示给用户。
class HaikuoRuleMarketException implements Exception {
  const HaikuoRuleMarketException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 版本号稳妥比较：索引里的 version 可能是数字（16）也可能是字符串
/// （"16" / "1.2"），本地规则的 version 是字符串。
///
/// 先把两边转成字符串：都能按数值理解时按数值比（整数 / 小数 /
/// 点分数值逐段比），比不了再按字典序。任何异常都退回字典序，
/// 绝不抛错。a < b 回负数，相等回 0，a > b 回正数。
int compareHaikuoVersions(Object? a, Object? b) {
  final left = '${a ?? ''}'.trim();
  final right = '${b ?? ''}'.trim();
  try {
    final numeric = _compareNumericVersions(left, right);
    if (numeric != null) return numeric;
  } catch (_) {
    // 数值比较出任何意外都退回字典序。
  }
  return left.compareTo(right);
}

/// 两边都是纯数值或点分纯数值时按数值比；有一边不是数值形态回 null。
int? _compareNumericVersions(String a, String b) {
  final aParts = a.split('.');
  final bParts = b.split('.');
  final aNumbers = <num>[];
  final bNumbers = <num>[];
  for (final part in aParts) {
    final value = num.tryParse(part.trim());
    if (value == null) return null;
    aNumbers.add(value);
  }
  for (final part in bParts) {
    final value = num.tryParse(part.trim());
    if (value == null) return null;
    bNumbers.add(value);
  }
  final length = aNumbers.length > bNumbers.length
      ? aNumbers.length
      : bNumbers.length;
  for (var i = 0; i < length; i++) {
    final av = i < aNumbers.length ? aNumbers[i] : 0;
    final bv = i < bNumbers.length ? bNumbers[i] : 0;
    if (av != bv) return av.compareTo(bv);
  }
  return 0;
}

/// 索引里的一条海阔规则。
class HaikuoRuleIndexEntry {
  const HaikuoRuleIndexEntry({
    required this.title,
    required this.file,
    required this.version,
    this.author = '',
    this.group = '',
    this.icon = '',
    this.updated = '',
  });

  factory HaikuoRuleIndexEntry.fromJson(Map<String, dynamic> json) {
    return HaikuoRuleIndexEntry(
      title: '${json['title'] ?? ''}'.trim(),
      file: '${json['file'] ?? ''}'.trim(),
      // version 在索引里是数字（16）；本地规则里是字符串。统一存
      // 字符串形态，比较走 [compareHaikuoVersions]。
      version: '${json['version'] ?? ''}'.trim(),
      author: '${json['author'] ?? ''}'.trim(),
      group: '${json['group'] ?? ''}'.trim(),
      icon: '${json['icon'] ?? ''}'.trim(),
      updated: '${json['updated'] ?? ''}'.trim(),
    );
  }

  final String title;

  /// 相对索引地址的规则文件路径，如 `rules/鉴黄师.json`。
  final String file;

  final String version;
  final String author;
  final String group;
  final String icon;
  final String updated;

  /// 单条规则的下载地址：索引地址同目录 + [file] 相对路径。
  /// 用 pathSegments 拼装，文件名里的中文会做 URL 编码。
  Uri downloadUri(Uri indexUri) {
    final segments = <String>[
      ...indexUri.pathSegments.take(
        indexUri.pathSegments.isEmpty ? 0 : indexUri.pathSegments.length - 1,
      ),
      ...file.split('/').where((part) => part.isNotEmpty),
    ];
    return indexUri.replace(pathSegments: segments);
  }
}

/// 解析好的仓库索引。
class HaikuoRuleIndex {
  const HaikuoRuleIndex({
    required this.name,
    required this.updated,
    required this.rules,
    required this.sourceUri,
  });

  factory HaikuoRuleIndex.parse(String text, {required Uri sourceUri}) {
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw const HaikuoRuleMarketException('仓库索引不是合法 JSON');
    }
    if (decoded is! Map) {
      throw const HaikuoRuleMarketException('仓库索引不是合法 JSON');
    }
    final json = Map<String, dynamic>.from(decoded);
    final rules = <HaikuoRuleIndexEntry>[];
    for (final row in json['rules'] as List? ?? const []) {
      if (row is! Map) continue;
      final entry = HaikuoRuleIndexEntry.fromJson(
        Map<String, dynamic>.from(row),
      );
      if (entry.title.isEmpty || entry.file.isEmpty) continue;
      rules.add(entry);
    }
    return HaikuoRuleIndex(
      name: '${json['name'] ?? ''}'.trim(),
      updated: '${json['updated'] ?? ''}'.trim(),
      rules: rules,
      sourceUri: sourceUri,
    );
  }

  final String name;
  final String updated;
  final List<HaikuoRuleIndexEntry> rules;
  final Uri sourceUri;
}

/// 一条索引规则相对本地库的安装状态。
enum HaikuoRuleInstallState { notInstalled, installed, updateAvailable }

/// 按字节拉取一个地址（测试注入假实现，不真联网）。
typedef HaikuoMarketFetcher = Future<List<int>> Function(Uri uri);

/// 海阔规则仓库服务：拉索引、下载单条规则、走海阔既有导入链路落库、
/// 对比本地库算安装状态。落库只调 [HaikuoStore.importBytes]
///（与文件导入同一条链：解析 → 同名处理 → 写 programs.json），
/// 不另写一套存储。
class HaikuoRuleMarketService {
  HaikuoRuleMarketService({
    HaikuoStore? store,
    this.fetcher,
    this.httpClient,
    this.indexUrl = haikuoRulesIndexUrl,
  }) : store = store ?? HaikuoStore();

  final HaikuoStore store;
  final String indexUrl;
  final HaikuoMarketFetcher? fetcher;
  final http.Client? httpClient;

  Uri get indexUri => Uri.parse(indexUrl);

  Future<List<int>> _fetch(Uri uri) async {
    final fetch = fetcher;
    if (fetch != null) return fetch(uri);
    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .get(
            uri,
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
              'Accept': 'application/json, text/plain, */*',
            },
          )
          // 20261126+1 定版：实拉同一索引耗时 17~103 秒，30 秒在慢网下必频繁
          // 假失败，索引与规则拉取统一放宽到 90 秒（加载态照旧、失败仍走空态重试）。
          .timeout(const Duration(seconds: 90));
      if (response.statusCode != 200) {
        throw HaikuoRuleMarketException('下载失败：HTTP ${response.statusCode}');
      }
      return response.bodyBytes;
    } on HaikuoRuleMarketException {
      rethrow;
    } catch (error) {
      throw HaikuoRuleMarketException('下载失败：$error');
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// 拉仓库索引；失败抛 [HaikuoRuleMarketException]，不返回假数据。
  Future<HaikuoRuleIndex> fetchIndex() async {
    final bytes = await _fetch(indexUri);
    final text = utf8.decode(bytes, allowMalformed: true);
    return HaikuoRuleIndex.parse(text, sourceUri: indexUri);
  }

  /// 本地库里与索引条目同名（按规则标题归一化比对）的规则，没有回 null。
  Future<HaikuoProgram?> findInstalled(HaikuoRuleIndexEntry entry) async {
    final wanted = normalizeRuleTitle(entry.title);
    for (final program in await store.list()) {
      if (normalizeRuleTitle(program.name) == wanted) return program;
    }
    return null;
  }

  /// 已装状态：本地没有 → 未装；本地版本低于索引 → 可更新；
  /// 其余（相等或更高）→ 已安装。
  Future<HaikuoRuleInstallState> installState(
    HaikuoRuleIndexEntry entry,
  ) async {
    final installed = await findInstalled(entry);
    if (installed == null) return HaikuoRuleInstallState.notInstalled;
    if (compareHaikuoVersions(entry.version, installed.version) > 0) {
      return HaikuoRuleInstallState.updateAvailable;
    }
    return HaikuoRuleInstallState.installed;
  }

  /// 一次算齐整个索引的安装状态（列表只读一次本地库）。
  Future<Map<String, HaikuoRuleInstallState>> installStates(
    HaikuoRuleIndex index,
  ) async {
    final programs = await store.list();
    final byName = <String, HaikuoProgram>{};
    for (final program in programs) {
      byName.putIfAbsent(normalizeRuleTitle(program.name), () => program);
    }
    return {
      for (final entry in index.rules)
        entry.title: () {
          final installed = byName[normalizeRuleTitle(entry.title)];
          if (installed == null) return HaikuoRuleInstallState.notInstalled;
          if (compareHaikuoVersions(entry.version, installed.version) > 0) {
            return HaikuoRuleInstallState.updateAvailable;
          }
          return HaikuoRuleInstallState.installed;
        }(),
    };
  }

  /// 下载单条规则并走海阔既有导入链路装入本地库。
  ///
  /// 同名处理完全沿用既有导入口径：由调用方传 [onDuplicates]
  ///（页面层传 `showHaikuoDuplicateDialog`），不传时按
  /// [HaikuoStore.addAll] 默认口径保留两者，不静默覆盖。
  Future<HaikuoImportResult> install(
    HaikuoRuleIndexEntry entry, {
    required HaikuoRuleIndex index,
    Future<HaikuoDuplicateDecision> Function(List<HaikuoDuplicate> duplicates)?
    onDuplicates,
  }) async {
    final bytes = await _fetch(entry.downloadUri(index.sourceUri));
    return store.importBytes(
      bytes,
      origin: '海阔规则仓库',
      onDuplicates: onDuplicates,
    );
  }
}

/// 「海阔规则」市场区：拉仓库索引 → 分组列表 → 点安装走海阔导入链路。
///
/// 与 .idjplugin 插件条目分区呈现：这里只装海阔 JSON 规则，落到
/// [HaikuoStore]，不经过插件安装器。
class HaikuoRuleMarketView extends StatefulWidget {
  const HaikuoRuleMarketView({super.key, this.service, this.onDuplicates});

  /// 测试注入假服务；生产环境为空，现建默认服务。
  final HaikuoRuleMarketService? service;

  /// 同名规则处理回调（测试可注入）；为空时用既有同名弹窗
  /// [showHaikuoDuplicateDialog]。
  final Future<HaikuoDuplicateDecision> Function(
    BuildContext context,
    List<HaikuoDuplicate> duplicates,
  )?
  onDuplicates;

  @override
  State<HaikuoRuleMarketView> createState() => _HaikuoRuleMarketViewState();
}

class _HaikuoRuleMarketViewState extends State<HaikuoRuleMarketView> {
  late final HaikuoRuleMarketService _service =
      widget.service ?? HaikuoRuleMarketService();

  var _state = 'loading'; // loading | ready | empty | error
  var _error = '';
  HaikuoRuleIndex? _index;
  var _states = const <String, HaikuoRuleInstallState>{};
  final Set<String> _installing = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _state = 'loading';
      _error = '';
    });
    try {
      final index = await _service.fetchIndex();
      final states = await _service.installStates(index);
      if (!mounted) return;
      setState(() {
        _index = index;
        _states = states;
        _state = index.rules.isEmpty ? 'empty' : 'ready';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = 'error';
        _error = error.toString();
      });
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<HaikuoDuplicateDecision> _askDuplicates(
    List<HaikuoDuplicate> duplicates,
  ) {
    final handler = widget.onDuplicates;
    if (handler != null) return handler(context, duplicates);
    return showHaikuoDuplicateDialog(context, duplicates);
  }

  Future<void> _install(HaikuoRuleIndexEntry entry) async {
    final index = _index;
    if (index == null || _installing.contains(entry.title)) return;
    setState(() => _installing.add(entry.title));
    try {
      final result = await _service.install(
        entry,
        index: index,
        onDuplicates: _askDuplicates,
      );
      if (!mounted) return;
      if (result.cancelled) {
        _toast('已取消安装「${entry.title}」');
      } else if (result.added.isEmpty && result.updated.isEmpty) {
        _toast('「${entry.title}」没有装入任何规则');
      } else {
        _toast('已安装「${entry.title}」');
      }
      final states = await _service.installStates(index);
      if (mounted) setState(() => _states = states);
    } catch (error) {
      if (mounted) _toast('安装失败：$error');
    } finally {
      if (mounted) setState(() => _installing.remove(entry.title));
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_state) {
      case 'loading':
        return const Center(child: CircularProgressIndicator());
      case 'error':
        return _emptyState(
          icon: Icons.cloud_off_rounded,
          title: '海阔规则仓库拉取失败',
          description: '网络失败：$_error',
          actionLabel: '重试',
        );
      case 'empty':
        return _emptyState(
          icon: Icons.storefront_outlined,
          title: '仓库暂时是空的',
          description: '索引里还没有可安装的海阔规则。',
          actionLabel: '重新拉取',
        );
      default:
        return _listBody();
    }
  }

  Widget _emptyState({
    required IconData icon,
    required String title,
    required String description,
    required String actionLabel,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              description,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: () => unawaited(_load()),
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }

  Widget _listBody() {
    final index = _index!;
    // 按索引里的 group 分组呈现，组内保持索引顺序。
    final groups = <String, List<HaikuoRuleIndexEntry>>{};
    for (final entry in index.rules) {
      groups.putIfAbsent(entry.group, () => []).add(entry);
    }
    final children = <Widget>[];
    if (index.name.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
          child: Text(
            index.updated.isEmpty
                ? index.name
                : '${index.name} · 更新于 ${index.updated}',
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
      );
    }
    for (final group in groups.entries) {
      if (group.key.isNotEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
            child: Text(
              group.key,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
        );
      }
      for (final entry in group.value) {
        children.add(_ruleRow(entry));
      }
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: children,
      ),
    );
  }

  Widget _ruleRow(HaikuoRuleIndexEntry entry) {
    final state = _states[entry.title] ?? HaikuoRuleInstallState.notInstalled;
    final installing = _installing.contains(entry.title);
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Row(
          children: [
            _icon(entry),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (entry.version.isNotEmpty) 'v${entry.version}',
                      if (entry.author.isNotEmpty) entry.author,
                      if (entry.updated.isNotEmpty) entry.updated,
                    ].join(' · '),
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ],
              ),
            ),
            _actionButton(entry, state, installing),
          ],
        ),
      ),
    );
  }

  Widget _icon(HaikuoRuleIndexEntry entry) {
    const fallback = Icon(Icons.rule_rounded, size: 22);
    if (entry.icon.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        entry.icon,
        width: 26,
        height: 26,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }

  Widget _actionButton(
    HaikuoRuleIndexEntry entry,
    HaikuoRuleInstallState state,
    bool installing,
  ) {
    if (installing) {
      return const FilledButton(
        onPressed: null,
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    switch (state) {
      case HaikuoRuleInstallState.installed:
        return const FilledButton(onPressed: null, child: Text('已安装'));
      case HaikuoRuleInstallState.updateAvailable:
        return FilledButton(
          onPressed: () => unawaited(_install(entry)),
          child: const Text('更新'),
        );
      case HaikuoRuleInstallState.notInstalled:
        return FilledButton(
          onPressed: () => unawaited(_install(entry)),
          child: const Text('安装'),
        );
    }
  }
}
