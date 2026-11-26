// 网盘番号封面刮削：番号提取样本（用户 2026-11-26 实报截图里的
// 文件名/文件夹名）、本地库命中行匹配、刮削链优先级与回落。
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/cloud_drive/cloud_115_offline.dart';
import 'package:moyi/cloud_drive/cloud_cover_scrape.dart';

ActressJsonEntry _entry({
  required String vodId,
  String vodCode = '',
  String vodPic = '',
}) => ActressJsonEntry(
  site: 'whos',
  vodId: vodId,
  vodName: '',
  vodPic: vodPic,
  vodActor: '',
  vodDirector: '',
  vodRemarks: '',
  vodPubdate: '',
  vodArea: '',
  vodYear: '',
  vodContent: '',
  vodPlayFrom: '',
  vodPlayUrl: '',
  typeName: '',
  vodCode: vodCode,
  vodActressPic: '',
);

void main() {
  group('网盘番号提取（截图样本）', () {
    test('文件夹名即番号', () {
      expect(pan115ExtractCode('HRSM-032'), 'HRSM-032');
      expect(pan115ExtractCode('HODV-21775'), 'HODV-21775');
      expect(pan115ExtractCode('HJMO-652'), 'HJMO-652');
      expect(pan115ExtractCode('HJMO-638.mp4'), 'HJMO-638');
    });

    test('带字幕后缀仍提主番号', () {
      expect(pan115ExtractCode('HJMO-652-C.mp4'), 'HJMO-652');
    });

    test('提不出番号的名字回 null', () {
      expect(pan115ExtractCode('普通电影.mp4'), isNull);
      expect(pan115ExtractCode('云下载'), isNull);
      expect(pan115ExtractCode('女优合集357都月るいさ作品1高清无水印29集'), isNull);
      expect(pan115ExtractCode('53DV-松島かえで'), isNull);
      expect(pan115ExtractCode('論壇文宣'), isNull);
    });

    // DV 前缀在 CodeExtractor 屏蔽表里（杜比视界规格词），与
    // 星辰115 Kotlin 原版一致：提取器本体对 DV 系列回 null，
    // 刮削层靠 panCoverExtractCode 的窄救援补（见下组）。
    test('DV 系列提取器本体回 null（与原版一致）', () {
      expect(pan115ExtractCode('DV-390(53dv390).mp4'), isNull);
      expect(pan115ExtractCode('DV-390.mp4'), isNull);
    });
  });

  group('刮削专用提取 panCoverExtractCode（DV 救援）', () {
    test('括号双写形状提出主番号', () {
      expect(panCoverExtractCode('DV-390(53dv390).mp4'), 'DV-390');
      expect(panCoverExtractCode('DV-405(53dv405).mkv'), 'DV-405');
      expect(panCoverExtractCode('DV-415(53dv415)'), 'DV-415');
    });

    test('裸番号与带后缀形状也能提', () {
      expect(panCoverExtractCode('DV-390.mp4'), 'DV-390');
      expect(panCoverExtractCode('DV-390-C.mp4'), 'DV-390');
    });

    test('普通名仍提不出（救援不误报）', () {
      expect(panCoverExtractCode('普通电影.mp4'), isNull);
      expect(panCoverExtractCode('云下载'), isNull);
      expect(panCoverExtractCode('53DV-松島かえで'), isNull);
      expect(panCoverExtractCode('HDR-2024 某电影.mkv'), isNull);
      expect(panCoverExtractCode('Movie DV.2024.1080p.mkv'), isNull);
      expect(panCoverExtractCode('ABC.2024.mkv'), isNull);
    });

    test('非 DV 番号仍走主提取器', () {
      expect(panCoverExtractCode('HRSM-032'), 'HRSM-032');
      expect(panCoverExtractCode('HJMO-652-C.mp4'), 'HJMO-652');
    });
  });

  group('本地库命中行匹配 panLocalCoverOf', () {
    test('vodId 同 slug 且带封面命中', () {
      final cover = panLocalCoverOf([
        _entry(vodId: 'hjmo-652', vodPic: 'https://img/hjmo652.jpg'),
      ], 'HJMO-652');
      expect(cover, 'https://img/hjmo652.jpg');
    });

    test('vodCode 对上也认（vodId 写法不同）', () {
      final cover = panLocalCoverOf([
        _entry(
          vodId: 'abc123xyz',
          vodCode: 'DV-390',
          vodPic: 'https://img/dv390.jpg',
        ),
      ], 'DV-390');
      expect(cover, 'https://img/dv390.jpg');
    });

    test('番号不同不串片', () {
      final cover = panLocalCoverOf([
        _entry(vodId: 'hjmo-653', vodPic: 'https://img/hjmo653.jpg'),
      ], 'HJMO-652');
      expect(cover, '');
    });

    test('命中行没封面不算命中', () {
      final cover = panLocalCoverOf([
        _entry(vodId: 'hjmo-652', vodPic: ''),
      ], 'HJMO-652');
      expect(cover, '');
    });
  });

  group('刮削链 PanCoverScrapeService', () {
    test('本地库命中直接用，JavDB 不发查询', () async {
      var javdbCalls = 0;
      final service = PanCoverScrapeService(
        localLookup: (_) async => 'https://img/local.jpg',
        javdbLookup: (_) async {
          javdbCalls++;
          return 'https://img/javdb.jpg';
        },
      );
      expect(await service.coverForCode('HJMO-652'), 'https://img/local.jpg');
      expect(javdbCalls, 0);
    });

    test('本地库没有才落 JavDB', () async {
      final service = PanCoverScrapeService(
        localLookup: (_) async => '',
        javdbLookup: (code) async =>
            code == 'DV-390' ? 'https://img/javdb.jpg' : '',
      );
      expect(await service.coverForCode('DV-390'), 'https://img/javdb.jpg');
    });

    test('两路都查不到回空（保持占位）', () async {
      final service = PanCoverScrapeService(
        localLookup: (_) async => '',
        javdbLookup: (_) async => '',
      );
      expect(await service.coverForCode('HJMO-652'), '');
    });

    test('本地库抛错静默落 JavDB', () async {
      final service = PanCoverScrapeService(
        localLookup: (_) async => throw StateError('库打不开'),
        javdbLookup: (_) async => 'https://img/javdb.jpg',
      );
      expect(await service.coverForCode('HJMO-652'), 'https://img/javdb.jpg');
    });

    test('提不出番号不发任何查询', () async {
      var calls = 0;
      final service = PanCoverScrapeService(
        localLookup: (_) async {
          calls++;
          return 'https://img/local.jpg';
        },
        javdbLookup: (_) async {
          calls++;
          return 'https://img/javdb.jpg';
        },
      );
      expect(await service.coverForName('普通电影.mp4'), '');
      expect(calls, 0);
    });

    test('coverForName 括号写法按主番号查', () async {
      final asked = <String>[];
      final service = PanCoverScrapeService(
        localLookup: (code) async {
          asked.add(code);
          return 'https://img/local.jpg';
        },
        javdbLookup: (_) async => '',
      );
      expect(
        await service.coverForName('DV-390(53dv390).mp4'),
        'https://img/local.jpg',
      );
      expect(asked, ['DV-390']);
    });
  });
}
