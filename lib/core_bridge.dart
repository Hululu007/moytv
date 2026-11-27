import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:crypto/crypto.dart';

import 'models.dart';
import 'jar_bridge.dart';
import 'tg_catalog_cache.dart';
import 'tg_list_postprocess.dart';
import 'jar_haijiao_takeover.dart';
import 'jar_youtube_takeover.dart';
import 'danmaku_models.dart';
import 'hongguo_comment.dart';
import 'import_file_store.dart';
import 'idj_contract.dart';
import 'idj_plugin_store.dart';
import 'js_lazy_fetch.dart';
import 'py_bridge.dart';
import 'py_lazy_fetch.dart';
import 'py_contract.dart';
import 'whos_fallback.dart';
import 'whos_local_library.dart';
import 'background_downloads.dart';
import 'local_store.dart';
import 'site_health.dart';
import 'playback_parse.dart';
import 'app_build.dart';
import 'source_status.dart';
import 'ranking_models.dart';
import 'cover_decoder.dart';
import 'cloud_drive/cloud_115_offline.dart';
import 'cloud_drive/cloud_credential_store.dart';
import 'cloud_drive/cloud_drive_engine.dart';
import 'catalog_updates.dart';
import 'download_collections.dart';
import 'resource_settings.dart';
import 'source_fanout.dart';

typedef _NativeRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

String _nativeRequest(String body) {
  final DynamicLibrary library;
  if (Platform.isAndroid) {
    library = DynamicLibrary.open('libmoyi_core.so');
  } else if (Platform.isWindows) {
    library = DynamicLibrary.open(
      path.join(path.dirname(Platform.resolvedExecutable), 'moyi_core.dll'),
    );
  } else if (Platform.isIOS) {
    library = DynamicLibrary.process();
  } else if (Platform.isMacOS) {
    // macOS 构建将 libmoyi_core.dylib 嵌入 Contents/Frameworks，
    // 通过 @executable_path/Frameworks 的 rpath 解析加载。
    library = DynamicLibrary.open('libmoyi_core.dylib');
  } else {
    throw UnsupportedError('当前首版支持 Android 手机、Windows 电脑和 macOS');
  }
  final request = library.lookupFunction<_NativeRequest, _DartRequest>(
    'MoyiRequest',
  );
  final free = library.lookupFunction<_NativeFree, _DartFree>('MoyiFree');
  final input = body.toNativeUtf8();
  Pointer<Utf8> output = nullptr;
  try {
    output = request(input);
    if (output == nullptr) {
      throw StateError('本地核心没有返回结果');
    }
    return output.toDartString();
  } finally {
    malloc.free(input);
    if (output != nullptr) {
      free(output);
    }
  }
}

class AppFailure implements Exception {
  AppFailure(this.message, {this.code = ''});
  final String message;
  final String code;
  @override
  String toString() => message;
}

abstract class AppRepository {
  Future<ResourceSettings> resourceSettings() async => const ResourceSettings();
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async => throw AppFailure('当前环境不支持资源设置');

  Future<Map<String, dynamic>> crackConfigSet(String content) async => {};
  Future<Map<String, dynamic>> hongguoDeviceStatus() async =>
      throw AppFailure('当前环境不支持设备注册档案');
  Future<Map<String, dynamic>> hongguoDeviceRegister() async =>
      throw AppFailure('当前环境不支持设备注册档案');
  Future<Map<String, dynamic>> hongguoDeviceReregister() async =>
      throw AppFailure('当前环境不支持设备注册档案');
  Future<Map<String, dynamic>> hongguoDeviceRefresh() async =>
      throw AppFailure('当前环境不支持设备注册档案');

  /// 红果账号新路（对照 tree_104 的 12 个账号动作）：
  /// 这里只新增魔蚁确实缺失的 6 个——发码/验码/扫码取码/轮询/
  /// 确认/资料。另 6 个（收藏/写收藏/历史/进度上传/预约列表/
  /// 写预约）魔蚁已有同名会话制方法（Go 核进程内持有会话，不用
  /// 传 Cookie），transport 直接复用，不另建同名方法（Dart 无重载）。
  /// 入参走魔蚁平铺字段约定（phone/code/cookie），不套 tree_104
  /// 的 content 装 JSON 字符串；Go 侧读 nativeInput 的
  /// Phone/Code/Cookie 字段。
  Future<Map<String, dynamic>> hongguoAccountSendSms(String mobile) async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountVerifySms(
    String mobile,
    String code,
  ) async => throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountQrCode() async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountQrPoll() async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountQrConfirm() async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountProfile(String cookie) async =>
      throw AppFailure('当前环境不支持红果账号');

  /// 红果服务端多维筛选（POST landpage/v）：content 为筛选请求体 JSON，
  /// cursor 为游标 JSON（{"offset":N,"session":"..."}），空表示首页。
  /// 返回 {items, groups, hasMore, nextCursor}；groups 只在首页返回。
  Future<Map<String, dynamic>> hongguoAccountFilter({
    required String content,
    String cursor = '',
  }) async => throw AppFailure('当前环境不支持红果筛选');
  Future<Map<String, dynamic>> hongguoAccountStatus() async =>
      throw AppFailure('当前环境不支持红果账号');

  /// 导出 Go 核当前账号会话给 Dart 持久化（跨重启恢复用）。
  /// 返回 {loggedIn, accountCookie, deviceId, installId, accountId,
  /// userName, expiresAtMs, cookieSource}；expiresAtMs 为 0 表示
  /// 服务端没给过期时间；Cookie 只导出，不记日志。
  Future<Map<String, dynamic>> hongguoAccountExportSession() async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountSetSession(
    Map<String, dynamic> session,
  ) async => throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountClearSession() async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoLoginQr() async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoLoginQrPoll() async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountInfo() async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoLoginSendCode(String phone) async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoLoginSms(
    String phone,
    String code,
  ) async => throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoLoginAppSendCode(String phone) async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoLoginAppSms(
    String phone,
    String code,
  ) async => throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountFavorites() async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountSetFavorite(
    String seriesId,
    bool add,
  ) async => throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountHistory() async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountUploadProgress(
    Map<String, dynamic> progress,
  ) async => throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountReservations(bool online) async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountReserve(String seriesId) async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountLoginRewardInfo() async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountClaimDailyCoins() async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<Map<String, dynamic>> hongguoAccountRelated(String seriesId) async =>
      throw AppFailure('当前环境不支持红果账号');
  Future<dynamic> legadoRun(
    String sourceJson,
    String action,
    String input,
  ) async => throw AppFailure('当前环境不支持开源阅读');
  Future<Map<String, dynamic>> crackConfigSummary() async => {};
  final catalogUpdates = CatalogUpdates();
  Future<void> cancelPreload() async {}
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
    int route = 0,
    bool adBlock = true,
  }) async => null;
  Future<void> cancelDanmaku() async {}
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async => throw AppFailure('当前环境不支持弹幕');
  Future<DanmakuPage> danmakuById(
    String seriesId,
    String videoId, {
    required int startMs,
    required int durationMs,
  }) async => throw AppFailure('当前环境不支持弹幕');
  Future<HongguoCommentPage> comments(
    PlaybackPlan plan, {
    String cursor = '',
  }) async => throw AppFailure('当前环境不支持评论');
  Future<HongguoCommentPage> commentsBySeries(
    String seriesId, {
    String cursor = '',
  }) async => throw AppFailure('当前环境不支持评论');
  Future<void> cancelComments() async {}
  Future<void> cancelCatalog() async {}
  Future<void> cancelSuggestions() async {}
  Future<void> cancelRecommendations() async {}
  Future<Drama?> supplementMetadata(Drama drama) async => null;
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持红果推荐');
  Future<List<RankingBoard>> rankingBoards() async => const [];
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持榜单');
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory.all];
  bool get supportsSourceManagement => false;
  Future<SourceStatus> sourceStatus(String source) async =>
      SourceStatus.fromJson({'source': source});
  Future<SourceStatus> startSourceJob(
    String source,
    String operation, {
    Drama? drama,
  }) async => throw AppFailure('当前环境不支持站源管理');
  Future<SourceStatus> cancelSourceJob(String source) async =>
      throw AppFailure('当前环境不支持站源管理');
  Future<List<CustomSourceSite>> customSources() async => const [];
  Future<CustomSourceSite> addCustomSource({
    required String name,
    required String base,
    String rule = '',
    String kind = '',
  }) async => throw AppFailure('当前环境不支持自定义源');
  Future<CustomSourceSite> updateCustomSource(
    String id, {
    required String name,
    required String base,
    String rule = '',
    String kind = '',
  }) async => throw AppFailure('当前环境不支持自定义源');
  Future<void> removeCustomSource(String id) async =>
      throw AppFailure('当前环境不支持自定义源');
  Future<Map<String, String>> validateCustomRule({
    required String name,
    required String base,
    String rule = '',
    String kind = '',
  }) async => throw AppFailure('当前环境不支持自定义源');
  Future<List<Map<String, String>>> previewCustomRule({
    required String name,
    required String base,
    String rule = '',
    String kind = '',
  }) async => throw AppFailure('当前环境不支持自定义源');

  /// 导出全部自定义源为 JSON 文本（含 XBPQ 规则原文）。
  Future<String> exportCustomSources() async => throw AppFailure('当前环境不支持自定义源');

  /// 导入自定义源文本，返回 {added, updated, skipped, failed} 计数与原因。
  /// content 既可以是本地 JSON/TXT 文本，也可以是一行远程配置地址，
  /// 原生核心会自动识别并抓取。
  Future<Map<String, dynamic>> importCustomSources(String content) async =>
      throw AppFailure('当前环境不支持自定义源');

  /// 恢复默认：删除全部自定义源，仅保留内置源。返回删除数量。
  Future<int> resetCustomSources() async => throw AppFailure('当前环境不支持自定义源');
  Future<List<String>> suggestions(String query) async => const [];
  Future<Map<String, dynamic>> storage() async => {};
  Future<String> downloadDirectory() async =>
      (await storage())['directory'] as String? ?? '';
  Future<String> downloadRemuxDirectory(String jobId) async =>
      throw AppFailure('当前环境不支持重混');
  Future<void> moveDownloads(String directory) async =>
      throw AppFailure('当前环境不支持迁移');
  Future<int> workLease(String id, String command) async => 0;
  bool get supportsDownloads => false;
  Future<List<DownloadJob>> downloads() async => [];
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async => throw AppFailure('当前环境不支持下载');
  Future<void> controlDownloads(String command, {String id = ''}) async {}
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids, {
    Map<String, String> expectedVersions = const {},
  }) async {
    if (expectedVersions.isNotEmpty) throw AppFailure('当前环境不支持校验后清理原分集');
    final completed = <String>[], failures = <String, String>{};
    for (final id in ids.toSet()) {
      try {
        await controlDownloads(command, id: id);
        completed.add(id);
      } catch (error) {
        failures[id] = error.toString();
      }
    }
    return DownloadBatchResult(completed: completed, failures: failures);
  }

  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) => enqueueDownloads(detail, episodes, quality: quality);
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async =>
      null;
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) =>
      resolve(drama, episode, quality: quality, route: route, adBlock: adBlock);
  Future<void> initialize();
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  });
  // 跨源聚合搜索：并发打所有给定站源，返回按标题/年份/集数归一去重后的结果。
  Future<CatalogPage> searchAcross(List<String> sources, String query);

  /// 流式跨源搜索（O1 渐进显示用）：与 [searchAcross] 同款扇出
  /// （同站源过滤、同腿划分、同单站预算），但每站回结果立即调
  /// [onSite]（按完成顺序），不等全部站回完；返回的 Future 在
  /// 全部站结束后完成，供调用方收尾。空结果的站不回调。
  ///
  /// [shouldStop]（O2 真取消）：扇出每取新站前检查，返回 true 时
  /// 不再发起后续站，已回调的结果保留，Future 正常完成。
  /// MethodChannel 在途调用与 Go 腿调用本身无法撤回——取消只
  /// 做到 Dart 侧不再等待、不再发起后续站、结果不写回。
  ///
  /// 默认实现走批回 [searchAcross] 再按站拆开回调（供测试假仓
  /// 与未覆写的实现用，到达顺序是整批、不流式，但结果集合一致）；
  /// NativeRepository 覆写为真流式。
  Future<void> searchAcrossProgressive(
    List<String> sources,
    String query, {
    required void Function(String source, List<Drama> items) onSite,
    bool Function()? shouldStop,
  }) async {
    if (shouldStop != null && shouldStop()) return;
    final page = await searchAcross(sources, query);
    _emitSiteItems(page.items, onSite, shouldStop);
  }

  /// 搜索结果增量轮询（西瓜播放器推荐用）。guoapp3 核心无此通道，默认返回空页，
  /// 调用方以首轮完整结果为准。
  Future<CatalogPage> searchProgress(String source, String query) async =>
      CatalogPage(const []);
  Future<CatalogPage> cached(String source, {String category = ''});
  Future<String> cover(Drama drama, {bool force = false});
  Future<DramaDetail> detail(Drama drama);
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  });
  Future<PlaybackPlan> resolveParse(
    PlaybackPlan plan,
    List<ParseInterface> apis,
  ) async => throw AppFailure('当前环境不支持解析接口播放');
  Future<PlaybackPlan> fallback(PlaybackPlan current);
  Future<PlaybackPlan> selectRoute(PlaybackPlan current, int route) =>
      throw AppFailure('当前环境不支持切换播放线路');
  Future<void> cancelPlayback();
  Future<void> release(String session);
}

/// 红果小说/听书分类（对照 Go hongguoIsBookCategory）：novel/audio，
/// 或 bcat 开头的书分类；视频分类（short_play/comic_series/ai_series
/// 等）不在此列。bcat 后缀无法在 Dart 侧核对书名，保守按书分类处理。
bool _isHongguoBookCategory(String category) =>
    category == 'novel' || category == 'audio' || category.startsWith('bcat');

/// 红果服务端多维筛选（landpage/v）纯逻辑：筛选项拼请求体、游标续页。
/// 只借对照仓 DiscoveryFilters.kt 的字段名，不抄常量与设备值。
/// 会话只放内存（NativeRepository 的字段），不落盘。

/// 服务端多维筛选 8 组键（对照仓 DiscoveryFilters.labels）。
/// 魔蚁现有 4 组 → 服务端键：cat→genre、topic→category_dim_theme、
/// background→category_dim_epoch、setting→category_dim_role；
/// 其余 4 组（sort/gender/online_time/creation_status）直接用服务端键。
const hongguoDiscoveryLabels = <String, String>{
  'genre': '类型',
  'category_dim_theme': '主题',
  'category_dim_role': '设定',
  'category_dim_epoch': '背景',
  'sort': '排序',
  'gender': '受众',
  'online_time': '时间',
  'creation_status': '状态',
};

/// 魔蚁旧筛选键 → 服务端键。
const hongguoDiscoveryLegacyKeyToServer = <String, String>{
  'cat': 'genre',
  'topic': 'category_dim_theme',
  'background': 'category_dim_epoch',
  'setting': 'category_dim_role',
};

/// 服务端键 → 魔蚁旧筛选键（仅 4 组有旧键；其余 4 组无旧键）。
const hongguoDiscoveryServerKeyToLegacy = <String, String>{
  'genre': 'cat',
  'category_dim_theme': 'topic',
  'category_dim_epoch': 'background',
  'category_dim_role': 'setting',
};

/// 服务端多维筛选条件：服务端键 → 选项 id（单选，每组最多一个）。
class HongguoDiscoverySelection {
  HongguoDiscoverySelection([Map<String, String>? values])
    : _values = Map<String, String>.unmodifiable(values ?? const {});

  final Map<String, String> _values;

  Map<String, String> get values => Map<String, String>.of(_values);

  bool get isEmpty => _values.values.every((value) => value.isEmpty);

  /// 选一项：空 id 即清除该组；切类型（genre）时丢弃旧类型的条件
  ///（对照 DiscoverySelection.choose：类型不同，维度体系不同）。
  HongguoDiscoverySelection choose(String type, String id) {
    if (!hongguoDiscoveryLabels.containsKey(type)) return this;
    final next = type == 'genre'
        ? <String, String>{}
        : Map<String, String>.of(_values);
    if (id.isEmpty) {
      next.remove(type);
    } else {
      next[type] = id;
    }
    return HongguoDiscoverySelection(next);
  }

  /// 拼 landpage 请求体（对照 DiscoverySelection.request）。
  /// select_items 8 组键齐全，未选的组发空数组；游标为空即首页。
  Map<String, dynamic> requestBody({HongguoDiscoveryCursor? cursor}) {
    final selected = <String, dynamic>{};
    for (final key in hongguoDiscoveryLabels.keys) {
      final value = _values[key];
      selected[key] = value == null || value.isEmpty
          ? <String>[]
          : <String>[value];
    }
    return <String, dynamic>{
      'offset': cursor?.offset ?? 0,
      'limit': 24,
      'need_selector_panel': cursor == null,
      'select_items': selected,
      'session_id': cursor?.session ?? '',
      'req_type': cursor == null ? 'default' : 'only_content',
      'client_req_type': 3,
      'filter_ids': '',
      'req_scene': reqScene,
    };
  }

  /// genre 为漫剧/AI 剧类型时走对应场景，否则默认场景。
  String get reqScene {
    final genre = _values['genre'];
    return genre == 'comic_series' || genre == 'ai_series' ? genre! : 'default';
  }

  /// 会话指纹：筛选条件排好序拼起来，换筛选项即换会话。
  String get fingerprint {
    final parts =
        _values.entries
            .where((entry) => entry.value.isNotEmpty)
            .map((entry) => '${entry.key}=${entry.value}')
            .toList()
          ..sort();
    return parts.join(',');
  }
}

/// 服务端筛选游标（Go 桥接的 nextCursor 原样透传）。
class HongguoDiscoveryCursor {
  const HongguoDiscoveryCursor({required this.offset, required this.session});

  final int offset;
  final String session;

  Map<String, dynamic> toJson() => {'offset': offset, 'session': session};

  factory HongguoDiscoveryCursor.fromJson(Map<String, dynamic> json) =>
      HongguoDiscoveryCursor(
        offset: intValue(json['offset']),
        session: json['session'] as String? ?? '',
      );
}

/// Go 桥接 hongguoAccountFilter 一页返回的解析结果：
/// {items, groups, hasMore, nextCursor}。
class HongguoDiscoveryFilterPage {
  const HongguoDiscoveryFilterPage({
    required this.items,
    required this.groups,
    required this.hasMore,
    required this.nextCursor,
    required this.nameToId,
  });

  final List<Drama> items;

  /// 界面可直接用的筛选组：旧 4 组沿用旧键（cat/topic/background/
  /// setting），选项 id 用展示名（调用方已选的中文值才能继续命中）；
  /// 新 4 组用服务端键与服务端 id。
  final List<CatalogFilterGroup> groups;
  final bool hasMore;
  final HongguoDiscoveryCursor? nextCursor;

  /// 展示名 → 服务端选项 id（按服务端键分），供旧 4 组中文值翻译。
  final Map<String, Map<String, String>> nameToId;

  factory HongguoDiscoveryFilterPage.fromBridgeJson(Map<String, dynamic> json) {
    final items = <Drama>[];
    for (final row in json['items'] as List? ?? const []) {
      if (row is! Map) continue;
      final item = Map<String, dynamic>.from(row);
      final seriesId = item['seriesId']?.toString() ?? '';
      if (seriesId.isEmpty) continue;
      final badge = item['badge']?.toString() ?? '';
      final episodeCount =
          int.tryParse(RegExp(r'(\d+)').firstMatch(badge)?.group(1) ?? '') ?? 0;
      final tags = (item['tags']?.toString() ?? '')
          .split(' · ')
          .map((tag) => tag.trim())
          .where((tag) => tag.isNotEmpty)
          .toList();
      items.add(
        Drama(
          id: 'hongguo:$seriesId',
          source: 'hongguo',
          title: item['title']?.toString() ?? '短剧',
          description: item['desc']?.toString() ?? '',
          cover: item['cover']?.toString() ?? '',
          episodes: episodeCount,
          tags: tags,
        ),
      );
    }
    final groups = <CatalogFilterGroup>[];
    final nameToId = <String, Map<String, String>>{};
    for (final row in json['groups'] as List? ?? const []) {
      if (row is! Map) continue;
      final group = Map<String, dynamic>.from(row);
      final type = group['type']?.toString() ?? '';
      if (!hongguoDiscoveryLabels.containsKey(type)) continue;
      final label = group['label']?.toString() ?? hongguoDiscoveryLabels[type]!;
      final legacyKey = hongguoDiscoveryServerKeyToLegacy[type];
      final options = <CatalogFilterOption>[];
      final index = <String, String>{};
      for (final optionRow in group['options'] as List? ?? const []) {
        if (optionRow is! Map) continue;
        final option = Map<String, dynamic>.from(optionRow);
        final id = option['id']?.toString() ?? '';
        final name = option['name']?.toString() ?? '';
        if (id.isEmpty || name.isEmpty) continue;
        index[name] = id;
        options.add(CatalogFilterOption(legacyKey == null ? id : name, name));
      }
      if (options.isEmpty) continue;
      nameToId[type] = index;
      groups.add(CatalogFilterGroup(legacyKey ?? type, label, options));
    }
    final hasMore = json['hasMore'] == true;
    HongguoDiscoveryCursor? nextCursor;
    if (hasMore && json['nextCursor'] is Map) {
      final cursor = HongguoDiscoveryCursor.fromJson(
        Map<String, dynamic>.from(json['nextCursor'] as Map),
      );
      if (cursor.offset > 0 && cursor.session.isNotEmpty) {
        nextCursor = cursor;
      }
    }
    return HongguoDiscoveryFilterPage(
      items: items,
      groups: groups,
      // 服务端说有更多却没给可用游标时按无更多处理，否则续页无从发。
      hasMore: hasMore && nextCursor != null,
      nextCursor: nextCursor,
      nameToId: nameToId,
    );
  }
}

/// 把调用方 filters（旧键中文值 / 服务端键 id）归一成服务端 selection。
/// 旧键按展示名查 [nameToId] 翻译成服务端 id；查不到的丢弃该组，
/// 绝不把中文值当 id 发给服务端（服务端只要 selector_item_id）。
/// 漫剧/AI 剧分类无显式类型选择时，用分类定 genre，避免筛出真人剧。
HongguoDiscoverySelection hongguoNormalizeFilters(
  Map<String, String> filters,
  Map<String, Map<String, String>> nameToId, {
  String category = '',
}) {
  final values = <String, String>{};
  for (final entry in filters.entries) {
    final value = entry.value;
    if (value.isEmpty) continue;
    final serverKey = hongguoDiscoveryLegacyKeyToServer[entry.key];
    if (serverKey != null) {
      final id = nameToId[serverKey]?[value];
      if (id != null && id.isNotEmpty) values[serverKey] = id;
      continue;
    }
    if (hongguoDiscoveryLabels.containsKey(entry.key)) {
      values[entry.key] = value;
    }
  }
  if (!values.containsKey('genre')) {
    if (category == 'comic_series') {
      values['genre'] = 'comic_series';
    } else if (category == 'ai_series') {
      values['genre'] = 'ai_series';
    }
  }
  return HongguoDiscoverySelection(values);
}

/// 服务端筛选会话：只放内存，不落盘。
/// 指纹 = 分类 + 归一前的筛选条件；换筛选项/换分类即新会话，游标作废。
class HongguoDiscoverySession {
  HongguoDiscoverySession({required this.fingerprint, required this.selection});

  final String fingerprint;
  final HongguoDiscoverySelection selection;
  List<CatalogFilterGroup> groups = const [];
  HongguoDiscoveryCursor? nextCursor;
  bool hasMore = false;

  void applyPage(HongguoDiscoveryFilterPage page, {bool first = false}) {
    if (first && page.groups.isNotEmpty) groups = page.groups;
    nextCursor = page.nextCursor;
    hasMore = page.hasMore;
  }
}

/// 混合搜索里失败站源的展示名：jar 站取注册名，导入站取导入名，
/// 内置站取站表名，都没有时回 id 本身（不回落到红果那种默认站）。
String searchAcrossSourceLabel(String source) {
  final spec = JarBridge.specFor(source);
  if (spec != null && spec.name.isNotEmpty) return spec.name;
  final imported = SourceSite.importedSites[source];
  if (imported != null && imported.name.isNotEmpty) return imported.name;
  for (final site in SourceSite.allValues) {
    if (site.id == source) return site.name;
  }
  return source;
}

/// 混合搜索失败提示：与 Go 核 nativeSearchFailureText 同口径——
/// 一家失败点名，两家以上点第一家加总数；无失败返回空串。
String searchAcrossFailureWarning(List<String> failedSources) {
  if (failedSources.isEmpty) return '';
  final labels = [
    for (final source in failedSources) searchAcrossSourceLabel(source),
  ]..sort();
  if (labels.length == 1) return '${labels.single} 未返回结果';
  return '${labels.first} 等 ${labels.length} 个站源未返回结果';
}

/// 把一批搜索结果按站拆开回调（流式搜索里 Go 腿整批回的拆包、
/// 以及默认批回退路的拆包共用）：同一站的条目合并为一次回调，
/// 顺序按该站在结果里首次出现；回调间检查 [shouldStop]，停了
/// 就不再回调后续站。空站不回调。
void _emitSiteItems(
  List<Drama> items,
  void Function(String source, List<Drama> items) onSite,
  bool Function()? shouldStop,
) {
  final bySource = <String, List<Drama>>{};
  final order = <String>[];
  for (final drama in items) {
    final list = bySource.putIfAbsent(drama.source, () {
      order.add(drama.source);
      return <Drama>[];
    });
    list.add(drama);
  }
  for (final source in order) {
    if (shouldStop != null && shouldStop()) return;
    onSite(source, bySource[source]!);
  }
}

/// 站点健康打点（Go 整批腿）：整批成功时按结果里出现的站逐站
/// 记搜索成功 + 条数，未出现的站不打点；整批失败由
/// [_recordGoSearchFailure] 对全部目标站各记一次失败。总开关
/// 关时 store 内部短路，这里不用再判。
void _recordGoSearchLeg(List<String> rest, List<Drama> items, int elapsedMs) {
  final counts = <String, int>{};
  for (final drama in items) {
    counts[drama.source] = (counts[drama.source] ?? 0) + 1;
  }
  for (final source in rest) {
    final count = counts[source];
    if (count == null) continue;
    SiteHealthStore.instance.recordSearch(
      source,
      ok: true,
      items: count,
      elapsedMs: elapsedMs,
    );
  }
}

void _recordGoSearchFailure(List<String> rest) {
  for (final source in rest) {
    SiteHealthStore.instance.recordSearch(source, ok: false);
  }
}

/// 封面字节归一：有些站的封面地址回的不是图片本身，而是一段
/// base64 文本（河马AV 的 .dat 封面就是 base64 编码的 WebP）。
/// 原样存盘后 Image 解不出来、手机上不出图。
///
/// 判定很严：只有“全文都是 base64 字符、能解、解出来是已知图片
/// 格式（JPEG/PNG/GIF/WebP/BMP）”才返回解码后的字节；其它一律
/// 原样返回同一份字节（调用方用 identical 判断是否改写缓存）。
/// 解码失败、截断、普通图片、HTML 报错页都不会误伤。
List<int> normalizeCoverBytes(List<int> bytes) {
  if (bytes.length < 32) return bytes;
  // 先看是不是已经是图片：是就直接回，避免对正常封面做无用功。
  if (_looksLikeImage(bytes)) return bytes;
  final cleaned = <int>[];
  for (final byte in bytes) {
    // 只容忍 base64 字母表与空白（换行/空格）；其它字节一律否决。
    if (byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d) {
      continue;
    }
    final isAlpha =
        (byte >= 0x41 && byte <= 0x5a) ||
        (byte >= 0x61 && byte <= 0x7a) ||
        (byte >= 0x30 && byte <= 0x39) ||
        byte == 0x2b ||
        byte == 0x2f ||
        byte == 0x3d;
    if (!isAlpha) return bytes;
    cleaned.add(byte);
  }
  if (cleaned.isEmpty || cleaned.length % 4 != 0) return bytes;
  // 填充符只许在末尾、最多两个。
  var padding = 0;
  for (var i = cleaned.length - 1; i >= 0 && cleaned[i] == 0x3d; i--) {
    padding++;
  }
  if (padding > 2) return bytes;
  for (var i = 0; i < cleaned.length - padding; i++) {
    if (cleaned[i] == 0x3d) return bytes;
  }
  List<int> decoded;
  try {
    decoded = base64Decode(String.fromCharCodes(cleaned));
  } catch (_) {
    return bytes;
  }
  if (!_looksLikeImage(decoded)) return bytes;
  return decoded;
}

bool _looksLikeImage(List<int> bytes) {
  if (bytes.length < 12) {
    return bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff;
  }
  // JPEG
  if (bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) return true;
  // PNG
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return true;
  }
  // GIF
  if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return true;
  // BMP
  if (bytes[0] == 0x42 && bytes[1] == 0x4d) return true;
  // WebP: RIFF....WEBP
  if (bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true;
  }
  return false;
}

class NativeRepository extends AppRepository {
  static final _coverDecoder = CoverDecoder();
  NativeRepository({
    this.background = false,
    TgCatalogCache? tgCatalogCache,
    Duration? searchPerSiteTimeout,
  }) : _tgCatalogCache = tgCatalogCache ?? TgCatalogCache(),
       _searchPerSiteTimeout =
           searchPerSiteTimeout ?? const Duration(seconds: 10);
  final bool background;

  /// 混合搜索里 jar/py/js 单站预算（默认 10 秒，与阅读搜索同口径，
  /// 树内站源搜索预算已有 10 秒先例，见 adult_scrape_service）：
  /// 构造参数只供测试注入短超时，生产调用一律默认。
  final Duration _searchPerSiteTimeout;

  /// TG 两站目录 1 小时缓存（只放内存）：二次进入直接显示缓存，
  /// 搜索/详情/翻页/强制刷新不走缓存。测试可注入假时钟缓存。
  final TgCatalogCache _tgCatalogCache;

  /// 红果服务端筛选会话（只放内存，不落盘）：展示名→服务端选项 id 的
  /// 索引跨会话复用，游标只跟当前筛选会话走。
  final Map<String, Map<String, String>> _hongguoFilterNameIndex = {};
  HongguoDiscoverySession? _hongguoFilterSession;

  static bool isPySource(String source) =>
      SourceSite.importedSites[source]?.importType == 'py' ||
      SourceSite.importedSites[source]?.importType == 'jsonlist';
  static bool isJsSource(String source) =>
      SourceSite.importedSites[source]?.importType == 'js';

  /// idj 插件站：站 key 以 `idj_` 开头（`idj_chengguo` 等），
  /// 在 `isJsSource` 的分支内再分流，走 `_idjCall` + `IdjContract`。
  static bool isIdjSource(String source) => source.startsWith('idj_');

  /// idj 插件包（唯一事实来源）：按登记的 `importExt`（插件 id）
  /// 从包文件读 manifest + 入口脚本。
  Future<IdjPluginBundle> _idjBundle(String source) async {
    final pluginId = SourceSite.importedSites[source]?.importExt ?? '';
    if (pluginId.isEmpty) {
      throw AppFailure('插件未注册，请重新安装');
    }
    final bundle = await IdjPluginStore().readBundle(pluginId);
    if (bundle == null) {
      throw AppFailure('插件包文件已损坏，请重新安装');
    }
    return bundle;
  }

  Future<IdjPluginManifest> _idjManifest(String source) async =>
      (await _idjBundle(source)).manifest;

  /// idj 调用（照抄 `_jsCall` 结构，action 改 `'idjCall'`）：
  /// 信封按 Go 工人落定的 `nativeInput` 字段走——脚本走 `content`，
  /// manifest 走已有的 `manifest`（JSON 字符串），`pluginId` / `fn` /
  /// `args` 走新增的三个字段（全是字符串，`args` 是 JSON 编码后的
  /// 单对象参数）；返回 `{"result": …}`。
  /// `fn` 是插件入口名（`home` / `category` / `search` / `detail` /
  /// `player` / `__probe` / `__has`）。`player` 只传 `flag` 与 `playId`，
  /// play 的传参修复（`play({id: episodeId, episodeId, line})`）由 Go 侧
  /// `idjParseArg` 组装，Dart 侧不要再包一层。
  /// 每次调用后调看门狗：成功清零、失败 +1（连续 3 次自动停用；
  /// 网络类错误不计数，见 `IdjPluginStore.recordFailure`；
  /// Go 只原样返回带码错误，计数与停用都在 Dart 这边做）。
  Future<Map<String, dynamic>> _idjCall(
    String source,
    String fn, {
    Map<String, dynamic> args = const {},
  }) async {
    _authorize(source);
    final bundle = await _idjBundle(source);
    final store = IdjPluginStore();
    try {
      final result = await _call({
        'action': 'idjCall',
        'pluginId': bundle.manifest.id,
        'content': bundle.script,
        'manifest': jsonEncode(bundle.manifest.raw),
        'fn': fn,
        'args': jsonEncode(args),
      });
      await store.recordSuccess(bundle.manifest.id);
      final inner = result['result'];
      if (inner is Map) return Map<String, dynamic>.from(inner);
      return {};
    } catch (error) {
      await store.recordFailure(
        bundle.manifest.id,
        code: error is AppFailure ? error.code : '',
      );
      rethrow;
    }
  }

  /// probe 试加载入口（供 `IdjPluginStore.probeHandler` 接线，
  /// `main.dart` 里接到这里）：安装时包还没落盘，所以不走 `_idjBundle`，
  /// 脚本与 manifest 由调用方直接传进来；Go 侧以 `fn: '__probe'`
  /// 新建 runtime 跑 prelude、加载入口脚本、调一次 `init({})`（若导出）、
  /// 检查能力函数是否齐全（缺失报错写明缺哪个函数）。
  Future<Map<String, dynamic>> idjProbe(
    String pluginId,
    String script,
    Map<String, dynamic> manifest,
  ) async {
    final result = await _call({
      'action': 'idjCall',
      'pluginId': pluginId,
      'content': script,
      'manifest': jsonEncode(manifest),
      'fn': '__probe',
      'args': '{}',
    });
    final inner = result['result'];
    if (inner is Map) return Map<String, dynamic>.from(inner);
    return {};
  }

  /// 小程序宿主数据桥（HostMiniAppSourceProvider）的原始取数入口：
  /// 与主界面 categories / catalog / detail 对 js/idj 站走的是同一条
  /// `_jsCall` / `_idjCall`——`_authorize` 用户权限校验在两条链内部，
  /// idj 的失败看门狗计数也在 `_idjCall` 内部，本方法只把操作名与
  /// 参数按两条链各自的口径转交，不新开通道、不绕校验。返回蜘蛛 /
  /// 插件的原始结果，形状翻译归调用方。
  /// operation 两边同名：home / category / search / detail / player
  /// （player 只对 js 站走本方法；idj 取流的结果是 streams 形状，
  /// 走 [idjPlaybackPlan] 过契约翻译）。
  Future<Map<String, dynamic>> spiderRawCall(
    String source,
    String operation, {
    String category = '',
    int page = 1,
    String query = '',
    String vodId = '',
    String flag = '',
    String playId = '',
  }) async {
    if (!isJsSource(source)) {
      throw AppFailure('站点不是 JS 蜘蛛/插件站：$source');
    }
    if (isIdjSource(source)) {
      final Map<String, dynamic> args = switch (operation) {
        'category' => <String, dynamic>{'id': category, 'page': page},
        'search' => <String, dynamic>{'keyword': query, 'page': page},
        'detail' => <String, dynamic>{'id': vodId},
        'player' => <String, dynamic>{'flag': flag, 'playId': playId},
        _ => const <String, dynamic>{},
      };
      return _idjCall(source, operation, args: args);
    }
    return _jsCall(
      source,
      operation,
      category: category,
      page: page,
      query: query,
      vodId: vodId,
      flag: flag,
      playId: playId,
    );
  }

  /// idj 取流：与 resolvePlayback 的 idj 分支同一口径——manifest 的
  /// media 白名单 + `_idjCall('player')` + [IdjContract] 形状翻译；
  /// `_authorize` 与看门狗都在 `_idjCall` 内，不另起通道。
  Future<PlaybackPlan> idjPlaybackPlan(
    String source, {
    required String flag,
    required String playId,
  }) async {
    final manifest = await _idjManifest(source);
    final result = await _idjCall(
      source,
      'player',
      args: {'flag': flag, 'playId': playId},
    );
    return IdjContract.planFromResult(
      result,
      mediaAllowlist: manifest.mediaDomains,
    );
  }

  Future<String> _jsSpiderScript(String source) async {
    final fileName = SourceSite.importedJsFiles[source];
    if (fileName != null && fileName.isNotEmpty) {
      final scriptPath = await ImportFileStore.pathOf(fileName);
      final scriptFile = File(scriptPath);
      if (await scriptFile.exists()) {
        return scriptFile.readAsString();
      }
    }
    // 远程 JS 站（TVBox 配置 api 指向 .js 文件）：首次打开时懒加载，
    // 与 py 站的 PyLazyFetch 同款机制。
    final saved = await JsLazyFetch.savedFileName(source);
    if (saved != null && saved.isNotEmpty) {
      final savedPath = await ImportFileStore.pathOf(saved);
      if (await File(savedPath).exists()) {
        SourceSite.importedJsFiles[source] = saved;
        return File(savedPath).readAsString();
      }
    }
    final remoteUrl = SourceSite.importedJsRemoteUrls[source];
    if (remoteUrl == null || remoteUrl.isEmpty) {
      throw AppFailure('导入记录缺少 JS 蜘蛛文件，请在导入中心删除该站后重新导入');
    }
    try {
      final savedName = await JsLazyFetch.fetchAndSave(source, remoteUrl);
      final scriptPath = await ImportFileStore.pathOf(savedName);
      final script = await File(scriptPath).readAsString();
      return script;
    } catch (error) {
      throw AppFailure(error.toString());
    }
  }

  Future<Map<String, dynamic>> _jsCall(
    String source,
    String operation, {
    String category = '',
    int page = 1,
    String query = '',
    String vodId = '',
    String flag = '',
    String playId = '',
  }) async {
    _authorize(source);
    final script = await _jsSpiderScript(source);
    final result = await _call({
      'action': 'jsSpider',
      'content': script,
      'command': operation,
      'category': category,
      'page': page,
      'query': query,
      'drama': {
        'id': vodId,
        'source': source,
        'sourceId': vodId,
        'title': '',
        'description': '',
        'cover': '',
      },
      'flag': flag,
      'playId': playId,
    });
    final inner = result['result'];
    if (inner is Map) return Map<String, dynamic>.from(inner);
    return {};
  }

  Future<String> _pySpiderPath(String source) async {
    final fileName = SourceSite.importedPyFiles[source];
    if (fileName != null && fileName.isNotEmpty) {
      return ImportFileStore.pathOf(fileName);
    }
    final saved = await PyLazyFetch.savedFileName(source);
    if (saved != null && saved.isNotEmpty) {
      final savedPath = await ImportFileStore.pathOf(saved);
      if (await File(savedPath).exists()) {
        SourceSite.importedPyFiles[source] = saved;
        return savedPath;
      }
    }
    final remoteUrl = SourceSite.importedPyRemoteUrls[source];
    if (remoteUrl == null || remoteUrl.isEmpty) {
      throw AppFailure('导入记录缺少蜘蛛文件，请在导入中心删除该站后重新导入');
    }
    try {
      final savedName = await PyLazyFetch.fetchAndSave(source, remoteUrl);
      return await ImportFileStore.pathOf(savedName);
    } catch (error) {
      throw AppFailure(error.toString());
    }
  }

  Future<Map<String, dynamic>> _pyCall(
    String source,
    Map<String, dynamic> request,
  ) async {
    _authorize(source);
    final path = await _pySpiderPath(source);
    final ext = SourceSite.importedSites[source]?.importExt ?? '';
    final payload = {
      ...request,
      if (ext.isNotEmpty) 'extend': ext,
      'cfDisguise': access?.pythonCfDisguise ?? true,
    };
    return PyBridge.call(path, payload);
  }

  Future<dynamic> _pyCallRaw(
    String source,
    Map<String, dynamic> request,
  ) async {
    _authorize(source);
    final path = await _pySpiderPath(source);
    final ext = SourceSite.importedSites[source]?.importExt ?? '';
    final payload = {
      ...request,
      if (ext.isNotEmpty) 'extend': ext,
      'cfDisguise': access?.pythonCfDisguise ?? true,
    };
    return PyBridge.callRaw(path, payload);
  }

  Future<Map<String, dynamic>> pyPing(String source) async =>
      await _pyCall(source, {'action': 'ping'});

  Future<List<String>> pyDependence(String source) async {
    final data = await _pyCallRaw(source, {'action': 'dependence'});
    return [for (final entry in data as List? ?? const []) entry.toString()];
  }

  Future<bool> pyIsVideoFormat(String source, String url) async {
    final data = await _pyCallRaw(source, {'action': 'format', 'url': url});
    return data == true;
  }

  Future<bool> pyManualVideoCheck(String source) async {
    final data = await _pyCallRaw(source, {'action': 'check'});
    return data == true;
  }

  Future<dynamic> pyAction(String source, String name) async =>
      await _pyCallRaw(source, {'action': 'action', 'name': name});

  Future<Map<String, dynamic>> pyProxy(String source, Object? param) async {
    final data = await _pyCall(source, {'action': 'proxy', 'param': param});
    return data;
  }

  Future<Map<String, dynamic>> pyHome(String source) async =>
      await _pyCall(source, {'action': 'home'});

  final _pyHomeFiltersCache = <String, Map<String, dynamic>>{};
  final _pyFilledCache = <String, Set<String>>{};

  Future<Set<String>> _pyFilledMethods(String source) async {
    final cached = _pyFilledCache[source];
    if (cached != null) return cached;
    final ping = await pyPing(source);
    final filled = {
      for (final entry in ping['filled'] as List? ?? const []) entry.toString(),
    };
    _pyFilledCache[source] = filled;
    return filled;
  }

  // ── whos 站：在线优先，本地库兜底 ────────────────────────────────
  //
  // whos.tv 前面是 Cloudflare，代取通道一断整站就空。在线拿不到内容时
  // 用包里/本地已落库的条目顶上，分类、搜索、详情、直链播放都不断档；
  // 拿得到内容时一律走在线，本地只做补充分类。

  Future<List<CatalogCategory>> _whosCategories([
    String source = whosSourceId,
  ]) async {
    var online = const <CatalogCategory>[];
    try {
      final home = await _pyCall(source, {'action': 'categories'});
      online = PyContract.categoriesFromHome(home);
    } catch (_) {}
    final library = WhosLocalLibrary.shared;
    final loaded = await library.ensureLoaded();
    final local = loaded
        ? await whosLocalCategoriesAsync(library)
        : const <CatalogCategory>[];
    final localById = {for (final row in local) row.id: row};
    final seen = <String>{};
    return [
      for (final row in online)
        if (seen.add(row.id))
          // 厂牌分类在线也有：名字后面补上本地库里的条数。
          row.id.startsWith(whosLocalBrandPrefix) && localById[row.id] != null
              ? CatalogCategory(row.id, localById[row.id]!.name)
              : row,
      for (final row in local)
        if (seen.add(row.id)) row,
    ];
  }

  Future<CatalogPage> _whosCatalog({
    required int page,
    required String query,
    required String category,
    String source = whosSourceId,
  }) async {
    CatalogPage? online;
    try {
      final result = await _pyCall(source, {
        'action': 'catalog',
        'page': page,
        'query': query,
        'category': category,
        'filter': false,
        'extend': const <String, String>{},
      });
      online = PyContract.pageFromResult(source, result, page: page);
    } catch (_) {}
    // 在线有内容、或在线已翻到末页（第二页起返回空）：照在线走。
    if (online != null && (online.items.isNotEmpty || page > 1)) {
      return online;
    }
    final library = WhosLocalLibrary.shared;
    if (await library.ensureLoaded()) {
      final local = await whosLocalPageAsync(
        library: library,
        category: category,
        query: query,
        page: page,
        source: source,
      );
      if (local.items.isNotEmpty || online == null) return local;
    }
    if (online != null) return online;
    throw AppFailure('$source 在线取不到内容，本地库里也没有可用的条目');
  }

  /// 找本地条目：先按本地 id，再按番号，最后按标题回捞。
  Future<WhosLocalWork?> _whosLocalWork(Drama drama) async {
    final library = WhosLocalLibrary.shared;
    if (!await library.ensureLoaded()) return null;
    final id = whosLocalWorkIdOf(drama);
    if (id.isNotEmpty) {
      final work = await library.byIdAsync(id);
      if (work != null) return work;
    }
    final code = drama.tags.firstWhere(
      (tag) => RegExp(r'[A-Za-z]{2,6}[-_ ]?\d{2,6}').hasMatch(tag),
      orElse: () => '',
    );
    for (final key in [code, drama.title]) {
      if (key.trim().isEmpty) continue;
      final hit = library.page(query: key, page: 1, pageSize: 1);
      if (hit.isNotEmpty) return hit.first;
    }
    return null;
  }

  /// 本地直链播放计划：地址已经是 m3u8，不需要再解析。
  Future<PlaybackPlan?> _whosLocalPlan(Drama drama, Episode episode) async {
    final work = await _whosLocalWork(drama);
    final raw = episode.raw['id'] as String? ?? episode.id;
    final url = (work?.playUrl.isNotEmpty ?? false) ? work!.playUrl : raw;
    if (!url.startsWith('http://') && !url.startsWith('https://')) return null;
    return PlaybackPlan(
      url: url,
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/131.0.0.0 Safari/537.36',
        'Referer': 'https://whos.tv/',
      },
    );
  }

  Future<List<CatalogFilterGroup>> _pyCategoryFilterGroups(
    String source,
    String category,
  ) async {
    if (category.isEmpty) return const [];
    try {
      var raw = _pyHomeFiltersCache[source];
      if (raw == null) {
        final home = await pyHome(source);
        raw = PyContract.filtersFromHome(home);
        _pyHomeFiltersCache[source] = raw;
      }
      return PyContract.filterGroupsForCategory(raw, category);
    } catch (_) {
      return const [];
    }
  }

  Future<List<CatalogFilterGroup>> _jarCategoryFilterGroups(
    String source,
    String category,
  ) async {
    if (category.isEmpty) return const [];
    try {
      final home = await _jarCall(source, (spec) => JarBridge.home(spec));
      final raw = PyContract.filtersFromHome(home);
      return PyContract.filterGroupsForCategory(raw, category);
    } catch (_) {
      return const [];
    }
  }

  Future<PlaybackPlan> _applyPyFormat(String source, PlaybackPlan plan) async {
    if (plan.url.isEmpty) return plan;
    try {
      final filled = await _pyFilledMethods(source);
      if (filled.contains('isVideoFormat')) return plan;
      final isVideo = await pyIsVideoFormat(source, plan.url);
      return plan.withNeedsParse(!isVideo);
    } catch (_) {
      return plan;
    }
  }

  HttpServer? _pyProxyServer;

  Future<HttpServer> _ensurePyProxyServer() async {
    final existing = _pyProxyServer;
    if (existing != null) return existing;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handleLocalProxyRequest);
    _pyProxyServer = server;
    return server;
  }

  Future<void> _handleLocalProxyRequest(HttpRequest request) async {
    if (request.uri.path == '/jarproxy') {
      await _handleJarProxyRequest(request);
    } else {
      await _handlePyProxyRequest(request);
    }
  }

  static bool _startsWithExtM3u(List<int> body) {
    const marker = [0x23, 0x45, 0x58, 0x54, 0x4D, 0x33, 0x55]; // '#EXTM3U'
    if (body.length < marker.length) return false;
    for (var i = 0; i < marker.length; i++) {
      if (body[i] != marker[i]) return false;
    }
    return true;
  }

  Future<void> _handleJarProxyRequest(HttpRequest request) async {
    try {
      final payload = request.uri.queryParameters['d'] ?? '';
      final decoded = jsonDecode(utf8.decode(base64Url.decode(payload))) as Map;
      final siteId = decoded['siteId'] as String? ?? '';
      final configId = decoded['configId'] as String? ?? '';
      final className = decoded['className'] as String? ?? '';
      final spec = JarBridge.specFor(siteId);
      if (spec == null ||
          spec.configId != configId ||
          spec.className != className) {
        throw JarBridgeFailure('jar 本地代理请求与注册站点不匹配，拒绝分发');
      }
      final rawParam = decoded['param'];
      final param = <String, String>{};
      if (rawParam is Map) {
        rawParam.forEach((key, value) {
          if (value != null) param[key.toString()] = value.toString();
        });
      }
      final result = await JarBridge.jarProxy(spec, param);
      final mime = result['mime'] as String? ?? 'application/octet-stream';
      var body = base64Decode(result['bodyBase64'] as String? ?? '');
      // 代理回的文本正文（m3u8 母列表）里嵌的下一级 9978 地址须一并
      // 改写成本地 /jarproxy 地址，否则播放器直接取 9978 无人监听；
      // 二进制分片正文绝不碰（类型与 #EXTM3U 头双重把关）。
      final isPlaylistText =
          mime.contains('mpegurl') ||
          mime.startsWith('text/') ||
          _startsWithExtM3u(body);
      if (isPlaylistText) {
        final port = request.connectionInfo?.localPort ?? _pyProxyServer?.port;
        if (port != null) {
          final text = utf8.decode(body, allowMalformed: true);
          final rewritten = JarBridge.rewriteLoopbackProxyUrls(
            text,
            port: port,
            spec: spec,
          );
          if (rewritten != text) {
            body = utf8.encode(rewritten);
          }
        }
      }
      request.response.statusCode = result['status'] as int? ?? 200;
      request.response.headers.set(HttpHeaders.contentTypeHeader, mime);
      request.response.add(body);
      await request.response.close();
    } catch (error) {
      request.response.statusCode = 500;
      request.response.write('jar proxy failed: $error');
      await request.response.close();
    }
  }

  Object _pyProxyParam(String rest) {
    if (rest.contains('=')) {
      final map = <String, String>{};
      for (final part in rest.split('&')) {
        final eq = part.indexOf('=');
        if (eq > 0) {
          map[Uri.decodeComponent(part.substring(0, eq))] = Uri.decodeComponent(
            part.substring(eq + 1),
          );
        }
      }
      if (map.isNotEmpty) return map;
    }
    return {'url': rest};
  }

  Future<String> _pyProxyLocalUrl(String source, String proxyUrl) async {
    final server = await _ensurePyProxyServer();
    final rest = proxyUrl.substring('proxy://'.length);
    final payload = base64Url.encode(
      utf8.encode(jsonEncode({'source': source, 'param': _pyProxyParam(rest)})),
    );
    return 'http://127.0.0.1:${server.port}/pyproxy?d=$payload';
  }

  Future<void> _handlePyProxyRequest(HttpRequest request) async {
    try {
      final payload = request.uri.queryParameters['d'] ?? '';
      final decoded = jsonDecode(utf8.decode(base64Url.decode(payload))) as Map;
      final source = decoded['source'] as String? ?? '';
      final param = decoded['param'];
      final result = await pyProxy(source, param);
      final body = base64Decode(result['bodyBase64'] as String? ?? '');
      request.response.statusCode = result['status'] as int? ?? 200;
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        result['mime'] as String? ?? 'application/octet-stream',
      );
      for (final entry in (result['headers'] as Map? ?? {}).entries) {
        request.response.headers.set(
          entry.key.toString(),
          entry.value.toString(),
        );
      }
      request.response.add(body);
      await request.response.close();
    } catch (error) {
      request.response.statusCode = 500;
      request.response.write('py proxy failed: $error');
      await request.response.close();
    }
  }

  Future<PlaybackPlan> _applyPyProxy(String source, PlaybackPlan plan) async {
    if (!plan.url.startsWith('proxy://')) return plan;
    try {
      final local = await _pyProxyLocalUrl(source, plan.url);
      return plan.withUrl(local);
    } catch (error) {
      throw AppFailure('本地代理服务启动失败：$error');
    }
  }

  Future<PlaybackPlan> _pyResolvePlan(
    String source,
    String flag,
    String playId,
  ) async {
    final result = await _pyCall(source, {
      'action': 'resolve',
      'flag': flag,
      'playId': playId,
    });
    var plan = PyContract.planFromResult(result);
    if (plan.url.isEmpty) {
      throw AppFailure(
        'py 蜘蛛取流未返回可播放地址（步骤=playerContent，线路=$flag，集标识=$playId）',
      );
    }
    final hasParseFlag =
        result.containsKey('parse') || result.containsKey('jx');
    if (!hasParseFlag) {
      plan = await _applyPyFormat(source, plan);
    }
    plan = await _applyPyProxy(source, plan);
    return plan;
  }

  LocalStore? access;

  /// 网盘引擎（懒建：第一次打开网盘站时才建，平时零开销）。
  Future<CloudDriveEngine>? _cloudEngineFuture;
  Future<CloudDriveEngine> _cloudDriveEngine() =>
      _cloudEngineFuture ??= _createCloudDriveEngine();

  Pan115Gateway? _actressPan115Gateway;

  /// 演员库详情页的 115 网关（懒建、单例）：登录态/搜文件/
  /// 取直链/离线提交全走网盘引擎的既有 115 登录，不另起
  /// 登录。演员库各入口在构造 DetailScreen 时注入它。
  Pan115Gateway actressPan115Gateway() =>
      _actressPan115Gateway ??= EnginePan115Gateway(
        engine: _cloudDriveEngine,
      );

  Future<CloudDriveEngine> _createCloudDriveEngine() async {
    final preferences = await SharedPreferences.getInstance();
    return CloudDriveEngine(
      credentialStore: CloudCredentialStore(preferences),
      httpClient: http.Client(),
      showSuspectedAds: () => access?.showSuspectedAdVideos ?? false,
      // 目录页落盘缓存目录（问题 6 秒开）：重启后先出画再刷新。
      catalogCacheDir: () async {
        final support = await getApplicationSupportDirectory();
        return Directory(path.join(support.path, 'cloud_catalog_cache'));
      },
    );
  }

  int runningCoreBuild = 0;
  final _readOwner = DateTime.now().microsecondsSinceEpoch.toString();
  int _readSequence = 0;
  final _activeReads = <String, int>{};

  void _adminPermission() {
    if (access != null && (access!.locked || !access!.profile.admin)) {
      throw AppFailure('仅管理员可修改本机资源设置');
    }
  }

  @override
  Future<ResourceSettings> resourceSettings() async {
    _adminPermission();
    return ResourceSettings.fromJson(
      await _call({'action': 'resourceSettings'}),
    );
  }

  @override
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async {
    _adminPermission();
    final saved = ResourceSettings.fromJson(
      await _call({
        'action': 'saveResourceSettings',
        'settings': settings.toJson(),
      }),
    );
    return saved;
  }

  @override
  Future<Map<String, dynamic>> crackConfigSet(String content) =>
      _call({'action': 'crackConfigSet', 'content': content});

  @override
  Future<Map<String, dynamic>> hongguoDeviceStatus() =>
      _call({'action': 'hongguoDeviceStatus'});

  @override
  Future<Map<String, dynamic>> hongguoDeviceRegister() =>
      _call({'action': 'hongguoDeviceRegister'});

  @override
  Future<Map<String, dynamic>> hongguoDeviceReregister() =>
      _call({'action': 'hongguoDeviceReregister'});

  @override
  Future<Map<String, dynamic>> hongguoDeviceRefresh() =>
      _call({'action': 'hongguoDeviceRefresh'});

  @override
  Future<Map<String, dynamic>> hongguoAccountSendSms(String mobile) =>
      _call({'action': 'hongguoAccountSendSms', 'phone': mobile});

  @override
  Future<Map<String, dynamic>> hongguoAccountVerifySms(
    String mobile,
    String code,
  ) => _call({
    'action': 'hongguoAccountVerifySms',
    'phone': mobile,
    'code': code,
  });

  @override
  Future<Map<String, dynamic>> hongguoAccountQrCode() =>
      _call({'action': 'hongguoAccountQrCode'});

  @override
  Future<Map<String, dynamic>> hongguoAccountQrPoll() =>
      _call({'action': 'hongguoAccountQrPoll'});

  @override
  Future<Map<String, dynamic>> hongguoAccountQrConfirm() =>
      _call({'action': 'hongguoAccountQrConfirm'});

  @override
  Future<Map<String, dynamic>> hongguoAccountProfile(String cookie) =>
      _call({'action': 'hongguoAccountProfile', 'cookie': cookie});

  @override
  Future<Map<String, dynamic>> hongguoAccountFilter({
    required String content,
    String cursor = '',
  }) async {
    _authorize('hongguo');
    return _call({
      'action': 'hongguoAccountFilter',
      'content': content,
      'cursor': cursor,
    });
  }

  /// 红果服务端筛选：按筛选会话的游标续页；首页或换筛选项时重拉首页。
  /// 展示名→服务端选项 id 的索引（[_hongguoFilterNameIndex]）跨会话复用。
  Future<CatalogPage> _hongguoServerFilterCatalog({
    required String category,
    required int page,
    required Map<String, String> filters,
  }) async {
    final fingerprint = [
      category,
      ...filters.entries
          .where((entry) => entry.value.isNotEmpty)
          .map((entry) => '${entry.key}=${entry.value}')
          .toList()
        ..sort(),
    ].join('|');
    final session = _hongguoFilterSession;
    if (page > 1 && session != null && session.fingerprint == fingerprint) {
      // 同一筛选会话续页：有游标就接着拉；服务端已无更多时回空页，
      // 不重拉首页（否则已拼好的列表会被首页冲掉）。
      if (session.hasMore && session.nextCursor != null) {
        final body = session.selection.requestBody(cursor: session.nextCursor);
        final result = await hongguoAccountFilter(
          content: jsonEncode(body),
          cursor: jsonEncode(session.nextCursor!.toJson()),
        );
        final parsed = HongguoDiscoveryFilterPage.fromBridgeJson(result);
        session.applyPage(parsed);
        return CatalogPage(
          parsed.items,
          hasMore: parsed.hasMore,
          page: page,
          filters: session.groups,
        );
      }
      return CatalogPage(
        const [],
        hasMore: false,
        page: page,
        filters: session.groups,
      );
    }
    // 首页或换筛选项：旧 4 组是中文值，服务端只要 selector_item_id，
    // 索引为空时先拉一次空条件首页取筛选面板（只取其 groups，条目丢弃）。
    final needsPanel =
        _hongguoFilterNameIndex.isEmpty &&
        filters.entries.any(
          (entry) =>
              entry.value.isNotEmpty &&
              hongguoDiscoveryLegacyKeyToServer.containsKey(entry.key),
        );
    if (needsPanel) {
      final panel = await hongguoAccountFilter(
        content: jsonEncode(HongguoDiscoverySelection().requestBody()),
      );
      _learnHongguoFilterIndex(
        HongguoDiscoveryFilterPage.fromBridgeJson(panel).nameToId,
      );
    }
    final selection = hongguoNormalizeFilters(
      filters,
      _hongguoFilterNameIndex,
      category: category,
    );
    final result = await hongguoAccountFilter(
      content: jsonEncode(selection.requestBody()),
    );
    final parsed = HongguoDiscoveryFilterPage.fromBridgeJson(result);
    _learnHongguoFilterIndex(parsed.nameToId);
    final next = HongguoDiscoverySession(
      fingerprint: fingerprint,
      selection: selection,
    )..applyPage(parsed, first: true);
    _hongguoFilterSession = next;
    return CatalogPage(
      parsed.items,
      hasMore: parsed.hasMore,
      page: page,
      filters: next.groups,
    );
  }

  void _learnHongguoFilterIndex(Map<String, Map<String, String>> learned) {
    for (final entry in learned.entries) {
      _hongguoFilterNameIndex
          .putIfAbsent(entry.key, () => {})
          .addAll(entry.value);
    }
  }

  @override
  Future<Map<String, dynamic>> hongguoAccountStatus() =>
      _call({'action': 'hongguoAccountStatus'});

  @override
  Future<Map<String, dynamic>> hongguoAccountExportSession() =>
      _call({'action': 'hongguoAccountExportSession'});

  @override
  Future<Map<String, dynamic>> hongguoAccountSetSession(
    Map<String, dynamic> session,
  ) => _call({'action': 'hongguoAccountSetSession', ...session});

  @override
  Future<Map<String, dynamic>> hongguoAccountClearSession() =>
      _call({'action': 'hongguoAccountClearSession'});

  @override
  Future<Map<String, dynamic>> hongguoLoginQr() =>
      _call({'action': 'hongguoLoginQr'});

  @override
  Future<Map<String, dynamic>> hongguoLoginQrPoll() =>
      _call({'action': 'hongguoLoginQrPoll'});

  @override
  Future<Map<String, dynamic>> hongguoAccountInfo() =>
      _call({'action': 'hongguoAccountInfo'});

  @override
  Future<Map<String, dynamic>> hongguoLoginSendCode(String phone) =>
      _call({'action': 'hongguoLoginSendCode', 'phone': phone});

  @override
  Future<Map<String, dynamic>> hongguoLoginSms(String phone, String code) =>
      _call({'action': 'hongguoLoginSms', 'phone': phone, 'code': code});

  @override
  Future<Map<String, dynamic>> hongguoLoginAppSendCode(String phone) =>
      _call({'action': 'hongguoLoginAppSendCode', 'phone': phone});

  @override
  Future<Map<String, dynamic>> hongguoLoginAppSms(String phone, String code) =>
      _call({'action': 'hongguoLoginAppSms', 'phone': phone, 'code': code});

  @override
  Future<Map<String, dynamic>> hongguoAccountFavorites() =>
      _call({'action': 'hongguoAccountFavorites'});

  @override
  Future<Map<String, dynamic>> hongguoAccountSetFavorite(
    String seriesId,
    bool add,
  ) => _call({
    'action': 'hongguoAccountSetFavorite',
    'seriesId': seriesId,
    'add': add,
  });

  @override
  Future<Map<String, dynamic>> hongguoAccountHistory() =>
      _call({'action': 'hongguoAccountHistory'});

  @override
  Future<Map<String, dynamic>> hongguoAccountUploadProgress(
    Map<String, dynamic> progress,
  ) => _call({'action': 'hongguoAccountUploadProgress', ...progress});

  @override
  Future<Map<String, dynamic>> hongguoAccountReservations(bool online) =>
      _call({'action': 'hongguoAccountReservations', 'online': online});

  @override
  Future<Map<String, dynamic>> hongguoAccountReserve(String seriesId) =>
      _call({'action': 'hongguoAccountReserve', 'seriesId': seriesId});

  @override
  Future<Map<String, dynamic>> hongguoAccountLoginRewardInfo() =>
      _call({'action': 'hongguoAccountLoginRewardInfo'});

  @override
  Future<Map<String, dynamic>> hongguoAccountClaimDailyCoins() =>
      _call({'action': 'hongguoAccountClaimDailyCoins'});

  @override
  Future<Map<String, dynamic>> hongguoAccountRelated(String seriesId) =>
      _call({'action': 'hongguoAccountRelated', 'seriesId': seriesId});

  @override
  Future<Map<String, dynamic>> crackConfigSummary() =>
      _call({'action': 'crackConfigSummary'});

  Future<Map<String, dynamic>> _read(
    String scope,
    Map<String, dynamic> input,
  ) async {
    final sequence = ++_readSequence;
    _activeReads[scope] = sequence;
    try {
      return await _call({
        ...input,
        'session': '$_readOwner:$scope',
        'sequence': sequence,
      });
    } finally {
      if (_activeReads[scope] == sequence) _activeReads.remove(scope);
    }
  }

  Future<void> _cancelReads(String prefix) async {
    final reads = _activeReads.entries
        .where((entry) => entry.key.startsWith(prefix))
        .toList();
    await Future.wait(
      reads.map((entry) async {
        try {
          await _call({
            'action': 'cancelRead',
            'session': '$_readOwner:${entry.key}',
            'sequence': entry.value,
          });
        } catch (_) {}
      }),
    );
  }

  @override
  Future<void> cancelDanmaku() => _cancelReads('danmaku');

  @override
  Future<HongguoCommentPage> comments(
    PlaybackPlan plan, {
    String cursor = '',
  }) async {
    _authorize('hongguo');
    if (plan.local || plan.session.isEmpty) {
      throw AppFailure('本集暂不支持评论');
    }
    return HongguoCommentPage.fromJson(
      await _read('comments', {
        'action': 'comments',
        'playbackSession': plan.session,
        'cursor': cursor,
      }),
    );
  }

  @override
  Future<HongguoCommentPage> commentsBySeries(
    String seriesId, {
    String cursor = '',
  }) async {
    _authorize('hongguo');
    return HongguoCommentPage.fromJson(
      await _read('commentsById', {
        'action': 'hongguoCommentsById',
        'seriesId': seriesId,
        'cursor': cursor,
      }),
    );
  }

  @override
  Future<void> cancelComments() => _cancelReads('comments');

  @override
  Future<void> cancelPreload() => _cancelReads('preload');

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
    int route = 0,
    bool adBlock = true,
  }) async => PlaybackPlan.fromJson(
    await _read('preload', {
      'action': 'preload',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'route': route,
      'adBlock': adBlock,
      'force': online || access?.canDownload == false,
    }),
  );

  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async {
    _authorize('hongguo');
    if (plan.local || plan.session.isEmpty || plan.danmakuId.isEmpty) {
      throw AppFailure('本集暂不支持弹幕');
    }
    return DanmakuPage.fromJson(
      await _read('danmaku', {
        'action': 'danmaku',
        'playbackSession': plan.session,
        'startMs': startMs,
        'durationMs': durationMs,
      }),
      episodeId: plan.danmakuId,
      startMs: startMs,
      durationMs: durationMs,
    );
  }

  @override
  Future<DanmakuPage> danmakuById(
    String seriesId,
    String videoId, {
    required int startMs,
    required int durationMs,
  }) async {
    _authorize('hongguo');
    return DanmakuPage.fromJson(
      await _read('danmakuById', {
        'action': 'hongguoDanmakuById',
        'seriesId': seriesId,
        'videoId': videoId,
        'startMs': startMs,
        'durationMs': durationMs,
      }),
      episodeId: videoId,
      startMs: startMs,
      durationMs: durationMs,
    );
  }

  @override
  Future<void> cancelCatalog() => _cancelReads('catalog-');
  @override
  Future<void> cancelSuggestions() => _cancelReads('suggestions');
  @override
  Future<void> cancelRecommendations() => _cancelReads('recommendations-');

  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async {
    _authorize('hongguo');
    return CatalogPage.fromJson(
      await _read('recommendations-$genre', {
        'action': 'recommendations',
        'category': genre,
        'command': more ? 'more' : '',
        'force': force,
      }),
    );
  }

  @override
  Future<Drama?> supplementMetadata(Drama drama) async {
    if (!(drama.source == 'hongguo' && drama.onlineDate.isEmpty ||
        drama.source == 'huangdou' &&
            (drama.heat.isEmpty || drama.vipStatus == null))) {
      return null;
    }
    final result = await _read('metadata', {
      'action': 'metadata',
      'drama': drama.toJson(),
    });
    return Drama.fromJson(Map<String, dynamic>.from(result['drama'] as Map));
  }

  @override
  bool get supportsSourceManagement => true;

  @override
  Future<List<RankingBoard>> rankingBoards() async {
    final result = await _call({'action': 'rankingBoards'});
    return [
          for (final row in result['items'] as List? ?? [])
            RankingBoard.fromJson(Map<String, dynamic>.from(row as Map)),
        ]
        .where(
          (board) =>
              SourceSite.isAvailable(board.source) &&
              (access?.allowsSource(board.source) ?? true),
        )
        .toList();
  }

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => RankingPage.fromJson(
    await _call({
      'action': 'rankings',
      'board': board,
      'page': page,
      'force': force,
    }),
  );

  @override
  Future<SourceStatus> sourceStatus(String source) async {
    if (isPySource(source) || isJsSource(source)) {
      return SourceStatus.fromJson({'source': source});
    }
    return SourceStatus.fromJson(
      await _call({'action': 'sourceStatus', 'source': source}),
    );
  }

  @override
  Future<SourceStatus> startSourceJob(
    String source,
    String operation, {
    Drama? drama,
  }) async {
    if (isPySource(source) || isJsSource(source)) {
      throw AppFailure('导入站为实时抓取，没有本地库，不支持更新/检测任务');
    }
    _authorize(source);
    if (drama != null && drama.source != source) throw AppFailure('站源与剧集不匹配');
    final epoch = access?.profileEpoch;
    await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    return SourceStatus.fromJson(
      await _call({
        'action': 'sourceJob',
        'source': source,
        'command': operation,
        if (drama != null) 'drama': drama.toJson(),
      }),
    );
  }

  @override
  Future<SourceStatus> cancelSourceJob(String source) async =>
      SourceStatus.fromJson(
        await _call({'action': 'cancelSourceJob', 'source': source}),
      );

  @override
  Future<List<CustomSourceSite>> customSources() async {
    _adminPermission();
    final result = await _call({'action': 'customSources'});
    return [
      for (final row in result['items'] as List? ?? const [])
        CustomSourceSite.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<CustomSourceSite> addCustomSource({
    required String name,
    required String base,
    String rule = '',
    String kind = '',
  }) async {
    _adminPermission();
    final result = await _call({
      'action': 'addCustomSource',
      'name': name,
      'base': base,
      'rule': rule,
      'kind': kind,
    });
    return CustomSourceSite.fromJson(Map<String, dynamic>.from(result as Map));
  }

  @override
  Future<CustomSourceSite> updateCustomSource(
    String id, {
    required String name,
    required String base,
    String rule = '',
    String kind = '',
  }) async {
    _adminPermission();
    final result = await _call({
      'action': 'updateCustomSource',
      'source': id,
      'name': name,
      'base': base,
      'rule': rule,
      'kind': kind,
    });
    return CustomSourceSite.fromJson(Map<String, dynamic>.from(result as Map));
  }

  @override
  Future<void> removeCustomSource(String id) async {
    _adminPermission();
    await _call({'action': 'removeCustomSource', 'source': id});
  }

  @override
  Future<Map<String, String>> validateCustomRule({
    required String name,
    required String base,
    String rule = '',
    String kind = '',
  }) async {
    _adminPermission();
    final result = await _call({
      'action': 'customRuleValidate',
      'name': name,
      'base': base,
      'rule': rule,
      'kind': kind,
    });
    return {
      for (final entry in (result as Map).entries)
        entry.key.toString(): entry.value.toString(),
    };
  }

  @override
  Future<List<Map<String, String>>> previewCustomRule({
    required String name,
    required String base,
    String rule = '',
    String kind = '',
  }) async {
    _adminPermission();
    final result = await _call({
      'action': 'customRulePreview',
      'name': name,
      'base': base,
      'rule': rule,
      'kind': kind,
    });
    return [
      for (final row in result['items'] as List? ?? const [])
        {
          for (final entry in (row as Map).entries)
            entry.key.toString(): entry.value.toString(),
        },
    ];
  }

  @override
  Future<String> exportCustomSources() async {
    _adminPermission();
    final result = await _call({'action': 'exportCustomSources'});
    return (result as Map)['content'] as String? ?? '';
  }

  @override
  Future<Map<String, dynamic>> importCustomSources(String content) async {
    _adminPermission();
    final result = await _call({
      'action': 'importCustomSources',
      'content': content,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  @override
  Future<int> resetCustomSources() async {
    _adminPermission();
    final result = await _call({'action': 'resetCustomSources'});
    return (result as Map)['removed'] as int? ?? 0;
  }

  void _authorize(String source, {bool download = false}) {
    if (!SourceSite.isAvailable(source)) {
      throw AppFailure('当前版本不包含此站源');
    }
    if (access == null) return;
    if (access!.locked ||
        !access!.allowsSource(source) ||
        download && !access!.canDownload) {
      throw AppFailure('当前用户没有此操作权限');
    }
  }

  void _downloadPermission() {
    if (access != null && (access!.locked || !access!.canDownload)) {
      throw AppFailure('当前用户仅支持在线观看');
    }
  }

  @override
  Future<List<String>> suggestions(String query) async {
    _authorize('hongguo');
    final result = await _read('suggestions', {
      'action': 'suggestions',
      'query': query,
    });
    return (result['items'] as List? ?? []).whereType<String>().toList();
  }

  @override
  Future<String> downloadDirectory() async {
    _downloadPermission();
    return (await _call({'action': 'downloadDirectory'}))['directory']
            as String? ??
        '';
  }

  @override
  Future<String> downloadRemuxDirectory(String jobId) async {
    _downloadPermission();
    return (await _call({
              'action': 'downloadRemuxDirectory',
              'jobId': jobId,
            }))['directory']
            as String? ??
        '';
  }

  @override
  Future<Map<String, dynamic>> storage() async {
    _downloadPermission();
    return _call({'action': 'storage'});
  }

  @override
  Future<void> moveDownloads(String directory) async {
    _downloadPermission();
    if (access != null && !access!.profile.admin) {
      throw AppFailure('仅管理员可更改下载目录');
    }
    await BackgroundDownloads.ensureStarted();
    await workLease('storage', 'start');
    try {
      await _call({'action': 'moveDownloads', 'directory': directory});
    } finally {
      await workLease('storage', 'end');
    }
  }

  Future<dynamic> legadoRun(
    String sourceJson,
    String action,
    String input,
  ) async {
    final res = await _call({
      'action': 'legadoRun',
      'content': sourceJson,
      'category': action,
      'query': input,
    });
    return res['result'];
  }

  Future<int> workLease(String id, String command) async => intValue(
    (await _call({
      'action': 'workLease',
      'jobId': id,
      'command': command,
    }))['count'],
  );
  int _playbackSequence = DateTime.now().microsecondsSinceEpoch;

  Future<Map<String, dynamic>> _call(Map<String, dynamic> input) async {
    try {
      final action = input['action'] as String;
      final unrestricted =
          {
            'initialize',
            'release',
            'cancelPlayback',
            'cancelRead',
          }.contains(action) ||
          action == 'workLease' && input['command'] == 'end';
      final epoch = access?.profileEpoch;
      if (!unrestricted && access?.locked == true) throw AppFailure('请先解锁当前用户');
      if (action == 'rankings') {
        _authorize(RankingBoard.sourceForID(input['board'] as String));
      }
      if (action == 'recommendations' ||
          action == 'cachedRecommendations' ||
          action == 'suggestions' ||
          action == 'danmaku' ||
          action == 'comments') {
        _authorize('hongguo');
      }
      if ({
        'catalog',
        'cached',
        'categories',
        'sourceStatus',
        'sourceJob',
        'cancelSourceJob',
      }.contains(action)) {
        _authorize(input['source'] as String);
      }
      if ({
        'cover',
        'prepareCover',
        'detail',
        'metadata',
        'resolve',
        'preload',
        'enqueueDownloads',
        'localPlayback',
      }.contains(action)) {
        _authorize(
          (input['drama'] as Map)['source'] as String,
          download: action == 'enqueueDownloads' || action == 'localPlayback',
        );
      }
      if (!unrestricted &&
          {
            'downloads',
            'controlDownloads',
            'controlDownloadBatch',
            'storage',
            'downloadDirectory',
            'downloadRemuxDirectory',
            'moveDownloads',
            'workLease',
          }.contains(action)) {
        _downloadPermission();
      }
      if (action == 'resolve' && access != null && !access!.canDownload) {
        input['force'] = true;
      }
      final body = jsonEncode(input);
      // idj 播放调用：Go 侧预算单独放宽到 90 秒，Dart 兜底给 100 秒，
      // 让 Go 的 E_TIMEOUT 先触发；其余 idj 调用 Go 预算 30 秒，
      // 70 秒兜底足够。
      final encoded = await Isolate.run(() => _nativeRequest(body)).timeout(
        Duration(
          seconds: action == 'moveDownloads'
              ? 620
              : action == 'danmaku' || action == 'comments'
              ? 15
              : action == 'preload'
              ? 20
              : action == 'idjCall' && input['fn'] == 'player'
              ? 100
              : 70,
        ),
      );
      final response = jsonDecode(encoded) as Map<String, dynamic>;
      if (response['ok'] != true) {
        throw AppFailure(
          response['error'] as String? ?? '读取失败，请重试',
          code: response['code'] as String? ?? '',
        );
      }
      final data = response['data'];
      if (!unrestricted && epoch != access?.profileEpoch) {
        if (data is Map && data['session'] is String) {
          await release(data['session'] as String);
        }
        if (action == 'workLease' && input['command'] == 'start') {
          await workLease(input['jobId'] as String, 'end');
        }
        throw AppFailure('用户已切换，请重新操作');
      }
      return data is Map ? Map<String, dynamic>.from(data) : {};
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      if (input['session'] is String &&
          input['sequence'] is int &&
          {
            'catalog',
            'categories',
            'suggestions',
            'recommendations',
            'metadata',
            'danmaku',
            'comments',
            'preload',
          }.contains(input['action'])) {
        unawaited(
          _call({
            'action': 'cancelRead',
            'session': input['session'],
            'sequence': input['sequence'],
          }).catchError((Object _) => <String, dynamic>{}),
        );
      }
      throw AppFailure('站源响应超时，请重试');
    } catch (_) {
      throw AppFailure('本地核心加载失败，请使用完整安装包重新安装');
    }
  }

  @override
  Future<void> initialize() async {
    final directory = await getApplicationSupportDirectory();
    final build = await _call({
      'action': 'initialize',
      'directory': directory.path,
    });
    runningCoreBuild = (build['coreBuild'] as num?)?.toInt() ?? 0;
    if (build['allSources'] != allSourcesEnabled) {
      throw AppFailure('应用与原生核心的站源版本不一致，请使用完整安装包重新安装');
    }
    if (!background) await BackgroundDownloads.prepare();
  }

  Future<Map<String, dynamic>> coreInfo() => _call({'action': 'coreInfo'});

  Future<T> _jarCall<T>(
    String source,
    Future<T> Function(JarSiteSpec spec) run,
  ) async {
    final spec = JarBridge.specFor(source);
    if (spec == null) throw AppFailure('jar 站点未注册');
    _authorize(source);
    try {
      return await run(spec);
    } on JarBridgeFailure catch (error) {
      throw AppFailure(error.message);
    }
  }

  Future<PlaybackPlan> _jarResolve(
    JarSiteSpec spec,
    Drama drama,
    Episode episode,
  ) async {
    final takeover = await JarYoutubeTakeover.tryResolve(spec, drama, episode);
    if (takeover != null) return takeover;
    final plan = await JarBridge.resolve(spec, drama, episode);
    return _applyJarProxy(spec, plan);
  }

  Future<PlaybackPlan> _applyJarProxy(
    JarSiteSpec spec,
    PlaybackPlan plan,
  ) async {
    final loopbackParams = JarBridge.loopbackProxyParams(plan.url);
    final isProxyScheme =
        plan.url.startsWith('proxy://') || plan.url.startsWith('proxy:');
    if (loopbackParams == null && !isProxyScheme) {
      return plan;
    }
    try {
      final server = await _ensurePyProxyServer();
      final param = loopbackParams ?? JarBridge.parseProxyParams(plan.url);
      final local = JarBridge.jarProxyLocalUrl(
        server.port,
        JarBridge.jarProxyPayload(spec, param),
      );
      return plan.withUrl(local);
    } catch (error) {
      throw AppFailure('jar 本地代理服务启动失败：$error');
    }
  }

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    final haijiaoGo = JarHaijiaoTakeover.goSourceForJarSite(source);
    if (haijiaoGo != null) {
      _authorize(source);
      return categories(haijiaoGo, force: force);
    }
    if (JarBridge.isJarSource(source)) {
      return _jarCall(
        source,
        (spec) => JarBridge.categories(spec, force: force),
      );
    }
    if (isPySource(source)) {
      if (isWhosLikeSource(source)) return _whosCategories(source);
      final home = await _pyCall(source, {'action': 'categories'});
      return PyContract.categoriesFromHome(home);
    }
    if (isJsSource(source)) {
      if (isIdjSource(source)) {
        final home = await _idjCall(source, 'home');
        return IdjContract.categoriesFromHome(home);
      }
      final home = await _jsCall(source, 'home');
      return PyContract.categoriesFromHome(home);
    }
    final result = await _read('categories-$source', {
      'action': 'categories',
      'source': source,
      'force': force,
    });
    return [
      for (final row in result['items'] as List? ?? const [])
        CatalogCategory.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    if (CloudDriveEngine.isCloudSource(source)) {
      final engine = await _cloudDriveEngine();
      return engine.catalog(
        source: source,
        page: page,
        query: query,
        category: category,
      );
    }
    final haijiaoGo = JarHaijiaoTakeover.goSourceForJarSite(source);
    if (haijiaoGo != null) {
      _authorize(source);
      return catalog(
        haijiaoGo,
        page: page,
        query: query,
        category: category,
        force: force,
        filters: filters,
      );
    }
    if (JarBridge.isJarSource(source)) {
      // TG 两站 1 小时目录缓存：只缓存第 1 页普通浏览；搜索、筛选、
      // 翻页一律现拉。手动强制刷新跳过读取、但照常回写——否则刷新
      // 后 1 小时内再进站会看到刷新前的旧内容。
      final jarSpec = JarBridge.specFor(source);
      final storable =
          page == 1 &&
          query.isEmpty &&
          filters.isEmpty &&
          jarSpec != null &&
          tgPostProcessAppliesToClass(jarSpec.className);
      if (storable && !force) {
        final cached = _tgCatalogCache.lookup(source, category);
        if (cached != null) return cached;
      }
      final pageResult = await _jarCall(
        source,
        (spec) => JarBridge.catalog(
          spec,
          page: page,
          query: query,
          category: category,
          filters: filters,
        ),
      );
      final CatalogPage result;
      if (category.isEmpty) {
        result = pageResult;
      } else {
        final groups = await _jarCategoryFilterGroups(source, category);
        result = groups.isEmpty
            ? pageResult
            : CatalogPage(
                pageResult.items,
                hasMore: pageResult.hasMore,
                warning: pageResult.warning,
                page: pageResult.page,
                fresh: pageResult.fresh,
                tags: pageResult.tags,
                filters: groups,
              );
      }
      if (storable) _tgCatalogCache.store(source, category, result);
      return result;
    }
    if (isJsSource(source)) {
      if (isIdjSource(source)) {
        if (query.isNotEmpty) {
          final result = await _idjCall(
            source,
            'search',
            args: {'keyword': query, 'page': page},
          );
          return IdjContract.pageFromResult(source, result, page: page);
        }
        if (category.isEmpty) {
          // 空分类拦截保留：不调 `category({id: ''})`（潮流会抛 E_ARGS），
          // 改调 `home()` 取首页内容；2048 的 home hasMore 恒 true，
          // 只取第一页、不追翻页。
          if (page > 1) {
            return CatalogPage(const [], hasMore: false, page: page);
          }
          final home = await _idjCall(source, 'home');
          return IdjContract.pageFromResult(source, home, page: page);
        }
        final result = await _idjCall(
          source,
          'category',
          args: {'id': category, 'page': page},
        );
        return IdjContract.pageFromResult(source, result, page: page);
      }
      if (query.isNotEmpty) {
        final result = await _jsCall(
          source,
          'search',
          query: query,
          page: page,
        );
        return PyContract.pageFromResult(source, result, page: page);
      }
      final result = await _jsCall(
        source,
        'category',
        category: category,
        page: page,
      );
      return PyContract.pageFromResult(source, result, page: page);
    }
    if (isPySource(source)) {
      if (isWhosLikeSource(source)) {
        return _whosCatalog(
          page: page,
          query: query,
          category: category,
          source: source,
        );
      }
      final result = await _pyCall(source, {
        'action': 'catalog',
        'page': page,
        'query': query,
        'category': category,
        'filter': filters.isNotEmpty,
        'extend': filters,
      });
      final pageResult = PyContract.pageFromResult(source, result, page: page);
      final groups = await _pyCategoryFilterGroups(source, category);
      if (groups.isEmpty) return pageResult;
      return CatalogPage(
        pageResult.items,
        hasMore: pageResult.hasMore,
        warning: pageResult.warning,
        page: pageResult.page,
        fresh: pageResult.fresh,
        tags: pageResult.tags,
        filters: groups,
      );
    }
    // 红果视频目录带筛选时走服务端多维筛选（landpage/v），不再把
    // 已拉回的列表在本机按标签过滤；站内分类（真人/漫剧/AI 剧）
    // 与题材仍走原有 category 参数，不动。小说/听书分类不走这条。
    if (source == 'hongguo' &&
        query.isEmpty &&
        filters.values.any((value) => value.isNotEmpty) &&
        !_isHongguoBookCategory(category)) {
      return _hongguoServerFilterCatalog(
        category: category,
        page: page,
        filters: filters,
      );
    }
    return CatalogPage.fromJson(
      await _read('catalog-$source', {
        'action': 'catalog',
        'source': source,
        'page': page,
        'query': query,
        'category': category,
        'force': force,
        'filters': filters,
      }),
    );
  }

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    final store = access;
    if (store != null) {
      sources = [
        for (final source in sources)
          if (store.siteVisible(source)) source,
      ];
    }
    sources = [
      for (final source in sources)
        JarHaijiaoTakeover.goSourceForJarSite(source) ?? source,
    ].toSet().toList();
    // 健康调度：按健康分降序的副本再分腿，只改发起顺序，
    // 不改结果合并语义；总开关关时 orderSources 原样返回。
    sources = SiteHealthStore.instance.orderSources(sources);
    final jarSources = sources.where(JarBridge.isJarSource).toList();
    final pyTargets = sources.where(isPySource).toList();
    final jsTargets = sources.where(isJsSource).toList();
    final rest = sources
        .where(
          (source) =>
              !JarBridge.isJarSource(source) &&
              !isPySource(source) &&
              !isJsSource(source),
        )
        .toList();
    if (jarSources.isEmpty && pyTargets.isEmpty && jsTargets.isEmpty) {
      // 纯 Go 腿：整批成败按 Go 腿口径打点，抛错语义不变。
      final watch = Stopwatch()..start();
      try {
        final page = CatalogPage.fromJson(
          await _call({
            'action': 'searchAcross',
            'sources': sources,
            'query': query,
          }),
        );
        watch.stop();
        _recordGoSearchLeg(sources, page.items, watch.elapsedMilliseconds);
        return page;
      } catch (_) {
        _recordGoSearchFailure(sources);
        rethrow;
      }
    }
    // 混合搜索：Go 核腿与 jar/py/js 腿并发跑，jar/py/js 腿内部 6 路
    // 有界并发、每站 10 秒预算。原先三腿串行、每站无预算：站一多，
    // 慢站耗时直接加总，整轮搜索能拖上几分钟；且单站异常被吞后
    // 整轮静默回空。现每腿失败只记名不抛错，失败站名挂 warning。
    final failures = <String>[];
    Future<List<Drama>> restLeg() async {
      if (rest.isEmpty) return const [];
      final watch = Stopwatch()..start();
      try {
        final corePage = CatalogPage.fromJson(
          await _call({
            'action': 'searchAcross',
            'sources': rest,
            'query': query,
          }),
        );
        watch.stop();
        _recordGoSearchLeg(rest, corePage.items, watch.elapsedMilliseconds);
        return corePage.items;
      } catch (_) {
        failures.addAll(rest);
        _recordGoSearchFailure(rest);
        return const [];
      }
    }

    final legs = <({String source, Future<CatalogPage> Function() run})>[
      for (final source in jarSources)
        (
          source: source,
          run: () =>
              _jarCall(source, (spec) => JarBridge.catalog(spec, query: query)),
        ),
      for (final target in pyTargets)
        (source: target, run: () => catalog(target, query: query)),
      for (final target in jsTargets)
        (source: target, run: () => catalog(target, query: query)),
    ];
    final restFuture = restLeg();
    final legsFuture = fanoutOrdered(legs, (leg) async {
      final watch = Stopwatch()..start();
      try {
        final page = await leg.run().timeout(_searchPerSiteTimeout);
        watch.stop();
        SiteHealthStore.instance.recordSearch(
          leg.source,
          ok: true,
          items: page.items.length,
          elapsedMs: watch.elapsedMilliseconds,
        );
        return page.items;
      } catch (_) {
        watch.stop();
        SiteHealthStore.instance.recordSearch(
          leg.source,
          ok: false,
          elapsedMs: watch.elapsedMilliseconds,
        );
        failures.add(leg.source);
        return const <Drama>[];
      }
    }, concurrency: 6);
    final items = <Drama>[...await restFuture];
    for (final pageItems in await legsFuture) {
      items.addAll(pageItems);
    }
    return CatalogPage(
      items,
      fresh: true,
      warning: searchAcrossFailureWarning(failures),
    );
  }

  @override
  Future<void> searchAcrossProgressive(
    List<String> sources,
    String query, {
    required void Function(String source, List<Drama> items) onSite,
    bool Function()? shouldStop,
  }) async {
    // 站源过滤与腿划分与 searchAcross 同款（两处各写一份，批回
    // 语义一字不动；改划分时两处一起改）。
    final store = access;
    if (store != null) {
      sources = [
        for (final source in sources)
          if (store.siteVisible(source)) source,
      ];
    }
    sources = {
      for (final source in sources)
        JarHaijiaoTakeover.goSourceForJarSite(source) ?? source,
    }.toList();
    // 健康调度同 searchAcross：只改发起顺序，渐进显示仍先回先上屏。
    sources = SiteHealthStore.instance.orderSources(sources);
    final jarSources = sources.where(JarBridge.isJarSource).toList();
    final pyTargets = sources.where(isPySource).toList();
    final jsTargets = sources.where(isJsSource).toList();
    final rest = sources
        .where(
          (source) =>
              !JarBridge.isJarSource(source) &&
              !isPySource(source) &&
              !isJsSource(source),
        )
        .toList();
    if (shouldStop != null && shouldStop()) return;
    if (jarSources.isEmpty && pyTargets.isEmpty && jsTargets.isEmpty) {
      // 纯 Go 腿：Go 侧一次整批回，拆包后按站回调；抛错语义与
      // 批回 searchAcross 一致（上抛，调用方记本腿失败）。在途
      // 调用无法撤回，停了也只能等它回完、结果不写回。
      final watch = Stopwatch()..start();
      try {
        final corePage = CatalogPage.fromJson(
          await _call({
            'action': 'searchAcross',
            'sources': sources,
            'query': query,
          }),
        );
        watch.stop();
        _recordGoSearchLeg(sources, corePage.items, watch.elapsedMilliseconds);
        _emitSiteItems(corePage.items, onSite, shouldStop);
        return;
      } catch (_) {
        _recordGoSearchFailure(sources);
        rethrow;
      }
    }
    // 混合搜索：Go 腿与 jar/py/js 腿并发跑；jar/py/js 腿逐站回调
    // 先出，Go 腿整批结果后到时再按站追加。单站失败只丢该站不
    // 抛错（与批回同口径；流式无处挂 warning，失败站静默丢弃，
    // 页面只看结果条目）。
    Future<List<Drama>> restLeg() async {
      if (rest.isEmpty) return const [];
      final watch = Stopwatch()..start();
      try {
        final corePage = CatalogPage.fromJson(
          await _call({
            'action': 'searchAcross',
            'sources': rest,
            'query': query,
          }),
        );
        watch.stop();
        _recordGoSearchLeg(rest, corePage.items, watch.elapsedMilliseconds);
        return corePage.items;
      } catch (_) {
        _recordGoSearchFailure(rest);
        return const [];
      }
    }

    final legs = <({String source, Future<CatalogPage> Function() run})>[
      for (final source in jarSources)
        (
          source: source,
          run: () =>
              _jarCall(source, (spec) => JarBridge.catalog(spec, query: query)),
        ),
      for (final target in pyTargets)
        (source: target, run: () => catalog(target, query: query)),
      for (final target in jsTargets)
        (source: target, run: () => catalog(target, query: query)),
    ];
    final restFuture = restLeg();
    await fanoutEach(
      legs,
      (leg) async {
        final watch = Stopwatch()..start();
        try {
          final page = await leg.run().timeout(_searchPerSiteTimeout);
          watch.stop();
          SiteHealthStore.instance.recordSearch(
            leg.source,
            ok: true,
            items: page.items.length,
            elapsedMs: watch.elapsedMilliseconds,
          );
          return page.items;
        } catch (_) {
          watch.stop();
          SiteHealthStore.instance.recordSearch(
            leg.source,
            ok: false,
            elapsedMs: watch.elapsedMilliseconds,
          );
          return const <Drama>[];
        }
      },
      onResult: (leg, items) {
        if (items.isNotEmpty) onSite(leg.source, items);
      },
      concurrency: 6,
      shouldStop: shouldStop,
    );
    // 取消后不再等 Go 腿：restLeg 内部已吞错，悬空的 Future 只会
    // 正常完成，不留未处理错误；结果不写回。
    if (shouldStop != null && shouldStop()) return;
    final restItems = await restFuture;
    _emitSiteItems(restItems, onSite, shouldStop);
  }

  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async {
    final haijiaoGo = JarHaijiaoTakeover.goSourceForJarSite(source);
    if (haijiaoGo != null) {
      return cached(haijiaoGo, category: category);
    }
    if (JarBridge.isJarSource(source) ||
        isPySource(source) ||
        isJsSource(source)) {
      return CatalogPage(const []);
    }
    return CatalogPage.fromJson(
      await _call({'action': 'cached', 'source': source, 'category': category}),
    );
  }

  Future<String> _pyCover(Drama drama, {bool force = false}) async {
    _authorize(drama.source);
    final url = drama.cover.trim();
    if (url.isEmpty) throw AppFailure('海报暂不可用');
    final fetchUrl = url.startsWith('proxy://')
        ? await _pyProxyLocalUrl(drama.source, url)
        : url;
    if (!fetchUrl.startsWith('http://') && !fetchUrl.startsWith('https://')) {
      throw AppFailure('该站海报需经蜘蛛代理取图，暂未接入');
    }
    final directory = await getApplicationSupportDirectory();
    final cacheDir = Directory(path.join(directory.path, 'py_covers'));
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    final file = File(
      path.join(cacheDir.path, '${sha1.convert(utf8.encode(url))}.img'),
    );
    if (!force && await file.exists() && await file.length() > 0) {
      // 命中磁盘缓存：先过一遍 base64 归一（旧版把 base64 文本原样
      // 存盘，Image 解不出来；归一后改写文件自愈，不用用户手动清缓存）。
      final cached = await file.readAsBytes();
      final normalized = normalizeCoverBytes(cached);
      if (!identical(normalized, cached)) {
        await file.writeAsBytes(normalized, flush: true);
      }
      return file.path;
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(fetchUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw AppFailure('海报下载失败（HTTP ${response.statusCode}）');
      }
      final bytes = await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      if (bytes.isEmpty) throw AppFailure('海报暂不可用');
      await file.writeAsBytes(normalizeCoverBytes(bytes), flush: true);
      return file.path;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async {
    final haijiaoGo = JarHaijiaoTakeover.goSourceForJarSite(drama.source);
    if (haijiaoGo != null) {
      try {
        return await cover(
          JarHaijiaoTakeover.remapDrama(drama, haijiaoGo),
          force: force,
        );
      } catch (_) {
        return _jarCall(drama.source, (_) => JarBridge.coverFile(drama));
      }
    }
    if (JarBridge.isJarSource(drama.source)) {
      return _jarCall(drama.source, (_) => JarBridge.coverFile(drama));
    }
    if (isPySource(drama.source) || isJsSource(drama.source)) {
      return _pyCover(drama, force: force);
    }
    final epoch = access?.profileEpoch;
    final result = await _call({
      'action': 'cover',
      'drama': drama.toJson(),
      'force': force,
    });
    final file = result['path'] as String? ?? '';
    if (file.isEmpty) throw AppFailure('海报暂不可用');
    if (result['heic'] != true) return file;
    final converted = await _coverDecoder.convert(
      file,
      () => _call({'action': 'prepareCover', 'drama': drama.toJson()}),
      force: force,
    );
    _authorize(drama.source);
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    return converted;
  }

  /// 详情健康打点包装：最终成败以对外返回为准只记一次；内部
  /// 分支（含 haijiao 回退递归）走 [_detailImpl] 不重复记。
  @override
  Future<DramaDetail> detail(Drama drama) async {
    final watch = Stopwatch()..start();
    try {
      final result = await _detailImpl(drama);
      watch.stop();
      SiteHealthStore.instance.recordDetail(
        drama.source,
        ok: true,
        elapsedMs: watch.elapsedMilliseconds,
      );
      return result;
    } catch (_) {
      watch.stop();
      SiteHealthStore.instance.recordDetail(
        drama.source,
        ok: false,
        elapsedMs: watch.elapsedMilliseconds,
      );
      rethrow;
    }
  }

  Future<DramaDetail> _detailImpl(Drama drama) async {
    if (CloudDriveEngine.isCloudSource(drama.source)) {
      final engine = await _cloudDriveEngine();
      return engine.detail(drama);
    }
    // ZakaTgMovie 壳侧归拢组（shelltg| id）：jar 侧没有标题归拢，
    // 详情由壳侧合成（会话缓存 → 站内搜索回捞），不进 jar 详情。
    if (tgIsShellGroupId(drama.id) &&
        JarBridge.specFor(drama.source)?.className == tgMovieAmnsClass) {
      return tgSynthesizeMovieGroupDetail(
        drama: drama,
        search: (query) => catalog(drama.source, query: query),
      );
    }
    final haijiaoGo = JarHaijiaoTakeover.goSourceForJarSite(drama.source);
    if (haijiaoGo != null) {
      try {
        return await _detailImpl(JarHaijiaoTakeover.remapDrama(drama, haijiaoGo));
      } catch (_) {
        return _jarCall(drama.source, (spec) => JarBridge.detail(spec, drama));
      }
    }
    if (JarBridge.isJarSource(drama.source)) {
      return _jarCall(drama.source, (spec) => JarBridge.detail(spec, drama));
    }
    if (isPySource(drama.source)) {
      if (isWhosLocalDrama(drama)) {
        final work = await _whosLocalWork(drama);
        if (work != null) return whosLocalDetail(drama, work);
      }
      final vodId = isWhosLocalDrama(drama)
          ? whosLocalWorkIdOf(drama)
          : drama.sourceId.isNotEmpty
          ? drama.sourceId
          : drama.id.startsWith('${drama.source}:')
          ? drama.id.substring(drama.source.length + 1)
          : drama.id;
      try {
        final result = await _pyCall(drama.source, {
          'action': 'detail',
          'vodId': vodId,
        });
        final detail = PyContract.detailFromResult(drama.source, drama, result);
        if (detail.episodes.isNotEmpty || !isWhosLikeSource(drama.source)) {
          return detail;
        }
        final work = await _whosLocalWork(drama);
        if (work != null) return whosLocalDetail(drama, work);
        return detail;
      } catch (error) {
        final work = isWhosLikeSource(drama.source)
            ? await _whosLocalWork(drama)
            : null;
        if (work != null) return whosLocalDetail(drama, work);
        rethrow;
      }
    }
    if (isJsSource(drama.source)) {
      final vodId = drama.sourceId.isNotEmpty
          ? drama.sourceId
          : drama.id.startsWith('${drama.source}:')
          ? drama.id.substring(drama.source.length + 1)
          : drama.id;
      if (isIdjSource(drama.source)) {
        final result = await _idjCall(
          drama.source,
          'detail',
          args: {'id': vodId},
        );
        return IdjContract.detailFromResult(drama.source, drama, result);
      }
      final result = await _jsCall(drama.source, 'detail', vodId: vodId);
      return PyContract.detailFromResult(drama.source, drama, result);
    }
    return DramaDetail.fromJson(
      await _call({'action': 'detail', 'drama': drama.toJson()}),
    );
  }

  String _cleanHongguoVideoId(String raw) {
    var value = raw.trim();
    if (value.isEmpty ||
        value.contains('://') ||
        value.contains('/') ||
        value.contains('?') ||
        value.contains('&')) {
      return '';
    }
    if (value.startsWith('hg-episode-v1:')) {
      value = value.substring('hg-episode-v1:'.length);
    }
    if (value.startsWith('vm:')) {
      value = value.substring(3);
    } else if (value.startsWith('raw:')) {
      value = value.substring(4);
    }
    final colon = value.indexOf(':');
    if (colon >= 0) {
      final head = value.substring(0, colon);
      if (!RegExp(r'^(2160|1440|1080|720|576|540|480|360)$').hasMatch(head)) {
        return '';
      }
      value = value.substring(colon + 1);
    }
    if (value.isEmpty || !RegExp(r'^[0-9]+$').hasMatch(value)) return '';
    return value;
  }

  Future<PlaybackPlan?> _tryGoHongguoPlan(
    Drama drama,
    Episode episode, {
    required int quality,
    required int route,
    required bool adBlock,
    bool force = false,
  }) async {
    final site = SourceSite.importedSites[drama.source];
    if (site == null) return null;
    if (!site.name.contains('红果') &&
        !drama.source.toLowerCase().contains('hongguo')) {
      return null;
    }
    final videoId = _cleanHongguoVideoId(
      episode.raw['id'] as String? ?? episode.id,
    );
    if (videoId.isEmpty) return null;
    var seriesId = drama.sourceId.isNotEmpty ? drama.sourceId : drama.id;
    final seriesColon = seriesId.lastIndexOf(':');
    if (seriesColon >= 0) seriesId = seriesId.substring(seriesColon + 1);
    if (seriesId.isEmpty || !RegExp(r'^[0-9]+$').hasMatch(seriesId)) {
      return null;
    }
    try {
      final parseApis = await ParseInterfaceStore.loadEnabled();
      final nativeDrama = Drama(
        id: 'hongguo:$seriesId',
        source: 'hongguo',
        sourceId: seriesId,
        title: drama.title,
        description: drama.description,
        cover: drama.cover,
      );
      final plan = PlaybackPlan.fromJson(
        await _call({
          'action': 'resolve',
          'drama': nativeDrama.toJson(),
          'chapter': {
            'id': videoId,
            'title': episode.title,
            'videoUrl': 'hongguo-cenc://$videoId',
            'currentEpisode': episode.number,
          },
          'index': episode.number,
          'quality': quality,
          'route': route,
          'adBlock': adBlock,
          if (force) 'force': true,
          'parseApis': [for (final api in parseApis) api.url],
          'parseApiHeaders': [for (final api in parseApis) api.headers],
          'sequence': ++_playbackSequence,
        }),
      );
      if (plan.url.isEmpty) return null;
      return plan;
    } catch (_) {
      return null;
    }
  }

  /// 播放健康打点包装：只记「取流成败」，不记播放器起播后的
  /// 卡顿（那是 PlaybackHealth 的事）；内部递归走 [_resolveImpl]。
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async {
    final watch = Stopwatch()..start();
    try {
      final plan = await _resolveImpl(
        drama,
        episode,
        quality: quality,
        route: route,
        adBlock: adBlock,
      );
      watch.stop();
      SiteHealthStore.instance.recordPlay(drama.source, ok: true);
      return plan;
    } catch (_) {
      SiteHealthStore.instance.recordPlay(drama.source, ok: false);
      rethrow;
    }
  }

  Future<PlaybackPlan> _resolveImpl(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async {
    if (CloudDriveEngine.isCloudSource(drama.source)) {
      final engine = await _cloudDriveEngine();
      return engine.resolve(drama, episode);
    }
    final haijiaoGo = JarHaijiaoTakeover.goSourceForJarSite(drama.source);
    if (haijiaoGo != null) {
      try {
        return await _resolveImpl(
          JarHaijiaoTakeover.remapDrama(drama, haijiaoGo),
          episode,
          quality: quality,
          route: route,
          adBlock: adBlock,
        );
      } catch (_) {
        return _jarCall(
          drama.source,
          (spec) => _jarResolve(spec, drama, episode),
        );
      }
    }
    if (JarBridge.isJarSource(drama.source)) {
      return _jarCall(
        drama.source,
        (spec) => _jarResolve(spec, drama, episode),
      );
    }
    if (isPySource(drama.source)) {
      final goPlan = await _tryGoHongguoPlan(
        drama,
        episode,
        quality: quality,
        route: route,
        adBlock: adBlock,
      );
      if (goPlan != null) return goPlan;
      if (isWhosLocalDrama(drama)) {
        final direct = await _whosLocalPlan(drama, episode);
        if (direct != null) return direct;
      }
      try {
        return await _pyResolvePlan(
          drama.source,
          episode.raw['flag'] as String? ?? '',
          episode.raw['id'] as String? ?? episode.id,
        );
      } catch (error) {
        if (!isWhosLikeSource(drama.source)) rethrow;
        final direct = await _whosLocalPlan(drama, episode);
        if (direct != null) return direct;
        rethrow;
      }
    }
    if (isJsSource(drama.source)) {
      if (isIdjSource(drama.source)) {
        // play 传参：只传 `flag`（线路显示名）与 `playId`（分集键），
        // Go 侧 `idjParseArg` 组装 `play({id: episodeId, episodeId,
        // line})`。不这样传橙果 / 爱果会恒播第 1 集、潮流会丢线路选择。
        final playId = episode.raw['id'] as String? ?? episode.id;
        final manifest = await _idjManifest(drama.source);
        final result = await _idjCall(
          drama.source,
          'player',
          args: {
            'flag': episode.raw['flag'] as String? ?? '',
            'playId': playId,
          },
        );
        return IdjContract.planFromResult(
          result,
          mediaAllowlist: manifest.mediaDomains,
        );
      }
      final result = await _jsCall(
        drama.source,
        'player',
        flag: episode.raw['flag'] as String? ?? '',
        playId: episode.raw['id'] as String? ?? episode.id,
      );
      final plan = PyContract.planFromResult(result);
      if (plan.url.isEmpty) {
        throw AppFailure('JS 蜘蛛取流未返回可播放地址');
      }
      return plan;
    }
    final parseApis = await ParseInterfaceStore.loadEnabled();
    return PlaybackPlan.fromJson(
      await _call({
        'action': 'resolve',
        'drama': drama.toJson(),
        'chapter': episode.raw,
        'index': episode.number,
        'quality': quality,
        'route': route,
        'adBlock': adBlock,
        'parseApis': [for (final api in parseApis) api.url],
        'parseApiHeaders': [for (final api in parseApis) api.headers],
        'sequence': ++_playbackSequence,
      }),
    );
  }

  @override
  Future<PlaybackPlan> resolveParse(
    PlaybackPlan plan,
    List<ParseInterface> apis,
  ) async {
    final resolved = PlaybackPlan.fromJson(
      await _call({
        'action': 'resolveParse',
        'url': plan.url,
        'headers': plan.headers,
        'parseApis': [for (final api in apis) api.url],
        'parseApiHeaders': [for (final api in apis) api.headers],
        'adBlock': true,
        'sequence': ++_playbackSequence,
      }),
    );
    return resolved.withHeaders({...plan.headers, ...resolved.headers});
  }

  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async =>
      PlaybackPlan.fromJson(
        await _call({
          'action': 'fallback',
          'session': current.session,
          'sequence': ++_playbackSequence,
        }),
      );
  @override
  Future<PlaybackPlan> selectRoute(PlaybackPlan current, int route) async =>
      PlaybackPlan.fromJson(
        await _call({
          'action': 'selectRoute',
          'session': current.session,
          'route': route,
          'sequence': ++_playbackSequence,
        }),
      );
  @override
  Future<void> cancelPlayback() async {
    await _call({'action': 'cancelPlayback', 'sequence': ++_playbackSequence});
  }

  @override
  bool get supportsDownloads => access?.canDownload ?? true;

  @override
  Future<List<DownloadJob>> downloads() async {
    final result = await _call({'action': 'downloads'});
    return (result['jobs'] as List? ?? [])
        .whereType<Map>()
        .map((value) => DownloadJob.fromJson(Map<String, dynamic>.from(value)))
        .where(
          (job) =>
              SourceSite.isAvailable(job.drama.source) &&
              (access == null || access!.allowsSource(job.drama.source)),
        )
        .toList();
  }

  @override
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    _authorize(detail.drama.source, download: true);
    final epoch = access?.profileEpoch;
    await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    final result = await _call({
      'action': 'enqueueDownloads',
      'drama': detail.drama.toJson(),
      'quality': quality,
      'entries': episodes
          .map((episode) => {'chapter': episode.raw, 'index': episode.number})
          .toList(),
    });
    return intValue(result['added']);
  }

  @override
  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    _authorize(detail.drama.source, download: true);
    final epoch = access?.profileEpoch;
    await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    final result = await _call({
      'action': 'enqueueDownloads',
      'force': true,
      'drama': detail.drama.toJson(),
      'quality': quality,
      'entries': episodes
          .map((episode) => {'chapter': episode.raw, 'index': episode.number})
          .toList(),
    });
    return intValue(result['added']);
  }

  @override
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids, {
    Map<String, String> expectedVersions = const {},
  }) async {
    _downloadPermission();
    final epoch = access?.profileEpoch;
    if (ids.isEmpty || ids.length > 500) throw AppFailure('每批请选择 1 至 500 个任务');
    final visible = (await downloads()).map((job) => job.id).toSet();
    if (ids.any((id) => !visible.contains(id))) {
      throw AppFailure('部分任务已删除或当前用户无权操作，请刷新');
    }
    if (command == 'resume') await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    return DownloadBatchResult.fromJson(
      await _call({
        'action': 'controlDownloadBatch',
        'command': command,
        'jobIds': ids,
        if (expectedVersions.isNotEmpty) 'expectedVersions': expectedVersions,
      }),
    );
  }

  Future<bool> refreshHongguoDevice() async {
    try {
      final result = await _call({'action': 'hongguoRefresh'});
      return result['rotated'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> controlDownloads(String command, {String id = ''}) async {
    _downloadPermission();
    if (command == 'resume' || command == 'resumeAll') {
      await BackgroundDownloads.ensureStarted();
    }
    if (access != null && !access!.profile.admin) {
      final visible = await downloads();
      if (command == 'pauseAll' || command == 'resumeAll') {
        for (final job in visible.where(
          (job) => command == 'pauseAll' ? job.active : job.resumable,
        )) {
          await _call({
            'action': 'controlDownloads',
            'command': command == 'pauseAll' ? 'pause' : 'resume',
            'jobId': job.id,
          });
        }
        return;
      }
      if (!visible.any((job) => job.id == id)) {
        throw AppFailure('当前用户没有此下载任务权限');
      }
    }
    await _call({
      'action': 'controlDownloads',
      'command': command,
      'jobId': id,
    });
  }

  @override
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async {
    final result = await _call({
      'action': 'localPlayback',
      'drama': drama.toJson(),
      'index': episode.number,
    });
    if ((result['url'] as String? ?? '').isEmpty) return null;
    return PlaybackPlan.fromJson(result);
  }

  @override
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async {
    final haijiaoGo = JarHaijiaoTakeover.goSourceForJarSite(drama.source);
    if (haijiaoGo != null) {
      try {
        return await resolveOnline(
          JarHaijiaoTakeover.remapDrama(drama, haijiaoGo),
          episode,
          quality: quality,
          route: route,
          adBlock: adBlock,
        );
      } catch (_) {
        return _jarCall(
          drama.source,
          (spec) => _jarResolve(spec, drama, episode),
        );
      }
    }
    if (JarBridge.isJarSource(drama.source)) {
      return _jarCall(
        drama.source,
        (spec) => _jarResolve(spec, drama, episode),
      );
    }
    if (isPySource(drama.source)) {
      final goPlan = await _tryGoHongguoPlan(
        drama,
        episode,
        quality: quality,
        route: route,
        adBlock: adBlock,
        force: true,
      );
      if (goPlan != null) return goPlan;
      return _pyResolvePlan(
        drama.source,
        episode.raw['flag'] as String? ?? '',
        episode.raw['id'] as String? ?? episode.id,
      );
    }
    if (isJsSource(drama.source)) {
      if (isIdjSource(drama.source)) {
        // play 传参：只传 `flag`（线路显示名）与 `playId`（分集键），
        // Go 侧 `idjParseArg` 组装 `play({id: episodeId, episodeId,
        // line})`。不这样传橙果 / 爱果会恒播第 1 集、潮流会丢线路选择。
        final playId = episode.raw['id'] as String? ?? episode.id;
        final manifest = await _idjManifest(drama.source);
        final result = await _idjCall(
          drama.source,
          'player',
          args: {
            'flag': episode.raw['flag'] as String? ?? '',
            'playId': playId,
          },
        );
        return IdjContract.planFromResult(
          result,
          mediaAllowlist: manifest.mediaDomains,
        );
      }
      final result = await _jsCall(
        drama.source,
        'player',
        flag: episode.raw['flag'] as String? ?? '',
        playId: episode.raw['id'] as String? ?? episode.id,
      );
      final plan = PyContract.planFromResult(result);
      if (plan.url.isEmpty) {
        throw AppFailure('JS 蜘蛛取流未返回可播放地址');
      }
      return plan;
    }
    final parseApis = await ParseInterfaceStore.loadEnabled();
    return PlaybackPlan.fromJson(
      await _call({
        'action': 'resolve',
        'drama': drama.toJson(),
        'chapter': episode.raw,
        'index': episode.number,
        'quality': quality,
        'route': route,
        'adBlock': adBlock,
        'force': true,
        'parseApis': [for (final api in parseApis) api.url],
        'parseApiHeaders': [for (final api in parseApis) api.headers],
        'sequence': ++_playbackSequence,
      }),
    );
  }

  @override
  Future<void> release(String session) async {
    if (session.isEmpty) {
      return;
    }
    try {
      await _call({'action': 'release', 'session': session});
    } catch (_) {}
  }
}
