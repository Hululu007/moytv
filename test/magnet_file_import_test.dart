import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:enough_convert/gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/torrent/magnet_file_import.dart';

const _hexHash = 'FC5353DC585D96AB95E99FD5CCAD7DC690A033EF';
const _hexHash2 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _base32Hash = 'MFRGGZDFMZTWQ2LKNNWG23TPOJQXE4A7';

String _magnet(String hash, {String name = ''}) {
  final dn = name.isEmpty ? '' : '&dn=${Uri.encodeComponent(name)}';
  return 'magnet:?xt=urn:btih:$hash$dn';
}

Uint8List _buildXlsx({
  required String sharedStringsXml,
  required String sheetXml,
}) {
  final archive = Archive();
  archive.addFile(
    ArchiveFile(
      'xl/sharedStrings.xml',
      sharedStringsXml.length,
      utf8.encode(sharedStringsXml),
    ),
  );
  archive.addFile(
    ArchiveFile(
      'xl/worksheets/sheet1.xml',
      sheetXml.length,
      utf8.encode(sheetXml),
    ),
  );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  group('文本提取', () {
    test('混行/空行/注释行/名字前缀/去重/坏行计数', () {
      final text = [
        '# 注释行',
        '',
        '  ',
        '// 另一行注释',
        '影片一 ${_magnet(_hexHash)}',
        _magnet(_hexHash2, name: '影片二'),
        _magnet(_hexHash), // 重复
        'magnet:?xt=urn:btih:XYZ', // 坏哈希
        'magnet:?dn=没有哈希',
        '纯文字一行，没有链接',
        'thunder://QUJDODgxNTIzNDQ2Mjk=',
        'ed2k://|file|test.mp4|123|ABCDEF0123456789ABCDEF0123456789|/',
      ].join('\n');
      final result = importMagnetsFromText(text);
      expect(result.magnets.length, 4);
      expect(result.magnets[0].infoHash, _hexHash.toLowerCase());
      expect(result.magnets[0].displayName, '影片一');
      expect(result.magnets[1].displayName, '影片二');
      expect(result.duplicates, 1);
      expect(result.skipped, 2);
      expect(result.linesScanned, 8);
      expect(result.unsupported, isFalse);
    });

    test('Base32 哈希认得出并保留大写', () {
      final result = importMagnetsFromText(_magnet(_base32Hash));
      expect(result.magnets.length, 1);
      expect(result.magnets.single.infoHash, _base32Hash);
      expect(result.magnets.single.isBase32Hash, isTrue);
    });

    test('thunder/ed2k 用链接 md5 作键、显示协议标签', () {
      final thunder = torrentMagnetFromLink('thunder://QUJDODgxNTIzNDQ2Mjk=')!;
      expect(thunder.infoHash.startsWith('x'), isTrue);
      expect(thunder.infoHash.length, 33);
      expect(thunder.displayName, '迅雷链接');
      final ed2k = torrentMagnetFromLink(
        'ed2k://|file|a.mp4|1|ABCDEF0123456789ABCDEF0123456789|/',
        namePrefix: '我的影片',
      )!;
      expect(ed2k.displayName, '我的影片');
    });

    test('GBK 编码的 txt 解得出来', () {
      final text = '测试影片 ${_magnet(_hexHash)}';
      final bytes = Uint8List.fromList(gbk.encode(text));
      expect(decodeImportText(bytes), text);
      final result = importMagnetsFromBytes(bytes, 'list.txt');
      expect(result.magnets.length, 1);
      expect(result.magnets.single.displayName, '测试影片');
    });

    test('csv 同行多列、名字列在链接前', () {
      final csv = '名称,链接\n影片一,${_magnet(_hexHash)}\n影片二,${_magnet(_hexHash2)}';
      final result = importMagnetsFromText(csv);
      expect(result.magnets.length, 2);
      expect(result.magnets[0].displayName, '影片一');
    });
  });

  group('xlsx 提取', () {
    test('共享字符串与内联字符串都认', () {
      final bytes = _buildXlsx(
        sharedStringsXml:
            '<?xml version="1.0"?><sst><si><t>${_magnet(_hexHash)}</t></si></sst>',
        sheetXml:
            '<?xml version="1.0"?><worksheet><sheetData>'
            '<row><c t="inlineStr"><is><t>${_magnet(_hexHash2)}</t></is></c></row>'
            '</sheetData></worksheet>',
      );
      final result = importMagnetsFromXlsx(bytes);
      expect(result.magnets.length, 2);
    });

    test('链接被富文本分段切开也能拼回整条', () {
      final full = _magnet(_hexHash);
      final first = full.substring(0, 30);
      final rest = full.substring(30);
      final bytes = _buildXlsx(
        sharedStringsXml:
            '<?xml version="1.0"?><sst><si><r><t>$first</t></r>'
            '<r><t>$rest</t></r></si></sst>',
        sheetXml:
            '<?xml version="1.0"?><worksheet><sheetData></sheetData></worksheet>',
      );
      final result = importMagnetsFromXlsx(bytes);
      expect(result.magnets.length, 1);
      expect(result.magnets.single.infoHash, _hexHash.toLowerCase());
    });

    test('XML 转义的 &amp; 解回 &', () {
      final magnet = _magnet(_hexHash, name: 'a&b');
      final escaped = magnet.replaceAll('&', '&amp;');
      final bytes = _buildXlsx(
        sharedStringsXml:
            '<?xml version="1.0"?><sst><si><t>$escaped</t></si></sst>',
        sheetXml:
            '<?xml version="1.0"?><worksheet><sheetData></sheetData></worksheet>',
      );
      final result = importMagnetsFromXlsx(bytes);
      expect(result.magnets.length, 1);
      expect(result.magnets.single.uri, contains('&dn='));
    });

    test('不是 zip 的 xlsx 报不支持、不崩', () {
      final result = importMagnetsFromBytes(
        Uint8List.fromList(utf8.encode('not a zip')),
        'bad.xlsx',
      );
      expect(result.unsupported, isTrue);
      expect(result.magnets, isEmpty);
    });

    test('xls 旧格式明确报不支持', () {
      final result = importMagnetsFromBytes(
        Uint8List.fromList([0xd0, 0xcf, 0x11, 0xe0]),
        'old.xls',
      );
      expect(result.unsupported, isTrue);
      expect(result.unsupportedReason, contains('xls'));
    });
  });

  test('显示编号三位数补零', () {
    expect(magnetDisplayNumber(0), '磁力 001');
    expect(magnetDisplayNumber(9), '磁力 010');
    expect(magnetDisplayNumber(99), '磁力 100');
  });
}
