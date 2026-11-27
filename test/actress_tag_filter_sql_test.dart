// 问题 5（2026-11-27）：演员库分类片点了不筛选——根因是
// listPersons/countPersons 的视频库分支用“按人名相关”的
// EXISTS 子查询筛分类（actresses.name 无索引，规划器逐行
// 全表扫，3 万人量级在定版库上 25 分钟跑不完；手机上首屏
// 超时、页面保留旧名单，观感就是点了没反应）。
// 修法：集合先行——actressNameInCategorySql /
// actressNameInTagSql 从分类/标签索引出发一趟算出人名集合，
// 外层 IN 一次物化。本测试钉住这两个条件的形状，防止退回
// 相关子查询；语义与性能在定版库上的 sqlite3 重放证据见
// ~/workspace/moyi_phonefix_20261127/REPORT.md（问题 5）。
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';

void main() {
  group('actressNameInCategorySql', () {
    test('是集合先行的 IN 子查询，不含按人名相关的 EXISTS', () {
      final sql = actressNameInCategorySql('r.name');
      expect(sql, startsWith('r.name IN (SELECT a9.name FROM '));
      expect(sql, contains('video_category vc9'));
      expect(sql, contains('video_actress va9'));
      expect(sql, contains('actresses a9'));
      expect(sql, contains("COALESCE(vc9.main_category, '') = ?"));
      // 绝不允许退回逐人相关：子查询里不得出现外层别名关联。
      expect(sql, isNot(contains('EXISTS')));
      expect(sql, isNot(contains('a9.name = r.name')));
      expect(sql, isNot(contains('va2')));
    });

    test('外层名字表达式可替换（汇总表/回退/计数三处共用）', () {
      expect(
        actressNameInCategorySql('a.name'),
        startsWith('a.name IN (SELECT a9.name FROM '),
      );
      expect(
        actressNameInCategorySql('actresses.name'),
        startsWith('actresses.name IN (SELECT a9.name FROM '),
      );
    });

    test('只有一个参数占位（分类值）', () {
      final sql = actressNameInCategorySql('r.name');
      expect('?'.allMatches(sql).length, 1);
    });
  });

  group('actressNameInTagSql', () {
    test('走 video_tag 的标签名集合，同样集合先行', () {
      final sql = actressNameInTagSql('a.name');
      expect(sql, startsWith('a.name IN (SELECT a9.name FROM '));
      expect(sql, contains('video_tag vt9'));
      expect(sql, contains('vt9.tag_name = ?'));
      expect(sql, isNot(contains('EXISTS')));
      expect('?'.allMatches(sql).length, 1);
    });
  });
}
