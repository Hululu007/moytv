import 'dart:async';

import 'package:flutter/material.dart';

import '../app_page_route.dart';
import '../core_bridge.dart';
import '../detail_screen.dart';
import '../local_store.dart';
import 'actress_av_style.dart';
import 'actress_online_detail.dart';
import 'actress_online_parse.dart';
import 'actress_online_sources.dart';

/// 演员库在线源视图（2026-11-26 用户令：123AV / PH 两源加进
/// 原生 who's 界面）：源切换条切到在线源时显示本视图——页签行
/// （PH 一级排序 + 二级分类、123AV 一级栏目）+ 视频卡片网格 +
/// 滚动翻页，搜索走页面顶部的统一搜索框（[query] 由宿主页下
/// 传，切到哪源搜哪源）。卡片与女优库作品卡同款（AvWorkCard，
/// 照 AvPlay 截图的浅色摆法）。
///
/// 点卡 = 现取详情与播放地址，组装 direct 直链集后走 App 既有
/// 播放器链（pushPlayer），与女优库点卡行为一致，不另造详情页。
/// 在线失败只给人话提示 + 重试，不露网页源的说明文案、不假装
/// 有数据。
class ActressOnlineSourceView extends StatefulWidget {
  const ActressOnlineSourceView({
    super.key,
    required this.source,
    required this.repository,
    required this.store,
    this.query = '',
    this.refreshTick = 0,
    this.fetch,
  });

  final ActressOnlineSource source;
  final AppRepository repository;
  final LocalStore store;

  /// 顶部统一搜索框的当前词（宿主页下传）：变了就按新词重搜。
  final String query;

  /// 宿主页刷新钮计数：变了就整表重拉。
  final int refreshTick;

  /// 取数注入（测试/预览用）；为空走默认 [ActressOnlineClient]。
  final ActressOnlineFetch? fetch;

  @override
  State<ActressOnlineSourceView> createState() =>
      ActressOnlineSourceViewState();
}

class ActressOnlineSourceViewState extends State<ActressOnlineSourceView> {
  final _scroll = ScrollController();
  late final ActressOnlineClient _client = ActressOnlineClient();

  late String _primaryId = widget.source.defaultPrimaryId;
  late String _secondaryId = widget.source.defaultSecondaryId;
  var _items = <OnlineVideoCard>[];
  var _page = 1;
  var _hasMore = true;
  var _loading = false;
  var _loadingMore = false;
  String? _error;
  String? _busyUrl;
  var _generation = 0;

  ActressOnlineFetch get _fetch => widget.fetch ?? _client.get;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ActressOnlineSourceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query ||
        oldWidget.refreshTick != widget.refreshTick) {
      unawaited(_load(reset: true));
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
      unawaited(_load());
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      final generation = ++_generation;
      setState(() {
        _loading = true;
        _error = null;
        _items = [];
        _page = 1;
        _hasMore = true;
        _loadingMore = false;
      });
      late final List<OnlineVideoCard> rows;
      try {
        rows = await widget.source.fetchCards(
          primaryId: _primaryId,
          secondaryId: _secondaryId,
          query: widget.query,
          page: 1,
          fetch: _fetch,
        );
      } catch (e) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _loading = false;
          _error = actressOnlineHumanError(e);
        });
        return;
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = rows;
        _page = 2;
        _hasMore = rows.isNotEmpty;
        _loading = false;
        if (rows.isEmpty) {
          _error = widget.query.trim().isEmpty
              ? '没有取到内容，可能是网络问题，点重试再试一次'
              : '没有找到与“${widget.query.trim()}”相关的内容';
        }
      });
      return;
    }
    if (_loadingMore || !_hasMore || _loading) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final rows = await widget.source.fetchCards(
        primaryId: _primaryId,
        secondaryId: _secondaryId,
        query: widget.query,
        page: _page,
        fetch: _fetch,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = [..._items, ...rows];
        _page += 1;
        _hasMore = rows.isNotEmpty;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('加载更多失败，请稍后再试')));
    }
  }

  void _pickPrimary(String id) {
    if (_primaryId == id) return;
    setState(() => _primaryId = id);
    unawaited(_load(reset: true));
  }

  void _pickSecondary(String id) {
    if (_secondaryId == id) return;
    setState(() => _secondaryId = id);
    unawaited(_load(reset: true));
  }

  Future<void> _playCard(OnlineVideoCard card) async {
    if (_busyUrl != null) return;
    setState(() => _busyUrl = card.pageUrl);
    try {
      final play = await widget.source.resolvePlay(card, fetch: _fetch);
      if (!mounted) return;
      // 2026-11-26 用户令：点卡进作品详情页（照 AvPlay 详情页
      // 补演员/剧照/信息卡）。详情构造与详情页在线线路区、女
      // 优页竞速共用一份（actressOnlinePlayDetail）：剧照只
      // 用详情页自带的、信息行只带真字段；播放走详情页海报/
      // 选集（direct 集 + 播放头透传）。源站未注册、仓库详
      // 情会抛错，靠 DetailScreen 对 initialDetail 的兜底落
      // 到这份候选详情上。
      final built = actressOnlinePlayDetail(
        source: widget.source,
        card: card,
        play: play,
      );
      await Navigator.of(context).push(
        appPageRoute<void>(
          settings: const RouteSettings(name: 'detail'),
          builder: (_) => DetailScreen(
            drama: built.drama,
            repository: widget.repository,
            store: widget.store,
            pan115Gateway: actressPan115GatewayOf(widget.repository),
            initialDetail: built.detail,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(actressOnlineHumanError(e))));
    } finally {
      if (mounted) setState(() => _busyUrl = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final searching = widget.query.trim().isNotEmpty;
    // 自带浅色底（2026-11-26 预览核图发现）：本视图文字色全是
    // AvStyle 浅色版式色，宿主主题是深色时不自带底会黑底黑字。
    return ColoredBox(
      color: AvStyle.bg,
      child: Column(
        children: [
        if (searching)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '在 ${widget.source.label} 里搜索：“${widget.query.trim()}”',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AvStyle.dim, fontSize: 12.5),
              ),
            ),
          )
        else ...[
          _chipsRow(
            keyPrefix: 'primary',
            tabs: widget.source.primaryTabs,
            selectedId: _primaryId,
            onPick: _pickPrimary,
          ),
          if (widget.source.secondaryTabs.isNotEmpty)
            _chipsRow(
              keyPrefix: 'secondary',
              tabs: widget.source.secondaryTabs,
              selectedId: _secondaryId,
              onPick: _pickSecondary,
            ),
        ],
        Expanded(child: _body()),
        ],
      ),
    );
  }

  /// 页签行：与女优库分类胶囊行同款（横向滚动浅色胶囊）。
  Widget _chipsRow({
    required String keyPrefix,
    required List<OnlineTabOption> tabs,
    required String selectedId,
    required void Function(String id) onPick,
  }) {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        itemCount: tabs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final tab = tabs[index];
          return Center(
            child: AvPill(
              key: ValueKey(
                'online-${widget.source.id}-$keyPrefix-${tab.id}',
              ),
              label: tab.name,
              selected: selectedId == tab.id,
              onTap: () => onPick(tab.id),
            ),
          );
        },
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AvStyle.accent),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off_rounded,
                color: AvStyle.dim,
                size: 40,
              ),
              const SizedBox(height: 12),
              Text(
                _error ?? '暂时没有内容',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AvStyle.dim, fontSize: 13.5),
              ),
              const SizedBox(height: 14),
              AvPill(
                key: ValueKey('online-${widget.source.id}-retry'),
                label: '重试',
                selected: false,
                onTap: () => unawaited(_load(reset: true)),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      color: AvStyle.accent,
      backgroundColor: AvStyle.bg,
      onRefresh: () => _load(reset: true),
      child: GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
        itemCount: _items.length + (_loadingMore ? 1 : 0),
        gridDelegate: avWorkGridDelegate,
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return const Center(
              child: CircularProgressIndicator(color: AvStyle.accent),
            );
          }
          return _card(_items[index]);
        },
      ),
    );
  }

  /// 视频卡：与女优库作品卡同款（AvWorkCard）；123AV 卡带
  /// 番号，在线卡无日期数据（不编），时长压封面右下；
  /// 取流中盖一层转圈。
  Widget _card(OnlineVideoCard card) {
    return AvWorkCard(
      key: ValueKey('online-card-${card.pageUrl}'),
      cover: card.cover,
      title: card.title,
      code: widget.source.id == 'av123' ? av123CodeOf(card.pageUrl) : '',
      date: '',
      duration: card.duration,
      busy: _busyUrl == card.pageUrl,
      onTap: () => unawaited(_playCard(card)),
    );
  }
}

/// 在线源错误翻成人话：只给用户能懂、能行动的说法，不露状态码
/// 堆叠与网页源的代理/VPN 说明文案。
String actressOnlineHumanError(Object error) {
  if (error is AppFailure) {
    final message = error.message;
    if (message.contains('403')) return '站点暂时拒绝了访问，请稍后再试';
    if (message.contains('超时')) return '网络超时，请检查网络后重试';
    if (message.contains('无法连接')) return '连不上这个站点，请检查网络后重试';
    if (message.contains('证书')) return '站点证书异常，请稍后再试';
    if (message.startsWith('内容源返回')) return '站点暂时不可用，请稍后再试';
    if (message.startsWith('内容源')) return '加载失败，请重试';
    return message;
  }
  return '加载失败，请重试';
}
