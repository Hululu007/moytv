/// 网盘登录中心（设置内入口）：四家网盘扫码登录 + 凭证管理。
///
/// 对标 TVBox_Web website.html 的配置中心，界面与文案全是魔蚁自己的。
/// 凭证只存本机（混淆存储，见 CloudCredentialStore 文件头说明），
/// 可逐家清除；登录后网盘作为站源进站点列表，全局通用。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../local_store.dart';
import 'cloud_credential_store.dart';
import 'cloud_drive_stations.dart';
import 'cloud_providers.dart';
import 'qr_code_widget.dart';

/// 各家验证到哪一步（诚实口径，界面上直接展示，不夸大）。
const _verifyNotes = <String, String>{
  'pan115': '扫码接口已实测；文件浏览与播放需真账号验证',
  'quark': '扫码接口已实测；文件浏览与播放需真账号验证',
  'aliyun': '扫码接口已实测；文件浏览与播放需真账号验证',
  'baidu': '扫码接口已实测；文件浏览与播放需真账号验证',
};

class CloudDriveScreen extends StatefulWidget {
  const CloudDriveScreen({super.key, required this.store});

  final LocalStore store;

  @override
  State<CloudDriveScreen> createState() => _CloudDriveScreenState();
}

class _CloudDriveScreenState extends State<CloudDriveScreen> {
  final _client = http.Client();
  final _providers = createCloudDriveProviders();
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
        SnackBar(content: Text('获取二维码失败：$e')),
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
                  '登录一次全局通用：登录后的网盘会作为站源出现在站源列表、搜索与局域网服务里。凭证只存本机，可随时清除。',
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
                if (!loggedIn)
                  FilledButton(
                    onPressed: () => _startQrLogin(provider),
                    child: const Text('扫码登录'),
                  ),
                if (!loggedIn)
                  OutlinedButton(
                    onPressed: () => _manualLogin(provider),
                    child: const Text('手动粘贴凭证'),
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
  Timer? _timer;
  String _status = '';
  bool _expired = false;
  bool _failed = false;
  QrLoginSession? _currentSession;

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
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    final session = _currentSession;
    if (session == null) return;
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
    QrPollResult result;
    try {
      result = await widget.provider.pollQrLogin(widget.client, session);
    } catch (e) {
      if (!mounted) return;
      _timer?.cancel();
      setState(() {
        _failed = true;
        _status = '轮询出错：$e';
      });
      return;
    }
    if (!mounted) return;
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
        _status = '获取二维码失败：$e';
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
