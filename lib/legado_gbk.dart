import 'dart:convert';

import 'legado_gbk_table.dart';

String decodeGbkBytes(List<int> bytes) {
  final out = StringBuffer();
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b < 0x80) {
      out.writeCharCode(b);
      i++;
      continue;
    }
    if (b >= 0x81 && b <= 0xFE && i + 1 < bytes.length) {
      final t = bytes[i + 1];
      if ((t >= 0x40 && t <= 0x7E) || (t >= 0x80 && t <= 0xFE)) {
        final trailIndex = t < 0x7F ? t - 0x40 : t - 0x41;
        final index = (b - 0x81) * 190 + trailIndex;
        final ch = index >= 0 && index < gbkTable.length
            ? gbkTable.codeUnitAt(index)
            : 0xFFFD;
        out.writeCharCode(ch);
        i += 2;
        continue;
      }
    }
    out.writeCharCode(0xFFFD);
    i++;
  }
  return out.toString();
}

String decodeLegadoBytes(List<int> bytes, String charset) {
  final normalized = charset
      .toLowerCase()
      .replaceAll('_', '')
      .replaceAll('-', '');
  if (normalized == 'gbk' ||
      normalized == 'gb2312' ||
      normalized == 'gb18030') {
    return decodeGbkBytes(bytes);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return utf8.decode(bytes, allowMalformed: true);
  }
}
