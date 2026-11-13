import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'mini_app_manifest.dart';

class MiniAppStore {
  MiniAppStore({Directory? rootOverride, http.Client? httpClient}) {
    _rootOverride = rootOverride;
    _httpClient = httpClient;
  }

  Directory? _rootOverride;
  http.Client? _httpClient;

  Future<Directory> get root async {
    final override = _rootOverride;
    if (override != null) return override;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'miniapps'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<List<MiniAppManifest>> listInstalled() async {
    final base = await root;
    if (!await base.exists()) return const [];
    final items = <MiniAppManifest>[];
    await for (final entity in base.list()) {
      if (entity is! Directory) continue;
      final manifest = await readManifest(entity);
      if (manifest != null && manifest.isValid) items.add(manifest);
    }
    items.sort((a, b) => a.name.compareTo(b.name));
    return items;
  }

  Future<MiniAppManifest?> readManifest(Directory dir) async {
    final file = File(p.join(dir.path, 'manifest.json'));
    if (!await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return MiniAppManifest.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<Directory?> installedDir(String appId) async {
    final base = await root;
    final dir = Directory(p.join(base.path, appId));
    if (!await dir.exists()) return null;
    return dir;
  }

  Future<MiniAppManifest> installFromZipBytes(
    List<int> bytes, {
    String? expectedMd5,
  }) async {
    if (expectedMd5 != null && expectedMd5.isNotEmpty) {
      final actual = md5.convert(bytes).toString();
      if (actual != expectedMd5.toLowerCase()) {
        throw const FormatException('安装包校验失败：md5 不一致');
      }
    }
    final archive = ZipDecoder().decodeBytes(bytes);
    return _installArchive(archive);
  }

  Future<MiniAppManifest> installFromZipFile(
    File file, {
    String? expectedMd5,
  }) async {
    return installFromZipBytes(await file.readAsBytes(), expectedMd5: expectedMd5);
  }

  Future<MiniAppManifest> installFromUrl(
    String url, {
    String? expectedMd5,
    int? expectedSize,
  }) async {
    final client = _httpClient ?? http.Client();
    try {
      final response = await client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        throw HttpException('下载安装包失败：HTTP ${response.statusCode}');
      }
      if (expectedSize != null &&
          response.bodyBytes.length != expectedSize) {
        throw const FormatException('安装包校验失败：大小不一致');
      }
      final manifest = await installFromZipBytes(
        response.bodyBytes,
        expectedMd5: expectedMd5,
      );
      return manifest;
    } finally {
      if (_httpClient == null) client.close();
    }
  }

  Future<MiniAppManifest> installFromDirectory(Directory source) async {
    final manifest = await readManifest(source);
    if (manifest == null || !manifest.isValid) {
      throw const FormatException('文件夹里没有合法的 manifest.json');
    }
    final base = await root;
    final target = Directory(p.join(base.path, manifest.appId));
    final staging = Directory(
      p.join(base.path, '.staging-${manifest.appId}'),
    );
    if (await staging.exists()) await staging.delete(recursive: true);
    await _copyDirectory(source, staging);
    return _promote(staging, target, manifest);
  }

  /// 只带一份 manifest.json 的小程序（manifest-only 在线站点型）：
  /// 落盘只写 manifest.json，不解包。内置播种用，与火蚁TV 同款。
  Future<MiniAppManifest> installFromManifestJson(
    String manifestJson,
  ) async {
    final decoded = jsonDecode(manifestJson);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('manifest.json 不合法');
    }
    final manifest = MiniAppManifest.fromJson(decoded);
    if (!manifest.isValid) {
      throw const FormatException('manifest.json 不合法');
    }
    final base = await root;
    final target = Directory(p.join(base.path, manifest.appId));
    if (await target.exists()) await target.delete(recursive: true);
    await target.create(recursive: true);
    await File(
      p.join(target.path, 'manifest.json'),
    ).writeAsString(jsonEncode(manifest.toJson()));
    return manifest;
  }

  Future<MiniAppManifest> _installArchive(Archive archive) async {
    for (final entry in archive.files) {
      if (!isSafeZipEntryName(entry.name)) {
        throw FormatException('安装包里有非法路径：${entry.name}');
      }
    }
    final manifestEntry = _findManifestEntry(archive);
    if (manifestEntry == null) {
      throw const FormatException('安装包里没有 manifest.json');
    }
    final prefix = _commonPrefix(manifestEntry.name);
    final manifest = _parseManifestBytes(manifestEntry.content as List<int>);
    if (manifest == null || !manifest.isValid) {
      throw const FormatException('安装包里的 manifest.json 不合法');
    }
    final base = await root;
    final staging = Directory(
      p.join(base.path, '.staging-${manifest.appId}'),
    );
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    for (final entry in archive.files) {
      if (entry.isFile == false) continue;
      final relative = prefix.isEmpty
          ? entry.name
          : entry.name.substring(prefix.length);
      if (relative.isEmpty) continue;
      final targetPath = safeJoinPath(staging.path, relative);
      if (targetPath == null) {
        throw FormatException('安装包里有非法路径：${entry.name}');
      }
      final target = File(targetPath);
      await target.parent.create(recursive: true);
      await target.writeAsBytes(entry.content as List<int>);
    }
    final target = Directory(p.join(base.path, manifest.appId));
    return _promote(staging, target, manifest);
  }

  Future<MiniAppManifest> _promote(
    Directory staging,
    Directory target,
    MiniAppManifest manifest,
  ) async {
    if (await target.exists()) await target.delete(recursive: true);
    await staging.rename(target.path);
    return manifest;
  }

  Future<void> deleteApp(String appId) async {
    final dir = await installedDir(appId);
    if (dir != null) await dir.delete(recursive: true);
  }

  ArchiveFile? _findManifestEntry(Archive archive) {
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final name = entry.name.replaceAll('\\', '/');
      if (name == 'manifest.json' || name.endsWith('/manifest.json')) {
        return entry;
      }
    }
    return null;
  }

  String _commonPrefix(String manifestName) {
    final name = manifestName.replaceAll('\\', '/');
    final index = name.lastIndexOf('/');
    if (index < 0) return '';
    return name.substring(0, index + 1);
  }

  MiniAppManifest? _parseManifestBytes(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) return null;
      return MiniAppManifest.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entity in source.list(recursive: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(p.join(target.path, name)));
      } else if (entity is File) {
        await entity.copy(p.join(target.path, name));
      }
    }
  }
}
