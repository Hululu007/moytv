import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/whos_json_index.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WhosJsonIndex.fromLines（合成数据）', () {
    late WhosJsonIndex index;
    setUp(() {
      index = WhosJsonIndex.fromLines(
        catalogLines: const [
          'ABP-188||First Title||https://v.hersav.me/images/av/a.jpg||https://v.hersav.me/a/a.m3u8',
          'ROE-566||Second Title||https://v.hersav.me/images/av/b.jpg||https://v.hersav.me/b/b.m3u8',
          'NOACT-001||No Actress Video||https://v.hersav.me/images/av/c.jpg||https://v.hersav.me/c/c.m3u8',
          'BADLINE',
          '',
        ],
        mapLines: const [
          'ABP-188||あやみ旬果',
          'ROE-566||星冬香;素人',
          'ROE-566||星冬香',
          'BADLINE',
          '',
        ],
      );
    });

    test('番号查演员：小写也能查，素人剔除', () {
      expect(index.castForCode('abp-188'), ['あやみ旬果']);
      expect(index.castForCode('ABP-188'), ['あやみ旬果']);
      // 素人是通用标注不是真人，不进演员表。
      expect(index.castForCode('ROE-566'), ['星冬香']);
      expect(index.castForCode('NOACT-001'), isEmpty);
      expect(index.castForCode('NOT-EXIST'), isEmpty);
      expect(index.castForCode(''), isEmpty);
    });

    test('演员查番号：双向索引', () {
      expect(index.codesForActor('あやみ旬果'), ['ABP-188']);
      expect(index.codesForActor('星冬香'), ['ROE-566']);
      expect(index.codesForActor('素人'), isEmpty);
      expect(index.codesForActor('不存在的人'), isEmpty);
    });

    test('番号查视频行：只留演员映射里有的番号', () {
      final abp = index.videoForCode('ABP-188');
      expect(abp, isNotNull);
      expect(abp!.title, 'First Title');
      expect(abp.pic, contains('v.hersav.me'));
      expect(abp.m3u8, endsWith('.m3u8'));
      // NOACT-001 不在演员映射里，视频行不常驻。
      expect(index.videoForCode('NOACT-001'), isNull);
      expect(index.videoForCode('NOT-EXIST'), isNull);
    });

    test('计数', () {
      expect(index.codeCount, 2);
      expect(index.actorCount, 2);
      expect(index.videoCount, 2);
      expect(index.isEmpty, isFalse);
    });
  });

  group('WhosJsonIndex.fromLines（空数据）', () {
    test('空索引不抛错', () {
      final index = WhosJsonIndex.fromLines(
        catalogLines: const [],
        mapLines: const [],
      );
      expect(index.isEmpty, isTrue);
      expect(index.castForCode('ABP-188'), isEmpty);
      expect(index.codesForActor('あやみ旬果'), isEmpty);
      expect(index.videoForCode('ABP-188'), isNull);
    });
  });

  group('WhosJsonIndex 真实资源（读包里两个 gz）', () {
    test('行数与已知番号对得上', () async {
      final index = await WhosJsonIndex.instance;
      // 真实快照：视频目录 339,526 行；演员映射 431,165 行（2026-11-24 合并版，
      // 解析时滤掉 186,829 个纯素人番号，留 244,336 个）。
      expect(index.videoCount, greaterThan(190000));
      expect(index.codeCount, 244336);
      expect(index.isEmpty, isFalse);
      // ROE-566：whos.json 第 1 条，演员是星冬香（映射里有）。
      expect(index.castForCode('ROE-566'), contains('星冬香'));
      final roe = index.videoForCode('ROE-566');
      expect(roe, isNotNull);
      expect(roe!.m3u8, contains('v.hersav.me'));
      expect(roe.m3u8, endsWith('.m3u8'));
      // ABP-188：三站 420 码里的老番号，映射里有演员。
      expect(index.castForCode('ABP-188'), isNotEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
