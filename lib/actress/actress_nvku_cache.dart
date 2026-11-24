import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models.dart';

/// 女优库模块进库会话缓存（2026-11-24 进库不重载）。
///
/// 根因：底部导航切走演员库时宿主（通用分支 `_tabBody`、红果首页
/// `switch (_tab)`）直接把 [ActressNvkuPage] 换掉，页实例被释放，
/// 再进就是全新实例、`_boot()` 把收藏/开库/标签/文件夹/封面/分类/
/// 作品第一页全量重查一遍——文件夹计数冷缓存 13–76 秒、封面 26 条
/// 查询 11–14 秒、分类还要走一趟网络，用户进去就要等。
/// 宿主换页是壳的行为，不在本模块改；这里把“已查出来的数据”留在
/// 进程里，第二次进库直接用缓存、不再碰数据库与网络。
///
/// 缓存只覆盖“进库重查”的那几份数据，不碰写路径：
/// - 文件夹/封面/标签：key 含库文件指纹（路径 + mtime + 大小），
///   库文件一变（同步/现爬/镜像写库、用户在外面换了文件）就自然
///   失效、重查；标签切换时 key 里标签变了，旧 key 不影响新查。
/// - 分类：站点分类按站 id 缓存（会话内不变）；本地/主分类按库
///   文件指纹缓存。
/// - 作品第一页：key = 分类 + 搜索词，5 分钟内再进直接用、不取；
///   过期了先上旧页、后台悄悄刷一遍再换新页（不转圈、不清列表）。
///
/// 失效（只在“数据真变了”时清，不在每次进库时清）：
/// - 用户主动刷新（下拉刷新、顶栏刷新钮）→ [clear] 全清再查；
/// - 列表页同步/现爬/叠加/镜像完成、手动重读 → 列表页
///   `_clearListCaches` 里调 [clear]，一处清就全覆盖。
/// 文件指纹是 mtime + 大小（schema 指纹不认内容变化，不能用它）。
class NvkuEntryCache {
  NvkuEntryCache._();

  /// 作品第一页缓存有效期：5 分钟内再进直接用、不取网络；
  /// 过期了先上旧页、后台悄悄刷。
  static const worksTtl = Duration(minutes: 5);

  /// 作品第一页最多留 8 个 key（分类 + 搜索词组合），超了淘汰
  /// 最久没用的一个；一页只有 30 条 Drama，内存可忽略。
  static const _maxWorksKeys = 8;

  static final _folders =
      <String, ({List<(String, int)> folders, Map<String, String> covers})>{};
  static final _tags =
      <String, ({String key, List<(String, int)> values})>{};
  static final _siteCategories =
      <String, ({List<CatalogCategory> items, bool offline})>{};
  static final _localCategories = <String, List<CatalogCategory>>{};
  static final _mainCategories = <String, List<CatalogCategory>>{};
  static final _works = <String, NvkuWorksEntry>{};

  /// 库文件指纹（路径 + mtime + 大小）：文件打不开/不存在时回 ''，
  /// 调用方仍按路径分 key，只是不再靠指纹防内容变化。
  static String dbStamp(String dbPath) {
    if (dbPath.isEmpty) return '';
    try {
      final stat = File(dbPath).statSync();
      return '${stat.modified.millisecondsSinceEpoch}|${stat.size}';
    } catch (_) {
      return '';
    }
  }

  static String _foldersKey(
    String stamp, {
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) => '$stamp|$videoTag|$category|$genericTagKey';

  static ({List<(String, int)> folders, Map<String, String> covers})?
  folders(
    String stamp, {
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) => _folders[_foldersKey(
    stamp,
    videoTag: videoTag,
    category: category,
    genericTagKey: genericTagKey,
  )];

  static void putFolders(
    String stamp, {
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
    required List<(String, int)> folders,
    required Map<String, String> covers,
  }) {
    _folders[_foldersKey(
      stamp,
      videoTag: videoTag,
      category: category,
      genericTagKey: genericTagKey,
    )] = (folders: folders, covers: covers);
  }

  static String _tagsKey(String stamp, {required bool strict}) =>
      '$stamp|${strict ? 'strict' : 'generic'}';

  static ({String key, List<(String, int)> values})? tags(
    String stamp, {
    required bool strict,
  }) => _tags[_tagsKey(stamp, strict: strict)];

  static void putTags(
    String stamp, {
    required bool strict,
    required ({String key, List<(String, int)> values}) value,
  }) {
    _tags[_tagsKey(stamp, strict: strict)] = value;
  }

  static ({List<CatalogCategory> items, bool offline})? siteCategories(
    String sourceId,
  ) => _siteCategories[sourceId];

  static void putSiteCategories(
    String sourceId,
    List<CatalogCategory> items, {
    required bool offline,
  }) {
    _siteCategories[sourceId] = (items: items, offline: offline);
  }

  static List<CatalogCategory>? localCategories(String stamp) =>
      _localCategories[stamp];

  static void putLocalCategories(
    String stamp,
    List<CatalogCategory> items,
  ) {
    _localCategories[stamp] = items;
  }

  static List<CatalogCategory>? mainCategories(String stamp) =>
      _mainCategories[stamp];

  static void putMainCategories(
    String stamp,
    List<CatalogCategory> items,
  ) {
    _mainCategories[stamp] = items;
  }

  static String _worksKey(String category, String query) =>
      '$category|$query';

  /// 作品第一页缓存（未命中回 null；命中但过期也回记录，由调用方
  /// 先上旧页、后台悄悄刷）。
  static NvkuWorksEntry? worksFirstPage(String category, String query) =>
      _works[_worksKey(category, query)];

  static void putWorksFirstPage(
    String category,
    String query, {
    required List<Drama> rows,
    required bool hasMore,
  }) {
    final key = _worksKey(category, query);
    _works.remove(key);
    while (_works.length >= _maxWorksKeys) {
      _works.remove(_works.keys.first);
    }
    _works[key] = NvkuWorksEntry(
      rows: rows,
      hasMore: hasMore,
      savedAt: DateTime.now(),
    );
  }

  /// 手动刷新 / 库内容变了时全清，下次进库重查。
  /// 只清缓存，不碰数据库连接与页面状态。
  static void clear() {
    _folders.clear();
    _tags.clear();
    _siteCategories.clear();
    _localCategories.clear();
    _mainCategories.clear();
    _works.clear();
  }

  /// 测试用：清掉会话缓存，免得一个测试的缓存漏到下一个。
  @visibleForTesting
  static void clearForTest() => clear();
}

/// 作品第一页缓存项：行 + 有没有下一页 + 存入时间。
class NvkuWorksEntry {
  const NvkuWorksEntry({
    required this.rows,
    required this.hasMore,
    required this.savedAt,
  });

  final List<Drama> rows;
  final bool hasMore;
  final DateTime savedAt;

  /// 5 分钟内算新鲜：再进直接用、不取网络。
  bool get isFresh =>
      DateTime.now().difference(savedAt) < NvkuEntryCache.worksTtl;
}
