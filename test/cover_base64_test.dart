import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/core_bridge.dart';

void main() {
  group('normalizeCoverBytes', () {
    // 32 字节以上的最小 WebP：RIFF + 大小 + WEBP + 填充。
    List<int> webpBytes() => [
      ...'RIFF'.codeUnits,
      24,
      0,
      0,
      0,
      ...'WEBP'.codeUnits,
      ...List.filled(20, 0x2a),
    ];

    List<int> pngBytes() => [
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
      ...List.filled(24, 0x00),
    ];

    List<int> jpegBytes() => [0xff, 0xd8, 0xff, ...List.filled(29, 0x11)];

    test('base64 编码的 WebP 解回图片字节', () {
      final raw = webpBytes();
      final encoded = utf8.encode(base64Encode(raw));
      final out = normalizeCoverBytes(encoded);
      expect(out, raw);
      expect(identical(out, encoded), isFalse);
    });

    test('base64 编码的 PNG/JPEG 解回图片字节', () {
      for (final raw in [pngBytes(), jpegBytes()]) {
        final encoded = utf8.encode(base64Encode(raw));
        expect(normalizeCoverBytes(encoded), raw);
      }
    });

    test('base64 带换行与空格也能解', () {
      final raw = webpBytes();
      final text = base64Encode(raw);
      final wrapped =
          '${text.substring(0, 20)}\n${text.substring(20, 40)} ${text.substring(40)}';
      expect(normalizeCoverBytes(utf8.encode(wrapped)), raw);
    });

    test('已经是图片的字节原样返回同一份', () {
      for (final raw in [webpBytes(), pngBytes(), jpegBytes()]) {
        expect(identical(normalizeCoverBytes(raw), raw), isTrue);
      }
    });

    test('普通文本原样返回', () {
      final text = utf8.encode(
        'this is not base64 at all, it has spaces and commas!!!',
      );
      expect(identical(normalizeCoverBytes(text), text), isTrue);
    });

    test('截断的 base64（长度不是 4 的倍数）原样返回', () {
      final text = utf8.encode(base64Encode(webpBytes()).substring(0, 43));
      expect(identical(normalizeCoverBytes(text), text), isTrue);
    });

    test('能解但解出来不是图片的 base64 原样返回', () {
      final text = utf8.encode(
        base64Encode(utf8.encode('hello world, this is plain text data!!')),
      );
      expect(identical(normalizeCoverBytes(text), text), isTrue);
    });

    test('填充符出现在中间的 base64 原样返回', () {
      final text = utf8.encode('QUJD====QUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJD');
      expect(identical(normalizeCoverBytes(text), text), isTrue);
    });

    test('短输入原样返回', () {
      final short = utf8.encode('QUJD');
      expect(identical(normalizeCoverBytes(short), short), isTrue);
    });

    test('HTML 报错页原样返回', () {
      final html = utf8.encode(
        '<html><body>403 Forbidden: access denied by shield</body></html>',
      );
      expect(identical(normalizeCoverBytes(html), html), isTrue);
    });
  });
}
