import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'update_config.dart';
import 'update_download.dart';

class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, this.build);

  final int major;
  final int minor;
  final int patch;
  final int build;

  static final RegExp _pattern = RegExp(r'(\d+)\.(\d+)\.(\d+)(?:[+-](\d+))?');

  static AppVersion? tryParse(String text) {
    final match = _pattern.firstMatch(text);
    if (match == null) return null;
    return AppVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.tryParse(match.group(4) ?? '') ?? 0,
    );
  }

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    return build.compareTo(other.build);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;
  bool operator <(AppVersion other) => compareTo(other) < 0;
  bool operator >=(AppVersion other) => compareTo(other) >= 0;
  bool operator <=(AppVersion other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch &&
      other.build == build;

  @override
  int get hashCode => Object.hash(major, minor, patch, build);

  @override
  String toString() => '$major.$minor.$patch';
}

class AppReleaseInfo {
  const AppReleaseInfo({
    required this.version,
    required this.tag,
    required this.name,
    required this.notes,
    required this.htmlUrl,
    this.apkUrl,
    this.apkName,
    this.apkSize = 0,
    this.apkSha256 = '',
    this.forceAfter,
    this.forceUntil,
  });

  final AppVersion version;
  final String tag;
  final String name;
  final String notes;
  final String htmlUrl;
  final String? apkUrl;
  final String? apkName;
  final int apkSize;
  final String apkSha256;
  final DateTime? forceAfter;
  final DateTime? forceUntil;

  static DateTime? _parseForceDate(String value, {required bool endOfDay}) {
    if (value.isEmpty) return null;
    final dateOnly = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (dateOnly != null) {
      final year = int.parse(dateOnly.group(1)!);
      final month = int.parse(dateOnly.group(2)!);
      final day = int.parse(dateOnly.group(3)!);
      final parsed = endOfDay
          ? DateTime(year, month, day, 23, 59, 59, 999)
          : DateTime(year, month, day);
      if (parsed.year != year || parsed.month != month || parsed.day != day) {
        return null;
      }
      return parsed;
    }
    return DateTime.tryParse(value);
  }

  static (DateTime?, DateTime?) _parseForceWindow(String notes) {
    DateTime? after;
    DateTime? until;
    for (final line in notes.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('FORCE_AFTER:')) {
        after = _parseForceDate(
          trimmed.substring('FORCE_AFTER:'.length).trim(),
          endOfDay: false,
        );
      } else if (trimmed.startsWith('FORCE_UNTIL:')) {
        until = _parseForceDate(
          trimmed.substring('FORCE_UNTIL:'.length).trim(),
          endOfDay: true,
        );
      }
    }
    return (after, until);
  }

  static AppReleaseInfo? fromGithubJson(Map<String, dynamic> json) {
    final tag = json['tag_name'] as String? ?? '';
    final version =
        AppVersion.tryParse(tag) ??
        AppVersion.tryParse(json['name'] as String? ?? '');
    if (version == null) return null;
    String? apkUrl;
    String? apkName;
    var apkSize = 0;
    var apkSha256 = '';
    final assets = json['assets'];
    if (assets is List) {
      Map<String, dynamic>? chosen;
      for (final asset in assets) {
        if (asset is! Map) continue;
        final map = Map<String, dynamic>.from(asset);
        final name = (map['name'] as String? ?? '').toLowerCase();
        if (!name.endsWith('.apk')) continue;
        chosen ??= map;
        if (name.contains('arm64')) chosen = map;
      }
      if (chosen != null) {
        apkUrl = chosen['browser_download_url'] as String?;
        apkName = chosen['name'] as String?;
        apkSize = (chosen['size'] as num?)?.toInt() ?? 0;
        final digest = chosen['digest'] as String? ?? '';
        if (digest.startsWith('sha256:')) {
          apkSha256 = digest.substring('sha256:'.length).toLowerCase();
        }
      }
    }
    final notes = json['body'] as String? ?? '';
    final forceWindow = _parseForceWindow(notes);
    return AppReleaseInfo(
      version: version,
      tag: tag,
      name: json['name'] as String? ?? tag,
      notes: notes,
      htmlUrl: json['html_url'] as String? ?? releasesPageUrl ?? '',
      apkUrl: apkUrl,
      apkName: apkName,
      apkSize: apkSize,
      apkSha256: apkSha256,
      forceAfter: forceWindow.$1,
      forceUntil: forceWindow.$2,
    );
  }
}

class AppUpdateChannel {
  AppUpdateChannel._();

  static const MethodChannel _channel = MethodChannel('moyi/appupdate');

  static Future<({String versionName, int build})> appInfo() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('appInfo');
    return (
      versionName: result?['versionName'] as String? ?? '',
      build: (result?['versionCode'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<void> installApk(String apkPath) =>
      _channel.invokeMethod<void>('installApk', {'path': apkPath});

  static Future<bool> openUrl(String url) async =>
      await _channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
}

class AppUpdateChecker {
  AppUpdateChecker._();

  static const String _lastCheckKey = 'app_update_last_check_ms';
  static const String _latestKey = 'app_update_latest_version';

  static Future<AppVersion> currentVersion() async {
    final info = await AppUpdateChannel.appInfo();
    return AppVersion.tryParse(info.versionName) ??
        AppVersion(0, 0, 0, info.build);
  }

  static AppReleaseInfo? selectAppRelease(List<dynamic> releases) {
    AppReleaseInfo? best;
    for (final raw in releases) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final tag = map['tag_name'] as String? ?? '';
      if (tag.startsWith(kCoreReleaseTagPrefix)) continue;
      if (map['draft'] == true || map['prerelease'] == true) continue;
      final info = AppReleaseInfo.fromGithubJson(map);
      if (info == null) continue;
      if (best == null || info.version > best.version) best = info;
    }
    return best;
  }

  static bool isForceUpdate(
    AppVersion current,
    AppReleaseInfo latest,
    DateTime now,
  ) {
    if (latest.version <= current) return false;
    if (latest.forceAfter == null && latest.forceUntil == null) return false;
    if (latest.forceAfter != null && now.isBefore(latest.forceAfter!)) {
      return false;
    }
    if (latest.forceUntil != null && now.isAfter(latest.forceUntil!)) {
      return false;
    }
    return true;
  }

  static Future<AppReleaseInfo> fetchLatest() async {
    final url = releasesApiUrl;
    if (url == null) throw StateError('更新源未配置');
    final text = await fetchUpdateText(
      url,
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'moyi-app-update',
      },
    );
    final decoded = jsonDecode(text);
    if (decoded is! List) throw const FormatException('发布信息格式无效');
    final info = selectAppRelease(decoded);
    if (info == null) throw const FormatException('未找到整包发布');
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_latestKey, info.version.toString());
    return info;
  }

  static Future<String> cachedLatestVersion() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_latestKey) ?? '';
  }

  static Future<void> maybeCheckSilently() async {
    try {
      if (!updateSourceConfigured) return;
      final preferences = await SharedPreferences.getInstance();
      final last = preferences.getInt(_lastCheckKey) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < const Duration(hours: 24).inMilliseconds) return;
      await preferences.setInt(_lastCheckKey, now);
      final latest = await fetchLatest();
      final current = await currentVersion();
      if (latest.version > current) {
        await preferences.setString(_latestKey, latest.version.toString());
      }
    } catch (_) {}
  }

  static Future<File> downloadApk(
    AppReleaseInfo release, {
    void Function(DownloadProgress progress)? onProgress,
    ResumableDownloader? downloader,
  }) async {
    final url = release.apkUrl;
    if (url == null || release.apkName == null) {
      throw StateError('该版本没有可下载的安装包');
    }
    final support = await getApplicationSupportDirectory();
    final directory = Directory(path.join(support.path, 'app_update'));
    final target = File(path.join(directory.path, release.apkName!));
    final file = await (downloader ?? ResumableDownloader()).download(
      url: url,
      target: target,
      onProgress: onProgress,
      headers: const {'User-Agent': 'moyi-app-update'},
    );
    if (release.apkSha256.isNotEmpty) {
      final digest = await sha256.bind(file.openRead()).first;
      if (digest.toString() != release.apkSha256) {
        await file.delete();
        throw StateError('安装包校验失败（SHA-256 不符），已删除');
      }
    }
    return file;
  }
}
