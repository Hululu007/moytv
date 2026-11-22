// 2026-11-22 用户报「修复数据库把数据库删坏了」：
// 截图库 categories/crawl_state/meta/videos（plain `id` 主键）。
// 纯函数测试，不碰真 sqlite 库（flutter test 里 sqflite 没有桌面实现；
// 写库 SQL 的重放见 python 回放脚本，行数结果记在提交说明里）。
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_generic_db.dart';
import 'package:moyi/actress/video_db_repair.dart';

/// 截图里的四张表（按截图里的列顺序）。
Map<String, List<String>> get screenshotTables => {
  'categories': ['id', 'name', 'last_updated'],
  'crawl_state': [
    'category_id',
    'current_page',
    'total_pages',
    'status',
    'last_updated',
  ],
  'meta': ['key', 'value'],
  'videos': [
    'id',
    'category_id',
    'name',
    'image',
    'actor',
    'director',
    'remarks',
    'pubdate',
    'area',
    'year',
    'content',
    'play_url',
    'crawl_time',
  ],
};

void main() {
  group('识别表：plain id 主键的外来库', () {
    test('id / videoid / vid / vodid / movieid / workid 都是番号', () {
      for (final column in ['id', 'videoid', 'vid', 'vodid', 'movieid', 'workid']) {
        expect(
          roleForColumn(column)?.$1,
          GenericDbRole.code,
          reason: column,
        );
      }
    });

    test('video 不被 vid 关键词抢走：仍是播放地址', () {
      expect(roleForColumn('video')?.$1, GenericDbRole.playUrl);
      expect(roleForColumn('video_url')?.$1, GenericDbRole.playUrl);
    });

    test('category_id 是分类（精确全名，不靠关键词）', () {
      expect(roleForColumn('category_id')?.$1, GenericDbRole.category);
    });

    test('截图库：作品表是 videos，关键角色全认出', () {
      final schema = classifyGenericTables(screenshotTables);
      final works = schema.worksTable;
      expect(works?.table, 'videos');
      expect(works?.columnFor(GenericDbRole.title), 'name');
      expect(works?.columnFor(GenericDbRole.cover), 'image');
      expect(works?.columnFor(GenericDbRole.playUrl), 'play_url');
      expect(works?.columnFor(GenericDbRole.actress), 'actor');
      expect(works?.columnFor(GenericDbRole.code), 'id');
      expect(works?.columnFor(GenericDbRole.category), 'category_id');
      expect(works?.columnFor(GenericDbRole.date), 'pubdate');
      expect(works?.idColumn, 'id');
    });

    test('截图库：categories 不再被当成人物表', () {
      final schema = classifyGenericTables(screenshotTables);
      expect(schema.personsTable, isNull);
    });

    test('截图库：categories 是分类字典表（反方向查表）', () {
      final schema = classifyGenericTables(screenshotTables);
      final lookup = schema.facetRelations.where(
        (r) => r.table == 'categories',
      );
      expect(lookup.length, 1);
      final relation = lookup.first;
      expect(relation.foreignKey, 'id');
      expect(relation.primaryKey, 'category_id');
      expect(
        relation.columnFor(GenericDbRole.category),
        'name',
      );
    });

    test('截图库：指纹与截图一致', () {
      final schema = classifyGenericTables(screenshotTables);
      expect(
        schema.fingerprint,
        'categories(id,name,last_updated);'
        'crawl_state(category_id,current_page,total_pages,status,last_updated);'
        'meta(key,value);'
        'videos(id,category_id,name,image,actor,director,remarks,pubdate,area,year,content,play_url,crawl_time)',
      );
    });
  });

  group('删死链连带表：裸 id 绝不当外键', () {
    test('截图库：categories / crawl_state / meta 都不连带删', () {
      final links = VideoDbRepair.linkTablesFor(
        screenshotTables,
        'videos',
        'id',
      );
      expect(links, isEmpty);
    });

    test('女优库标准结构：video_actress / video_category 照旧连带', () {
      final links = VideoDbRepair.linkTablesFor({
        'videos': ['vod_id', 'title'],
        'actresses': ['cate_id', 'name', 'avatar'],
        'video_actress': ['vod_id', 'cate_id'],
        'video_category': ['vod_id', 'main_category'],
      }, 'videos', 'vod_id');
      expect(
        links.map((l) => '${l.table}.${l.column}'),
        containsAll(['video_actress.vod_id', 'video_category.vod_id']),
      );
      expect(
        links.map((l) => l.table),
        isNot(contains('actresses')),
      );
    });

    test('外键味的列名仍算关联（movie_id → files.movie_id）', () {
      final links = VideoDbRepair.linkTablesFor({
        'movies': ['movie_id', 'title', 'url'],
        'files': ['movie_id', 'url'],
        'meta': ['key', 'value'],
      }, 'movies', 'movie_id');
      expect(
        links.map((l) => '${l.table}.${l.column}'),
        ['files.movie_id'],
      );
    });

    test('主键为空不连带任何表', () {
      expect(
        VideoDbRepair.linkTablesFor(screenshotTables, 'videos', ''),
        isEmpty,
      );
    });
  });
}
