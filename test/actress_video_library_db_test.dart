import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_models.dart';

// 视频库（女优库.db）纯函数测试：sqflite 在 flutter test 里打不开
// 真库（databaseFactory 未初始化），所以这里只测不碰数据库的纯
// 函数；SQL 与合并的端到端重放见 ~/workspace/.verify_tmp/
// whos_merge/ 下的 Python 脚本（sqlite3 跑 Dart 里的 SQL 原文）。
void main() {
  group('isVideoLibrarySchema', () {
    test('三张表齐了才认', () {
      expect(
        isVideoLibrarySchema({'actresses', 'videos', 'video_actress'}),
        isTrue,
      );
      expect(
        isVideoLibrarySchema(
          {'actresses', 'videos', 'video_actress', 'video_category'},
        ),
        isTrue,
      );
    });
    test('缺一张就不认', () {
      expect(isVideoLibrarySchema({'actresses', 'videos'}), isFalse);
      expect(isVideoLibrarySchema({'videos', 'video_actress'}), isFalse);
      expect(isVideoLibrarySchema({'actresses', 'video_actress'}), isFalse);
      expect(isVideoLibrarySchema({'persons', 'works'}), isFalse);
      expect(isVideoLibrarySchema({}), isFalse);
    });
  });

  group('videoLibraryPersonFromRow', () {
    test('原库行：名字即 cate_id，无来源身份', () {
      final person = videoLibraryPersonFromRow({
        'id': 7,
        'display_name': '今村由美',
        'cate_id': '今村由美',
        'avatar_url': 'https://example.com/a.jpg',
        'works_count': 12,
      });
      expect(person.localId, 7);
      expect(person.displayName, '今村由美');
      // 2026-11-23 v58 修复：老库行没有 sex 列时性别是未知（''），
      // 不许再默认成“女”（貞松大輔是男优却显示“女”就是这么来的）。
      expect(person.sex, '');
      expect(person.avatarUrl, 'https://example.com/a.jpg');
      expect(person.worksCount, 12);
      expect(person.rosterWorks, 12);
      expect(person.exactWorks, 12);
      expect(person.fromWhos, isFalse);
      expect(person.fromChaoliu, isFalse);
      expect(person.fromMissav, isFalse);
      expect(person.sourceIdFor(ActressRosterSourceId.whos), '');
    });

    test('新补的 whos 行：cate_id 解析出 slug', () {
      final person = videoLibraryPersonFromRow({
        'id': 30001,
        'display_name': '新人A',
        'cate_id': 'whos:alice-chan',
        'avatar_url': '',
        'works_count': 0,
      });
      expect(person.fromWhos, isTrue);
      expect(person.whosSlug, 'alice-chan');
      expect(
        person.sourceIdFor(ActressRosterSourceId.whos),
        'alice-chan',
      );
      expect(person.fromChaoliu, isFalse);
      expect(person.worksCount, 0);
    });

    test('新补的 mjv / missav 行：cate_id 解析出来源 id', () {
      final mjv = videoLibraryPersonFromRow({
        'id': 30002,
        'display_name': '新人B',
        'cate_id': 'mjv:12345',
        'avatar_url': '',
        'works_count': 3,
      });
      expect(mjv.fromChaoliu, isTrue);
      expect(mjv.chaoliuId, '12345');
      expect(
        mjv.sourceIdFor(ActressRosterSourceId.chaoliu),
        '12345',
      );

      final missav = videoLibraryPersonFromRow({
        'id': 30003,
        'display_name': '新人C',
        'cate_id': 'missav:actresses/someone',
        'avatar_url': '',
        'works_count': 0,
      });
      expect(missav.fromMissav, isTrue);
      expect(missav.missavPath, 'actresses/someone');
    });
  });

  group('videoLibraryWorkFromRow', () {
    test('vod_id 作番号键/封面剧集 id，播放在 filmDb 兜底', () {
      final work = videoLibraryWorkFromRow({
        'id': 11,
        'code_key': 'ssis-123',
        'title': '测试标题',
        'date': '2024-01-02',
        'site': 'whos.tv',
        'cover_source': 'whos.tv',
        'cover_url': 'https://example.com/cover.jpg',
        'category': '有码',
      }, 7);
      expect(work.id, 11);
      expect(work.personId, 7);
      expect(work.codeKey, 'ssis-123');
      expect(work.codeDisplay, 'ssis-123');
      expect(work.coverDramaId, 'ssis-123');
      expect(work.title, '测试标题');
      expect(work.date, '2024-01-02');
      expect(work.site, 'whos.tv');
      expect(work.coverUrl, 'https://example.com/cover.jpg');
      expect(work.category, '有码');
    });
  });

  group('videoLibraryMergeAction', () {
    test('没有旧行 → insert', () {
      expect(
        videoLibraryMergeAction(null, 'https://example.com/a.m3u8'),
        VideoLibraryMergeAction.insert,
      );
    });
    test('同 vod_id 同链接 → skip', () {
      expect(
        videoLibraryMergeAction(
          'https://example.com/a.m3u8',
          'https://example.com/a.m3u8',
        ),
        VideoLibraryMergeAction.skip,
      );
    });
    test('同 vod_id 不同链接 → update', () {
      expect(
        videoLibraryMergeAction(
          'https://example.com/a.m3u8',
          'https://example.com/b.m3u8',
        ),
        VideoLibraryMergeAction.update,
      );
    });
    test('新地址为空 → skip（不拿空值盖已有地址）', () {
      expect(
        videoLibraryMergeAction('https://example.com/a.m3u8', ''),
        VideoLibraryMergeAction.skip,
      );
      expect(videoLibraryMergeAction('', ''), VideoLibraryMergeAction.skip);
    });
  });

  group('videoLibraryVodId', () {
    test('小写 + 横杠原样', () {
      expect(videoLibraryVodId('SSIS-123'), 'ssis-123');
      expect(videoLibraryVodId('mvsd-546'), 'mvsd-546');
      expect(videoLibraryVodId('  IPZZ-073 '), 'ipzz-073');
    });
    test('无横杠归一化码还原横杠', () {
      expect(videoLibraryVodId('SSIS123'), 'ssis-123');
      expect(videoLibraryVodId('MVSD546'), 'mvsd-546');
    });
    test('FC2 归成 fc2-ppv-…', () {
      expect(videoLibraryVodId('fc2ppv-4913308'), 'fc2-ppv-4913308');
      expect(videoLibraryVodId('FC2PPV4913308'), 'fc2-ppv-4913308');
      expect(videoLibraryVodId('FC2-PPV-1234567'), 'fc2-ppv-1234567');
    });
    test('前导零不去掉', () {
      expect(videoLibraryVodId('MMYM-032'), 'mmym-032');
      expect(videoLibraryVodId('IPZZ-073'), 'ipzz-073');
    });
    test('空串返回空串', () {
      expect(videoLibraryVodId(''), '');
      expect(videoLibraryVodId('   '), '');
    });
  });

  group('rosterVideoLibraryCateId', () {
    test('三家来源前缀', () {
      expect(
        rosterVideoLibraryCateId(
          ActressRosterSourceId.whos,
          'alice-chan',
        ),
        'whos:alice-chan',
      );
      expect(
        rosterVideoLibraryCateId(
          ActressRosterSourceId.chaoliu,
          '12345',
        ),
        'mjv:12345',
      );
      expect(
        rosterVideoLibraryCateId(
          ActressRosterSourceId.missav,
          'actresses/someone',
        ),
        'missav:actresses/someone',
      );
    });
  });

  group('ActressJsonEntry.playUrl', () {
    test('去掉 正片\$ 前缀', () {
      final entry = ActressJsonEntry(
        site: 'whos',
        vodId: '7320a540',
        vodName: '测试',
        vodPic: '',
        vodActor: '',
        vodDirector: '',
        vodRemarks: '高清',
        vodPubdate: '2024-01-01',
        vodArea: '',
        vodYear: '',
        vodContent: '',
        vodPlayFrom: 'whos',
        vodPlayUrl: '正片\$https://example.com/a.m3u8',
        typeName: '有码',
        vodCode: 'sdam-186',
        vodActressPic: '',
      );
      expect(entry.playUrl, 'https://example.com/a.m3u8');
      expect(entry.playable, isTrue);
    });
    test('没前缀就不是可播地址', () {
      final entry = ActressJsonEntry(
        site: 'whos',
        vodId: '7320a540',
        vodName: '测试',
        vodPic: '',
        vodActor: '',
        vodDirector: '',
        vodRemarks: '高清',
        vodPubdate: '2024-01-01',
        vodArea: '',
        vodYear: '',
        vodContent: '',
        vodPlayFrom: 'whos',
        vodPlayUrl: 'https://example.com/a.m3u8',
        typeName: '有码',
        vodCode: 'sdam-186',
        vodActressPic: '',
      );
      expect(entry.playUrl, '');
      expect(entry.playable, isFalse);
    });
  });
}
