import 'package:moyi/content_py.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('py 播放地址解析', () {
    test('首条线路的集数按标题与播放标识拆开', () {
      final chapters = parsePyPlayUrl(
        '喜马拉雅\$\$\$免费同书',
        '第1集\$123_1_456#第2集\$123_1_789\$\$\$第1集\$999_1_111',
      );
      expect(chapters, hasLength(2));
      expect(chapters[0].title, '第1集');
      expect(chapters[0].id, '123_1_456');
      expect(chapters[0].meta, '喜马拉雅');
      expect(chapters[1].id, '123_1_789');
    });

    test('直链集数原样保留为播放地址', () {
      final chapters = parsePyPlayUrl(
        '听书',
        '第1章\$http://127.0.0.1:1234/hg_audio.mp4?book=1#第2章\$http://127.0.0.1:1234/hg_audio.mp4?book=2',
      );
      expect(chapters, hasLength(2));
      expect(chapters[0].id, startsWith('http://127.0.0.1'));
    });

    test('空播放地址返回空列表', () {
      expect(parsePyPlayUrl('听书', ''), isEmpty);
    });
  });
}
