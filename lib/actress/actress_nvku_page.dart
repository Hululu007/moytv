import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core_bridge.dart';
import '../local_store.dart';
import '../models.dart';
import '../player_picker.dart';
import 'actress_database.dart';
import 'actress_list_page.dart';
import 'actress_models.dart';
import '../whos_fallback.dart';
import '../whos_local_library.dart';

/// 女优库（2026-11-21 用户令：模块区域 UI 改用 nvku 那套网页的样式，
/// 在线站与本地数据库同一套分类与标签索引）。
///
/// 版式照 nvku-8m2c 的网页来：深色底 + 顶栏品牌/条数徽标 + 搜索框 +
/// 底部四个页签（首页 / 分类 / 女优 / 收藏）。数据两条腿：
/// - 在线：nvku 内置源（32 万条、有码/无码/4K/其它），分类与条数取自
///   站点自己的 meta；
/// - 本地：随包 whos 库 + 用户视频库（MYTV/db），分类/厂牌标签与
///   数据库同一口径，在线取不到内容时自动降级到本地，不留白屏。
/// 「女优」页签就是原来的女优库列表页（本地库名册 + 站点筛选 +
/// 同步/现爬都在那边），这里只换外壳，不重做数据层。
class ActressNvkuPage extends StatefulWidget {
  const ActressNvkuPage({
    super.key,
    required this.repository,
    required this.store,
    this.database,
    this.showTitle = true,
  });

  final AppRepository repository;
  final LocalStore store;
  final ActressDatabase? database;
  final bool showTitle;

  @override
  State<ActressNvkuPage> createState() => _ActressNvkuPageState();
}

// nvku 网页配色（style.css 的 :root）。
const _bg = Color(0xFF0B0B10);
const _card = Color(0xFF171722);
const _line = Color(0xFF242433);
const _tx = Color(0xFFEEEEF5);
const _dim = Color(0xFF8B8B9E);
const _pk = Color(0xFFFF2F6D);

const _favKey = 'actress_nvku_fav';

class _ActressNvkuPageState extends State<ActressNvkuPage> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  var _tab = 0;
  var _query = '';

  var _siteCategories = <CatalogCategory>[];
  var _localCategories = <CatalogCategory>[];
  var _category = 'new';
  var _works = <Drama>[];
  var _page = 1;
  var _hasMore = true;
  var _loading = false;
  var _loadingMore = false;
  var _offline = false;
  var _favorites = <_FavItem>[];
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_boot());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    await _loadFavorites();
    await _loadCategories();
    await _loadWorks(reset: true);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
      unawaited(_loadWorks());
    }
  }

  Future<void> _loadCategories() async {
    var online = const <CatalogCategory>[];
    var offline = false;
    try {
      online = await widget.repository.categories(nvkuSourceId);
    } catch (_) {
      offline = true;
    }
    final library = WhosLocalLibrary.shared;
    final loaded = await library.ensureLoaded();
    final local = loaded
        ? whosLocalCategories(library)
        : const <CatalogCategory>[];
    if (!mounted) return;
    setState(() {
      _siteCategories = online;
      _localCategories = local;
      _offline = offline || online.isEmpty;
      if (_category.isEmpty ||
          ![
            'new',
            ...online.map((c) => c.id),
            ...local.map((c) => c.id),
          ].contains(_category)) {
        _category = 'new';
      }
    });
  }

  /// 作品分页：在线优先，站挂了/取不到就换本地库（分类 id 在两边的
  /// 命名一致：new / rank / brand:xxx，站点分类是 c0/c1/c2/c7）。
  Future<void> _loadWorks({bool reset = false}) async {
    if (reset) {
      final generation = ++_generation;
      setState(() {
        _loading = true;
        _works = [];
        _page = 1;
        _hasMore = true;
      });
      final rows = await _fetchPage(1);
      if (!mounted || generation != _generation) return;
      setState(() {
        _works = rows;
        _page = 2;
        _hasMore = rows.length >= _pageSize;
        _loading = false;
      });
      return;
    }
    if (_loadingMore || !_hasMore || _loading) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    final rows = await _fetchPage(_page);
    if (!mounted || generation != _generation) return;
    setState(() {
      _works = [..._works, ...rows];
      _page += 1;
      _hasMore = rows.length >= _pageSize;
      _loadingMore = false;
    });
  }

  static const _pageSize = 30;

  Future<List<Drama>> _fetchPage(int page) async {
    try {
      final result = await widget.repository.catalog(
        nvkuSourceId,
        page: page,
        query: _query,
        category: _category,
      );
      if (result.items.isNotEmpty) return result.items;
      if (_query.isNotEmpty || page > 1) return result.items;
    } catch (_) {
      if (mounted && !_offline) setState(() => _offline = true);
    }
    // 本地兜底：站被挡/取不到时用随包库与视频库顶上，分类照旧可用。
    final library = WhosLocalLibrary.shared;
    if (!await library.ensureLoaded()) return const [];
    final rows = library.page(
      category: _localCategoryFor(_category),
      query: _query,
      page: page,
      pageSize: _pageSize,
    );
    return [
      for (final work in rows) whosLocalToDrama(work, source: nvkuSourceId),
    ];
  }

  /// 站点分类 → 本地库分类：站点分类（c0/c1/c2/c7）库里没有对应
  /// 维度，落回「最新」；其余 new/rank/brand: 两边同名直接用。
  String _localCategoryFor(String category) {
    if (category.startsWith('brand:') ||
        category == 'rank' ||
        category == 'new') {
      return category;
    }
    return 'new';
  }

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_favKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((row) => _FavItem.fromJson(Map<String, dynamic>.from(row)))
          .toList();
      if (!mounted) return;
      setState(() => _favorites = list);
    } catch (_) {
      // 坏数据不影响页面。
    }
  }

  Future<void> _toggleFavorite(Drama drama) async {
    final hit = _favorites.indexWhere((row) => row.id == drama.id);
    final next = List<_FavItem>.of(_favorites);
    if (hit >= 0) {
      next.removeAt(hit);
    } else {
      next.insert(
        0,
        _FavItem(
          id: drama.id,
          source: drama.source,
          title: drama.title,
          cover: drama.cover,
          code: drama.tags.isNotEmpty ? drama.tags.first : '',
        ),
      );
    }
    setState(() => _favorites = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _favKey,
      jsonEncode([for (final row in next) row.toJson()]),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(hit >= 0 ? '已取消收藏' : '已收藏')));
  }

  bool _isFavorite(String id) => _favorites.any((row) => row.id == id);

  Future<void> _play(Drama drama) async {
    try {
      final detail = await widget.repository.detail(drama);
      if (!mounted) return;
      if (detail.episodes.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这条暂时没有可播地址')));
        return;
      }
      await pushPlayer<void>(
        context,
        detail: detail,
        initialIndex: 0,
        repository: widget.repository,
        store: widget.store,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这条暂时取不到播放地址')));
    }
  }

  void _submitSearch(String value) {
    final next = value.trim();
    // 女优页签（2026-11-21）：这条搜索框由演员列表页接管（同一个
    // controller，列表自己 debounce 搜索），这里不再拿它搜作品，
    // 免得把「首页」那套作品列表也一起刷一遍。
    if (_tab == 2) {
      setState(() {});
      return;
    }
    if (next == _query) return;
    setState(() => _query = next);
    unawaited(_loadWorks(reset: true));
  }

  void _pickCategory(String id) {
    if (_category == id) return;
    setState(() => _category = id);
    unawaited(_loadWorks(reset: true));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _topBar(),
            Expanded(
              child: switch (_tab) {
                1 => _categoryTab(),
                2 => _actressTab(),
                3 => _favoriteTab(),
                _ => _homeTab(),
              },
            ),
          ],
        ),
      ),
      bottomNavigationBar: _bottomTabs(),
    );
  }

  Widget _topBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
      decoration: const BoxDecoration(
        color: Color(0xEB0B0B10),
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: Column(
        children: [
          // 2026-11-22 用户令（顶栏合并全部在顶部）：这一页嵌在片库顶栏
          // 里时（showTitle=false），外层已经有品牌条了，这里不能再出
          // 一条“女优库 + 本地库 + 刷新”，只留搜索框，避免两条顶栏。
          if (widget.showTitle) ...[
            Row(
            children: [
              Text(
                widget.showTitle ? '女优库' : '女优库',
                style: const TextStyle(
                  color: _tx,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .5,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF1D1D29),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _offline ? '本地库' : '在线 + 本地',
                  style: const TextStyle(
                    color: _dim,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '刷新',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh_rounded, color: _dim, size: 20),
                onPressed: () => unawaited(_boot()),
              ),
            ],
          ),
            const SizedBox(height: 8),
          ],
          TextField(
            key: const ValueKey('nvku-search'),
            controller: _search,
            onSubmitted: _submitSearch,
            textInputAction: TextInputAction.search,
            style: const TextStyle(color: _tx, fontSize: 15),
            decoration: InputDecoration(
              isDense: true,
              hintText: _tab == 2 ? '搜女优名 / 番号' : '搜番号 / 片名 / 女优',
              hintStyle: const TextStyle(color: _dim, fontSize: 14),
              prefixIcon: const Icon(Icons.search, color: _dim, size: 20),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, color: _dim, size: 18),
                      onPressed: () {
                        _search.clear();
                        if (_tab == 2) {
                          setState(() {});
                        } else {
                          _submitSearch('');
                        }
                      },
                    ),
              filled: true,
              fillColor: const Color(0xFF15151E),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF3A3A52)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomTabs() {
    const items = [
      (Icons.grid_view_rounded, '首页'),
      (Icons.category_outlined, '分类'),
      (Icons.face_retouching_natural, '女优'),
      (Icons.star_border_rounded, '收藏'),
    ];
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xF20B0B10),
        border: Border(top: BorderSide(color: _line)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: InkWell(
                  onTap: () => setState(() => _tab = i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          items[i].$1,
                          size: 21,
                          color: _tab == i ? _pk : _dim,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          items[i].$2,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: _tab == i
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: _tab == i ? _pk : _dim,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, String note) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 16, 2, 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: _tx,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          Text(note, style: const TextStyle(color: _dim, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _homeTab() {
    final cats = [
      ..._siteCategories,
      ..._localCategories.where(
        (row) => !_siteCategories.any((site) => site.id == row.id),
      ),
    ];
    return RefreshIndicator(
      color: _pk,
      backgroundColor: _card,
      onRefresh: _boot,
      child: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          _sectionTitle(
            _query.isEmpty ? '最新上架' : '搜索结果',
            _query.isEmpty ? '按发行日期' : _query,
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator(color: _pk)),
            )
          else if (_works.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  _query.isEmpty ? '暂时取不到作品' : '没有找到“$_query”',
                  style: const TextStyle(color: _dim),
                ),
              ),
            )
          else
            _workGrid(_works, height: null),
          if (_loadingMore)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator(color: _pk)),
            ),
          if (cats.isNotEmpty && _query.isEmpty) ...[
            _sectionTitle('分类', '${cats.length} 类'),
            _categoryTiles(cats),
          ],
        ],
      ),
    );
  }

  Widget _categoryTiles(List<CatalogCategory> cats) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: cats.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 9,
        crossAxisSpacing: 9,
        childAspectRatio: 2.6,
      ),
      itemBuilder: (context, index) {
        final cat = cats[index];
        final hot = cat.id != 'new' && index < 3;
        return InkWell(
          key: ValueKey('nvku-cat-${cat.id}'),
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            _pickCategory(cat.id);
            setState(() => _tab = 1);
          },
          child: Container(
            padding: const EdgeInsets.fromLTRB(13, 14, 13, 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _line),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: hot
                    ? const [Color(0xFF2A1A26), Color(0xFF15151F)]
                    : const [Color(0xFF1D1D2B), Color(0xFF15151F)],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  cat.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _tx,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  cat.id == 'new' ? '按发行日期' : cat.id,
                  style: const TextStyle(color: _dim, fontSize: 11),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _categoryTab() {
    final cats = [
      ..._siteCategories,
      ..._localCategories.where(
        (row) => !_siteCategories.any((site) => site.id == row.id),
      ),
    ];
    return Column(
      children: [
        if (cats.isNotEmpty)
          SizedBox(
            height: 46,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              itemCount: cats.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final cat = cats[index];
                final on = _category == cat.id;
                return ChoiceChip(
                  key: ValueKey('nvku-chip-${cat.id}'),
                  selected: on,
                  onSelected: (_) => _pickCategory(cat.id),
                  label: Text(cat.name),
                  labelStyle: TextStyle(
                    color: on ? Colors.white : _dim,
                    fontSize: 13,
                  ),
                  backgroundColor: _card,
                  selectedColor: _pk,
                  side: const BorderSide(color: _line),
                  showCheckmark: false,
                );
              },
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: _pk))
              : _works.isEmpty
              ? Center(
                  child: Text(
                    _query.isEmpty ? '这个分类暂时取不到作品' : '没有找到“$_query”',
                    style: const TextStyle(color: _dim),
                  ),
                )
              : GridView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                  itemCount: _works.length + (_hasMore ? 1 : 0),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 130,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.56,
                  ),
                  itemBuilder: (context, index) {
                    if (index >= _works.length) {
                      return const Center(
                        child: CircularProgressIndicator(color: _pk),
                      );
                    }
                    return _workCard(_works[index]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _workGrid(List<Drama> works, {double? height}) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: works.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: 12,
        crossAxisSpacing: 10,
        childAspectRatio: 0.56,
      ),
      itemBuilder: (context, index) => _workCard(works[index]),
    );
  }

  Widget _workCard(Drama drama) {
    final code = drama.tags.isNotEmpty ? drama.tags.first : '';
    final fav = _isFavorite(drama.id);
    return InkWell(
      key: ValueKey('nvku-work-${drama.id}'),
      onTap: () => unawaited(_play(drama)),
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    color: _card,
                    width: double.infinity,
                    height: double.infinity,
                    child: drama.cover.isEmpty
                        ? Center(
                            child: Text(
                              code.isEmpty ? 'NV' : code,
                              style: const TextStyle(color: _dim, fontSize: 12),
                            ),
                          )
                        : Image.network(
                            drama.cover,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          ),
                  ),
                ),
                Positioned(
                  right: 2,
                  top: 2,
                  child: GestureDetector(
                    onTap: () => unawaited(_toggleFavorite(drama)),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        color: Color(0xCC000000),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        fav ? Icons.star : Icons.star_border,
                        size: 15,
                        color: fav ? _pk : _dim,
                      ),
                    ),
                  ),
                ),
                if (drama.onlineDate.isNotEmpty)
                  Positioned(
                    left: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xB3000000),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        drama.onlineDate,
                        style: const TextStyle(color: _tx, fontSize: 10),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Text(
            drama.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _tx, fontSize: 12, height: 1.3),
          ),
        ],
      ),
    );
  }

  Widget _actressTab() {
    return ActressListPage(
      key: const ValueKey('nvku-actress-list'),
      repository: widget.repository,
      store: widget.store,
      database: widget.database,
      showTitle: false,
      // 2026-11-21 用户令：女优页签里不许再冒第二个搜索框——搜索只用
      // 顶栏那一条，本页监听同一个输入框（搜索框置顶、不随列表滚）。
      externalSearch: _search,
    );
  }

  Widget _favoriteTab() {
    if (_favorites.isEmpty) {
      return const Center(
        child: Text('还没有收藏，点卡片右上角的星', style: TextStyle(color: _dim)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: _favorites.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: 12,
        crossAxisSpacing: 10,
        childAspectRatio: 0.56,
      ),
      itemBuilder: (context, index) {
        final row = _favorites[index];
        return _workCard(
          Drama(
            id: row.id,
            source: row.source,
            sourceId: row.id,
            title: row.title,
            cover: row.cover,
            tags: [if (row.code.isNotEmpty) row.code],
          ),
        );
      },
    );
  }
}

/// 收藏项：只留卡片和播放要用的字段（不存整条 Drama）。
class _FavItem {
  const _FavItem({
    required this.id,
    required this.source,
    required this.title,
    this.cover = '',
    this.code = '',
  });

  final String id;
  final String source;
  final String title;
  final String cover;
  final String code;

  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source,
    'title': title,
    'cover': cover,
    'code': code,
  };

  factory _FavItem.fromJson(Map<String, dynamic> json) => _FavItem(
    id: json['id'] as String? ?? '',
    source: json['source'] as String? ?? '',
    title: json['title'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
    code: json['code'] as String? ?? '',
  );
}
