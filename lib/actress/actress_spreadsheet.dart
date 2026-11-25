import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'actress_generic_db.dart';

/// 表格（CSV / Excel）与演员库之间的列映射与编解码。
///
/// 「表格导入更新」与「导出 CSV/Excel」共用同一套口径（用户令：
/// 导出→改→导回的往返链必须成立）：
/// - 列名识别与 .sql 导入同一套宽容规则：先认表格专属列
///   （女优头像、标签），其余走 [roleForColumn]（番号/标题/封面/
///   播放地址/女优/分类认常见中英文名）；
/// - 导出固定八列中文表头：番号、标题、封面、播放地址、女优、
///   女优头像、分类、标签；
/// - 多值单元格拼法：播放地址用 ` | ` 连接（拆时还认换行、
///   英文/中文分号），女优与标签用 `、` 连接（拆分口径与 .sql
///   归一化的 _splitActressNames 一致：、，,;；/｜| 都拆）。
///
/// Excel 读写选型：pub.dev 上的 excel 包不在本机包缓存里且本机
/// 拉不到 pub.dev，改用已在项目依赖里的 archive（zip 解包/打包）
/// + xml（XML 解析）两个现成库，只写表格语义层（共享字符串、
/// 工作表行列），不自己造 zip/XML 轮子。
enum SpreadsheetColumn {
  code,
  title,
  cover,
  playUrl,
  actress,
  actressAvatar,
  category,
  tags,
}

/// 导出固定表头（与 [SpreadsheetColumn] 顺序一一对应）。
const spreadsheetExportHeaders = <String>[
  '番号',
  '标题',
  '封面',
  '播放地址',
  '女优',
  '女优头像',
  '分类',
  '标签',
];

/// 表格专属列名（归一化后）：先于 [roleForColumn] 判定——
/// 「女优头像」含“女优”会被判成女优列、「标签」的 tag 在通用
/// 口径里归分类，都不是表格语义。
const _avatarHeaders = {
  '女优头像',
  '演员头像',
  '头像',
  'avatar',
  'actressavatar',
  'avatarurl',
  'headimg',
  'headpic',
};

const _tagHeaders = {'标签', '标签名', 'tags', 'tag', 'tagname'};

/// 表头 → 列角色；认不出返回 null（该列忽略）。
SpreadsheetColumn? spreadsheetColumnForHeader(String header) {
  final normalized = normalizeDbFieldName(header);
  if (normalized.isEmpty) return null;
  if (_avatarHeaders.contains(normalized)) {
    return SpreadsheetColumn.actressAvatar;
  }
  if (_tagHeaders.contains(normalized)) return SpreadsheetColumn.tags;
  final role = roleForColumn(header);
  if (role == null) return null;
  return switch (role.$1) {
    GenericDbRole.code => SpreadsheetColumn.code,
    GenericDbRole.title => SpreadsheetColumn.title,
    GenericDbRole.cover => SpreadsheetColumn.cover,
    GenericDbRole.playUrl => SpreadsheetColumn.playUrl,
    GenericDbRole.actress => SpreadsheetColumn.actress,
    GenericDbRole.category => SpreadsheetColumn.category,
    GenericDbRole.date => null,
  };
}

/// 一行作品数据（导入更新与导出共用）。
class SpreadsheetWorkRow {
  SpreadsheetWorkRow({this.rowNumber = 0});

  /// 表格里的行号（表头算第 1 行），报错/计数定位用。
  final int rowNumber;

  /// 番号（对齐键）：空 = 缺番号，导入时跳过。
  String code = '';

  /// 以下字段 null = 表格没给这一列（或单元格为空）：更新时不动。
  String? title;
  String? cover;
  String? category;
  String? actressAvatar;

  /// 播放地址（单元格拆分后）：空表 = 没给地址，更新时不动；
  /// 非空 = 整表替换该作品的地址。
  List<String> playUrls = const [];

  /// 女优名（拆分后）：空表 = 没给，更新时不动；非空 = 建人/关联
  /// （只加不删原有关系）。
  List<String> actresses = const [];

  /// 标签（拆分后）：空表 = 没给；非空 = 追加（只加不删）。
  List<String> tags = const [];
}

/// 播放地址单元格拆分：`|`、换行、英文/中文分号都算分隔。
List<String> splitPlayUrlCell(String cell) {
  final urls = <String>[];
  for (final part in cell.split(RegExp(r'[|｜\n;；]+'))) {
    final url = part.trim();
    if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
  }
  return urls;
}

/// 多名单元格拆分（女优/标签共用）：口径同 .sql 归一化。
List<String> splitNamesCell(String cell) {
  final names = <String>[];
  for (final part in cell.split(RegExp(r'[、，,;；/｜|]+'))) {
    final name = part.trim();
    if (name.isNotEmpty && !names.contains(name)) names.add(name);
  }
  return names;
}

/// 播放地址单元格拼法（导出用）。
String joinPlayUrlCell(List<String> urls) => urls.join(' | ');

/// 多名单元格拼法（导出用）。
String joinNamesCell(List<String> names) => names.join('、');

/// 把二维表格（首行表头）解析成作品行。没有番号列直接抛
/// [FormatException]（整份表格没法对齐，属结构性失败）。
List<SpreadsheetWorkRow> parseSpreadsheetGrid(List<List<String>> grid) {
  if (grid.isEmpty) throw const FormatException('表格是空的');
  final header = grid.first;
  final columns = <int, SpreadsheetColumn>{};
  for (var i = 0; i < header.length; i++) {
    final column = spreadsheetColumnForHeader(header[i]);
    if (column != null) columns[i] = column;
  }
  if (!columns.values.contains(SpreadsheetColumn.code)) {
    throw const FormatException('表格里没有番号列（番号/ID/代码 都认）');
  }
  final rows = <SpreadsheetWorkRow>[];
  for (var r = 1; r < grid.length; r++) {
    final cells = grid[r];
    String cell(SpreadsheetColumn column) {
      for (final entry in columns.entries) {
        if (entry.value != column) continue;
        if (entry.key >= cells.length) return '';
        return cells[entry.key].trim();
      }
      return '';
    }

    final row = SpreadsheetWorkRow(rowNumber: r + 1);
    row.code = cell(SpreadsheetColumn.code);
    final title = cell(SpreadsheetColumn.title);
    if (title.isNotEmpty) row.title = title;
    final cover = cell(SpreadsheetColumn.cover);
    if (cover.isNotEmpty) row.cover = cover;
    final category = cell(SpreadsheetColumn.category);
    if (category.isNotEmpty) row.category = category;
    final avatar = cell(SpreadsheetColumn.actressAvatar);
    if (avatar.isNotEmpty) row.actressAvatar = avatar;
    row.playUrls = splitPlayUrlCell(cell(SpreadsheetColumn.playUrl));
    row.actresses = splitNamesCell(cell(SpreadsheetColumn.actress));
    row.tags = splitNamesCell(cell(SpreadsheetColumn.tags));
    rows.add(row);
  }
  return rows;
}

// ---------------------------------------------------------------------------
// CSV
// ---------------------------------------------------------------------------

/// CSV 编码：CRLF 行尾；含逗号/引号/换行的字段加引号、引号翻倍。
String encodeCsv(List<List<String>> grid) {
  final buffer = StringBuffer();
  for (final row in grid) {
    buffer.write(
      row.map((cell) {
        if (cell.contains(',') ||
            cell.contains('"') ||
            cell.contains('\n') ||
            cell.contains('\r')) {
          return '"${cell.replaceAll('"', '""')}"';
        }
        return cell;
      }).join(','),
    );
    buffer.write('\r\n');
  }
  return buffer.toString();
}

/// CSV 解码：RFC 4180 口径——引号内逗号/换行/双引号都算数据。
List<List<String>> decodeCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var inQuotes = false;
  var i = 0;
  void endCell() {
    row.add(cell.toString());
    cell.clear();
  }

  void endRow() {
    endCell();
    rows.add(row);
    row = <String>[];
  }

  while (i < text.length) {
    final c = text[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i += 2;
          continue;
        }
        inQuotes = false;
        i++;
        continue;
      }
      cell.write(c);
      i++;
      continue;
    }
    if (c == '"') {
      inQuotes = true;
      i++;
    } else if (c == ',') {
      endCell();
      i++;
    } else if (c == '\r') {
      i++;
    } else if (c == '\n') {
      endRow();
      i++;
    } else {
      cell.write(c);
      i++;
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) endRow();
  // 末尾空行（文件以换行结尾时 endRow 已收过）不产生幽灵行：
  // 上面的收尾只在有残留时触发，这里再去掉纯空行尾巴。
  while (rows.isNotEmpty && rows.last.every((c) => c.trim().isEmpty)) {
    rows.removeLast();
  }
  return rows;
}

// ---------------------------------------------------------------------------
// Excel (.xlsx)
// ---------------------------------------------------------------------------

String _xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _columnLetters(int index) {
  var n = index + 1;
  var letters = '';
  while (n > 0) {
    final rem = (n - 1) % 26;
    letters = String.fromCharCode(65 + rem) + letters;
    n = (n - 1) ~/ 26;
  }
  return letters;
}

/// XLSX 编码：单工作表「作品」，全部单元格内联字符串。
List<int> encodeXlsx(List<List<String>> grid) {
  final rowsXml = StringBuffer();
  for (var r = 0; r < grid.length; r++) {
    rowsXml.write('<row r="${r + 1}">');
    for (var c = 0; c < grid[r].length; c++) {
      final value = grid[r][c];
      if (value.isEmpty) continue;
      rowsXml.write(
        '<c r="${_columnLetters(c)}${r + 1}" t="inlineStr">'
        '<is><t xml:space="preserve">${_xmlEscape(value)}</t></is></c>',
      );
    }
    rowsXml.write('</row>');
  }
  const contentTypes =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
      '</Types>';
  const rootRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
      '</Relationships>';
  const workbook =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets><sheet name="作品" sheetId="1" r:id="rId1"/></sheets></workbook>';
  const workbookRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
      '</Relationships>';
  final sheet =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<sheetData>$rowsXml</sheetData></worksheet>';
  final archive = Archive()
    ..addFile(ArchiveFile.string('[Content_Types].xml', contentTypes))
    ..addFile(ArchiveFile.string('_rels/.rels', rootRels))
    ..addFile(ArchiveFile.string('xl/workbook.xml', workbook))
    ..addFile(ArchiveFile.string('xl/_rels/workbook.xml.rels', workbookRels))
    ..addFile(ArchiveFile.string('xl/worksheets/sheet1.xml', sheet));
  return ZipEncoder().encode(archive);
}

/// XLSX 解码：读第一个工作表，认共享字符串/内联字符串/数值。
List<List<String>> decodeXlsx(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  String? readEntry(String name) {
    for (final file in archive.files) {
      if (file.name == name) {
        return utf8.decode(file.content as List<int>);
      }
    }
    return null;
  }

  // 共享字符串表（有才解析）。
  final shared = <String>[];
  final sharedXml = readEntry('xl/sharedStrings.xml');
  if (sharedXml != null) {
    final doc = XmlDocument.parse(sharedXml);
    for (final si in doc.findAllElements('si')) {
      shared.add(
        si.findAllElements('t').map((t) => t.innerText).join(),
      );
    }
  }
  String? sheetXml = readEntry('xl/worksheets/sheet1.xml');
  if (sheetXml == null) {
    for (final file in archive.files) {
      if (file.name.startsWith('xl/worksheets/') &&
          file.name.endsWith('.xml')) {
        sheetXml = utf8.decode(file.content as List<int>);
        break;
      }
    }
  }
  if (sheetXml == null) {
    throw const FormatException('Excel 文件里找不到工作表');
  }
  final doc = XmlDocument.parse(sheetXml);
  final grid = <List<String>>[];
  for (final rowElement in doc.findAllElements('row')) {
    final cells = <String>[];
    for (final cellElement in rowElement.findElements('c')) {
      final ref = cellElement.getAttribute('r') ?? '';
      final letters = RegExp(r'^[A-Z]+').firstMatch(ref)?.group(0) ?? '';
      var index = 0;
      for (final unit in letters.codeUnits) {
        index = index * 26 + (unit - 64);
      }
      final columnIndex = index - 1;
      while (cells.length < columnIndex) {
        cells.add('');
      }
      final type = cellElement.getAttribute('t') ?? '';
      var value = '';
      if (type == 's') {
        final raw = cellElement.findElements('v').firstOrNull?.innerText;
        final sharedIndex = int.tryParse(raw ?? '');
        if (sharedIndex != null &&
            sharedIndex >= 0 &&
            sharedIndex < shared.length) {
          value = shared[sharedIndex];
        }
      } else if (type == 'inlineStr') {
        value = cellElement
            .findAllElements('t')
            .map((t) => t.innerText)
            .join();
      } else {
        value = cellElement.findElements('v').firstOrNull?.innerText ?? '';
      }
      if (cells.length == columnIndex) {
        cells.add(value);
      } else if (columnIndex < cells.length) {
        cells[columnIndex] = value;
      } else {
        cells.add(value);
      }
    }
    grid.add(cells);
  }
  return grid;
}

/// 按扩展名把表格文件字节解成作品行（.csv 走文本、.xlsx 走 zip）。
List<SpreadsheetWorkRow> spreadsheetRowsFromBytes(
  List<int> bytes, {
  required bool isXlsx,
}) {
  if (isXlsx) return parseSpreadsheetGrid(decodeXlsx(bytes));
  // CSV 可能带 BOM，utf8 解码后去掉。
  var text = utf8.decode(bytes);
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  return parseSpreadsheetGrid(decodeCsv(text));
}

/// 把作品行编成二维表格（固定八列表头，导出口径）。
List<List<String>> spreadsheetGridFromRows(
  Iterable<SpreadsheetWorkRow> rows,
) {
  return [
    spreadsheetExportHeaders,
    for (final row in rows)
      [
        row.code,
        row.title ?? '',
        row.cover ?? '',
        joinPlayUrlCell(row.playUrls),
        joinNamesCell(row.actresses),
        row.actressAvatar ?? '',
        row.category ?? '',
        joinNamesCell(row.tags),
      ],
  ];
}
