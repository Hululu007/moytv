import 'models.dart';

/// TG 两站（ZakaTg / ZakaTgMovie）目录 1 小时缓存：只放内存，不落盘。
///
/// 口径：按站 + 分类区分，只缓存第 1 页的普通浏览（无搜索词、无筛
/// 选）；搜索、详情、翻页（第 2 页起）、手动强制刷新一律不走缓存。
/// 命中条件：同一站 + 分类、存入未满 [ttl]；到期后下一次打开重新拉。
class TgCatalogCache {
  TgCatalogCache({
    this.ttl = const Duration(hours: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _now;
  final _entries = <String, _TgCatalogCacheEntry>{};

  static String keyFor(String source, String category) => '$source\n$category';

  CatalogPage? lookup(String source, String category) {
    final key = keyFor(source, category);
    final entry = _entries[key];
    if (entry == null) return null;
    if (_now().difference(entry.storedAt) >= ttl) {
      _entries.remove(key);
      return null;
    }
    return entry.page;
  }

  void store(String source, String category, CatalogPage page) {
    _entries[keyFor(source, category)] = _TgCatalogCacheEntry(
      page: page,
      storedAt: _now(),
    );
  }

  void clear() => _entries.clear();
}

class _TgCatalogCacheEntry {
  const _TgCatalogCacheEntry({required this.page, required this.storedAt});

  final CatalogPage page;
  final DateTime storedAt;
}
