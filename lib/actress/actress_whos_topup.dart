// 无库顶上（2026-11-25 用户令「顶上」，局部推翻 11-22「不灌内置
// 种子」口径）：内部工作库不存在或为空（没导过 .sql）时，演员库
// 首页先用内置 who's 数据顶上——视频目录出作品流、番号→女优映射
// 按人归拢；导入成功后首页完全走数据库，本视图不再出现。
//
// 性能口径（硬线）：目录 33.9 万行不解析成对象常驻。解压后的全文
// 只留一份字符串 + 每行起始偏移表（int 表），翻到哪页才把那几行
// 切出来解析成 WhosVideo；解压+建偏移表放 compute 子隔离跑，
// 不卡首帧。人物侧复用 WhosJsonIndex 既有常驻索引（只含映射内
// 番号），不另建一份。
//
// 分类/类型/标签只有数据库里有，JSON 里只有一个「日本AV」，
// 无库时照旧不出分类（不拿假分类糊弄）；女优没有头像，人物卡
// 头像位用 ActressAvatar 的姓名占位，不现取、不编造。
import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'actress_neon.dart';
import 'actress_widgets.dart';
import 'whos_json_index.dart';

/// 内置视频目录分页器：全文一份字符串 + 行偏移表，按页解析。
class WhosCatalogPager {
  WhosCatalogPager._(this._text, this._lineStarts);

  /// 测试/注入用：直接拿解压后的全文建分页器。
  factory WhosCatalogPager.fromText(String text) =>
      WhosCatalogPager._(text, _lineStartsOf(text));

  static List<int> _lineStartsOf(String text) {
    final starts = <int>[0];
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A && i + 1 < text.length) {
        starts.add(i + 1);
      }
    }
    return starts;
  }

  static WhosCatalogPager? _shared;
  static Future<WhosCatalogPager>? _loading;

  /// 全局单例（与 WhosJsonIndex 同款懒加载）：读包内目录 gz，
  /// 子隔离解压建表；失败回空分页器（total=0），不抛错挡页面。
  static Future<WhosCatalogPager> get shared {
    final existing = _shared;
    if (existing != null) return Future.value(existing);
    return _loading ??= _loadShared();
  }

  static Future<WhosCatalogPager> _loadShared() async {
    try {
      final bytes = await rootBundle.load(WhosJsonIndex.catalogAsset);
      final text = await compute(
        _decodeCatalogBytes,
        bytes.buffer.asUint8List(),
      );
      final pager = WhosCatalogPager.fromText(text);
      _shared = pager;
      return pager;
    } catch (_) {
      return WhosCatalogPager._('', const []);
    }
  }

  final String _text;
  final List<int> _lineStarts;

  /// 目录总行数（作品数）。
  int get total => _lineStarts.length;

  bool get isEmpty => _lineStarts.isEmpty;

  String _lineAt(int index) {
    final start = _lineStarts[index];
    final end = index + 1 < _lineStarts.length
        ? _lineStarts[index + 1] - 1
        : _text.length;
    return _text.substring(start, end).trim();
  }

  /// 第 index 行解析成作品；行坏了（列数不对）返回 null。
  WhosVideo? workAt(int index) {
    if (index < 0 || index >= _lineStarts.length) return null;
    final parts = _lineAt(index).split('||');
    if (parts.length != 4) return null;
    final code = parts[0].trim().toUpperCase();
    if (code.isEmpty) return null;
    return WhosVideo(
      code: code,
      title: parts[1].trim(),
      pic: parts[2].trim(),
      m3u8: parts[3].trim(),
    );
  }

  /// 一页作品（跳过坏行）。
  List<WhosVideo> page(int offset, int limit) {
    final rows = <WhosVideo>[];
    for (var i = offset; i < offset + limit && i < total; i++) {
      final work = workAt(i);
      if (work != null) rows.add(work);
    }
    return rows;
  }

  /// 按番号/标题查（包含匹配，不分大小写）：逐行扫，命中上限即停。
  /// 只在用户提交搜索时跑，不逐键触发。
  List<WhosVideo> search(String query, {int limit = 120}) {
    final needle = query.trim().toUpperCase();
    if (needle.isEmpty) return const [];
    final rows = <WhosVideo>[];
    for (var i = 0; i < total && rows.length < limit; i++) {
      final line = _lineAt(i).toUpperCase();
      if (!line.contains(needle)) continue;
      final work = workAt(i);
      if (work != null) rows.add(work);
    }
    return rows;
  }
}

String _decodeCatalogBytes(Uint8List bytes) {
  return utf8.decode(const GZipDecoder().decodeBytes(bytes));
}

/// 无库顶上视图：作品流（内置目录分页）+ 按女优看（映射归拢）。
/// 播放由宿主页面注入 [onPlay]（走 whosLocalDetail + 播放器）。
class ActressWhosTopupView extends StatefulWidget {
  const ActressWhosTopupView({
    super.key,
    required this.onPlay,
    required this.onImport,
    required this.onManage,
    this.pagerFuture,
    this.indexFuture,
  });

  /// 点作品卡播放（宿主实现：构详情推播放器）。
  final Future<void> Function(WhosVideo video) onPlay;

  /// 顶部提示条上的「导入 .sql 数据库」。
  final VoidCallback onImport;

  /// 顶部提示条上的「数据库管理」。
  final VoidCallback onManage;

  /// 注入缝（测试用小样本；生产走单例）。
  final Future<WhosCatalogPager>? pagerFuture;
  final Future<WhosJsonIndex>? indexFuture;

  @override
  State<ActressWhosTopupView> createState() => _ActressWhosTopupViewState();
}

class _ActressWhosTopupViewState extends State<ActressWhosTopupView> {
  static const _pageSize = 60;

  WhosCatalogPager? _pager;
  WhosJsonIndex? _index;
  var _loading = true;
  var _tab = 0; // 0 作品流，1 按女优看

  final _works = <WhosVideo>[];
  var _worksDone = false;
  List<WhosVideo>? _searchResults;
  final _searchController = TextEditingController();

  List<({String name, int works})> _actors = const [];
  var _actorsShown = 0;

  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
    unawaited(_load());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final pager = await (widget.pagerFuture ?? WhosCatalogPager.shared);
    final index = await (widget.indexFuture ?? WhosJsonIndex.instance);
    if (!mounted) return;
    setState(() {
      _pager = pager;
      _index = index;
      _loading = false;
      _actors = index.actorsByWorks();
      _actorsShown = _pageSize.clamp(0, _actors.length);
      _appendWorks();
    });
  }

  void _appendWorks() {
    final pager = _pager;
    if (pager == null || _worksDone) return;
    final next = pager.page(_works.length, _pageSize);
    _works.addAll(next);
    if (_works.length >= pager.total || next.isEmpty) _worksDone = true;
  }

  void _maybeLoadMore() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - 600) return;
    setState(() {
      if (_tab == 0 && _searchResults == null) {
        _appendWorks();
      } else if (_tab == 1 && _actorsShown < _actors.length) {
        _actorsShown = (_actorsShown + _pageSize).clamp(0, _actors.length);
      }
    });
  }

  void _submitSearch(String value) {
    final pager = _pager;
    if (pager == null) return;
    final query = value.trim();
    setState(() {
      _searchResults = query.isEmpty ? null : pager.search(query);
    });
  }

  Future<void> _openActor(String name) async {
    final index = _index;
    if (index == null) return;
    final codes = index.codesForActor(name);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ActressWhosActorWorksPage(
          name: name,
          codes: codes,
          index: index,
          onPlay: widget.onPlay,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final pager = _pager!;
    if (pager.isEmpty) {
      // 内置目录读不出来：回落到原来的纯空态（导入入口照给）。
      return _emptyFallback(context);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _hintBar(context),
        _tabBar(context),
        Expanded(
          child: _tab == 0 ? _worksView(context) : _actorsView(context),
        ),
      ],
    );
  }

  Widget _emptyFallback(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '还没有导入数据库：请在设置里导入 .sql 数据库',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                onPressed: widget.onImport,
                child: const Text('导入 .sql 数据库'),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: widget.onManage,
                child: const Text('数据库管理'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _hintBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      color: Neon.surface,
      child: Row(
        children: [
          const Expanded(
            child: Text(
              '还没导入数据库，先用内置数据顶上（导入后自动换成数据库）',
              style: TextStyle(color: Neon.textDim, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: widget.onImport,
            child: const Text('导入 .sql'),
          ),
          TextButton(onPressed: widget.onManage, child: const Text('数据库管理')),
        ],
      ),
    );
  }

  Widget _tabBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          ChoiceChip(
            label: const Text('作品'),
            selected: _tab == 0,
            onSelected: (_) => setState(() => _tab = 0),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('按女优看'),
            selected: _tab == 1,
            onSelected: (_) => setState(() => _tab = 1),
          ),
          if (_tab == 0) ...[
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  hintText: '搜番号或标题，回车搜',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: _submitSearch,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _worksView(BuildContext context) {
    final results = _searchResults;
    final rows = results ?? _works;
    if (rows.isEmpty) {
      return Center(
        child: Text(
          results != null ? '内置目录里没找到' : '内置目录是空的',
          style: const TextStyle(color: Neon.textDim),
        ),
      );
    }
    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: 12,
        crossAxisSpacing: 10,
        childAspectRatio: 0.56,
      ),
      itemCount: rows.length + (results == null && !_worksDone ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= rows.length) {
          return const Center(child: CircularProgressIndicator());
        }
        return _WhosWorkCard(
          video: rows[index],
          onTap: () => unawaited(widget.onPlay(rows[index])),
        );
      },
    );
  }

  Widget _actorsView(BuildContext context) {
    if (_actors.isEmpty) {
      return const Center(
        child: Text('内置映射里暂时没有女优', style: TextStyle(color: Neon.textDim)),
      );
    }
    final shown = _actors.take(_actorsShown).toList();
    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: 12,
        crossAxisSpacing: 10,
        childAspectRatio: 0.72,
      ),
      itemCount: shown.length,
      itemBuilder: (context, index) {
        final actor = shown[index];
        return Container(
          decoration: actressNeonCardDecoration(),
          child: InkWell(
            onTap: () => unawaited(_openActor(actor.name)),
            borderRadius: BorderRadius.circular(15),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  ActressAvatar(avatarUrl: '', name: actor.name, radius: 42),
                  const SizedBox(height: 8),
                  Text(
                    actor.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.titleSmall?.copyWith(color: Neon.text),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '约 ${actor.works} 部',
                    maxLines: 1,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Neon.textDim),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 顶上模式里点女优后的作品页：番号列表逐条取目录行出卡。
class ActressWhosActorWorksPage extends StatelessWidget {
  const ActressWhosActorWorksPage({
    super.key,
    required this.name,
    required this.codes,
    required this.index,
    required this.onPlay,
  });

  final String name;
  final List<String> codes;
  final WhosJsonIndex index;
  final Future<void> Function(WhosVideo video) onPlay;

  @override
  Widget build(BuildContext context) {
    final videos = <WhosVideo>[
      for (final code in codes) ?index.videoForCode(code),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: videos.isEmpty
          ? const Center(
              child: Text('她的作品暂时取不到', style: TextStyle(color: Neon.textDim)),
            )
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 130,
                mainAxisSpacing: 12,
                crossAxisSpacing: 10,
                childAspectRatio: 0.56,
              ),
              itemCount: videos.length,
              itemBuilder: (context, index) => _WhosWorkCard(
                video: videos[index],
                onTap: () => unawaited(onPlay(videos[index])),
              ),
            ),
    );
  }
}

/// 顶上作品卡：封面 + 番号 + 标题，样式对齐女优库作品卡（霓虹卡面、
/// 中央透明播放键装饰），点按由外层接管。
class _WhosWorkCard extends StatelessWidget {
  const _WhosWorkCard({required this.video, required this.onTap});

  final WhosVideo video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: actressNeonCardDecoration(radius: 10),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      color: Neon.surface,
                      width: double.infinity,
                      height: double.infinity,
                      child: video.pic.isEmpty
                          ? Center(
                              child: Text(
                                video.code,
                                style: const TextStyle(
                                  color: Neon.textDim,
                                  fontSize: 12,
                                ),
                              ),
                            )
                          : Image.network(
                              video.pic,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  const SizedBox.shrink(),
                            ),
                    ),
                  ),
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Center(child: ActressPosterPlayKey()),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            video.code,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Neon.textDim, fontSize: 11),
          ),
          Text(
            video.title.isEmpty ? video.code : video.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Neon.text, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
