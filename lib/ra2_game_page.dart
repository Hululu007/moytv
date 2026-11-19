import 'package:flutter/material.dart';

import 'web_game_page.dart';

/// 游戏地址：只出现在代码里，界面上任何地方都不显示（标题栏、
/// 加载提示、失败面板一律不带网址字串，也不把系统错误描述
/// 原样显示出来，描述里可能含网址）。
const String _gameUrl = 'https://game.ra2web.com/';

/// 唯一放行的主机：站内跳转只认它。
const String _gameHost = 'game.ra2web.com';

/// 导航放行判定（纯函数，可单测）：只放行本站主机内的跳转；
/// 跳出本站的导航一律拦截，不跳系统浏览器。子资源加载不走
/// 导航回调，不受这条限制影响。
bool ra2NavigationAllowed(String url) =>
    webGameNavigationAllowed(url, _gameHost);

/// 网页游戏页（红警2）：Win7/XP 桌面游戏窗口的窗口体。
/// 通用游戏窗的薄壳：传红警2常量 + keyPrefix 'ra2'，加载/失败
/// 面板的键仍是 `ra2-*`，与既有测试一致。
class Ra2GamePage extends StatelessWidget {
  const Ra2GamePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const WebGamePage(
      gameUrl: _gameUrl,
      allowedHost: _gameHost,
      keyPrefix: 'ra2',
    );
  }
}
