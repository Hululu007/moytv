import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:enough_convert/gbk.dart';

import 'torrent_magnet.dart';

/// 磁力文件导入：从 txt / csv / xlsx 文件字节里提取种子链接。
///
/// - 认 magnet:?、thunder://、ed2k:// 三种链接；按 info-hash 去重
///   （thunder/ed2k 没有 btih 哈希，用链接的 md5 作去重键）。
/// - 容忍“名字 + 链接”同行、空行、注释行；坏行跳过并计数。
/// - xls 旧格式（二进制 OLE）不覆盖：importMagnetsFromBytes 会返回
///   unsupportedReason，不编假数据。
class MagnetImportResult {
  const MagnetImportResult({
    required this.magnets,
    required this.linesScanned,
    required this.skipped,
    required this.duplicates,
    this.unsupportedReason = '',
  });

  /// 提取到的链接（已去重，保持文件内出现顺序）。
  final List<TorrentMagnet> magnets;

  /// 扫描过的行/单元格文本行数。
  final int linesScanned;

  /// 含链接标记但解析失败的坏行数。
  final int skipped;

  /// 因重复被丢掉的链接数。
  final int duplicates;

  /// 非空表示整个文件不支持（如 xls 旧格式），magnets 为空。
  final String unsupportedReason;

  bool get unsupported => unsupportedReason.isNotEmpty;
}

MagnetImportResult importMagnetsFromBytes(
  Uint8List bytes,
  String fileName,
) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.xls') && !lower.endsWith('.xlsx')) {
    return const MagnetImportResult(
      magnets: [],
      linesScanned: 0,
      skipped: 0,
      duplicates: 0,
      unsupportedReason: 'xls 是旧二进制表格格式，暂不支持导入；请另存为 xlsx、csv 或 txt 后再导入',
    );
  }
  if (lower.endsWith('.xlsx')) {
    return importMagnetsFromXlsx(bytes);
  }
  return importMagnetsFromText(decodeImportText(bytes));
}

/// 文本解码：优先 UTF-8，失败退回 GBK，最后容忍坏字节。
String decodeImportText(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    try {
      return gbk.decode(bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
}

final _linkPattern = RegExp(
  r'''(magnet:\?[^\s"'<>]+|thunder://[^\s"'<>]+|ed2k://[^\s"'<>]+)''',
  caseSensitive: false,
);

final _linkMarker = RegExp(
  r'magnet:\?|thunder://|ed2k://',
  caseSensitive: false,
);

/// 从一整段文本里提取种子链接（txt/csv 共用同一条路）。
MagnetImportResult importMagnetsFromText(String text) {
  final magnets = <TorrentMagnet>[];
  final seen = <String>{};
  var skipped = 0;
  var duplicates = 0;
  var lines = 0;
  for (final rawLine in text.split(RegExp(r'\r\n|\n|\r'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#') || line.startsWith('//')) continue;
    lines++;
    var lineHasLink = false;
    for (final match in _linkPattern.allMatches(line)) {
      lineHasLink = true;
      final candidate = match.group(0)!;
      final prefix = line.substring(0, match.start).trim();
      final magnet = torrentMagnetFromLink(candidate, namePrefix: prefix);
      if (magnet == null) {
        skipped++;
        continue;
      }
      final key = _dedupeKey(magnet);
      if (!seen.add(key)) {
        duplicates++;
        continue;
      }
      magnets.add(magnet);
    }
    if (!lineHasLink && _linkMarker.hasMatch(line)) {
      skipped++;
    }
  }
  return MagnetImportResult(
    magnets: magnets,
    linesScanned: lines,
    skipped: skipped,
    duplicates: duplicates,
  );
}

/// 从 xlsx 文件字节里提取种子链接：解 zip，取共享字符串与工作表文本。
MagnetImportResult importMagnetsFromXlsx(Uint8List bytes) {
  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (error) {
    return MagnetImportResult(
      magnets: const [],
      linesScanned: 0,
      skipped: 0,
      duplicates: 0,
      unsupportedReason: 'xlsx 文件解不开（不是有效的 zip 包）：$error',
    );
  }
  final buffer = StringBuffer();
  var parts = 0;
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final name = file.name.replaceAll('\\', '/');
    final isSheet =
        name.startsWith('xl/worksheets/') && name.endsWith('.xml');
    final isSharedStrings = name == 'xl/sharedStrings.xml';
    if (!isSheet && !isSharedStrings) continue;
    final xml = decodeImportText(Uint8List.fromList(file.content as List<int>));
    buffer.writeln(xlsxXmlToText(xml));
    parts++;
  }
  if (parts == 0) {
    return const MagnetImportResult(
      magnets: [],
      linesScanned: 0,
      skipped: 0,
      duplicates: 0,
      unsupportedReason: 'xlsx 里没有找到工作表或共享字符串',
    );
  }
  return importMagnetsFromText(buffer.toString());
}

/// xlsx 的 XML 片段转纯文本：单元格/行/共享字符串边界换行，其余标签去掉
/// （同一字符串被多个 `<t>` 分段时不插分隔符，链接不会被切断），再解 XML 转义。
String xlsxXmlToText(String xml) {
  var text = xml;
  text = text.replaceAll(RegExp(r'</(si|row|c)>'), '\n');
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');
  text = text
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
  text = text.replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
    final code = int.tryParse(match.group(1)!);
    if (code == null || code < 0 || code > 0x10FFFF) return match.group(0)!;
    return String.fromCharCode(code);
  });
  text = text.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (match) {
    final code = int.tryParse(match.group(1)!, radix: 16);
    if (code == null || code < 0 || code > 0x10FFFF) return match.group(0)!;
    return String.fromCharCode(code);
  });
  return text;
}

/// 一条原始链接转 TorrentMagnet：magnet 走标准解析；thunder/ed2k 用
/// 链接 md5 作会话键（没有 btih 哈希），显示名缺省为协议标签。
TorrentMagnet? torrentMagnetFromLink(String raw, {String namePrefix = ''}) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final kind = torrentLinkKind(text);
  if (kind == TorrentLinkKind.magnet) {
    final parsed = parseMagnetUri(text);
    if (parsed == null) return null;
    if (parsed.displayName.isEmpty && namePrefix.isNotEmpty) {
      return TorrentMagnet(
        uri: parsed.uri,
        infoHash: parsed.infoHash,
        isBase32Hash: parsed.isBase32Hash,
        displayName: _cleanNamePrefix(namePrefix),
        trackers: parsed.trackers,
      );
    }
    return parsed;
  }
  if (kind == TorrentLinkKind.thunder || kind == TorrentLinkKind.ed2k) {
    final digest = md5.convert(utf8.encode(text)).toString();
    final label = kind == TorrentLinkKind.thunder ? '迅雷链接' : 'ed2k 链接';
    final name = namePrefix.isNotEmpty ? _cleanNamePrefix(namePrefix) : label;
    return TorrentMagnet(
      uri: text,
      infoHash: 'x$digest',
      isBase32Hash: false,
      displayName: name,
    );
  }
  return null;
}

String _cleanNamePrefix(String prefix) {
  var name = prefix.trim();
  name = name.replaceAll(RegExp(r'^[\s\-–—|,;:：、]+'), '');
  name = name.replaceAll(RegExp(r'[\s\-–—|,;:：、]+$'), '');
  if (name.length > 80) name = name.substring(0, 80);
  return name;
}

String _dedupeKey(TorrentMagnet magnet) {
  if (magnet.infoHash.startsWith('x')) return magnet.infoHash;
  return magnet.infoHash.toLowerCase();
}

/// 列表显示编号：磁力 001、磁力 002…（从 1 开始，三位数补零）。
String magnetDisplayNumber(int zeroBasedIndex) {
  final number = zeroBasedIndex + 1;
  return '磁力 ${number.toString().padLeft(3, '0')}';
}
