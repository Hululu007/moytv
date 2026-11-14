import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/cloud_drive/cloud_filename.dart';

void main() {
  group('parseCloudFileName 中文季集', () {
    test('第X季第Y集', () {
      final p = parseCloudFileName('进击的巨人 第2季 第3集.mp4');
      expect(p.seriesTitle, '进击的巨人');
      expect(p.season, 2);
      expect(p.episode, 3);
      expect(p.groupable, isTrue);
    });

    test('中文数字集号', () {
      final p = parseCloudFileName('剧名 第十二集.mp4');
      expect(p.seriesTitle, '剧名');
      expect(p.episode, 12);
      expect(p.season, isNull);
    });

    test('裸“第1集”无剧名不分组', () {
      final p = parseCloudFileName('第1集.mp4');
      expect(p.seriesTitle, isEmpty);
      expect(p.normalizedKey, isEmpty);
      expect(p.groupable, isFalse);
      expect(p.searchTitle, '第1集');
    });
  });

  group('parseCloudFileName 西式写法', () {
    test('SxxEyy + 发布标签', () {
      final p = parseCloudFileName('进击的巨人 S01E02 [1080p][x264].mkv');
      expect(p.seriesTitle, '进击的巨人');
      expect(p.season, 1);
      expect(p.episode, 2);
    });

    test('EP 裸集号', () {
      expect(parseCloudFileName('剧名 EP12.mp4').episode, 12);
      expect(parseCloudFileName('剧名 E03.mkv').episode, 3);
    });

    test('末尾数字当集号', () {
      expect(parseCloudFileName('剧名 12.mp4').episode, 12);
      expect(parseCloudFileName('剧名-03.mp4').episode, 3);
    });

    test('点分隔英文名 + 年份', () {
      final p = parseCloudFileName('Movie.Name.2024.1080p.BluRay.x264.mkv');
      expect(p.seriesTitle, 'Movie Name');
      expect(p.year, '2024');
      expect(p.episode, isNull);
    });
  });

  group('parseCloudFileName 归一与回落', () {
    test('不同分隔写法归同一键', () {
      final a = parseCloudFileName('进击的巨人 第1集.mp4');
      final b = parseCloudFileName('进击的巨人.第2集.mp4');
      final c = parseCloudFileName('进击的巨人_第3集.mp4');
      expect(a.normalizedKey, b.normalizedKey);
      expect(a.normalizedKey, c.normalizedKey);
      expect(a.normalizedKey, '进击的巨人');
    });

    test('无集号文件不分组', () {
      final p = parseCloudFileName('正片.mp4');
      expect(p.seriesTitle, '正片');
      expect(p.episode, isNull);
      expect(p.groupable, isFalse);
    });

    test('独立年份剥离进 year 字段', () {
      final p = parseCloudFileName('流浪地球 2019 1080p WEB-DL.mp4');
      expect(p.seriesTitle, '流浪地球');
      expect(p.year, '2019');
    });

    test('贴在剧名里的年份不动', () {
      final p = parseCloudFileName('2001太空漫游.mp4');
      expect(p.seriesTitle, '2001太空漫游');
    });

    test('中文发布词独立成词才去掉', () {
      expect(parseCloudFileName('剧名 国语 第1集.mp4').seriesTitle, '剧名');
      expect(parseCloudFileName('国语剧场 第1集.mp4').seriesTitle, '国语剧场');
    });

    test('括号发布信息整段去掉', () {
      final p = parseCloudFileName('剧名 (2024) [WEB-DL] 第1集.mp4');
      expect(p.seriesTitle, '剧名');
      expect(p.episode, 1);
    });
  });
}
