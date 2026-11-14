import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/cloud_drive/qr_code_encoder.dart';

void main() {
  group('二维码编码器（对照 Python segno 参考向量）', () {
    late List<Map<String, dynamic>> vectors;

    setUpAll(() {
      final raw = File('test/qr_vectors.json').readAsStringSync();
      final decoded = jsonDecode(raw) as List;
      vectors = decoded.cast<Map<String, dynamic>>();
    });

    test('向量文件有 6 条', () {
      expect(vectors.length, 6);
    });

    test('逐条比对版本、掩码与矩阵', () {
      for (final vector in vectors) {
        final content = vector['content'] as String;
        final fixedMask = vector['mask'] as int?;
        final result = fixedMask == null
            ? encodeQrCode(content)
            : encodeQrCode(content, fixedMask: fixedMask);
        expect(result.version, vector['version'], reason: '${vector['name']} 版本');
        expect(result.mask, vector['mask_chosen'], reason: '${vector['name']} 掩码');
        final expectedRows = (vector['matrix'] as List).cast<String>();
        expect(result.size, expectedRows.length, reason: '${vector['name']} 尺寸');
        for (var row = 0; row < expectedRows.length; row++) {
          final actual = result.modules[row].map((b) => b ? '1' : '0').join();
          expect(actual, expectedRows[row], reason: '${vector['name']} 第 $row 行');
        }
      }
    });

    test('超容量抛错不截断', () {
      expect(() => encodeQrCode('A' * 300), throwsArgumentError);
    });

    test('空内容可编码', () {
      final result = encodeQrCode('');
      expect(result.version, 1);
      expect(result.size, 21);
    });
  });
}
