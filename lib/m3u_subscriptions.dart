import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'core_bridge.dart';
import 'live_http.dart';
import 'live_models.dart';
import 'live_parser.dart';

class M3uSubscription {
  M3uSubscription({
    required this.id,
    required this.name,
    required this.kind,
    required this.channels,
    this.url = '',
    this.fileName = '',
    this.groupCount = 0,
    this.updatedAtMs = 0,
    int? channelCount,
  }) : channelCount = channelCount ?? channels.length;

  /// 原 5000 条上限已删：它会静默丢掉大文件约 85% 的条目
  ///（女优合集每份约 34447 条），且解析本身已全量跑过，
  /// 截断省不了性能；内存改由按需加载兜底（一次只留一个
  /// 订阅的频道在内存，切订阅即丢，见 LocalStore.loadM3uChannels）。

  static const kindFile = 'file';
  static const kindUrl = 'url';

  final String id;
  final String name;
  final String kind;
  final String url;
  final String fileName;
  final int groupCount;
  final int updatedAtMs;
  final List<LiveChannel> channels;

  /// 订阅的频道总数（解析出的真实条数，不随内存加载状态变）。
  /// 快照只存这个数，不存频道本身；频道按需从本地 m3u 副本重解析。
  final int channelCount;
  String get sourceId => 'm3u:$id';
  bool get isUrl => kind == kindUrl;

  M3uSubscription copyWith({
    String? name,
    List<LiveChannel>? channels,
    int? groupCount,
    int? updatedAtMs,
    String? fileName,
    int? channelCount,
  }) => M3uSubscription(
    id: id,
    name: name ?? this.name,
    kind: kind,
    url: url,
    fileName: fileName ?? this.fileName,
    groupCount: groupCount ?? this.groupCount,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    channels: channels ?? this.channels,
    // 注意：换频道列表时不自动从 channels 推导总数——“卸载”
    // 传的是空列表（表示未加载），不是 0 个频道；换列表的
    // 调用方须同时传 channelCount（加载时传解析出的条数）。
    channelCount: channelCount ?? this.channelCount,
  );

  /// 快照只写元数据：频道存在本地 m3u 副本里，用时重解析，
  /// 不再把几千上万条频道塞进 SharedPreferences 单键快照
  ///（此前每订阅 5000 条约 3MB，9 份约 28MB，超 16MB 上限
  /// 就报“本地记录超过保存上限”）。
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'url': url,
    'fileName': fileName,
    'groupCount': groupCount,
    'updatedAtMs': updatedAtMs,
    'channelCount': channelCount,
  };

  factory M3uSubscription.fromJson(Map<String, dynamic> json) {
    // 老快照兼容：旧版 toJson 写过 channels，读出来继续用，
    // 新版不再写它；下次提交时自然瘦身。
    final legacyChannels = [
      for (final row in json['channels'] as List? ?? const [])
        if (row is Map)
          LiveChannel.fromFavourite(Map<String, dynamic>.from(row)),
    ];
    return M3uSubscription(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      kind: json['kind'] as String? ?? kindFile,
      url: json['url'] as String? ?? '',
      fileName: json['fileName'] as String? ?? '',
      groupCount: json['groupCount'] as int? ?? 0,
      updatedAtMs: json['updatedAtMs'] as int? ?? 0,
      channels: legacyChannels,
      channelCount: json['channelCount'] as int? ?? legacyChannels.length,
    );
  }
}

class M3uParseReport {
  const M3uParseReport({
    required this.groups,
    required this.badEntries,
    required this.totalEntries,
  });

  final List<LiveGroup> groups;
  final int badEntries;
  final int totalEntries;

  int get channelCount =>
      groups.fold(0, (total, group) => total + group.channels.length);
  List<LiveChannel> get channels => [
    for (final group in groups) ...group.channels,
  ];
}

M3uParseReport analyzeM3u(String text, {required String source}) {
  if (text.trim().isEmpty) {
    throw const FormatException('文件为空，没有可解析的频道');
  }
  var normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  var totalEntries = 0;
  var badEntries = 0;
  final lines = normalized.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXTINF:')) continue;
    totalEntries++;
    var playable = false;
    for (var j = i + 1; j < lines.length; j++) {
      final next = lines[j].trim();
      if (next.isEmpty || next.startsWith('#')) continue;
      playable = isPlayableLiveUrl(next.split('|').first.trim());
      break;
    }
    if (!playable) badEntries++;
  }
  if (totalEntries > 0 && !normalized.trimLeft().startsWith('#EXTM3U')) {
    normalized = '#EXTM3U\n$normalized';
  }
  final parsed = LiveParser.parse(normalized, source: source);
  if (parsed.channelCount == 0) {
    throw FormatException(
      totalEntries > 0
          ? '未解析到任何频道：共 $totalEntries 条 #EXTINF，其中 $badEntries 条地址不可用，'
                '请确认文件是标准 m3u'
          : '未解析到任何频道：请确认文件是标准 m3u（含 #EXTINF 与播放地址）',
    );
  }
  // 不再截断：见 M3uSubscription 上的说明。
  return M3uParseReport(
    groups: parsed.groups,
    badEntries: badEntries,
    totalEntries: totalEntries,
  );
}

class M3uFileStore {
  M3uFileStore._();

  static Future<Directory> directory() async {
    final documents = await getApplicationDocumentsDirectory();
    final dir = Directory('${documents.path}/m3u_subscriptions');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<String> save(String id, List<int> bytes) async {
    final dir = await directory();
    final safeId = id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final fileName = '$safeId.m3u';
    // 先写临时文件再改名：原先直接覆盖目标文件，写一半被中断会
    // 留下截断的副本，后续刷新读到残文件直接报解析失败。
    final temp = File(
      '${dir.path}/.$fileName.tmp${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename('${dir.path}/$fileName');
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
      rethrow;
    }
    return fileName;
  }

  static Future<String> readText(String fileName) async {
    final dir = await directory();
    final file = File('${dir.path}/$fileName');
    if (!await file.exists()) {
      throw AppFailure('本地 m3u 副本不存在，请删除该订阅后重新导入');
    }
    return file.readAsString();
  }

  static Future<void> delete(String fileName) async {
    if (fileName.isEmpty) return;
    final dir = await directory();
    final file = File('${dir.path}/$fileName');
    if (await file.exists()) await file.delete();
  }
}

class M3uSubscriptionService {
  M3uSubscriptionService._();

  static String newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  static Future<String> fetchText(String url) async {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('订阅地址无效：$url');
    }
    final http = LiveHttp();
    try {
      return await http.get(trimmed);
    } catch (error) {
      throw AppFailure('拉取订阅失败：$error');
    } finally {
      http.close();
    }
  }

  static Future<M3uSubscription> build({
    required String name,
    required String kind,
    required String text,
    required List<int> rawBytes,
    String url = '',
    String? existing,
  }) async {
    final id = existing ?? newId();
    final report = analyzeM3u(text, source: 'm3u:$id');
    final fileName = await M3uFileStore.save(id, rawBytes);
    return M3uSubscription(
      id: id,
      name: name.trim().isEmpty ? '未命名订阅' : name.trim(),
      kind: kind,
      url: url,
      fileName: fileName,
      groupCount: report.groups.length,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      channels: report.channels,
    );
  }

  /// 按需取频道：内存里有就直接用，没有就读本地 m3u 副本重解析。
  /// 无副本（极老订阅或副本被删）且内存也没有时报 AppFailure，
  /// 调用方提示用户删掉重导。force 时跳过内存里的旧列表重读文件。
  static Future<List<LiveChannel>> loadChannels(
    M3uSubscription sub, {
    bool force = false,
  }) async {
    if (!force && sub.channels.isNotEmpty) return sub.channels;
    if (sub.fileName.isEmpty) {
      throw AppFailure('本地 m3u 副本不存在，请删除该订阅后重新导入');
    }
    final text = await M3uFileStore.readText(sub.fileName);
    return analyzeM3u(text, source: sub.sourceId).channels;
  }
}
