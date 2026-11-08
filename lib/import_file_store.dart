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
}
