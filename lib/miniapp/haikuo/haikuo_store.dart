import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'haikuo_codec.dart';
import 'haikuo_program.dart';

/// 海阔小程序的本地仓库。
///
/// 导入的小程序统一落在一个 JSON 文件里（而不是每个小程序一个目录），
/// 因为海阔小程序本身就是一份 JSON，不需要解包执行目录；
/// 这样卸载、去重、导出都只动一个文件，出问题也好排查。
class HaikuoStore {
  HaikuoStore({Directory? rootOverride, http.Client? httpClient})
    : _rootOverride = rootOverride,
      _httpClient = httpClient;

  final Directory? _rootOverride;
  final http.Client? _httpClient;

  static const _fileName = 'programs.json';

  Future<Directory> get root async {
    final override = _rootOverride;
    if (override != null) {
      if (!await override.exists()) await override.create(recursive: true);
      return override;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'haikuo'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> get _file async {
    final dir = await root;
    return File(p.join(dir.path, _fileName));
  }

  Future<List<HaikuoProgram>> list() async {
    final file = await _file;
    if (!await file.exists()) return const [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      final list = decoded is Map<String, dynamic>
          ? decoded['programs']
          : decoded;
      if (list is! List) return const [];
      final programs = <HaikuoProgram>[];
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          programs.add(HaikuoProgram.fromJson(item));
        } else if (item is Map) {
          programs.add(
            HaikuoProgram.fromJson({
              for (final entry in item.entries) '${entry.key}': entry.value,
            }),
          );
        }
      }
      programs.sort((a, b) {
        final left = a.importedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final right = b.importedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return right.compareTo(left);
      });
      return programs;
    } catch (_) {
      // 文件坏了不拖垮页面：当空库处理，下一次导入会覆盖成正常结构。
      return const [];
    }
  }

  Future<void> _writeAll(List<HaikuoProgram> programs) async {
    final file = await _file;
    final payload = {
      'version': 1,
      'updatedAt': DateTime.now().toIso8601String(),
      'programs': programs.map((program) => program.toJson()).toList(),
    };
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(payload), flush: true);
    await temp.rename(file.path);
  }

  Future<HaikuoImportResult> addAll(
    List<HaikuoProgram> incoming, {
    String origin = '',
  }) async {
    final existing = await list();
    final byId = {for (final program in existing) program.id: program};
    final added = <HaikuoProgram>[];
    final updated = <HaikuoProgram>[];
    for (final program in incoming) {
      final tagged = program.copyWith(
        origin: origin.isEmpty ? program.origin : origin,
      );
      final previous = byId[tagged.id];
      if (previous == null) {
        added.add(tagged);
      } else {
        updated.add(tagged);
      }
      byId[tagged.id] = tagged;
    }
    if (added.isEmpty && updated.isEmpty) {
      return HaikuoImportResult(added: const [], updated: const []);
    }
    final merged = byId.values.toList()
      ..sort((a, b) {
        final left = a.importedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final right = b.importedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return right.compareTo(left);
      });
    await _writeAll(merged);
    return HaikuoImportResult(added: added, updated: updated);
  }

  Future<void> remove(String id) async {
    final programs = await list();
    final remaining = programs.where((program) => program.id != id).toList();
    await _writeAll(remaining);
  }

  Future<void> clear() async {
    await _writeAll(const []);
  }

  /// 导入本地 JSON 文件（.json / .txt / .zip / 口令文本都能吃）。
  Future<HaikuoImportResult> importFile(File file) async {
    final bytes = await file.readAsBytes();
    return importBytes(bytes, origin: '文件：${p.basename(file.path)}');
  }

  /// 从内存字节导入：文件选择器在部分机型上拿不到路径时，
  /// 页面层用选到的字节走这里兜底，不再只报“没拿到文件路径”。
  Future<HaikuoImportResult> importBytes(
    List<int> bytes, {
    String origin = '文件',
  }) async {
    final programs = HaikuoCodec.parseBytes(bytes, origin: origin);
    return addAll(programs, origin: origin);
  }

  /// 导入一段文本：可能是 JSON 正文，也可能是口令。
  Future<HaikuoImportResult> importText(
    String text, {
    String origin = '文本',
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const HaikuoFormatException('内容为空');
    }
    // 云口令短码（云6oooole/xxxxxx/xxx）：先联网取回口令文本，
    // 再按普通口令走；未知云编号在这里直接报明原因。
    final cloudUrl = HaikuoCodec.cloudApiUrl(trimmed);
    if (cloudUrl != null) {
      final bytes = await _fetch(cloudUrl);
      final resolved = HaikuoCodec.parseCloudApiResponse(
        HaikuoCodec.decodeText(bytes),
      );
      return importText(resolved, origin: origin);
    }
    // 纯 JSON 直接走解析，不需要联网。
    if (HaikuoCodec.looksLikeJson(trimmed)) {
      final programs = HaikuoCodec.parseText(trimmed, origin: origin);
      return addAll(programs, origin: origin);
    }
    final candidates = HaikuoCodec.extractCandidates(trimmed);
    final errors = <String>[];
    for (final candidate in candidates) {
      try {
        final programs = await _importCandidate(candidate, origin);
        if (programs.isNotEmpty) {
          return await addAll(programs, origin: origin);
        }
      } on HaikuoFormatException catch (error) {
        errors.add(error.message);
      } catch (error) {
        errors.add('$error');
      }
    }
    throw HaikuoFormatException(
      errors.isEmpty
          ? '口令里没有可用的海阔小程序'
          : '口令解析失败：${errors.first}',
    );
  }

  Future<List<HaikuoProgram>> _importCandidate(
    String candidate,
    String origin,
  ) async {
    final value = candidate.trim();
    if (value.isEmpty) return const [];
    if (value.toLowerCase().startsWith('http://') ||
        value.toLowerCase().startsWith('https://')) {
      final bytes = await _fetch(value);
      return HaikuoCodec.parseBytes(bytes, origin: origin);
    }
    if (HaikuoCodec.looksLikeJson(value)) {
      return HaikuoCodec.parseText(value, origin: origin);
    }
    final decoded = HaikuoCodec.tryBase64(value);
    if (decoded != null && decoded.isNotEmpty) {
      return HaikuoCodec.parseBytes(decoded, origin: origin);
    }
    return HaikuoCodec.parseText(value, origin: origin);
  }

  /// 从链接导入：可以是 JSON 直链、zip 包，也可以是口令页面。
  Future<HaikuoImportResult> importUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw const HaikuoFormatException('链接为空');
    }
    final lower = trimmed.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      throw const HaikuoFormatException('链接需要以 http:// 或 https:// 开头');
    }
    final bytes = await _fetch(trimmed);
    List<HaikuoProgram> programs;
    try {
      programs = HaikuoCodec.parseBytes(bytes, origin: '链接');
    } on HaikuoFormatException {
      // 拿回来的可能是 HTML 页面，页面上写着口令：退一步按文本再认一次。
      final text = HaikuoCodec.decodeText(bytes);
      final candidates = HaikuoCodec.extractCandidates(text);
      programs = const [];
      for (final candidate in candidates) {
        if (candidate == trimmed) continue;
        try {
          final parsed = await _importCandidate(candidate, '链接');
          if (parsed.isNotEmpty) {
            programs = parsed;
            break;
          }
        } catch (_) {
          continue;
        }
      }
      if (programs.isEmpty) {
        throw const HaikuoFormatException('这个链接里没有找到小程序 JSON');
      }
    }
    return addAll(programs, origin: '链接');
  }

  Future<List<int>> _fetch(String url) async {
    final client = _httpClient ?? http.Client();
    try {
      final response = await client.get(
        Uri.parse(url),
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
          'Accept': 'application/json, text/plain, */*',
        },
      ).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HaikuoFormatException('下载失败：HTTP ${response.statusCode}');
      }
      return response.bodyBytes;
    } on HaikuoFormatException {
      rethrow;
    } catch (error) {
      throw HaikuoFormatException('下载失败：$error');
    } finally {
      if (_httpClient == null) client.close();
    }
  }

  /// 导出成一份 JSON，方便换机或备份。
  Future<String> exportJson(List<HaikuoProgram> programs) async {
    final payload = {
      'name': '海阔小程序导出',
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'data': programs.map((program) => program.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }
}
