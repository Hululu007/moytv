import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'core_bridge.dart';
import 'hongguo_account.dart';
import 'hongguo_cloud_records.dart';

/// 红果账号会话存储。
///
/// 安全存储口径：pubspec 里没有 flutter_secure_storage 这类安全存储，
/// 按魔蚁现有做法把账号直存 SharedPreferences（与播放控制那路记
/// hongguoDecoderLessons 的做法一致），**未加密存**。
/// 跨重启不断线：登录成功后调 hongguoAccountExportSession 把 Go 核
/// 会话（含 Cookie）存下来；冷启动 load() 时先调
/// hongguoAccountSetSession 把存的会话交回 Go 核，再调
/// hongguoAccountStatus 确认；Cookie 为空时绝不调 SetSession
/// （空 Cookie 会清掉 Go 会话）。登出调 hongguoAccountClearSession
/// + 清 Dart 侧存量，两边都清。
/// 登出只清账号侧（hongguoAccount / hongguoAccountSession /
/// hongguoCloudUploadQueue 三个键），不动本机收藏/历史/搜索记录。

class HongguoPhoneNumber {
  static const List<String> areaCodes = ['+86', '+852', '+853', '+886'];

  static String normalize(String raw) =>
      raw.replaceAll(RegExp(r'[\s\-]'), '');

  /// +86 要求 11 位、1 开头；其他区号要求 5–15 位纯数字。
  static bool isValid(String areaCode, String raw) {
    final phone = normalize(raw);
    if (phone.isEmpty || !RegExp(r'^\d+$').hasMatch(phone)) return false;
    if (areaCode == '+86') {
      return phone.length == 11 && phone.startsWith('1');
    }
    return phone.length >= 5 && phone.length <= 15;
  }

  /// 发码入参的手机号形状：+86 只传 11 位裸号（修仙版
  /// HongguoPhoneNumber.format 同款：大陆号 return digits，不拼区
  /// 号）。旧版这里拼了 "+86 " 前缀，Go 侧 hongguoFormatMobile 收
  /// 到 13 位数字直接报“大陆手机号是 1 开头的 11 位数字”，合法号码
  /// 也被误报；新路 passport 的 mobile 字段同样只认裸号。境外号
  /// 保持 "+区号 号码"。
  static String forBridge(String areaCode, String raw) {
    final phone = normalize(raw);
    if (areaCode == '+86') return phone;
    return '$areaCode $phone';
  }
}

class HongguoAccountStore {
  HongguoAccountStore({required this.repository, required this.preferences}) {
    current = this;
    _queue = HongguoCloudUploadQueue(
      repository: repository,
      preferences: preferences,
      accountId: account?.userId ?? '',
      generation: _generation,
    );
  }

  /// 播放页云端上传调用的唯一入口：取当前 store，未建 store 或
  /// 未登录时返回 null，调用方直接跳过。
  static HongguoAccountStore? current;

  final AppRepository repository;
  final SharedPreferences preferences;

  HongguoAccount? _account;
  HongguoAccount? get account => _account;

  /// Go 核进程内是否持有有效账号会话（hongguoAccountStatus 的
  /// loggedIn）。Dart 侧缓存的账号资料与它可能不一致：资料在、
  /// 会话不在 = 登录已过期，需重新登录。
  bool _sessionLive = false;
  bool get sessionLive => _sessionLive;

  bool get loggedIn => _account != null && _sessionLive;

  /// 账号代际：登出 / 换号时 +1，旧上传队列按此丢弃。
  int _generation = 0;
  int get generation => _generation;

  late HongguoCloudUploadQueue _queue;
  HongguoCloudUploadQueue get cloudQueue => _queue;

  void _rebuildQueue() {
    _queue = HongguoCloudUploadQueue(
      repository: repository,
      preferences: preferences,
      accountId: _account?.userId ?? '',
      generation: _generation,
    );
  }

  /// 启动恢复：先读 Dart 侧缓存的账号资料，再把持久化的会话交回
  /// Go 核（有 Cookie 才调 SetSession，空 Cookie 绝不调），最后
  /// 调 hongguoAccountStatus 确认；状态有会话才算恢复成功，
  /// 否则资料还在、会话标过期，界面显示“登录已过期”。
  Future<void> load() async {
    await ensureHongguoAccountLoaded();
    _account = hongguoAccountNotifier.value;
    final savedSession = await loadHongguoAccountSession();
    if (savedSession != null && savedSession.hasCookie) {
      try {
        await repository.hongguoAccountSetSession(
          savedSession.toBridgeJson(),
        );
      } catch (_) {
        // 交回失败不阻塞启动：下面状态确认会把会话标过期。
      }
    }
    try {
      final status = await repository.hongguoAccountStatus();
      _sessionLive = status['loggedIn'] == true;
      if (_sessionLive) {
        final accountId = status['accountId']?.toString() ?? '';
        final userName = status['userName'] as String? ?? '';
        final idChanged =
            accountId.isNotEmpty &&
            _account != null &&
            _account!.userId != accountId;
        final nameBetter =
            userName.isNotEmpty &&
            _account != null &&
            (_account!.displayName.isEmpty ||
                _account!.displayName == _account!.userId);
        if (_account != null && (idChanged || nameBetter)) {
          _account = HongguoAccount(
            userId: accountId.isNotEmpty ? accountId : _account!.userId,
            displayName: userName.isNotEmpty
                ? userName
                : _account!.displayName,
            maskedPhone: _account!.maskedPhone,
            method: _account!.method,
          );
          await saveHongguoAccount(_account!);
        }
      }
    } catch (_) {
      _sessionLive = false;
    }
    _rebuildQueue();
    if (_sessionLive) unawaited(_queue.drain());
  }

  /// 登录成功后导出 Go 核会话并持久化。导出报未登录时清掉旧存
  /// （旧会话已作废）；导出没 Cookie 时不存空会话；导出失败
  /// （桥接异常）不影响本次登录本身，只记本次未持久化。
  /// 返回导出的会话，无有效会话时返回 null。
  Future<HongguoAccountSession?> exportAndSaveSession() async {
    HongguoAccountSession session;
    bool exportedLoggedIn;
    try {
      final exported = await repository.hongguoAccountExportSession();
      session = HongguoAccountSession.fromJson(exported);
      exportedLoggedIn = exported['loggedIn'] == true;
    } catch (_) {
      return null;
    }
    if (!exportedLoggedIn) {
      // Go 核说没会话：旧存已作废，清掉，免得冷启动反复交回死会话。
      await clearHongguoAccountSession();
      return null;
    }
    if (!session.hasCookie) return null;
    await saveHongguoAccountSession(session);
    return session;
  }

  /// 登录成功后的落盘：Go 核已在进程内持有会话，Dart 侧存账号
  /// 资料（userId / 昵称 / 掩码手机 / 方式），再调
  /// hongguoAccountExportSession 把 Go 核会话（含 Cookie）
  /// 持久化，供冷启动恢复用。扫码与手机号两条路都走这里，
  /// 导出失败不影响本次登录本身。
  Future<HongguoAccount> signInFromBridge({
    required String method,
    String maskedPhone = '',
  }) async {
    final info = await repository.hongguoAccountInfo();
    final userId =
        info['userId']?.toString() ?? info['biz_user_id']?.toString() ?? '';
    final userName = info['userName'] as String? ?? '';
    if (userId.isEmpty) {
      throw AppFailure('登录成功但未拿到账号信息，请重试');
    }
    final account = HongguoAccount(
      userId: userId,
      displayName: userName.isEmpty ? userId : userName,
      maskedPhone: maskedPhone,
      method: method,
    );
    final saved = await _persistAccount(account);
    await exportAndSaveSession();
    return saved;
  }

  /// 手头已有完整会话时用：有 Cookie 才调 hongguoAccountSetSession
  /// 交给 Go 核（空 Cookie 绝不调，会清掉 Go 会话），再落盘。
  /// 正常登录走 signInFromBridge（内部已调导出），此路供恢复/
  /// 测试等手头已有会话的场景用。
  Future<HongguoAccount> signInWithSession({
    required HongguoAccountSession session,
    required HongguoAccount account,
  }) async {
    if (session.hasCookie) {
      await repository.hongguoAccountSetSession(session.toBridgeJson());
    }
    await saveHongguoAccountSession(session);
    return _persistAccount(account);
  }

  Future<HongguoAccount> _persistAccount(HongguoAccount account) async {
    _account = account;
    _sessionLive = true;
    await saveHongguoAccount(account);
    _rebuildQueue();
    return account;
  }

  Future<void> refreshProfile() async {
    final info = await repository.hongguoAccountInfo();
    final userId =
        info['userId']?.toString() ?? info['biz_user_id']?.toString() ?? '';
    if (userId.isEmpty || _account == null) return;
    final userName = info['userName'] as String? ?? '';
    final account = HongguoAccount(
      userId: userId,
      displayName: userName.isEmpty ? _account!.displayName : userName,
      maskedPhone: _account!.maskedPhone,
      method: _account!.method,
    );
    _account = account;
    await saveHongguoAccount(account);
  }

  /// 登出只清账号侧三个键 + 通知 Go 核清会话；本机收藏 / 历史 /
  /// 搜索记录一个键都不动，登出再登入后本机记录还在。
  /// 另清控制器存的凭证键（hongguoAccountCredentials），免得
  /// 控制器登出后还留着旧 Cookie。
  Future<void> signOut() async {
    _generation++;
    try {
      await repository.hongguoAccountClearSession();
    } catch (_) {}
    await clearHongguoAccount();
    await clearHongguoAccountSession();
    await clearHongguoAccountCredentials();
    await _queue.discardAll();
    _account = null;
    _sessionLive = false;
    _rebuildQueue();
  }

  // ------------------------------------------------------------ 扫码登录

  Future<HongguoQrCode> fetchQrCode() async {
    final result = await repository.hongguoLoginQr();
    final code = HongguoQrCode.fromJson(result);
    if (code.imageBase64.isEmpty) {
      throw AppFailure('未拿到二维码，请重试');
    }
    return code;
  }

  /// 轮询一次：true = 已确认登录（Go 侧已跟确认跳转并落会话）。
  Future<bool> pollQrOnce() async {
    final result = await repository.hongguoLoginQrPoll();
    return result['loggedIn'] == true;
  }

  // ------------------------------------------------------------ 手机号登录

  /// 发码：站内路主用，失败回退 App 形态路。
  /// 注意：开发机上绝不 live 调——只做到请求构造与界面流程可测，
  /// 真发码等用户在自己手机上用自己手机号走。
  Future<HongguoSmsSent> sendCode({
    required String areaCode,
    required String phone,
  }) async {
    final bridgePhone = HongguoPhoneNumber.forBridge(areaCode, phone);
    try {
      final result = await repository.hongguoLoginSendCode(bridgePhone);
      return HongguoSmsSent.fromJson(result, 'site');
    } on AppFailure {
      final result = await repository.hongguoLoginAppSendCode(bridgePhone);
      return HongguoSmsSent.fromJson(result, 'app');
    }
  }

  /// 验证码校验：站内路主用，失败回退 App 形态路；成功后拉账号
  /// 信息落盘。发码与校验走同一路不强制：站内发码成功后若站内
  /// 校验失败，仍会试 App 校验（Go 侧两路独立）。
  Future<HongguoAccount> verifyCode({
    required String areaCode,
    required String phone,
    required String code,
    String maskedPhone = '',
  }) async {
    final bridgePhone = HongguoPhoneNumber.forBridge(areaCode, phone);
    final trimmedCode = code.trim();
    if (trimmedCode.isEmpty) throw AppFailure('请输入验证码');
    try {
      final result = await repository.hongguoLoginSms(
        bridgePhone,
        trimmedCode,
      );
      final userId =
          result['userId']?.toString() ??
          result['biz_user_id']?.toString() ??
          '';
      if (userId.isEmpty) throw AppFailure('验证码校验未返回账号');
    } on AppFailure catch (error) {
      final result = await repository.hongguoLoginAppSms(
        bridgePhone,
        trimmedCode,
      );
      if (result['loggedIn'] != true &&
          (result['accountId']?.toString() ?? '').isEmpty) {
        throw AppFailure(error.message);
      }
    }
    return signInFromBridge(method: 'sms', maskedPhone: maskedPhone);
  }

  // ------------------------------------------------------------ 云端进度

  /// 播放页进度保存时调：未登录直接跳过；已登录入队并试发。
  Future<void> enqueueCloudProgress({
    required String seriesId,
    required String itemId,
    required int episodeIndex,
    required int episodeCount,
    required double positionSeconds,
    required double totalSeconds,
  }) async {
    if (!loggedIn || _account == null) return;
    await _queue.enqueue(
      HongguoCloudProgressItem(
        accountId: _account!.userId,
        seriesId: seriesId,
        itemId: itemId,
        episodeIndex: episodeIndex,
        episodeCount: episodeCount,
        progressMs: (positionSeconds * 1000).round(),
        totalMs: (totalSeconds * 1000).round(),
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 退出播放 / 切集时补发一次队里攒着的进度。
  Future<void> flushCloudProgress() async {
    if (!loggedIn) return;
    await _queue.drain();
  }
}

/// 调试用：把一段 JSON 文本解析成账号资料（测试夹具走这条）。
HongguoAccount hongguoAccountFromBridgeJson(Map<String, dynamic> json) =>
    HongguoAccount(
      userId:
          json['userId']?.toString() ??
          json['biz_user_id']?.toString() ??
          '',
      displayName: json['userName'] as String? ?? '',
      maskedPhone: json['maskedMobile'] as String? ?? '',
      method: json['method'] as String? ?? '',
    );

String hongguoAccountSessionDebugJson(HongguoAccountSession session) =>
    jsonEncode({
      'accountId': session.accountId,
      'deviceId': session.deviceId,
      'installId': session.installId,
      'cookie': session.maskedCookie,
    });
