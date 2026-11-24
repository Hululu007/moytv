import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'site_icon.dart';
import 'site_thumb_cache.dart';

/// 站点卡片里的缩图区：16:9 平图，不做 3D 翻滚透视。
///
/// 取图链：站内随机视频封面地址（[SiteThumbCache]，按站 id 缓存）
/// → 图片文件（[SiteIconCache] 的磁盘缓存，不另建机制）。
/// 任一环节拿不到就显示站标（[SiteIcon]，含图案标兜底），
/// 绝不留空、绝不挂假图、绝不阻塞列表。
///
/// 懒加载：只在卡片滚进外层列表视口（上下各放一屏边距预取）
/// 时才开始拉首页；滚不到的卡不拉。宫格是 shrinkWrap 的，
/// 首帧会把全区卡片都建出来，光靠 initState 拉取会在打开
/// 弹窗瞬间打遍全区站点，所以必须按可见性再 gate 一道。
class SiteThumbImage extends StatefulWidget {
  const SiteThumbImage({
    super.key,
    required this.siteId,
    required this.siteName,
    this.iconUrls = const [],
    this.thumbCache,
    this.thumbFetcher,
    this.imageCache,
    this.borderRadius = 12,
  });

  final String siteId;
  final String siteName;

  /// 调用方给定的站标候选地址（按序尝试），见 [SiteIcon]。
  final List<String> iconUrls;

  /// 缩图地址缓存（站 id → 封面地址）：不传则不拉缩图，只显示站标。
  final SiteThumbCache? thumbCache;

  /// 拉首页随机取封面：不传则不拉缩图，只显示站标。
  final SiteThumbFetcher? thumbFetcher;

  /// 图片文件缓存：不传用 [SiteIconCache.instance]；测试注入假缓存。
  final SiteIconCache? imageCache;

  final double borderRadius;

  @override
  State<SiteThumbImage> createState() => _SiteThumbImageState();
}

class _SiteThumbImageState extends State<SiteThumbImage> {
  File? _file;

  /// 已开始拉（避免重复触发）。
  bool _started = false;

  /// 已有结论（有图已显示 / 无图本次弹窗内不再重拉）。
  bool _done = false;

  ScrollPosition? _outerPosition;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFetch());
  }

  @override
  void didUpdateWidget(SiteThumbImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.siteId != widget.siteId ||
        oldWidget.thumbCache != widget.thumbCache ||
        oldWidget.thumbFetcher != widget.thumbFetcher) {
      _file = null;
      _started = false;
      _done = false;
      _detachScrollListener();
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFetch());
    }
  }

  @override
  void dispose() {
    _detachScrollListener();
    super.dispose();
  }

  void _detachScrollListener() {
    final position = _outerPosition;
    if (position != null) {
      position.removeListener(_onScroll);
      _outerPosition = null;
    }
  }

  /// 滚动时不直接查可见性：通知来时布局还是滚前那帧的，
  /// 查了也是旧位置；改到下一帧布局完再查，位置才准。
  void _onScroll() {
    if (_started || _done || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFetch());
  }

  /// 最外层可滚动祖先的位置（弹窗的 ListView）：宫格自己的
  /// Scrollable 从不滚动，用它判断可见性是错的，必须往上找。
  /// 从卡片往外逐层找 Scrollable，取最外层那一个的位置。
  ScrollPosition? _findOuterPosition() {
    ScrollPosition? outer;
    var ctx = context;
    while (true) {
      final state = Scrollable.maybeOf(ctx);
      if (state == null) break;
      outer = state.position;
      ctx = state.context;
    }
    return outer;
  }

  /// 卡片是否在外层列表视口内（上下各放 200 逻辑像素预取边距，
  /// 快滚到时提前拉）。布局未完成时返回 false，等滚动再查。
  bool _isVisible() {
    final position = _outerPosition;
    final box = context.findRenderObject();
    if (position == null || box is! RenderBox || !box.hasSize) return false;
    final viewportBox = position.context.storageContext.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return false;
    const margin = 200.0;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    final viewTop = viewportBox.localToGlobal(Offset.zero).dy;
    final viewBottom = viewTop + viewportBox.size.height;
    return bottom > viewTop - margin && top < viewBottom + margin;
  }

  void _maybeFetch() {
    if (_started || _done || !mounted) return;
    final cache = widget.thumbCache;
    final fetcher = widget.thumbFetcher;
    if (cache == null || fetcher == null) {
      // 不拉缩图的弹窗（直播/阅读区）：站标即结论，不再查。
      _done = true;
      return;
    }
    _outerPosition ??= _findOuterPosition();
    if (!_isVisible()) {
      // 还没滚到：挂滚动监听，滚到再查；监听只挂一次。
      final position = _outerPosition;
      if (position != null) {
        position.removeListener(_onScroll);
        position.addListener(_onScroll);
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFetch());
      }
      return;
    }
    _detachScrollListener();
    _started = true;
    unawaited(_fetchThumb(cache, fetcher));
  }

  Future<void> _fetchThumb(
    SiteThumbCache cache,
    SiteThumbFetcher fetcher,
  ) async {
    final url = await cache.thumbUrlFor(widget.siteId, fetcher: fetcher);
    if (!mounted) return;
    if (url == null || url.isEmpty) {
      // 拉不到/超时/首页为空/没封面：本次弹窗内不再重拉；
      // 失败不进缓存，下次打开弹窗再拉（站恢复了就有图）。
      _done = true;
      return;
    }
    final file = await (widget.imageCache ?? SiteIconCache.instance).resolve(
      url,
    );
    if (!mounted) return;
    _done = true;
    if (file != null) {
      setState(() => _file = file);
    }
    // 图片下载失败时地址照常留在缓存里，下次打开再解图片；
    // 本次显示站标，不留空。
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    if (file != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: Image.file(
          file,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, _, _) => _fallbackIcon(),
        ),
      );
    }
    return _fallbackIcon();
  }

  /// 站标（或图案标）居中放在 16:9 的缩图区里：无图时卡片
  /// 形状不变，不塌、不留空。
  Widget _fallbackIcon() {
    return Center(
      child: SiteIcon(
        siteId: widget.siteId,
        siteName: widget.siteName,
        iconUrls: widget.iconUrls,
        size: 44,
        borderRadius: 12,
      ),
    );
  }
}
