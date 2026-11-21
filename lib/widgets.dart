import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'core_bridge.dart';
import 'app_layout.dart';
import 'liquid_glass.dart';
import 'models.dart';
import 'remote_widgets.dart';

Future<void> saveUserChange(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('未能保存，请检查存储空间和权限后重试。')));
    }
  }
}

class RefreshAction extends StatefulWidget {
  const RefreshAction({
    super.key,
    required this.loading,
    required this.tooltip,
    required this.onPressed,
  });
  final bool loading;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  State<RefreshAction> createState() => _RefreshActionState();
}

class _RefreshActionState extends State<RefreshAction>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation;

  @override
  void initState() {
    super.initState();
    _rotation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    if (widget.loading) _rotation.repeat();
  }

  @override
  void didUpdateWidget(covariant RefreshAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loading == oldWidget.loading) return;
    if (widget.loading) {
      _rotation.repeat();
    } else {
      _rotation.reset();
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    value: widget.loading ? '正在更新' : null,
    child: IconButton(
      tooltip: widget.loading ? '正在更新' : widget.tooltip,
      onPressed: widget.loading ? null : widget.onPressed,
      disabledColor: widget.loading
          ? Theme.of(context).colorScheme.primary
          : null,
      icon: RotationTransition(
        turns: _rotation,
        child: Icon(
          glassDesign(context) ? LucideIcons.rotateCw : Icons.refresh_rounded,
        ),
      ),
    ),
  );
}

class DramaCover extends StatelessWidget {
  const DramaCover({
    super.key,
    required this.drama,
    required this.repository,
    this.radius = 14,
    this.showEpisodeLabel = true,
  });
  final Drama drama;
  final AppRepository repository;
  final double radius;
  final bool showEpisodeLabel;
  static const imagesDisabled = bool.fromEnvironment('DISABLE_REMOTE_IMAGES');

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final glass = glassDesign(context);
    final placeholder = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.surfaceContainerHighest, colors.surfaceContainer],
        ),
      ),
      child: Center(
        child: Icon(
          glass ? LucideIcons.clapperboard : Icons.movie_creation_outlined,
          size: 40,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
    final cover = Stack(
      fit: StackFit.expand,
      children: [
        placeholder,
        if (!imagesDisabled && drama.id.isNotEmpty)
          CachedCoverImage(
            key: ValueKey('${drama.id}\u0000${drama.cover}'),
            drama: drama,
            repository: repository,
            placeholder: placeholder,
          ),
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: .78),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (showEpisodeLabel && drama.episodes > 0)
          Positioned(
            left: 9,
            bottom: 9,
            child: Text(
              '共 ${drama.episodes} 集',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        if (drama.vip)
          Positioned(
            left: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFF6C86B),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'VIP',
                style: TextStyle(
                  color: Color(0xFF40300D),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    );
    final corners = BorderRadius.circular(radius);
    return glass
        ? ClipRSuperellipse(borderRadius: corners, child: cover)
        : ClipRRect(borderRadius: corners, child: cover);
  }
}

class CachedCoverImage extends StatefulWidget {
  const CachedCoverImage({
    super.key,
    required this.drama,
    required this.repository,
    required this.placeholder,
  });
  final Drama drama;
  final AppRepository repository;
  final Widget placeholder;
  @override
  State<CachedCoverImage> createState() => _CachedCoverImageState();
}

class _CachedCoverImageState extends State<CachedCoverImage> {
  // 已解析的封面文件路径（会话级）：切区/切页签会整棵销毁瓦片子树，
  // 重挂时每个瓦片重跑 cover() 异步往返、期间只显示占位图，就是
  // 首页深滚返回时整屏海报闪烁的根因。路径解析结果与瓦片 State
  // 无关，记在这里让重挂首帧就能出图，不再重拉、不再闪占位图。
  // 键与 didUpdateWidget 的换图条件一致（站源 + id + 封面地址），
  // 封面地址变了就按新键重拉，不会拿旧图顶替。
  static final Map<String, String> _resolvedPaths = <String, String>{};
  static const _resolvedPathsMax = 512;

  late Future<String> _file;

  /// 命中 _resolvedPaths 时首帧直接用的路径：FutureBuilder 的
  /// initialData，让第一帧就不走占位图分支。
  String? _initialPath;
  int _coverRevision = 0;
  bool _coverFailed = false;
  bool _retryOnFailure = false;
  bool _retryQueued = false;
  String? _failedPath;

  static String _cacheKey(Drama drama) =>
      '${drama.source}\u0000${drama.id}\u0000${drama.cover}';

  /// 取封面路径：命中缓存直接给已完成的 Future（不调 cover()）；
  /// 未命中才调 cover()，成功后记入缓存。cover() 可能同步抛错，
  /// 在这里兜成带错的 Future，不把异常抛回调用方。
  Future<String> _requestCover(Drama drama, {bool force = false}) {
    final key = _cacheKey(drama);
    final cached = _resolvedPaths[key];
    if (!force && cached != null) {
      _initialPath = cached;
      return Future<String>.value(cached);
    }
    _initialPath = null;
    Future<String> next;
    try {
      next = widget.repository.cover(drama, force: force);
    } catch (e) {
      next = Future<String>.error(e);
    }
    unawaited(
      next.then((path) {
        _resolvedPaths.remove(key);
        _resolvedPaths[key] = path;
        while (_resolvedPaths.length > _resolvedPathsMax) {
          _resolvedPaths.remove(_resolvedPaths.keys.first);
        }
      }, onError: (_) {}),
    );
    return next;
  }

  @override
  void initState() {
    super.initState();
    _coverRevision = widget.repository.catalogUpdates.coverRevision(
      widget.drama.id,
    );
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    _file = _requestCover(widget.drama);
  }

  @override
  void didUpdateWidget(covariant CachedCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.catalogUpdates.removeListener(_metadataChanged);
      widget.repository.catalogUpdates.addListener(_metadataChanged);
    }
    if (oldWidget.repository != widget.repository ||
        oldWidget.drama.id != widget.drama.id ||
        oldWidget.drama.cover != widget.drama.cover ||
        oldWidget.drama.source != widget.drama.source) {
      _coverFailed = _retryOnFailure = false;
      _failedPath = null;
      _coverRevision = widget.repository.catalogUpdates.coverRevision(
        widget.drama.id,
      );
      _file = _requestCover(widget.drama);
    }
  }

  void _metadataChanged() {
    final revision = widget.repository.catalogUpdates.coverRevision(
      widget.drama.id,
    );
    if (revision == _coverRevision) return;
    _coverRevision = revision;
    _retryOnFailure = true;
    if (_coverFailed) _queueRetry();
  }

  void _queueRetry() {
    if (_retryQueued || !_retryOnFailure) return;
    _retryQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _retryQueued = false;
      if (!mounted || !_retryOnFailure) return;
      _retryOnFailure = false;
      _retry(_failedPath);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    super.dispose();
  }

  Future<void> _retry(String? path) async {
    try {
      if (path != null) {
        await ResizeImage.resizeIfNeeded(
          440,
          null,
          FileImage(File(path)),
        ).evict();
      }
    } catch (_) {
      // 缓存清理失败不影响重试本身，继续走封面重取。
    }
    if (!mounted) return;
    // _requestCover 已把 cover() 的同步抛错兜成带错的 Future：
    // 绝不能把异常抛回点按手势（会冲断同次手势里卡片自身的
    // onTap），失败时让 FutureBuilder 继续显示失败态。
    final next = _requestCover(
      widget.repository.catalogUpdates.current(widget.drama),
      force: true,
    );
    // FutureBuilder 要到下一帧重建时才订阅这个 Future：先挂一个空
    // 错误处理，避免错误在订阅前送达被当成未处理异常上报；
    // FutureBuilder 自己的订阅不受影响，失败态照常显示。
    unawaited(next.then((_) {}, onError: (_) {}));
    if (!mounted) return;
    setState(() {
      _coverFailed = _retryOnFailure = false;
      _failedPath = null;
      _file = next;
    });
  }

  Widget _failed(String? path) {
    _coverFailed = true;
    _failedPath = path;
    // 解码失败的路径已是死路径：从会话缓存里清掉，否则重挂又拿
    // 同一条死路径首帧出失败态，刷不掉。
    if (path != null) {
      _resolvedPaths.removeWhere((_, value) => value == path);
    }
    if (_retryOnFailure) _queueRetry();
    // 2026-11-22：本地库作品的封面本来就是直链（女优库.db 的
    // pic_url）。取图器认不出库里的站名时别再留“重试海报”按钮，
    // 直接拿直链上屏。
    if (_hasDirectCoverUrl(widget.drama.cover)) {
      return _directCover();
    }
    return Center(
      child: IconButton(
        tooltip: '重试海报',
        onPressed: () => _retry(path),
        icon: Icon(
          Icons.refresh_rounded,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  static bool _hasDirectCoverUrl(String cover) {
    final url = cover.trim();
    return url.startsWith('http://') || url.startsWith('https://');
  }

  /// 直链封面：不等取图器、不走本地缓存文件，直接网络出图。
  /// 拿不到就退回占位图（不弹重试按钮、不报错）。
  Widget _directCover() {
    return Image.network(
      widget.drama.cover.trim(),
      fit: BoxFit.cover,
      cacheWidth: 440,
      gaplessPlayback: true,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => widget.placeholder,
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _file,
    // 命中会话缓存时 initialData 就是已解析路径：首帧直接走出图
    // 分支，不闪占位图；未命中时为 null，走原来的等待分支。
    initialData: _initialPath,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done &&
          !snapshot.hasData) {
        // 2026-11-22：有封面直链就先把直链显示出来，不再干等取图器
        // （本地库作品的 pic_url 就是直链，等它回来之前一片灰很难看）。
        if (_hasDirectCoverUrl(widget.drama.cover)) return _directCover();
        return widget.placeholder;
      }
      if (snapshot.hasError || !snapshot.hasData) {
        return _failed(null);
      }
      return Image.file(
        File(snapshot.data!),
        fit: BoxFit.cover,
        cacheWidth: 440,
        // 换图时旧图留到新图到来，不闪白。
        gaplessPlayback: true,
        excludeFromSemantics: true,
        errorBuilder: (_, error, stack) => _failed(snapshot.data),
      );
    },
  );
}

class DramaTile extends StatelessWidget {
  const DramaTile({
    super.key,
    required this.drama,
    required this.repository,
    required this.onTap,
    this.subtitle,
    this.focusNode,
    this.onFocus,
    this.actions,
    this.badge,
    this.topBadge,
    this.tagText,
    this.selected,
    this.onMore,
    this.onLongPress,
  });
  final Drama drama;
  final AppRepository repository;
  final VoidCallback onTap;
  final String? subtitle;
  final FocusNode? focusNode;
  final VoidCallback? onFocus;
  final Widget? actions;
  final String? badge;
  final String? topBadge;
  final String? tagText;
  final bool? selected;
  final VoidCallback? onMore;
  final VoidCallback? onLongPress;

  static double titleHeight(BuildContext context) =>
      MediaQuery.textScalerOf(
        context,
      ).scale(AppLayout.isTelevision(context) ? 17 : 14) *
      2.6;

  static double subtitleHeight(BuildContext context) =>
      MediaQuery.textScalerOf(
        context,
      ).scale(AppLayout.isTelevision(context) ? 14 : 12) *
      1.3;

  static double extentFor(BuildContext context, double width) =>
      (width * 1.5 + 13 + titleHeight(context) + subtitleHeight(context))
          .ceilToDouble();

  static double theaterExtentFor(BuildContext context, double width) =>
      extentFor(context, width) + subtitleHeight(context) + 4;

  @override
  Widget build(BuildContext context) {
    final television = AppLayout.isTelevision(context);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              DramaCover(drama: drama, repository: repository),
              if (topBadge != null && topBadge!.isNotEmpty)
                Positioned(
                  left: 8,
                  top: drama.vip ? 34 : 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      topBadge!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              if (badge != null && badge!.isNotEmpty)
                Positioned(
                  left: 6,
                  right: 6,
                  bottom: 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .72),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      child: Text(
                        badge!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              if (actions != null && selected == null)
                Positioned(top: 2, right: 2, child: actions!),
              if (selected != null)
                Positioned(
                  top: 6,
                  right: 6,
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: selected!
                        ? Theme.of(context).colorScheme.primary
                        : Colors.black.withValues(alpha: .64),
                    child: Icon(
                      glassDesign(context)
                          ? selected!
                                ? LucideIcons.check
                                : LucideIcons.circle
                          : selected!
                          ? Icons.check_rounded
                          : Icons.circle_outlined,
                      size: 22,
                      color: selected!
                          ? Theme.of(context).colorScheme.onPrimary
                          : Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 9),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: SizedBox(
            height: titleHeight(context),
            child: Text(
              drama.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                height: 1.3,
                fontSize: 12,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: SizedBox(
            height: subtitleHeight(context),
            child: Text(
              subtitle ?? drama.category,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        if (tagText != null && tagText!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 2, right: 2),
            child: SizedBox(
              height: subtitleHeight(context),
              child: Text(
                tagText!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.3,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
    if (television) {
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.contextMenu): ?onMore,
        },
        child: RemoteTarget(
          focusNode: focusNode,
          onFocus: onFocus,
          onPressed: onTap,
          selected: selected ?? false,
          label:
              '${drama.title}，${drama.episodes}集${badge == null ? '' : '，$badge'}',
          child: content,
        ),
      );
    }
    if (glassDesign(context)) {
      final longPress = onLongPress ?? onMore;
      return Semantics(
        button: true,
        selected: selected,
        label: '${drama.title}，${drama.episodes}集',
        child: PressableScale(
          pressedScale: .965,
          child: GlassTapTarget(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            onLongPress: longPress == null
                ? null
                : () {
                    HapticFeedback.mediumImpact();
                    longPress();
                  },
            onSecondaryTap: onMore,
            child: content,
          ),
        ),
      );
    }
    return Semantics(
      button: true,
      selected: selected,
      label: '${drama.title}，${drama.episodes}集',
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress ?? onMore,
        onSecondaryTap: onMore,
        borderRadius: BorderRadius.circular(14),
        child: content,
      ),
    );
  }
}

class StatusPanel extends StatelessWidget {
  const StatusPanel({
    super.key,
    required this.title,
    this.message = '',
    this.detail,
    this.onRetry,
    this.icon = Icons.movie_filter_outlined,
    this.action = '重试',
    this.secondaryAction,
  });
  final String title;
  final String message;
  final String? detail;
  final VoidCallback? onRetry;
  final IconData icon;
  final String action;
  final Widget? secondaryAction;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (message.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (detail != null && detail!.isNotEmpty) ...[
            const SizedBox(height: 16),
            ExpansionTile(
              title: const Text('查看原始错误'),
              children: [SelectableText(detail!)],
            ),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: 24),
            FilledButton.icon(
              autofocus: AppLayout.isTelevision(context),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(action),
            ),
          ],
          if (secondaryAction != null) ...[
            const SizedBox(height: 8),
            secondaryAction!,
          ],
        ],
      ),
    ),
  );
}

SliverGridDelegate dramaGridDelegate(
  BuildContext context,
  double width, {
  /// 卡片内容超出默认格高时补的高度。DramaTile 的 tagText 行
  /// （上间距 4 + 一行副标题高）不在 extentFor 里，带 tagText
  /// 的卡要把这段补上，否则 Column 溢出。
  double extraExtent = 0,
}) {
  final columns = width < 600 ? 3 : (width / 180).floor().clamp(4, 9);
  final spacing = width < 600 ? 10.0 : 18.0;
  final tileWidth = (width - (columns - 1) * spacing) / columns;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    mainAxisSpacing: videoGridMainAxisSpacing(tileWidth),
    crossAxisSpacing: spacing,
    mainAxisExtent: DramaTile.extentFor(context, tileWidth) + extraExtent,
  );
}

double videoGridMainAxisSpacing(double tileWidth) =>
    (tileWidth * 0.10).clamp(8.0, 16.0);

String formatPosition(double seconds) {
  final value = seconds.isFinite ? seconds.toInt().clamp(0, 999999) : 0;
  return '${value ~/ 60}:${(value % 60).toString().padLeft(2, '0')}';
}
