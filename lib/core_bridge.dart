import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:crypto/crypto.dart';

import 'models.dart';
import 'jar_bridge.dart';
import 'jar_haijiao_takeover.dart';
import 'jar_youtube_takeover.dart';
import 'danmaku_models.dart';
import 'hongguo_comment.dart';
import 'import_file_store.dart';
import 'py_bridge.dart';
import 'py_lazy_fetch.dart';
import 'py_contract.dart';
import 'background_downloads.dart';
import 'local_store.dart';
import 'playback_parse.dart';
import 'app_build.dart';
import 'source_status.dart';
import 'ranking_models.dart';
import 'cover_decoder.dart';
import 'catalog_updates.dart';
import 'download_collections.dart';
import 'resource_settings.dart';

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
  Future<Map<String, dynamic>> lan(
    String command,
    Map<String, dynamic> payload,
  ) async => throw AppFailure('当前环境不支持设备互联');
  Future<PlaybackPlan?> prepareHandoff(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) =>
      preload(drama, episode, quality: quality, route: route, adBlock: adBlock);
  Future<void> cancelHandoff() async {}
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
  }) async =>
      throw AppFailure('当前环境不支持红果筛选');
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
  Future<List<ClearanceChallenge>> clearanceNeeded() async => const [];
  Future<void> setClearance({
    required String host,
    required String cookie,
    required String ua,
  }) async => throw AppFailure('当前环境不支持过盾回填');
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
    category == 'novel' ||
    category == 'audio' ||
    category.startsWith('bcat');

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
    return genre == 'comic_series' || genre == 'ai_series'
        ? genre!
        : 'default';
  }

  /// 会话指纹：筛选条件排好序拼起来，换筛选项即换会话。
  String get fingerprint {
    final parts = _values.entries
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

  factory HongguoDiscoveryFilterPage.fromBridgeJson(
    Map<String, dynamic> json,
  ) {
    final items = <Drama>[];
    for (final row in json['items'] as List? ?? const []) {
      if (row is! Map) continue;
      final item = Map<String, dynamic>.from(row);
      final seriesId = item['seriesId']?.toString() ?? '';
      if (seriesId.isEmpty) continue;
      final badge = item['badge']?.toString() ?? '';
      final episodeCount =
          int.tryParse(
            RegExp(r'(\d+)').firstMatch(badge)?.group(1) ?? '',
          ) ??
          0;
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
      final label =
          group['label']?.toString() ?? hongguoDiscoveryLabels[type]!;
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
  HongguoDiscoverySession({
    required this.fingerprint,
    required this.selection,
  });

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

class NativeRepository extends AppRepository {
  static final _coverDecoder = CoverDecoder();
  NativeRepository({this.background = false});
  final bool background;

  /// 红果服务端筛选会话（只放内存，不落盘）：展示名→服务端选项 id 的
  /// 索引跨会话复用，游标只跟当前筛选会话走。
  final Map<String, Map<String, String>> _hongguoFilterNameIndex = {};
  HongguoDiscoverySession? _hongguoFilterSession;

  static bool isPySource(String source) =>
      SourceSite.importedSites[source]?.importType == 'py';
  static bool isJsSource(String source) =>
      SourceSite.importedSites[source]?.importType == 'js';

  Future<String> _jsSpiderScript(String source) async {
    final fileName = SourceSite.importedJsFiles[source];
    if (fileName == null || fileName.isEmpty) {
      throw AppFailure('导入记录缺少 JS 蜘蛛文件，请在导入中心删除该站后重新导入');
    }
    final scriptPath = await ImportFileStore.pathOf(fileName);
    final scriptFile = File(scriptPath);
    if (!await scriptFile.exists()) {
      throw AppFailure('JS 蜘蛛文件已丢失，请在导入中心删除该站后重新导入');
    }
    return scriptFile.readAsString();
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
      final body = base64Decode(result['bodyBase64'] as String? ?? '');
      request.response.statusCode = result['status'] as int? ?? 200;
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        result['mime'] as String? ?? 'application/octet-stream',
      );
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

  int runningCoreBuild = 0;
  final _readOwner = DateTime.now().microsecondsSinceEpoch.toString();
  int _readSequence = 0;
  final _activeReads = <String, int>{};

  @override
  Future<Map<String, dynamic>> lan(
    String command,
    Map<String, dynamic> payload,
  ) => _call({'action': 'lan', 'command': command, 'lan': payload});

  @override
  Future<PlaybackPlan?> prepareHandoff(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async {
    final data = await _read('handoff', {
      'action': 'prepareHandoff',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'route': route,
      'adBlock': adBlock,
      'force': access != null && !access!.canDownload,
    });
    return PlaybackPlan.fromJson(data);
  }

  @override
  Future<void> cancelHandoff() => _cancelReads('handoff');

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
    return ResourceSettings.fromJson(
      await _call({
        'action': 'saveResourceSettings',
        'settings': settings.toJson(),
      }),
    );
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
        final body = session.selection.requestBody(
          cursor: session.nextCursor,
        );
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

  void _learnHongguoFilterIndex(
    Map<String, Map<String, String>> learned,
  ) {
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

  @override
  Future<List<ClearanceChallenge>> clearanceNeeded() async {
    final result = await _call({'action': 'clearanceNeeded'});
    final userAgent = result['userAgent'] as String? ?? '';
    return [
      for (final row in result['items'] as List? ?? const [])
        ClearanceChallenge.fromJson(
          Map<String, dynamic>.from(row as Map),
          userAgent,
        ),
    ];
  }

  @override
  Future<void> setClearance({
    required String host,
    required String cookie,
    required String ua,
  }) async {
    await _call({
      'action': 'setClearance',
      'host': host,
      'cookie': cookie,
      'ua': ua,
    });
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
            'updateSystemProxy',
          }.contains(action) ||
          action == 'workLease' && input['command'] == 'end' ||
          action == 'lan' &&
              {
                'stop',
                'respond',
                'cancel',
                'disconnect',
              }.contains(input['command']);
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
        'prepareHandoff',
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
      final encoded = await Isolate.run(() => _nativeRequest(body)).timeout(
        Duration(
          seconds: action == 'moveDownloads'
              ? 620
              : action == 'danmaku' || action == 'comments'
              ? 15
              : action == 'preload'
              ? 20
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
            'prepareHandoff',
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
    if (!background) {
      SystemProxyMonitor.start((value) async {
        await _call({'action': 'updateSystemProxy', 'systemProxy': value});
      });
    }
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
    if (!plan.url.startsWith('proxy://') && !plan.url.startsWith('proxy:')) {
      return plan;
    }
    try {
      final server = await _ensurePyProxyServer();
      final param = JarBridge.parseProxyParams(plan.url);
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
      final home = await _pyCall(source, {'action': 'categories'});
      return PyContract.categoriesFromHome(home);
    }
    if (isJsSource(source)) {
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
      if (category.isEmpty) return pageResult;
      final groups = await _jarCategoryFilterGroups(source, category);
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
    if (isJsSource(source)) {
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
      return CatalogPage.fromJson(
        await _call({
          'action': 'searchAcross',
          'sources': sources,
          'query': query,
        }),
      );
    }
    final items = <Drama>[];
    if (rest.isNotEmpty) {
      final corePage = CatalogPage.fromJson(
        await _call({
          'action': 'searchAcross',
          'sources': rest,
          'query': query,
        }),
      );
      items.addAll(corePage.items);
    }
    for (final source in jarSources) {
      try {
        final page = await _jarCall(
          source,
          (spec) => JarBridge.catalog(spec, query: query),
        );
        items.addAll(page.items);
      } catch (_) {}
    }
    for (final target in pyTargets) {
      try {
        final page = await catalog(target, query: query);
        items.addAll(page.items);
      } catch (_) {}
    }
    for (final target in jsTargets) {
      try {
        final page = await catalog(target, query: query);
        items.addAll(page.items);
      } catch (_) {}
    }
    return CatalogPage(items, fresh: true);
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
      await file.writeAsBytes(bytes, flush: true);
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

  @override
  Future<DramaDetail> detail(Drama drama) async {
    final haijiaoGo = JarHaijiaoTakeover.goSourceForJarSite(drama.source);
    if (haijiaoGo != null) {
      try {
        return await detail(JarHaijiaoTakeover.remapDrama(drama, haijiaoGo));
      } catch (_) {
        return _jarCall(drama.source, (spec) => JarBridge.detail(spec, drama));
      }
    }
    if (JarBridge.isJarSource(drama.source)) {
      return _jarCall(drama.source, (spec) => JarBridge.detail(spec, drama));
    }
    if (isPySource(drama.source)) {
      final vodId = drama.sourceId.isNotEmpty
          ? drama.sourceId
          : drama.id.startsWith('${drama.source}:')
          ? drama.id.substring(drama.source.length + 1)
          : drama.id;
      final result = await _pyCall(drama.source, {
        'action': 'detail',
        'vodId': vodId,
      });
      return PyContract.detailFromResult(drama.source, drama, result);
    }
    if (isJsSource(drama.source)) {
      final vodId = drama.sourceId.isNotEmpty
          ? drama.sourceId
          : drama.id.startsWith('${drama.source}:')
          ? drama.id.substring(drama.source.length + 1)
          : drama.id;
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
          'sequence': ++_playbackSequence,
        }),
      );
      if (plan.url.isEmpty) return null;
      return plan;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async {
    final haijiaoGo = JarHaijiaoTakeover.goSourceForJarSite(drama.source);
    if (haijiaoGo != null) {
      try {
        return await resolve(
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
      return _pyResolvePlan(
        drama.source,
        episode.raw['flag'] as String? ?? '',
        episode.raw['id'] as String? ?? episode.id,
      );
    }
    if (isJsSource(drama.source)) {
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
