import 'dart:async';

import 'package:flutter/material.dart';

import 'local_store.dart';
import 'm3u_subscriptions.dart';
import 'tvbox_config.dart';

/// 订阅的进入方向：影视（站点浏览）或直播（频道列表）。
enum SubscriptionEntryKind { video, live }

/// 双入口里的一个可选项：影视侧是配置内的一个站点，直播侧是一个直播源。
class SubscriptionEntryItem {
  const SubscriptionEntryItem({
    required this.id,
    required this.name,
    this.detail = '',
  });

  /// 影视侧为站源 id（见 [videoSiteIdForRecord]），直播侧为直播源 id。
  final String id;
  final String name;
  final String detail;
}

/// 订阅的一个进入方向，含该方向下的全部可选项。
class SubscriptionEntry {
  const SubscriptionEntry({required this.kind, required this.items});

  final SubscriptionEntryKind kind;
  final List<SubscriptionEntryItem> items;

  bool get isVideo => kind == SubscriptionEntryKind.video;
  bool get isLive => kind == SubscriptionEntryKind.live;

  /// 入口按钮文案：双边订阅两个按钮分别显示方向与数量，单选项不带数量。
  String get actionLabel {
    final base = isVideo ? '影视' : '直播';
    if (items.length <= 1) return base;
    return isVideo ? '$base · ${items.length} 个站' : '$base · ${items.length} 个';
  }

  String get sheetTitle => isVideo ? '选择站点进入' : '选择直播源进入';
}

/// 配置内一条站点记录对应的可浏览站源 id：jar 站按 siteId 注册，
/// 其余（py/接口/T4）按 coreId 注册，coreId 为空时回落 siteId。
/// 与 TvBoxConfigStore._registerRecord 的注册口径一致。
String videoSiteIdForRecord(TvBoxSiteRecord site) =>
    site.coreId.isNotEmpty ? site.coreId : site.siteId;

String _videoKindLabel(String kind) => switch (kind) {
  'py' => 'py 站',
  'jar' => 'jar 站',
  't4' => 'T4 站',
  'api' => '接口站',
  _ => '',
};

String _liveHost(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return host;
}

/// 一份 TVBox 配置的进入方向：有站点出影视入口，有直播出直播入口，
/// 双边都有则两个入口都出，只有单边则只出单入口，两边都没有则空。
List<SubscriptionEntry> subscriptionEntriesForConfig(TvBoxConfigRecord record) {
  final entries = <SubscriptionEntry>[];
  if (record.sites.isNotEmpty) {
    entries.add(
      SubscriptionEntry(
        kind: SubscriptionEntryKind.video,
        items: [
          for (final site in record.sites)
            SubscriptionEntryItem(
              id: videoSiteIdForRecord(site),
              name: site.name,
              detail: _videoKindLabel(site.kind),
            ),
        ],
      ),
    );
  }
  if (record.lives.isNotEmpty) {
    entries.add(
      SubscriptionEntry(
        kind: SubscriptionEntryKind.live,
        items: [
          for (final live in record.lives)
            SubscriptionEntryItem(
              id: live.id,
              name: live.name,
              detail: _liveHost(live.url),
            ),
        ],
      ),
    );
  }
  return entries;
}

/// m3u 订阅只有直播一边：恒为单个直播入口。
List<SubscriptionEntry> subscriptionEntriesForM3u(M3uSubscription sub) => [
  SubscriptionEntry(
    kind: SubscriptionEntryKind.live,
    items: [
      SubscriptionEntryItem(
        id: sub.sourceId,
        name: sub.name,
        detail: '${sub.channelCount} 个频道',
      ),
    ],
  ),
];

/// 订阅行上的进入按钮：双边订阅出“影视/直播”两个入口，单边只出一个，
/// 无入口时不占地方。某方向有多个可选项时先弹选单，单选项直接进入。
class SubscriptionEntryButtons extends StatelessWidget {
  const SubscriptionEntryButtons({
    super.key,
    required this.entries,
    required this.onEnterVideo,
    required this.onEnterLive,
    this.padding = const EdgeInsets.fromLTRB(14, 0, 14, 12),
  });

  final List<SubscriptionEntry> entries;

  /// 影视进入：回调参数为站源 id。
  final ValueChanged<String> onEnterVideo;

  /// 直播进入：回调参数为直播源 id。
  final ValueChanged<String> onEnterLive;
  final EdgeInsetsGeometry padding;

  void _enter(BuildContext context, SubscriptionEntry entry) {
    if (entry.items.length == 1) {
      _pick(entry, entry.items.single);
      return;
    }
    unawaited(
      showSubscriptionEntrySheet(
        context,
        entry,
        onPick: (item) => _pick(entry, item),
      ),
    );
  }

  void _pick(SubscriptionEntry entry, SubscriptionEntryItem item) {
    if (entry.isVideo) {
      onEnterVideo(item.id);
    } else {
      onEnterLive(item.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final entry in entries)
            FilledButton.tonalIcon(
              key: ValueKey(
                'subscription-entry-${entry.isVideo ? 'video' : 'live'}',
              ),
              onPressed: () => _enter(context, entry),
              icon: Icon(
                entry.isVideo ? Icons.movie_outlined : Icons.live_tv_rounded,
                size: 18,
              ),
              label: Text(entry.actionLabel),
            ),
        ],
      ),
    );
  }
}

/// 多选项的方向选单：列出该方向的全部可选项，点一项即进入。
Future<void> showSubscriptionEntrySheet(
  BuildContext context,
  SubscriptionEntry entry, {
  required ValueChanged<SubscriptionEntryItem> onPick,
}) async {
  final picked = await showModalBottomSheet<SubscriptionEntryItem>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              entry.sheetTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final item in entry.items)
                  ListTile(
                    key: ValueKey('subscription-entry-item-${item.id}'),
                    leading: Icon(
                      entry.isVideo
                          ? Icons.dns_outlined
                          : Icons.live_tv_rounded,
                    ),
                    title: Text(item.name),
                    subtitle: item.detail.isEmpty
                        ? null
                        : Text(
                            item.detail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pop(context, item),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  if (picked != null) onPick(picked);
}

/// 点“影视”进入：把待办请求记到 LocalStore（内存态，不落盘），
/// 再退回首页；首页在 didPopNext 里消费请求、切站浏览。
void enterSubscriptionVideo(
  BuildContext context,
  LocalStore store,
  String siteId,
) {
  store.requestSubscriptionEntry(siteId: siteId);
  Navigator.of(context).popUntil((route) => route.isFirst);
}

/// 点“直播”进入：同影视进入，首页消费后切到直播区并选中该直播源。
void enterSubscriptionLive(
  BuildContext context,
  LocalStore store,
  String liveSourceId,
) {
  store.requestSubscriptionEntry(liveSourceId: liveSourceId);
  Navigator.of(context).popUntil((route) => route.isFirst);
}
