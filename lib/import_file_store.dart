import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class ImportFileStore {
  ImportFileStore._();

  static Future<Directory> directory() async {
    final documents = await getApplicationDocumentsDirectory();
    final dir = Directory('${documents.path}/imported_spiders');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<String> save(
    String id,
    String extension,
    List<int> bytes,
  ) async {
    final dir = await directory();
    final safeId = id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final fileName = '$safeId.$extension';
    await File('${dir.path}/$fileName').writeAsBytes(bytes, flush: true);
    return fileName;
  }

  static Future<String> pathOf(String fileName) async {
    final dir = await directory();
    return '${dir.path}/$fileName';
  }

  static Future<void> delete(String fileName) async {
    if (fileName.isEmpty) return;
    final dir = await directory();
    final file = File('${dir.path}/$fileName');
    if (await file.exists()) await file.delete();
  }

  /// 删除一条导入站登记的全部存盘文件：登记的蜘蛛文件本身，以
  /// 及 JSON 列表站的伴生列表文件（ext 里存的绝对路径取文件名）。
  /// 不存在的文件直接跳过；type 不是 jsonlist 时只删蜘蛛文件。
  static Future<void> deleteRecordFiles({
    required String type,
    required String fileName,
    required String ext,
  }) async {
    await delete(fileName);
    if (type != 'jsonlist' || ext.isEmpty) return;
    String jsonPath = '';
    try {
      final decoded = jsonDecode(ext);
      if (decoded is Map) {
        jsonPath = (decoded['path'] as String? ?? '').trim();
      }
    } catch (_) {
      jsonPath = ext.trim();
    }
    if (jsonPath.isEmpty) return;
    final base = jsonPath.split('/').last;
    if (base.isEmpty || base == fileName) return;
    await delete(base);
  }
}
