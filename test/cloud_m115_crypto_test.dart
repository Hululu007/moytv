/// m115 加密层的向量自验。
///
/// 向量由 tmp_vectors/ref_m115.py 生成：那是一份按 p115cipher 公开算法
/// 独立写出的 Python 实现（XOR 混淆、RSA 裸运算、固定常量），AES 部分
/// 用 openssl 命令行、LZ4 部分用 python-lz4 标准库产生。本测试逐字节
/// 对答案：Dart 实现与独立实现不一致就红。
/// 注意：m115 的 RSA 加/解密不是互逆运算（两边都用公钥指数，私钥在
/// 服务器侧），所以解密向量用的是任意密文 + 参考实现算出的期望明文，
/// 不是自加密自解密往返。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/cloud_drive/cloud_m115_crypto.dart';

Uint8List hexBytes(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('m115 向量', () {
    test('rsaEncrypt pickcode_short', () {
      final plain = hexBytes(
        '7b227069636b636f6465223a2261626364313233346566676835363738227d',
      );
      expect(
        m115RsaEncrypt(plain),
        'HB38IKKAkIlTTPLQLWruZRTyZm2sb+jnPG3qkH6DT8xQ8iKH/fozOdrn2jaGQ4ze2UolnrUyNaosgHqgz7gkLZxP323HO5G2GG9+dkTg5O2BMahilMbcPwZ80Fm3S+/xyZ/pDPEOQvdqFpKL/aq9Myn24WLcQFQHMJTnoNG9ldk=',
      );
    });
    test('rsaEncrypt pickcode_unicode', () {
      final plain = hexBytes(
        '7b227069636b636f6465223a22783979387a37e4b8ade69687e6b58be8af956162227d',
      );
      expect(
        m115RsaEncrypt(plain),
        'TXOvLHUsxlZQdC7QPzm8C1ptP1mMpxHx6gRP7WFxJbm8ZtzO6Lb4mGO1QtTRlEaii4UvSOECfJYvd5qZ0ld4jDn9M014CNfUy9qo5IdGuI56Bg8jQXAspkzZcnefS1JY8nE1jMx9gIV0orlgO7TusNWOgMMnV9RJlzk/pVMgxeg=',
      );
    });
    test('rsaEncrypt long_200', () {
      final plain = hexBytes(
        '0d141b222930373e454c535a61686f767d848b9299a0a7aeb5bcc3cad1d8dfe6edf4fb020910171e252c333a41484f565d646b727980878e959ca3aab1b8bfc6cdd4dbe2e9f0f7fe050c131a21282f363d444b525960676e757c838a91989fa6adb4bbc2c9d0d7dee5ecf3fa01080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3dae1e8eff6fd040b121920272e353c434a51585f666d747b828990979ea5acb3bac1c8cfd6dde4ebf2f900070e151c232a31383f464d545b626970777e',
      );
      expect(
        m115RsaEncrypt(plain),
        'Tbpi/sTE8ttE4MaKEa/IlNdz5TjtTr8or/w4kRHfSIsbloVUf+UnSxOQM+948DL6f5HCWb8tqFeyP9Glo8oiaAsJaDZoBE6rEbCtyHzad9sEnPGOz0FhO9Oe1topHLEskvdqAUZ2qGdbF9+ligjM12iCHtmCaUVK1bjQBOLTzaJanFr+KleOQTRGPdYr1zVqyE3HjcuaYSut2tEosn+YO1HPt6CYNxHxJUpeh9anVwz82D3ZzsvpVoyh3cKlOBLfngOiwesPDCyWvO0uZiRSKqp2TNF3EgfrSYxXpBxDQNMK+0TM3Qht9dScRfG6s+RxUG+/TMu2Vqrb2j7hSM1Y7g==',
      );
    });
    test('rsaEncrypt exact_101', () {
      final plain = hexBytes(
        '0104070a0d101316191c1f2225282b2e3134373a3d404346494c4f5255585b5e6164676a6d707376797c7f8285888b8e9194979a9da0a3a6a9acafb2b5b8bbbec1c4c7cacdd0d3d6d9dcdfe2e5e8ebeef1f4f7fafd000306090c0f1215181b1e2124272a2d',
      );
      expect(
        m115RsaEncrypt(plain),
        'JaGli2YGYjnPwrvS3zn2qNsEG2hI5wDo5BYyH4u++I9zInw/bHoY/BeWNRrD3X/GePuzQc95YFXkYUZKUpG27iLrpEULm1vmWFH07HoOeA2fRhO0bHRzXsdJaruW8vaewrhBM6solESfDA38m4qEWT4yDwUcA3CXpbZPjdCjB8M=',
      );
    });
    test('rsaEncrypt exact_102', () {
      final plain = hexBytes(
        '02070c11161b20252a2f34393e43484d52575c61666b70757a7f84898e93989da2a7acb1b6bbc0c5cacfd4d9dee3e8edf2f7fc01060b10151a1f24292e33383d42474c51565b60656a6f74797e83888d92979ca1a6abb0b5babfc4c9ced3d8dde2e7ecf1f6fb',
      );
      expect(
        m115RsaEncrypt(plain),
        'ZWepibezUqhfHF89bXzk3nwVv0NxAS7LUA0/+7rKM+W0LXmKSfbuPfQI8DzksYHj6W3TA68jmm/WSowPuohFi1Mu3I8it4+/wWHJAW//BoZaPFtGMBtEPFFyhnO4ll7woBSpSvOA+CxfZtuf7P9eI51v1BwKqHT7q+nbMWMVKkRcOA2/otZqIS2CjSy3AS/1iebKeJbwfdmkv8nfIB2k3DoykimUNEhK/c0CezBk4h2KlnKgBHryJENE4fS3vP8r0VjQz5ziyasPqxkz1YP/MasIyABctUXd6AX/I+nm531nk4xn34IMMmqQVKlmDqOVAzpMdZfKPQgO0aMMltMuUw==',
      );
    });
    test('rsaDecrypt rand_128', () {
      final plain = m115RsaDecrypt(
        'eImaq7zN3u8AESIzRFVmd4iZqrvM3e7/ECEyQ1RldoeYqbrL3O3+DyAxQlNkdYaXqLnK2+z9Dh8wQVJjdIWWp7jJ2uv8DR4vQFFic4SVprfI2er7DB0uP1BhcoOUpbbH2On6CxwtPk9gcYKTpLXG1+j5ChssPU5fcIGSo7TF1uc=',
      );
      expect(
        hexOf(plain),
        '1363c2c6470b600b9989fe23ea95bfb8db956f63e7a58562abbe3c60554ac8ada2',
      );
    });
    test('rsaDecrypt rand_256', () {
      final plain = m115RsaDecrypt(
        'mKm6y9zt/g8gMUJTZHWGl6i5ytvs/Q4fMEFSY3SFlqe4ydrr/A0eL0BRYnOElaa3yNnq+wwdLj9QYXKDlKW2x9jp+gscLT5PYHGCk6S1xtfo+QobLD1OX3CBkqO0xdbn+AkaKzxNXm+AkaKzxNXm9wgZKjtMXW5/kKGyw9Tl9gcYKTpLXG1+j6CxwtPk9QYXKDlKW2x9jp+wwdLj9AUWJzhJWmt8jZ6vwNHi8wQVJjdIWWp7jJ2uv9Dh8gMUJTZHWGl6i5ytvs/g8QITJDVGV2h5ipusvc7f8AESIzRFVmd4iZqrvM3e7wARIjNEVWZ3iJmqu8zd7v8QITJDVGV2hw==',
      );
      expect(
        hexOf(plain),
        '945c72df00e4a2a8953536e68d5a1c9478ad34937b01d5fb9847ec3e6af7bbc34f6c323121ea89a548ed290d32186c11d4fdbc2949eb8a6e024be2910eed65e76fd7dd72772e25ef27270f664776efa0b20dc38db37e08a126ddbd7d409e1db19e96f489a15bb6aeeaa1e3220eb7b872d1baebcee62ee73d03e969fa484542c2a13cc24d119c8215862ad25d61cff4647744b96bab75a26f2b9aad5376a20c01a79b0267',
      );
    });
    test('contentMaybeDecrypt json_small', () {
      final cipher = base64Decode(
        'HQj+k+Tj9vol0k4d/NxGS3DhC8GKu3YBcVix5zFwfN4=',
      );
      final plain = m115ContentMaybeDecrypt(cipher);
      expect(
        hexOf(plain),
        '7b227374617465223a747275652c2264617461223a2278227d',
      );
    });
    test('contentMaybeDecrypt json_repetitive', () {
      final cipher = base64Decode(
        'mRIvmSYV54adcRPJS+84F81E2PlSl7HiV+f9pj4uI2x6c3H14c0Q5HTnPArXmOtvzx4UMwfeq4N4/uxCsiUlStmJIIQIqSsEfaeDoDWAQOfSkkgo5zn9lb/LDrggt2md2QgT8QaNl7yM5KPvjnkDnQ==',
      );
      final plain = m115ContentMaybeDecrypt(cipher);
      expect(
        hexOf(plain),
        '7b2266696c655f6e616d65223a22616263616263616263222c2266696c655f75726c223a2268747470733a2f2f63646e2e6578616d706c652e636f6d2f616161612f626262622f636363632e6d70343f663d3326743d31383933343536303030227d7b2266696c655f6e616d65223a22616263616263616263222c2266696c655f75726c223a2268747470733a2f2f63646e2e6578616d706c652e636f6d2f616161612f626262622f636363632e6d70343f663d3326743d31383933343536303030227d7b2266696c655f6e616d65223a22616263616263616263222c2266696c655f75726c223a2268747470733a2f2f63646e2e6578616d706c652e636f6d2f616161612f626262622f636363632e6d70343f663d3326743d31383933343536303030227d7b2266696c655f6e616d65223a22616263616263616263222c2266696c655f75726c223a2268747470733a2f2f63646e2e6578616d706c652e636f6d2f616161612f626262622f636363632e6d70343f663d3326743d31383933343536303030227d7b2266696c655f6e616d65223a22616263616263616263222c2266696c655f75726c223a2268747470733a2f2f63646e2e6578616d706c652e636f6d2f616161612f626262622f636363632e6d70343f663d3326743d31383933343536303030227d7b2266696c655f6e616d65223a22616263616263616263222c2266696c655f75726c223a2268747470733a2f2f63646e2e6578616d706c652e636f6d2f616161612f626262622f636363632e6d70343f663d3326743d31383933343536303030227d',
      );
    });
    test('contentMaybeDecrypt json_multiframe', () {
      final cipher = base64Decode(
        'ubSne1eaCB+8SkUjbZKRCxQMVlWmxrHvtedXrvL2V/+nW5NJvtk+hascXLoW2eI0fV5fRflVjXkuS5LfwMebaNv1dLYyjd4uLdmUXc60AZxKPTydHZEoitOmgxbyclmU',
      );
      final plain = m115ContentMaybeDecrypt(cipher);
      expect(
        hexOf(plain),
        '7b226b223a227676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676767676227d',
      );
    });
    test('xor115 两例', () {
      expect(
        hexOf(
          m115Xor(
            hexBytes(
              '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2021222324',
            ),
            hexBytes('7806ad4c33865d184c013f46'),
          ),
        ),
        '787904ae4836805a10450b344a7508a25c22944e0c5917285e611cb6502e9842386d231c62',
      );
      expect(
        hexOf(
          m115Xor(hexBytes('68656c6c6f313135776f726c64'), hexBytes('8da5a58d')),
        ),
        'e5e8c9c9e2bc9490fae2d7c9e9',
      );
    });

    test('rsaGenKey', () {
      expect(
        hexOf(m115RsaGenKey(hexBytes('000102030405060708090a0b0c0d0e0f'), 12)),
        'ac81271bc54352d81c587497',
      );
    });

    test('contentMaybeDecrypt 明文 JSON 原样返回', () {
      final body = utf8.encode('{"state":true}');
      expect(m115ContentMaybeDecrypt(body), body);
    });

    test('rsaDecrypt 太短的密文报错', () {
      expect(
        () => m115RsaDecrypt(base64Encode([1, 2, 3])),
        throwsFormatException,
      );
    });
  });
}
