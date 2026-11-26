/// 网盘登录中心（设置内入口）：五家网盘登录 + 凭证管理。
/// 115 登录后另有账号信息位（昵称/ID/会员/容量，接口真返回才显示）
/// 与上传入口（选本地文件流式上传到根目录，进度弹窗如实反馈）。
///
/// 对标 TVBox_Web website.html 的配置中心，界面与文案全是魔蚁自己的。
/// 115/夸克/阿里/百度走扫码登录，移动云盘走手机号 + 短信验证码登录
/// （触发风控时在内嵌页里完成滑块验证）。凭证只存本机（混淆存储，
/// 见 CloudCredentialStore 文件头说明），可逐家清除；登录后网盘作为
/// 站源进站点列表，全局通用。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
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

/// 115 上传的选文件结果：本地路径 + 显示名（路径拿不到时为空串）。
typedef Pan115UploadPick = ({String path, String name});

class CloudDriveScreen extends StatefulWidget {
  const CloudDriveScreen({
    super.key,
    required this.store,
    this.providers,
    this.uploadPicker,
  });

  final LocalStore store;

  /// 注入网盘列表（单测用假 provider；不传则用五家真实 provider）。
  final List<CloudDriveProvider>? providers;

  /// 注入 115 上传的选文件动作（单测/预览用；不传走系统文件选择器）。
  final Future<Pan115UploadPick?> Function()? uploadPicker;

  @override
  State<CloudDriveScreen> createState() => _CloudDriveScreenState();
}

class _CloudDriveScreenState extends State<CloudDriveScreen> {
  final _client = http.Client();
  late final _providers = widget.providers ?? createCloudDriveProviders();
  CloudCredentialStore? _credentialStore;
  Set<String> _loggedIn = {};
  bool _loading = true;

  /// 115 账号信息位的状态：账号与容量各自独立成败，拉到哪个显示
  /// 哪个；两个都失败才落 [_pan115InfoError] 显示原因。
  Pan115AccountInfo? _pan115Account;
  Pan115SpaceInfo? _pan115Space;
  String? _pan115InfoError;
  bool _pan115InfoLoading = false;

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
    unawaited(_loadPan115Info());
  }

  void _refreshStations() {
    final store = _credentialStore;
    if (store == null) return;
    CloudDriveStations.refresh(store);
    setState(() {
      _loggedIn = store.loggedInProviderIds(_providers.map((p) => p.id)).toSet();
    });
    unawaited(_loadPan115Info());
  }

  /// 拉 115 账号/容量信息（账号信息位用）：未登录就清空；账号与
  /// 容量各自独立成败，失败原因如实落字，不编数据。
  Future<void> _loadPan115Info() async {
    final store = _credentialStore;
    if (store == null || _pan115InfoLoading) return;
    Pan115Provider? pan115;
    for (final provider in _providers) {
      if (provider is Pan115Provider) {
        pan115 = provider;
        break;
      }
    }
    if (pan115 == null) return;
    if (!_loggedIn.contains(pan115.id)) {
      if (_pan115Account != null ||
          _pan115Space != null ||
          _pan115InfoError != null) {
        setState(() {
          _pan115Account = null;
          _pan115Space = null;
          _pan115InfoError = null;
        });
      }
      return;
    }
    final credentials = store.load(pan115.id);
    if (credentials == null) return;
    setState(() => _pan115InfoLoading = true);
    Pan115AccountInfo? account;
    Pan115SpaceInfo? space;
    String? error;
    try {
      account = await pan115.accountInfo(_client, credentials);
    } catch (e) {
      error = _qrErrorMessage(e, '账号信息获取失败，请检查网络后重试');
    }
    try {
      space = await pan115.spaceInfo(_client, credentials);
    } catch (e) {
      error ??= _qrErrorMessage(e, '容量信息获取失败，请检查网络后重试');
    }
    if (!mounted) return;
    setState(() {
      _pan115InfoLoading = false;
      if (account != null) _pan115Account = account;
      if (space != null) _pan115Space = space;
      _pan115InfoError = (account == null && space == null) ? error : null;
    });
  }

  /// 115 上传入口：选本地文件 → 流式上传到网盘根目录，进度与成败
  /// 在弹窗里如实反馈（失败原因显示 provider 给的中文说明）。
  Future<void> _startPan115Upload(Pan115Provider provider) async {
    final store = _credentialStore;
    if (store == null) return;
    final credentials = store.load(provider.id);
    if (credentials == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录 115 网盘')),
      );
      return;
    }
    Pan115UploadPick? pick;
    try {
      pick = await (widget.uploadPicker?.call() ?? _pickUploadFile());
    } catch (_) {
      pick = null;
    }
    if (!mounted) return;
    if (pick == null) return; // 用户取消选文件，不打扰。
    if (pick.path.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没能拿到所选文件的路径，请换个文件再试')),
      );
      return;
    }
    final picked = pick;
    final done = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _Pan115UploadDialog(
        provider: provider,
        client: _client,
        credentials: credentials,
        file: File(picked.path),
        fileName: picked.name,
        targetFolderId: provider.rootFolderId,
      ),
    );
    if (done == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('上传完成，文件已存入 115 网盘根目录')),
      );
    }
  }

  Future<Pan115UploadPick?> _pickUploadFile() async {
    // file_picker 13.1.0：pickFiles 直接回 List<PlatformFile>，
    // 取消选择回空列表。
    final files = await FilePicker.pickFiles(type: FileType.any);
    if (files.isEmpty) return null;
    final file = files.first;
    return (path: file.path ?? '', name: file.name);
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
            if (provider is Pan115Provider && loggedIn) ...[
              const SizedBox(height: 8),
              _pan115InfoBlock(),
            ],
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
                if (loggedIn && provider is Pan115Provider)
                  OutlinedButton(
                    onPressed: () => _startPan115Upload(provider),
                    child: const Text('上传文件到根目录'),
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

  /// 115 账号信息位：只展示接口真拿到的字段；昵称/ID 没返回就写
  /// “未返回”，容量没拉到写“未获取到”，不编数据。两个接口都失败
  /// 时显示失败原因 + 重试。
  Widget _pan115InfoBlock() {
    final account = _pan115Account;
    final space = _pan115Space;
    if (account == null && space == null) {
      if (_pan115InfoError != null) {
        return Row(
          children: [
            Expanded(child: Text('账号信息获取失败：$_pan115InfoError')),
            TextButton(
              onPressed: () => unawaited(_loadPan115Info()),
              child: const Text('重试'),
            ),
          ],
        );
      }
      return const Text('正在读取账号信息…');
    }
    String two(int v) => v.toString().padLeft(2, '0');
    String vipExpireText = '';
    if (account != null && !account.vipForever && account.vipExpireSeconds > 0) {
      final d = DateTime.fromMillisecondsSinceEpoch(
        account.vipExpireSeconds * 1000,
      );
      vipExpireText = '${d.year}-${two(d.month)}-${two(d.day)}';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (account != null && account.avatarUrl.isNotEmpty) ...[
              CircleAvatar(
                radius: 14,
                backgroundImage: NetworkImage(account.avatarUrl),
                onBackgroundImageError: (_, _) {},
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                account == null
                    ? '账号：未获取到'
                    : '昵称：${account.nickname.isEmpty ? '未返回' : account.nickname}',
              ),
            ),
          ],
        ),
        if (account != null) ...[
          Text('账号 ID：${account.userId.isEmpty ? '未返回' : account.userId}'),
          if (account.vipForever)
            const Text('会员：永久会员')
          else if (account.vipExpireSeconds > 0)
            Text('会员到期：$vipExpireText'),
        ],
        Text(
          space == null
              ? '容量：未获取到'
              : '容量：已用 ${_formatBytes(space.usedBytes)} / '
                    '共 ${_formatBytes(space.totalBytes)}'
                    '（剩余 ${_formatBytes(space.remainBytes)}）',
        ),
        if (_pan115InfoLoading) const Text('正在刷新账号信息…'),
      ],
    );
  }
}

/// 字节数显示（账号信息位的容量、上传进度共用）。
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

/// 115 上传进度弹窗：打开即开始上传（流式读本地文件），进度按已发
/// 字节走；成功/失败都如实落字，失败显示 provider 给的中文原因，
/// 其余异常只给干净的通用文案（异常原文可能带请求地址）。
class _Pan115UploadDialog extends StatefulWidget {
  const _Pan115UploadDialog({
    required this.provider,
    required this.client,
    required this.credentials,
    required this.file,
    required this.fileName,
    required this.targetFolderId,
  });

  final Pan115Provider provider;
  final http.Client client;
  final CloudCredentials credentials;
  final File file;
  final String fileName;
  final String targetFolderId;

  @override
  State<_Pan115UploadDialog> createState() => _Pan115UploadDialogState();
}

class _Pan115UploadDialogState extends State<_Pan115UploadDialog> {
  int _sent = 0;
  int _total = 0;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      await widget.provider.uploadLocalFile(
        widget.client,
        widget.credentials,
        file: widget.file,
        fileName: widget.fileName,
        targetFolderId: widget.targetFolderId,
        onProgress: (sent, total) {
          if (!mounted) return;
          setState(() {
            _sent = sent;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() => _done = true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is CloudDriveException ? e.message : '上传失败，请检查网络后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('上传到 115 网盘'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.fileName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          if (_error != null)
            Text(
              '上传失败：$_error',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            )
          else if (_done)
            const Text('上传完成，文件已存入网盘根目录。')
          else ...[
            LinearProgressIndicator(
              value: _total > 0 ? _sent / _total : null,
            ),
            const SizedBox(height: 8),
            Text(
              _total > 0
                  ? '正在上传：${_formatBytes(_sent)} / ${_formatBytes(_total)}'
                  : '正在准备上传（校验文件、判断秒传）…',
            ),
          ],
        ],
      ),
      actions: [
        if (_error != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('关闭'),
          ),
        if (_done)
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('完成'),
          ),
        if (_error == null && !_done)
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('隐藏（上传继续）'),
          ),
      ],
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
