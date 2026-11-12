import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core_bridge.dart';
import 'hongguo_account.dart';
import 'hongguo_account_store.dart';
import 'hongguo_cloud_records.dart';
import 'local_store.dart';

/// 红果登录页：手机号登录是主路（用户只有一台手机，扫码要第二台
/// 设备才能扫），扫码登录是备用，两个都要有、都要能用。
/// 发码 live 验要等用户在自己手机上用自己手机号走，开发机上不调。
class HongguoLoginPage extends StatefulWidget {
  const HongguoLoginPage({
    super.key,
    required this.repository,
    required this.accountStore,
    this.accountController,
  });

  final AppRepository repository;
  final HongguoAccountStore accountStore;

  /// 新路控制器（可空）：有则发码/验码优先走控制器 transport，
  /// 失败回退旧 store 路；没有则全程走旧路。
  final HongguoAccountController? accountController;

  @override
  State<HongguoLoginPage> createState() => _HongguoLoginPageState();
}

class _HongguoLoginPageState extends State<HongguoLoginPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  String _areaCode = '+86';
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  bool _sending = false;
  bool _verifying = false;
  int _retryIn = 0;
  Timer? _retryTimer;
  String? _sentRoute;
  String? _error;

  HongguoQrCode? _qr;
  int _qrLeft = 0;
  Timer? _qrTimer;
  Timer? _qrPollTimer;
  bool _qrLoading = false;
  bool _qrPolling = false;
  String? _qrError;

  @override
  void dispose() {
    _tabs.dispose();
    _phoneController.dispose();
    _codeController.dispose();
    _retryTimer?.cancel();
    _qrTimer?.cancel();
    _qrPollTimer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------ 手机号

  void _startCountdown(int seconds) {
    _retryTimer?.cancel();
    setState(() => _retryIn = seconds < 0 ? 0 : seconds);
    if (_retryIn <= 0) return;
    _retryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_retryIn <= 1) {
        timer.cancel();
        setState(() => _retryIn = 0);
      } else {
        setState(() => _retryIn--);
      }
    });
  }

  Future<void> _sendCode() async {
    final phone = HongguoPhoneNumber.normalize(_phoneController.text);
    if (!HongguoPhoneNumber.isValid(_areaCode, phone)) {
      setState(() => _error = '手机号格式不对，请检查区号与号码');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    // 新路优先：控制器 transport 发码。错误码 7 是平台限流，只显示
    // 限流文案并进 60 秒冷却（按钮变“60 秒后重发”禁用，冷却内再点
    // 不发请求），不回退旧路（回退会再撞限流）；其他失败回退旧路。
    final controller = widget.accountController;
    if (controller != null) {
      try {
        final sent = await controller.transportSendSmsCode(
          HongguoPhoneNumber.forBridge(_areaCode, phone),
        );
        if (!mounted) return;
        setState(() {
          _sending = false;
          _sentRoute = sent.route == 'app' ? 'App 形态' : '站内';
        });
        _startCountdown(sent.retrySeconds);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('验证码已发送到 ${sent.maskedMobile}（${sent.route}）'),
          ),
        );
        return;
      } on HongguoLoginFailure catch (error) {
        if (!mounted) return;
        if (error.errorCode == 7) {
          setState(() {
            _sending = false;
            _error = error.message;
          });
          _startCountdown(60);
          return;
        }
        // 非限流失败：往下走旧路。
      } catch (_) {
        // transport 未接通（如 Go 新动作未落地）：往下走旧路。
      }
      if (!mounted) return;
    }
    try {
      final sent = await widget.accountStore.sendCode(
        areaCode: _areaCode,
        phone: phone,
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sentRoute = sent.route == 'app' ? 'App 形态' : '站内';
      });
      _startCountdown(sent.retrySeconds);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('验证码已发送到 ${sent.maskedMobile}（${sent.route}）'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _verifyCode() async {
    final phone = HongguoPhoneNumber.normalize(_phoneController.text);
    if (!HongguoPhoneNumber.isValid(_areaCode, phone)) {
      setState(() => _error = '手机号格式不对，请检查区号与号码');
      return;
    }
    if (_codeController.text.trim().isEmpty) {
      setState(() => _error = '请输入验证码');
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    // 新路优先：控制器验码（verify→资料→存凭证+账号→刷新云端）；
    // 失败回退旧 store 路。但新路验码成功后资料拉取失败时（100103
    // 那类），验证码已被消费：先重试已验会话的核对，不回退旧路重验。
    final controller = widget.accountController;
    if (controller != null) {
      try {
        final account = await controller.loginWithSms(
          mobile: HongguoPhoneNumber.forBridge(_areaCode, phone),
          code: _codeController.text,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已登录：${account.displayName}')),
        );
        Navigator.of(context).pop(account);
        return;
      } catch (_) {
        if (!mounted) return;
        // 验码已换到会话、失败在后面的资料核对时（100103 那类），
        // 验证码已被消费：直接重试核对，不回退旧路重验（重验必败）。
        if (controller.hasPendingVerifiedLogin) {
          try {
            final account = await controller.retryPendingVerifiedLogin();
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已登录：${account.displayName}')),
            );
            Navigator.of(context).pop(account);
            return;
          } catch (error) {
            if (!mounted) return;
            setState(() {
              _verifying = false;
              _error = error.toString();
            });
            return;
          }
        }
      }
    }
    try {
      final account = await widget.accountStore.verifyCode(
        areaCode: _areaCode,
        phone: phone,
        code: _codeController.text,
        maskedPhone: HongguoAccount.maskPhone(phone),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已登录：${account.displayName}')),
      );
      Navigator.of(context).pop(account);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _error = error.toString();
      });
    }
  }

  // ------------------------------------------------------------ 扫码

  Future<void> _fetchQr() async {
    setState(() {
      _qrLoading = true;
      _qrError = null;
    });
    try {
      final qr = await widget.accountStore.fetchQrCode();
      if (!mounted) return;
      setState(() {
        _qr = qr;
        _qrLeft = qr.expiresSeconds;
        _qrLoading = false;
        _qrPolling = true;
      });
      _startQrTimers();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _qrLoading = false;
        _qrError = error.toString();
      });
    }
  }

  void _startQrTimers() {
    _qrTimer?.cancel();
    _qrPollTimer?.cancel();
    _qrTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_qrLeft <= 1) {
        timer.cancel();
        _qrPollTimer?.cancel();
        setState(() {
          _qrLeft = 0;
          _qrPolling = false;
          _qrError = '二维码已过期，请重新获取';
        });
      } else {
        setState(() => _qrLeft--);
      }
    });
    _qrPollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted || !_qrPolling) return;
      try {
        final done = await widget.accountStore.pollQrOnce();
        if (!mounted) return;
        if (done) {
          _qrTimer?.cancel();
          _qrPollTimer?.cancel();
          setState(() => _qrPolling = false);
          final account = await widget.accountStore.signInFromBridge(
            method: 'qr',
          );
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('扫码登录成功：${account.displayName}')),
          );
          Navigator.of(context).pop(account);
        }
      } catch (error) {
        if (!mounted) return;
        setState(() => _qrError = error.toString());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('红果账号登录'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '手机号登录'),
            Tab(text: '扫码登录'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_phoneTab(), _qrTab()],
      ),
    );
  }

  Widget _phoneTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('手机号登录是日常主路，扫码是备用。'),
        const SizedBox(height: 16),
        Row(
          children: [
            DropdownButton<String>(
              value: _areaCode,
              items: [
                for (final code in HongguoPhoneNumber.areaCodes)
                  DropdownMenuItem(value: code, child: Text(code)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _areaCode = value);
              },
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: '手机号',
                  hintText: '11 位手机号',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '验证码'),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: _sending || _retryIn > 0 ? null : _sendCode,
              child: Text(
                _sending
                    ? '发送中…'
                    : _retryIn > 0
                    ? '$_retryIn 秒后重发'
                    : '发验证码',
              ),
            ),
          ],
        ),
        if (_sentRoute != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('验证码经$_sentRoute通道发送'),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _verifying ? null : _verifyCode,
          child: Text(_verifying ? '校验中…' : '登录'),
        ),
        const SizedBox(height: 16),
        const Text('验证码只发到你自己输入的手机号，不会在开发机上代发。'),
      ],
    );
  }

  Widget _qrTab() {
    final qr = _qr;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('用另一台手机打开红果扫一扫。60 秒内有效，超时请重新获取。'),
        const SizedBox(height: 16),
        if (_qrLoading)
          const Center(child: CircularProgressIndicator())
        else if (qr != null && _qrLeft > 0)
          Column(
            children: [
              Image.memory(
                base64Decode(qr.imageBase64),
                width: 280,
                height: 280,
              ),
              const SizedBox(height: 12),
              Text('剩余 $_qrLeft 秒${_qrPolling ? ' · 等待扫码…' : ''}'),
            ],
          )
        else
          const Text('还没有二维码'),
        if (_qrError != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _qrError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _qrLoading ? null : _fetchQr,
          child: Text(qr == null ? '获取二维码' : '重新获取二维码'),
        ),
      ],
    );
  }
}

/// 红果账号页：资料 + 登录态 + 本机/账号记录分开展示 + 登出。
/// 入口在设置页“设备”组，与“设备注册档案”并列。
class HongguoAccountPage extends StatefulWidget {
  const HongguoAccountPage({
    super.key,
    required this.repository,
    required this.store,
  });

  final AppRepository repository;
  final LocalStore store;

  @override
  State<HongguoAccountPage> createState() => _HongguoAccountPageState();
}

class _HongguoAccountPageState extends State<HongguoAccountPage> {
  HongguoAccountStore? _accountStore;
  HongguoAccountController? _accountController;
  bool _loading = true;
  bool _signingOut = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _openStore();
  }

  Future<void> _openStore() async {
    final preferences = await SharedPreferences.getInstance();
    final accountStore = HongguoAccountStore(
      repository: widget.repository,
      preferences: preferences,
    );
    final accountController = HongguoAccountController.withTransport(
      GoHongguoAccountTransport(widget.repository),
      repository: widget.repository,
    );
    try {
      await accountStore.load();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
    try {
      await accountController.load();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _accountStore = accountStore;
      _accountController = accountController;
      _loading = false;
    });
  }

  Future<void> _openLogin() async {
    final accountStore = _accountStore;
    if (accountStore == null) return;
    final result = await Navigator.of(context).push<HongguoAccount>(
      MaterialPageRoute<HongguoAccount>(
        builder: (_) => HongguoLoginPage(
          repository: widget.repository,
          accountStore: accountStore,
          accountController: _accountController,
        ),
      ),
    );
    if (result != null && mounted) {
      // 控制器登录后 store 侧还是旧态：重载一次，让账号页读到新账号。
      try {
        await accountStore.load();
      } catch (_) {}
      if (mounted) setState(() {});
    }
  }

  Future<void> _signOut() async {
    final accountStore = _accountStore;
    if (accountStore == null) return;
    setState(() => _signingOut = true);
    await accountStore.signOut();
    await _accountController?.logout();
    if (!mounted) return;
    setState(() => _signingOut = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已退出登录，本机记录不受影响')));
  }

  @override
  Widget build(BuildContext context) {
    final accountStore = _accountStore;
    if (_loading || accountStore == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('红果账号')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final account = accountStore.account;
    final loggedIn = accountStore.loggedIn;
    return Scaffold(
      appBar: AppBar(title: const Text('红果账号')),
      body: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(
              account == null
                  ? '未登录'
                  : loggedIn
                  ? account.displayName
                  : '${account.displayName}（登录已过期）',
            ),
            subtitle: Text(
              account == null
                  ? '登录后同步账号收藏、云端历史与预约'
                  : loggedIn
                  ? '${account.methodLabel}${account.maskedPhone.isEmpty ? '' : ' · ${account.maskedPhone}'}'
                  : '会话已失效，请重新登录；本机记录还在',
            ),
            trailing: account == null
                ? FilledButton(
                    onPressed: _openLogin,
                    child: const Text('去登录'),
                  )
                : loggedIn
                ? OutlinedButton(
                    onPressed: _signingOut ? null : _signOut,
                    child: Text(_signingOut ? '退出中…' : '退出登录'),
                  )
                : FilledButton(
                    onPressed: _openLogin,
                    child: const Text('重新登录'),
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          const Divider(),
          Expanded(
            child: HongguoCloudRecordsView(
              repository: widget.repository,
              accountStore: accountStore,
              store: widget.store,
              onOpenDrama: (drama) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已选：${drama.title}')),
                );
              },
              onResumeCloud: (item) {
                final decision = decideHongguoResume(
                  cloud: item,
                  preferCloud: true,
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '云端续播：第 ${decision.episodeIndex + 1} 集，'
                      '${decision.positionSeconds.round()} 秒',
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
