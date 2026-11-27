import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 底部导航页签的稳定身份（用户 2026-11-27 令：底部栏像手机桌面一样
/// 可编辑——拖动排序、隐藏、自动补位）。枚举顺序即出厂默认顺序，也
/// 是 home_screen 里 _onBottomTab/_bottomTabIndex 一直用的下标口径
/// （0 片库 … 7 我的），改顺序等于改全局口径，不许动。
enum BottomNavTab {
  library('library', '片库', LucideIcons.clapperboard),
  live('live', '直播', LucideIcons.tv),
  listenRead('listen', '听读', LucideIcons.bookHeadphones),
  cloudDrive('pan', '网盘', LucideIcons.hardDrive),
  miniApp('miniapp', '小程序', LucideIcons.layoutGrid),
  actress('actress', '演员库', LucideIcons.users),
  gameZone('game', '游戏区', LucideIcons.gamepad2),
  mine('mine', '我的', LucideIcons.user);

  const BottomNavTab(this.id, this.label, this.icon);

  /// 持久化用的稳定 id（存进偏好的是 id 不是下标，将来增删页签不串位）。
  final String id;
  final String label;
  final IconData icon;

  static BottomNavTab? byId(String id) {
    for (final tab in values) {
      if (tab.id == id) return tab;
    }
    return null;
  }
}

/// 用户的底部导航布局偏好：全体页签的一个排列 [order] + 被用户隐藏
/// 的集合 [hidden]。隐藏只是不显示、随时可恢复（用户口径：删除不要
/// ＝不让删、须可恢复），本类没有任何真删页签的操作。
///
/// 系统门禁隐藏与用户隐藏是两回事：门禁集合不落进 [hidden]，只在
/// 渲染时经 [displayVisible] 临时叠加过滤；门禁解除后页签按用户排
/// 的顺序原位回来，两边不串。
class BottomNavLayout {
  BottomNavLayout({required this.order, required this.hidden});

  factory BottomNavLayout.defaults() => BottomNavLayout(
    order: List.of(BottomNavTab.values),
    hidden: <BottomNavTab>{},
  );

  /// 全体页签的排列（含被隐藏的：隐藏的页签在排列里保留位置，恢复
  /// 时回到原来的相对位置）。
  final List<BottomNavTab> order;

  /// 被用户隐藏的页签（进「已隐藏」池，在设置-底部导航管理里恢复）。
  final Set<BottomNavTab> hidden;

  /// 用户口径下可见的页签（按用户排的顺序）。
  List<BottomNavTab> get visible => [
    for (final tab in order)
      if (!hidden.contains(tab)) tab,
  ];

  /// 实际渲染用的可见页签：在用户可见集合上再叠一层系统门禁过滤。
  /// 门禁集合只影响这一次渲染，不写回 [hidden]。
  List<BottomNavTab> displayVisible({
    Set<BottomNavTab> gateHidden = const {},
  }) => [
    for (final tab in visible)
      if (!gateHidden.contains(tab)) tab,
  ];

  /// 在可见序列里把第 [from] 个页签移到第 [to] 个（拖动排序落点）。
  /// 被隐藏的页签在 [order] 里原地不动，可见槽位依次换成新序列，
  /// 所以跨中央圆钮左右拖动只是序列内换位、没有特殊分支。
  void moveVisible(int from, int to) {
    final vis = visible;
    if (from < 0 || from >= vis.length) return;
    if (to < 0 || to >= vis.length) return;
    if (from == to) return;
    final moved = vis.removeAt(from);
    vis.insert(to, moved);
    var cursor = 0;
    for (var i = 0; i < order.length; i++) {
      if (!hidden.contains(order[i])) {
        order[i] = vis[cursor++];
      }
    }
  }

  /// 隐藏一个页签。至少保留 1 个可见页签：藏到最后一个时返回 false
  /// 不动手（底线拦截）。
  bool hide(BottomNavTab tab) {
    if (hidden.contains(tab)) return false;
    if (visible.length <= 1) return false;
    hidden.add(tab);
    return true;
  }

  /// 恢复显示（从「已隐藏」池里放回底部栏，位置按 [order] 原位）。
  void show(BottomNavTab tab) {
    hidden.remove(tab);
  }

  /// 一键重置默认布局：出厂顺序、全部显示。
  void reset() {
    order
      ..clear()
      ..addAll(BottomNavTab.values);
    hidden.clear();
  }

  String get orderRaw => order.map((tab) => tab.id).join(',');

  String get hiddenRaw => hidden.map((tab) => tab.id).join(',');

  /// 从存量字符串解析：未知 id 忽略、重复 id 去重、缺失的页签按默认
  /// 顺序补到末尾（将来版本新增页签时老用户自动多出一个、不丢旧
  /// 排序）；解析完若可见为空（存量被写坏）则清空隐藏名单兜底，
  /// 保证底部栏永远至少有一个页签。
  factory BottomNavLayout.fromStored(String? orderRaw, String? hiddenRaw) {
    final order = <BottomNavTab>[];
    if (orderRaw != null) {
      for (final part in orderRaw.split(',')) {
        final tab = BottomNavTab.byId(part.trim());
        if (tab != null && !order.contains(tab)) order.add(tab);
      }
    }
    for (final tab in BottomNavTab.values) {
      if (!order.contains(tab)) order.add(tab);
    }
    final hidden = <BottomNavTab>{};
    if (hiddenRaw != null) {
      for (final part in hiddenRaw.split(',')) {
        final tab = BottomNavTab.byId(part.trim());
        if (tab != null) hidden.add(tab);
      }
    }
    final layout = BottomNavLayout(order: order, hidden: hidden);
    if (layout.visible.isEmpty) layout.hidden.clear();
    return layout;
  }

  static const String orderKey = 'bottomNavOrderV1';
  static const String hiddenKey = 'bottomNavHiddenV1';

  static BottomNavLayout load(SharedPreferences preferences) =>
      BottomNavLayout.fromStored(
        preferences.getString(orderKey),
        preferences.getString(hiddenKey),
      );

  Future<void> save(SharedPreferences preferences) async {
    await preferences.setString(orderKey, orderRaw);
    await preferences.setString(hiddenKey, hiddenRaw);
  }
}
