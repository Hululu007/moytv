/// 网盘登录中心（设置内入口）：五家网盘登录 + 凭证管理。
///
/// 对标 TVBox_Web website.html 的配置中心，界面与文案全是魔蚁自己的。
/// 115/夸克/阿里/百度走扫码登录，移动云盘走手机号 + 短信验证码登录
/// （触发风控时在内嵌页里完成滑块验证）。凭证只存本机（混淆存储，
/// 见 CloudCredentialStore 文件头说明），可逐家清除；登录后网盘作为
/// 站源进站点列表，全局通用。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../local_store.dart';
import 'cloud_credential_store.dart';
import 'cloud_drive_stations.dart';
import 'cloud_provider_139.dart';
import 'cloud_providers.dart';
import 'qr_code_widget.dart';

/// 各家验证到哪一步（诚实口径，界面上直接展示，不夸大）。
const _verifyNotes = <String, String>{
  'pan115': '扫码接口已实测；文件浏览与播放需真账号验证',
  'quark': '扫码接口已实测；文件浏览与播放需真账号验证',
  'aliyun': '扫码接口已实测；文件浏览与播放需真账号验证',
  'baidu': '扫码接口已实测；文件浏览与播放需真账号验证',
  'yun139': '短信登录；文件浏览与播放需真账号验证',
};

class CloudDriveScreen extends StatefulWidget {
  const CloudDriveScreen({super.key, required this.store, this.providers});

  final LocalStore store;

  /// 注入网盘列表（单测用假 provider；不传则用五家真实 provider）。
  final List<CloudDriveProvider>? providers;

  @override
  State<CloudDriveScreen> createState() => _CloudDriveScreenState();
}

class _CloudDriveScreenState extends State<CloudDriveScreen> {
  final _client = http.Client();
  late final _providers = widget.providers ?? createCloudDriveProviders();
  CloudCredentialStore? _credentialStore;
  Set<String> _loggedIn = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final store = CloudCredentialStore(prefs);
    setState(() {
      _credentialStore = store;
      _loggedIn = store.loggedInProviderIds(_providers.map((p) => p.id)).toSet();
      _loading = false;
    });
  }

  void _refreshStations() {
    final store = _credentialStore;
    if (store == null) return;
    CloudDriveStations.refresh(store);
    setState(() {
      _loggedIn = store.loggedInProviderIds(_providers.map((p) => p.id)).toSet();
    });
  }

  Future<void> _clear(CloudDriveProvider provider) async {
    final store = _credentialStore;
    if (store == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('清除${provider.displayName}登录？'),
        content: const Text('清除后该网盘会从站源列表里消失，文件本身不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await store.clear(provider.id);
    _refreshStations();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已清除${provider.displayName}登录')),
      );
    }
  }

  Future<void> _startQrLogin(CloudDriveProvider provider) async {
    final store = _credentialStore;
    if (store == null) return;
    QrLoginSession session;
    try {
      session = await provider.startQrLogin(_client);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _qrErrorMessage(e, '获取二维码失败，请检查网络后重试'),
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    final credentials = await showDialog<CloudCredentials>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _QrLoginDialog(
        provider: provider,
        session: session,
        client: _client,
      ),
    );
    if (credentials == null || !mounted) return;
    await store.save(provider.id, credentials);
    _refreshStations();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${provider.displayName}登录成功，已加入站源列表')),
      );
    }
  }

  Future<void> _startSmsLogin(Yun139Provider provider) async {
    final store = _credentialStore;
    if (store == null) return;
    final credentials = await showDialog<CloudCredentials>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _SmsLoginDialog(
        provider: provider,
        client: _client,
      ),
    );
    if (credentials == null || !mounted) return;
    await store.save(provider.id, credentials);
    _refreshStations();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${provider.displayName}登录成功，已加入站源列表')),
      );
    }
  }

  Future<void> _refreshYun139(Yun139Provider provider) async {
    final store = _credentialStore;
    if (store == null) return;
    final current = store.load(provider.id);
    if (current == null) return;
    try {
      final refreshed = await provider.refreshCredentials(_client, current);
      await store.save(provider.id, refreshed);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('移动云盘登录已刷新')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('刷新失败：$e，请清除后重新登录')),
      );
    }
  }

  Future<void> _manualLogin(CloudDriveProvider provider) async {
    final store = _credentialStore;
    if (store == null) return;
    final controller = TextEditingController();
    final isAliyun = provider.id == 'aliyun';
    final pasted = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('手动登录${provider.displayName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isAliyun
                  ? '粘贴 refresh_token（从阿里云盘网页版登录态里取）。'
                  : '粘贴登录后的 Cookie（从浏览器/抓包里取整串 Cookie）。',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '粘贴到这里',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (pasted == null || pasted.isEmpty || !mounted) return;
    try {
      if (isAliyun) {
        final aliyun = provider as AliyunProvider;
        final credentials = await aliyun.credentialsFromRefreshToken(
          _client,
          pasted,
        );
        if (credentials == null) {
          throw CloudDriveException('refresh_token 无效，换取凭证失败');
        }
        await store.save(provider.id, credentials);
      } else {
        await store.save(
          provider.id,
          CloudCredentials(
            fields: {'cookie': pasted},
            savedAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
      return;
    }
    _refreshStations();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${provider.displayName}已保存，打开站源列表验证是否可用')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('网盘登录')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  '登录一次全局通用：登录后的网盘会作为站源出现在站源列表、搜索里。凭证只存本机，可随时清除。',
                ),
                const SizedBox(height: 16),
                for (final provider in _providers)
                  _providerCard(provider),
                const SizedBox(height: 24),
                const Text(
                  '广告视频过滤',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                SwitchListTile(
                  title: const Text('显示疑似广告视频'),
                  subtitle: const Text(
                    '默认隐藏小文件、极短、文件名带推广信息的疑似广告视频；打开后全部显示并标注“疑似广告”。只过滤显示，绝不删文件。判定是经验规则，可能误判。',
                  ),
                  value: widget.store.showSuspectedAdVideos,
                  onChanged: (value) async {
                    await widget.store.setShowSuspectedAdVideos(value);
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
    );
  }

  Widget _providerCard(CloudDriveProvider provider) {
    final loggedIn = _loggedIn.contains(provider.id);
    final yun139 = provider is Yun139Provider;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    provider.displayName,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                Chip(
                  label: Text(loggedIn ? '已登录' : '未登录'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _verifyNotes[provider.id] ?? '',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                if (!loggedIn && yun139)
                  FilledButton(
                    onPressed: () => _startSmsLogin(provider),
                    child: const Text('短信登录'),
                  ),
                if (!loggedIn && !yun139)
                  FilledButton(
                    onPressed: () => _startQrLogin(provider),
                    child: const Text('扫码登录'),
                  ),
                if (!loggedIn && !yun139)
                  OutlinedButton(
                    onPressed: () => _manualLogin(provider),
                    child: const Text('手动粘贴凭证'),
                  ),
                if (loggedIn && yun139)
                  OutlinedButton(
                    onPressed: () => _refreshYun139(provider),
                    child: const Text('刷新登录'),
                  ),
                if (loggedIn)
                  OutlinedButton(
                    onPressed: () => _clear(provider),
                    child: const Text('清除登录'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 扫码流程里给用户看的错误文案：网盘侧抛的中文说明（[CloudDriveException]，
/// 文案是写死的中文、不含地址）直接显示；其余异常一律用干净的通用文案，
/// 绝不把异常原文（可能含完整请求地址与凭证参数）显示出来。
String _qrErrorMessage(Object error, String fallback) =>
    error is CloudDriveException ? error.message : fallback;

/// 扫码登录弹窗：二维码 + 轮询 + 过期重取 + 内容链接复制。
class _QrLoginDialog extends StatefulWidget {
  const _QrLoginDialog({
    required this.provider,
    required this.session,
    required this.client,
  });

  final CloudDriveProvider provider;
  final QrLoginSession session;
  final http.Client client;

  @override
  State<_QrLoginDialog> createState() => _QrLoginDialogState();
}

class _QrLoginDialogState extends State<_QrLoginDialog> {
  /// 连续瞬时网络失败达到这么多次才判失败（轮询间隔 2 秒，5 次约
  /// 10 秒，盖住一次网络抖动；超过就是真断网，没必要再等）。
  static const _maxConsecutivePollFailures = 5;

  Timer? _timer;
  String _status = '';
  bool _expired = false;
  bool _failed = false;
  QrLoginSession? _currentSession;
  int _consecutivePollFailures = 0;

  /// 一次轮询请求在途时跳过后续 tick：请求超时 20 秒、tick 间隔
  /// 2 秒，不加这个网络一挂就会叠起一串并发请求。
  bool _pollInFlight = false;

  @override
  void initState() {
    super.initState();
    _currentSession = widget.session;
    _status = widget.session.message;
    _startPolling();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _timer?.cancel();
    _consecutivePollFailures = 0;
    _pollInFlight = false;
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    final session = _currentSession;
    if (session == null || _pollInFlight) return;
    if (DateTime.now().isAfter(session.expiresAt)) {
      _timer?.cancel();
      if (mounted) {
        setState(() {
          _expired = true;
          _status = '二维码已过期，请重新获取';
        });
      }
      return;
    }
    _pollInFlight = true;
    QrPollResult result;
    try {
      result = await widget.provider.pollQrLogin(widget.client, session);
    } catch (e) {
      if (!mounted) return;
      // 瞬时网络错（连接被断/重置/超时）不终结轮询：继续等下一个
      // tick，只提示“正在重试”；连续失败到上限才判失败。一次抖动
      // 就停轮询是 2026-11-18 用户手机上 115 扫码报障的根因。
      if (_isTransientPollError(e)) {
        _consecutivePollFailures++;
        if (_consecutivePollFailures >= _maxConsecutivePollFailures) {
          _timer?.cancel();
          setState(() {
            _failed = true;
            _status = '网络不稳定，获取扫码状态失败，请重新获取';
          });
        } else {
          setState(() {
            _status = '网络波动，正在重试…';
          });
        }
        return;
      }
      _timer?.cancel();
      setState(() {
        _failed = true;
        _status = _qrErrorMessage(e, '获取扫码状态失败，请重新获取');
      });
      return;
    } finally {
      _pollInFlight = false;
    }
    if (!mounted) return;
    // 拿到任何一次正常结果都清零：只数“连续”失败。
    _consecutivePollFailures = 0;
    switch (result.status) {
      case QrPollStatus.success:
        _timer?.cancel();
        Navigator.of(context).pop(result.credentials);
      case QrPollStatus.expired:
        _timer?.cancel();
        setState(() {
          _expired = true;
          _status = result.message;
        });
      case QrPollStatus.failed:
        _timer?.cancel();
        setState(() {
          _failed = true;
          _status = result.message;
        });
      case QrPollStatus.scanned:
        setState(() => _status = '已扫码，请在 ${widget.provider.appName} 内确认登录');
      case QrPollStatus.waiting:
        setState(() => _status = result.message);
    }
  }

  /// 轮询里可重试的瞬时网络错：连接被断/重置（http 客户端包成
  /// [http.ClientException]，用户截图里就是这一种）、Socket/Http 层
  /// 错误、请求超时。其余异常（返回解析失败、不支持的操作等）不是
  /// 网络抖动，不重试，立即判失败。
  bool _isTransientPollError(Object error) {
    return error is TimeoutException ||
        error is SocketException ||
        error is HttpException ||
        error is http.ClientException;
  }

  Future<void> _refreshQr() async {
    setState(() {
      _expired = false;
      _failed = false;
      _status = '正在获取二维码…';
    });
    try {
      final session = await widget.provider.startQrLogin(widget.client);
      if (!mounted) return;
      setState(() {
        _currentSession = session;
        _status = session.message;
      });
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _status = _qrErrorMessage(e, '获取二维码失败，请检查网络后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _currentSession ?? widget.session;
    final qr = session.qrImageUrl.isNotEmpty
        ? Image.network(
            session.qrImageUrl,
            width: 220,
            height: 220,
            errorBuilder: (_, _, _) => const SizedBox(
              width: 220,
              height: 220,
              child: Center(child: Text('二维码图片加载失败')),
            ),
          )
        : QrCodeWidget(
            content: session.qrContent,
            size: 220,
            fallback: const SizedBox(
              width: 220,
              height: 220,
              child: Center(child: Text('二维码内容过长，无法生成图片，请复制链接')),
            ),
          );
    return AlertDialog(
      title: Text('${widget.provider.displayName}扫码登录'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            qr,
            const SizedBox(height: 12),
            Text(_status, textAlign: TextAlign.center),
            if (session.qrContent.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                session.qrContent,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: session.qrContent));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('二维码链接已复制')),
                  );
                },
                child: const Text('复制二维码链接'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_expired || _failed)
          TextButton(onPressed: _refreshQr, child: const Text('重新获取')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// 移动云盘短信登录弹窗：手机号 + 获取验证码 + 验证码 + 登录。
///
/// 触发风控时打开内嵌滑块页（[_CaptchaWebViewPage]），用户在页内完成
/// 滑块后返回本弹窗等短信、输验证码登录；登录时带上发短信时返回的
/// 滑块头。发短信后 60 秒内不重复发送，避免连点刷接口。
class _SmsLoginDialog extends StatefulWidget {
  const _SmsLoginDialog({required this.provider, required this.client});

  final Yun139Provider provider;
  final http.Client client;

  @override
  State<_SmsLoginDialog> createState() => _SmsLoginDialogState();
}

class _SmsLoginDialogState extends State<_SmsLoginDialog> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  Timer? _cooldownTimer;
  int _cooldownSeconds = 0;
  bool _busy = false;
  bool _smsSent = false;
  String _status = '输入手机号获取验证码，触发验证时会打开滑块页。';
  Map<String, String> _sliderHeaders = const {};

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldownSeconds = 60);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_cooldownSeconds <= 1) {
        timer.cancel();
        setState(() => _cooldownSeconds = 0);
      } else {
        setState(() => _cooldownSeconds--);
      }
    });
  }

  Future<void> _sendSms() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) {
      setState(() => _status = '请先输入手机号');
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在发送验证码…';
    });
    Yun139SmsResult result;
    try {
      result = await widget.provider.sendSms(widget.client, phone);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '发送失败：$e';
      });
      return;
    }
    if (!mounted) return;
    if (result.requiresCaptcha) {
      setState(() {
        _busy = false;
        _status = '需要完成滑块验证，正在打开验证页…';
      });
      final completed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => _CaptchaWebViewPage(url: result.captchaUrl),
        ),
      );
      if (!mounted) return;
      if (completed == true) {
        setState(() {
          _sliderHeaders = result.sliderHeaders;
          _smsSent = true;
          _status = '滑块已完成，请查收短信验证码并输入，60 秒后可重发。';
        });
        _startCooldown();
      } else {
        setState(() => _status = '滑块验证未完成，请重新获取验证码。');
      }
      return;
    }
    setState(() {
      _busy = false;
      _smsSent = true;
      _status = result.message;
    });
    _startCooldown();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _status = '正在登录…';
    });
    try {
      final credentials = await widget.provider.loginWithSms(
        widget.client,
        _phoneController.text,
        _codeController.text,
        sliderHeaders: _sliderHeaders,
      );
      if (!mounted) return;
      Navigator.of(context).pop(credentials);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '登录失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('移动云盘短信登录'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '手机号',
                hintText: '11 位移动手机号',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _codeController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '短信验证码',
                      hintText: '6 位数字',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: (_busy || _cooldownSeconds > 0) ? null : _sendSms,
                  child: Text(
                    _cooldownSeconds > 0 ? '$_cooldownSeconds 秒后重发' : '获取验证码',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(_status),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: (_busy || !_smsSent) ? null : _login,
          child: const Text('登录'),
        ),
      ],
    );
  }
}

/// 滑块验证内嵌页：最小 WebView（与清关桥同款 WebViewController 用法，
/// 不复用清关页——那页绑的是 cf_clearance 回填逻辑，与滑块无关）。
///
/// 滑块完成没有可监听的可靠信号（源头前端也是 iframe + 用户自行返回
/// 等短信），所以这里不猜“完成了”：用户在页内完成滑块后自己点
/// “我已完成验证”返回；点返回不代表服务端已通过，短信没来就重发。
class _CaptchaWebViewPage extends StatefulWidget {
  const _CaptchaWebViewPage({required this.url});

  final String url;

  @override
  State<_CaptchaWebViewPage> createState() => _CaptchaWebViewPageState();
}

class _CaptchaWebViewPageState extends State<_CaptchaWebViewPage> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted);
    unawaited(_controller.loadRequest(Uri.parse(widget.url)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('滑块验证')),
      body: Column(
        children: [
          Expanded(child: WebViewWidget(controller: _controller)),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('请在上方页面内完成滑块验证，完成后点下面按钮返回，等待短信验证码。'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('我已完成验证'),
                        ),
                      ),
                    ],
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
