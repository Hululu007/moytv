import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core_bridge.dart';
import '../html_host/html_host_page.dart';
import '../html_host/html_site.dart';
import '../local_store.dart';
import 'actress_nvku_page.dart';

/// 演员库入口（2026-11-26）：合并网页（123AV 外壳 + whos 女优库
/// 板块）作演员库界面，宿主走既有 HTML 站源宿主页与 fm 桥；
/// 本地女优库兜底经 fm.nvku 桥查工作库（见 html_nvku.dart）。
///
/// 原生女优库页（ActressNvkuPage）保留作回退：合并页资源加载
/// 失败时自动落回原生页，代码不删。
class ActressHtmlEntryPage extends StatefulWidget {
  const ActressHtmlEntryPage({
    super.key,
    required this.repository,
    required this.store,
    this.showTitle = true,
  });

  final AppRepository repository;
  final LocalStore store;

  /// 与原生页同名参数：嵌入区里调用方传 false。HTML 页自带界面
  /// 框架，此参数只透传给回退的原生页。
  final bool showTitle;

  static const String siteKey = 'actress-library';
  static const String assetPath = 'assets/actress_library.html';

  @override
  State<ActressHtmlEntryPage> createState() => _ActressHtmlEntryPageState();
}

class _ActressHtmlEntryPageState extends State<ActressHtmlEntryPage> {
  late final Future<String> _htmlFuture = _load();

  /// 载入合并页资源，并把宿主页的顶栏模式预置为 edge（无顶栏）：
  /// 本页是嵌入区里打开的（片库区/窗口/短剧页签），壳侧已有顶栏，
  /// 宿主页自带顶栏会叠成双栏；走宿主自带的 chrome 启动偏好
  /// 机制（`moyi_html_chrome:<siteKey>`），不改宿主代码。页面自身
  /// 的导航（源切换条、详情层）完整，不依赖宿主顶栏。
  Future<String> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const prefKey = 'moyi_html_chrome:${ActressHtmlEntryPage.siteKey}';
      if (prefs.getString(prefKey) == null) {
        await prefs.setString(prefKey, 'edge');
      }
    } catch (_) {}
    return rootBundle.loadString(ActressHtmlEntryPage.assetPath);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _htmlFuture,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return HtmlHostPage(
            entry: HtmlSiteEntry(
              siteKey: ActressHtmlEntryPage.siteKey,
              siteName: '女优库',
              route: HtmlSiteRoute.singleFile,
              entryHtml: snapshot.data!,
            ),
            repository: widget.repository,
            store: widget.store,
          );
        }
        if (snapshot.hasError) {
          return ActressNvkuPage(
            repository: widget.repository,
            store: widget.store,
            showTitle: widget.showTitle,
          );
        }
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      },
    );
  }
}
