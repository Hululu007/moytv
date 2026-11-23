// 多库勾选判定（2026-11-23 用户令：数据库全部支持勾选）。
// sqflite 在 flutter test 里打不开真库（databaseFactory 未初始化），
// 所以判定层只测纯函数：classifyGenericTables /
// filmIsStrictVideosSchema / jsonEntriesForWorkTitle /
// normalizeAvCode；真库上的计数与适配器 SQL 端到端重放见
// ~/workspace/actress_generic_selection_verify/replay.py
//（Python sqlite3 跑 Dart 里的 SQL 原文，对真实 lsp/yellow/AV 总库）。
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_film_library.dart';
import 'package:moyi/actress/actress_generic_db.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_models.dart';

void main() {
  group('多库勾选判定：严格库', () {
    test('女优库三表齐全认作严格库', () {
      final schema = classifyGenericTables({
        'actresses': ['cate_id', 'name', 'avatar', 'sex'],
        'videos': [
          'vod_id',
          'title',
          'pic_url',
          'm3u8_url',
          'vod_play_url',
          'vod_play_from',
          'vod_pubdate',
          'type_name',
        ],
        'video_actress': ['vod_id', 'cate_id'],
        'video_category': ['vod_id', 'main_category'],
      });
      expect(schema.worksTable?.table, 'videos');
      expect(filmIsStrictVideosSchema(schema), isTrue);
    });
  });

  group('多库勾选判定：通用库', () {
    test('lsp.db：videos 表认作作品表，女优列是 actor', () {
      // 真实结构（2026-11-23 实测 ~/workspace/
      // actress_merge_av_lsp_yellow_20261123/src/lsp.db）：
      // videos 223654 行，actor 列全空（0 行有值）。
      final schema = classifyGenericTables({
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
        'categories': ['id', 'name', 'last_updated'],
        'meta': ['key', 'value'],
      });
      expect(filmIsStrictVideosSchema(schema), isFalse);
      final works = schema.worksTable;
      expect(works?.table, 'videos');
      expect(works?.columnFor(GenericDbRole.title), 'name');
      expect(works?.columnFor(GenericDbRole.cover), 'image');
      expect(works?.columnFor(GenericDbRole.actress), 'actor');
      expect(works?.columnFor(GenericDbRole.playUrl), 'play_url');
      expect(works?.columnFor(GenericDbRole.category), 'category_id');
      expect(works?.columnFor(GenericDbRole.date), 'pubdate');
    });

    test('yellow.db：videos 表认作作品表，没有女优列', () {
      // 真实结构（2026-11-23 实测 yellow.db）：videos 91849 行，
      // 只有 title/pic/play_url/cate_id/cate_name，没有女优列。
      final schema = classifyGenericTables({
        'videos': ['id', 'title', 'pic', 'play_url', 'cate_id', 'cate_name'],
      });
      expect(filmIsStrictVideosSchema(schema), isFalse);
      final works = schema.worksTable;
      expect(works?.table, 'videos');
      expect(works?.columnFor(GenericDbRole.title), 'title');
      expect(works?.columnFor(GenericDbRole.cover), 'pic');
      expect(works?.columnFor(GenericDbRole.playUrl), 'play_url');
      expect(works?.columnFor(GenericDbRole.actress), isNull);
    });

    test('AV 总库：三张严格表都在（空表），作品表仍是 videos', () {
      // 真实结构（2026-11-23 实测 av_total.db）：videos /
      // video_actress / video_category / actresses 全是 0 行，
      // 361681 条在 results 表（fanhao + video_url）。
      final schema = classifyGenericTables({
        'actresses': ['cate_id', 'name', 'avatar'],
        'videos': [
          'vod_id',
          'title',
          'pic_url',
          'm3u8_url',
          'vod_play_url',
          'vod_play_from',
          'vod_pubdate',
          'type_name',
          'created_at',
        ],
        'video_actress': ['vod_id', 'cate_id'],
        'video_category': ['vod_id', 'main_category'],
        'results': [
          'id',
          'url',
          'title',
          'clean_title',
          'fanhao',
          'main_cate',
          'sub_cate',
          'magnet_list',
          'video_url',
          'is_youma',
          'time',
        ],
      });
      // 表名齐了就认严格（行数是 countPlayableVideos 的事）。
      expect(filmIsStrictVideosSchema(schema), isTrue);
      expect(schema.worksTable?.table, 'videos');
      // results 表也被认作有标题 + 播放地址（计数时取最大那张）。
      final results = schema.tables.firstWhere((t) => t.table == 'results');
      expect(results.hasTitleAndPlayUrl, isTrue);
      expect(results.columnFor(GenericDbRole.title), 'title');
    });
  });

  group('标题兜底匹配 jsonEntriesForWorkTitle', () {
    ActressJsonEntry entry({
      required String name,
      required String playUrl,
      String code = '',
    }) =>
        ActressJsonEntry(
          site: 'chaoliu',
          vodId: 'generic:1',
          vodName: name,
          vodPic: '',
          vodActor: '',
          vodDirector: '',
          vodRemarks: '',
          vodPubdate: '',
          vodArea: '',
          vodYear: '',
          vodContent: '',
          vodPlayFrom: 'chaoliu',
          vodPlayUrl: playUrl,
          typeName: '',
          vodCode: code,
          vodActressPic: '',
          directPlay: true,
        );

    test('同标题（大小写/分隔符不同）匹配', () {
      final pool = [
        entry(name: 'IPZZ-840 标题', playUrl: '正片\$https://x/1.m3u8'),
      ];
      final hit = jsonEntriesForWorkTitle(pool, 'ipzz840 标题');
      expect(hit.length, 1);
    });

    test('不同标题不匹配', () {
      final pool = [
        entry(name: 'IPZZ-840 标题', playUrl: '正片\$https://x/1.m3u8'),
      ];
      expect(jsonEntriesForWorkTitle(pool, 'IPZZ-841 标题'), isEmpty);
    });

    test('纯中文标题归一化后为空，不硬认', () {
      final pool = [
        entry(name: '新婚人妻', playUrl: '正片\$https://x/1.m3u8'),
      ];
      expect(jsonEntriesForWorkTitle(pool, '新婚人妻'), isEmpty);
    });

    test('不可播的条目不进匹配', () {
      final pool = [
        entry(name: 'IPZZ-840 标题', playUrl: ''),
      ];
      expect(jsonEntriesForWorkTitle(pool, 'IPZZ-840 标题'), isEmpty);
    });
  });

  group('跨库去重键归一化', () {
    test('严格库 vod_id 与通用库 code 列归一化后相同', () {
      // 严格库存 'ipzz-840'、通用库 code 列存 'IPZZ-840'，
      // 去重键的番号位都要过 normalizeAvCode 才能对上。
      expect(normalizeAvCode('ipzz-840'), normalizeAvCode('IPZZ-840'));
      expect(normalizeAvCode('ipzz-840'), 'IPZZ840');
    });
  });
}
