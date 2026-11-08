import 'dart:async';

import 'app_page_route.dart';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'core_bridge.dart';
import 'models.dart';

const shieldUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36';

Future<void> openClearanceFlow(
  BuildContext context,
  AppRepository repository,
) async {
  List<ClearanceChallenge> pending;
  try {
    pending = await repository.clearanceNeeded();
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('读取待验证站点失败：$error')));
    }
    return;
  }
  if (!context.mounted) return;
  if (pending.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('当前没有待验证的站点')));
    return;
  }
  await Navigator.of(context).push(
    appPageRoute<void>(
      builder: (_) => ClearanceWebViewPage(
        repository: repository,
        challenge: pending.first,
      ),
    ),
  );
}

class ClearanceWebViewPage extends StatefulWidget {
  const ClearanceWebViewPage({
    super.key,
    required this.repository,
    required this.challenge,
  });

  final AppRepository repository;
  final ClearanceChallenge challenge;

  @override
  State<ClearanceWebViewPage> createState() => _ClearanceWebViewPageState();
}

class _ClearanceWebViewPageState extends State<ClearanceWebViewPage> {
  late final WebViewController _controller;
  final WebViewCookieManager _cookieManager = WebViewCookieManager();
  Timer? _timer;
  bool _checking = false;
  bool _done = false;
  String _status = '请在页面中完成站点验证，完成后将自动回填并返回。';

  String get _userAgent => widget.challenge.userAgent.isNotEmpty
      ? widget.challenge.userAgent
      : shieldUserAgent;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_userAgent)
      ..setNavigationDelegate(
        NavigationDelegate(onPageFinished: (_) => unawaited(_checkCookies())),
      );
    unawaited(_controller.loadRequest(Uri.parse(widget.challenge.url)));
    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_checkCookies()),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool _domainMatches(String domain) {
    final normalized = domain.startsWith('.') ? domain.substring(1) : domain;
    final host = widget.challenge.host;
    return host == normalized || host.endsWith('.$normalized');
  }

  Future<void> _checkCookies() async {
    if (_checking || _done) return;
    _checking = true;
    try {
      final cookies = await _cookieManager.getCookies(
        domain: Uri.parse(widget.challenge.url),
      );
      final matched = [
        for (final cookie in cookies)
          if (_domainMatches(cookie.domain)) cookie,
      ];
      final clearance = matched.where(
        (cookie) => cookie.name == 'cf_clearance',
      );
      if (clearance.isEmpty) return;
      final header = matched
          .map((cookie) => '${cookie.name}=${cookie.value}')
          .join('; ');
      await widget.repository.setClearance(
        host: widget.challenge.host,
        cookie: header,
        ua: _userAgent,
      );
      _done = true;
      if (!mounted) return;
      setState(() => _status = '验证已完成，正在返回。');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('站点验证已回填，请重新打开该站点')));
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() => _status = '回填失败：$error');
      }
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('站点验证 · ${widget.challenge.host}')),
      body: Column(
        children: [
          Expanded(child: WebViewWidget(controller: _controller)),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Icon(
                    Icons.verified_user_outlined,
                    size: 18,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _status,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
