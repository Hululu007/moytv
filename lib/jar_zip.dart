import 'dart:convert';

import 'package:archive/archive.dart';

import 'jar_site_config.dart';

class JarZipFailure implements Exception {
  JarZipFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class JarZipPackage {
  const JarZipPackage({
    required this.jarName,
    required this.jarBytes,
    required this.configs,
    required this.extraJsonNames,
    required this.extraJsonFiles,
    required this.skippedJarNames,
  });

  final String jarName;
  final List<int> jarBytes;
  final List<JarSiteConfig> configs;
  final List<String> extraJsonNames;
  final Map<String, List<int>> extraJsonFiles;
  final List<String> skippedJarNames;
}

bool isZipBytes(List<int> bytes) {
  if (bytes.length < 4) return false;
  if (bytes[0] != 0x50 || bytes[1] != 0x4B) return false;
  return bytes[2] == 0x03 && bytes[3] == 0x04 ||
      bytes[2] == 0x05 && bytes[3] == 0x06;
}

String _baseName(String name) {
  final slash = name.lastIndexOf('/');
  return slash < 0 ? name : name.substring(slash + 1);
}

JarZipPackage decodeJarZipPackage(List<int> bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (error) {
    throw JarZipFailure('zip 包解包失败：$error');
  }
  final jars = [
    for (final file in archive.files)
      if (file.isFile && file.name.toLowerCase().endsWith('.jar')) file,
  ];
  if (jars.isEmpty) {
    throw JarZipFailure('zip 包里没有找到 .jar 文件');
  }
  jars.sort((a, b) => a.name.compareTo(b.name));
  final jar = jars.first;
  final configs = <JarSiteConfig>[];
  final extraJsonNames = <String>[];
  final extraJsonFiles = <String, List<int>>{};
  for (final file in archive.files) {
    if (!file.isFile) continue;
    if (!file.name.toLowerCase().endsWith('.json')) continue;
    final content = List<int>.from(file.content as List<int>);
    final base = _baseName(file.name);
    if (base.isEmpty) continue;
    List<JarSiteConfig> parsed = const [];
    try {
      parsed = parseJarSiteConfigs(utf8.decode(content, allowMalformed: true));
    } catch (_) {
      parsed = const [];
    }
    if (parsed.isNotEmpty) {
      configs.addAll(parsed);
    } else {
      extraJsonNames.add(base);
      extraJsonFiles[base] = content;
    }
  }
  return JarZipPackage(
    jarName: jar.name,
    jarBytes: List<int>.from(jar.content as List<int>),
    configs: configs,
    extraJsonNames: extraJsonNames,
    extraJsonFiles: extraJsonFiles,
    skippedJarNames: [for (final other in jars.skip(1)) other.name],
  );
}
