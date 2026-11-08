import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'core_bridge.dart';
import 'live_http.dart';
import 'live_models.dart';
import 'live_parser.dart';

class M3uSubscription {
  const M3uSubscription({
    required this.id,
    required this.name,
    required this.kind,
    required this.channels,
    this.url = '',
    this.fileName = '',
    this.groupCount = 0,
    this.updatedAtMs = 0,
  });

  static const kindFile = 'file';
  static const kindUrl = 'url';
  static const maxChannels = 5000;

  final String id;
  final String name;
  final String kind;
  final String url;
  final String fileName;
  final int groupCount;
  final int updatedAtMs;
  final List<LiveChannel> channels;

  int get channelCount => channels.length;
  String get sourceId => 'm3u:$id';
  bool get isUrl => kind == kindUrl;

  M3uSubscription copyWith({
    String? name,
    List<LiveChannel>? channels,
    int? groupCount,
    int? updatedAtMs,
    String? fileName,
  }) => M3uSubscription(
    id: id,
    name: name ?? this.name,
    kind: kind,
    url: url,
    fileName: fileName ?? this.fileName,
    groupCount: groupCount ?? this.groupCount,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    channels: channels ?? this.channels,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'url': url,
    'fileName': fileName,
    'groupCount': groupCount,
    'updatedAtMs': updatedAtMs,
    'channels': [for (final channel in channels) channel.toFavourite()],
  };

  factory M3uSubscription.fromJson(Map<String, dynamic> json) =>
      M3uSubscription(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        kind: json['kind'] as String? ?? kindFile,
        url: json['url'] as String? ?? '',
        fileName: json['fileName'] as String? ?? '',
        groupCount: json['groupCount'] as int? ?? 0,
        updatedAtMs: json['updatedAtMs'] as int? ?? 0,
        channels: [
          for (final row in json['channels'] as List? ?? const [])
            if (row is Map)
              LiveChannel.fromFavourite(Map<String, dynamic>.from(row)),
        ],
      );
}

class M3uParseReport {
  const M3uParseReport({
    required this.groups,
    required this.badEntries,
    required this.totalEntries,
    required this.truncated,
  });

  final List<LiveGroup> groups;
  final int badEntries;
  final int totalEntries;
  final bool truncated;

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
  var groups = parsed.groups;
  var truncated = false;
  if (parsed.channelCount > M3uSubscription.maxChannels) {
    truncated = true;
    var remaining = M3uSubscription.maxChannels;
    final trimmed = <LiveGroup>[];
    for (final group in groups) {
      if (remaining <= 0) break;
      final take = group.channels.take(remaining).toList();
      remaining -= take.length;
      if (take.isNotEmpty) trimmed.add(LiveGroup(group.name, take));
    }
    groups = trimmed;
  }
  return M3uParseReport(
    groups: groups,
    badEntries: badEntries,
    totalEntries: totalEntries,
    truncated: truncated,
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
    await File('${dir.path}/$fileName').writeAsBytes(bytes, flush: true);
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
}
