import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_play_record.dart';
import 'package:moyi/models.dart';

/// 播片自动记录（2026-11-25 用户令：写的那边也走新方法）：
/// 播放器真播起来后记进内部工作库（.sql 导入落成的库），
/// 不再写 MYTV/db/站点库.db。假 writer 捕获条目断言；
/// 真库落盘链路另见下方 Python sqlite3 重放验证
/// （按 _mergeVideoEntry 的 SQL 写一行 → listFilms 的 SQL 能查到）。
void main() {
  group('ActressPlayRecorder 播片记录（写内部工作库）', () {
    const drama = Drama(
      id: 'SSIS-123',
      source: 'chaoliu',
      title: '测试片名',
      cover: 'https://img.example.com/cover.jpg',
      category: '有码',
      onlineDate: '2024-01-02',
      description: '简介',
    );

    test('合法播放写进一条：番号归一化、字段齐全', () async {
      final written = <VideoLibraryEntry>[];
      final recorder = ActressPlayRecorder(
        writer: (entries) async {
          written.addAll(entries);
        },
      );
      final ok = await recorder.recordPlay(
        drama: drama,
        playUrl: 'https://cdn.example.com/SSIS-123.m3u8',
      );
      expect(ok, isTrue);
      expect(written, hasLength(1));
      final entry = written.single;
      expect(entry.vodId, 'ssis-123');
      expect(entry.title, '测试片名');
      expect(entry.picUrl, 'https://img.example.com/cover.jpg');
      expect(entry.playUrl, 'https://cdn.example.com/SSIS-123.m3u8');
      expect(entry.playFrom, 'chaoliu');
      expect(entry.typeName, '有码');
      expect(entry.category, '有码');
      expect(entry.actressName, '');
    });

    test('非法地址不写：空地址/非 http(s)/空番号都回 false', () async {
      var calls = 0;
      final recorder = ActressPlayRecorder(
        writer: (_) async {
          calls++;
        },
      );
      expect(await recorder.recordPlay(drama: drama, playUrl: ''), isFalse);
      expect(
        await recorder.recordPlay(drama: drama, playUrl: 'ftp://x/y.mp4'),
        isFalse,
      );
      expect(
        await recorder.recordPlay(drama: drama, playUrl: 'not-a-url'),
        isFalse,
      );
      const noId = Drama(id: '', source: 'chaoliu', title: '没番号');
      expect(
        await recorder.recordPlay(
          drama: noId,
          playUrl: 'https://cdn.example.com/x.m3u8',
        ),
        isFalse,
      );
      expect(calls, 0);
    });

    test('写库抛错回 false，不挡播放', () async {
      final recorder = ActressPlayRecorder(
        writer: (_) async {
          throw StateError('库还没导入');
        },
      );
      expect(
        await recorder.recordPlay(
          drama: drama,
          playUrl: 'https://cdn.example.com/SSIS-123.m3u8',
        ),
        isFalse,
      );
    });
  });
}
