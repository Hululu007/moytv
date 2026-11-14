import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/cloud_drive/cloud_drive_types.dart';

void main() {
  group('kindFromExtension', () {
    test('视频扩展名', () {
      for (final ext in [
        'mp4',
        'mkv',
        'avi',
        'mov',
        'wmv',
        'flv',
        'webm',
        'm4v',
        'ts',
        'm2ts',
        'rmvb',
        'rm',
        '3gp',
        'mpg',
        'mpeg',
        'f4v',
        'vob',
        'asf',
        'm3u8',
      ]) {
        expect(kindFromExtension('片子.$ext'), CloudFileKind.video, reason: ext);
      }
    });

    test('音频扩展名', () {
      for (final ext in [
        'mp3',
        'flac',
        'wav',
        'aac',
        'm4a',
        'ogg',
        'opus',
        'wma',
        'ape',
        'amr',
        'aiff',
        'dts',
      ]) {
        expect(kindFromExtension('歌.$ext'), CloudFileKind.audio, reason: ext);
      }
    });

    test('图片扩展名', () {
      for (final ext in [
        'jpg',
        'jpeg',
        'png',
        'gif',
        'webp',
        'bmp',
        'avif',
        'heic',
        'heif',
      ]) {
        expect(kindFromExtension('图.$ext'), CloudFileKind.image, reason: ext);
      }
    });

    test('字幕扩展名', () {
      for (final ext in [
        'srt',
        'ass',
        'ssa',
        'vtt',
        'sub',
        'smi',
        'sbv',
        'lrc',
      ]) {
        expect(
          kindFromExtension('字幕.$ext'),
          CloudFileKind.subtitle,
          reason: ext,
        );
      }
    });

    test('大小写不敏感', () {
      expect(kindFromExtension('片子.MP4'), CloudFileKind.video);
      expect(kindFromExtension('图.JPG'), CloudFileKind.image);
    });

    test('STRM 指针文件与 ISO 光盘认成视频，img 不认', () {
      expect(kindFromExtension('直播.strm'), CloudFileKind.video);
      expect(kindFromExtension('直播.STRM'), CloudFileKind.video);
      expect(kindFromExtension('电影.iso'), CloudFileKind.video);
      expect(kindFromExtension('电影.ISO'), CloudFileKind.video);
      // .img 含义太杂（磁盘镜像/固件/图片都用），无把握不认。
      expect(kindFromExtension('光盘.img'), CloudFileKind.other);
    });

    test('认不出来的归 other，绝不猜', () {
      expect(kindFromExtension('文档.pdf'), CloudFileKind.other);
      expect(kindFromExtension('压缩.zip'), CloudFileKind.other);
      expect(kindFromExtension('没扩展名'), CloudFileKind.other);
      expect(kindFromExtension('图片.tif'), CloudFileKind.other);
      expect(kindFromExtension('矢量.svg'), CloudFileKind.other);
      expect(kindFromExtension('种子.torrent'), CloudFileKind.other);
    });
  });

  group('classifyCloudFile', () {
    test('文件夹优先于一切', () {
      expect(
        classifyCloudFile(name: '片子.mp4', isFolder: true),
        CloudFileKind.folder,
      );
      expect(
        classifyCloudFile(
          name: '片子.mp4',
          isFolder: true,
          providerHint: CloudFileKind.video,
        ),
        CloudFileKind.folder,
      );
    });

    test('网盘提示优先于扩展名', () {
      expect(
        classifyCloudFile(
          name: '无名文件',
          isFolder: false,
          providerHint: CloudFileKind.video,
        ),
        CloudFileKind.video,
      );
    });

    test('网盘提示为 other 时回落扩展名', () {
      expect(
        classifyCloudFile(
          name: '片子.mp4',
          isFolder: false,
          providerHint: CloudFileKind.other,
        ),
        CloudFileKind.video,
      );
    });

    test('无提示时按扩展名', () {
      expect(
        classifyCloudFile(name: '歌.mp3', isFolder: false),
        CloudFileKind.audio,
      );
    });
  });

  group('scoreAdVideo 疑似广告视频判定', () {
    const mb = 1024 * 1024;

    test('三信号齐全判疑似', () {
      final v = scoreAdVideo(
        name: '最新地址 www.abc123.com 请收藏.mp4',
        sizeBytes: 25 * mb,
        durationSeconds: 30,
      );
      expect(v.suspected, isTrue);
    });

    test('文件名 + 小文件（无时长）也判疑似', () {
      final v = scoreAdVideo(name: '加微信 vx12345 更多精彩.mp4', sizeBytes: 20 * mb);
      expect(v.suspected, isTrue);
    });

    test('单靠名字像不判', () {
      final v = scoreAdVideo(
        name: '最新地址 www.abc123.com.mp4',
        sizeBytes: 900 * mb,
        durationSeconds: 3600,
      );
      expect(v.suspected, isFalse);
    });

    test('单靠小+短不判', () {
      final v = scoreAdVideo(
        name: '家庭聚会片段.mp4',
        sizeBytes: 10 * mb,
        durationSeconds: 20,
      );
      expect(v.suspected, isFalse);
    });

    test('时长超过 10 分钟否决', () {
      final v = scoreAdVideo(
        name: '推广 www.abc.com 请记住.mp4',
        sizeBytes: 25 * mb,
        durationSeconds: 601,
      );
      expect(v.suspected, isFalse);
      expect(v.score, 0);
    });

    test('超过 500MB 否决', () {
      final v = scoreAdVideo(
        name: '推广 www.abc.com 请记住.mp4',
        sizeBytes: 501 * mb,
        durationSeconds: 30,
      );
      expect(v.suspected, isFalse);
      expect(v.score, 0);
    });

    test('时长未知时时长信号不计分', () {
      // 文件名 1 分 + 大小 1 分（50MB）= 大小+时长 1 分 < 2，不判。
      final v = scoreAdVideo(name: '推广视频.mp4', sizeBytes: 50 * mb);
      expect(v.suspected, isFalse);
    });

    test('文件名分上限 3 分', () {
      final v = scoreAdVideo(
        name: 'www.a.com 加微信vx1 加QQ123 进群 永久地址 防走失 点击进入.mp4',
        sizeBytes: 10 * mb,
        durationSeconds: 30,
      );
      expect(v.suspected, isTrue);
      // 名 3 + 大小 2 + 时长 2 = 7。
      expect(v.score, 7);
    });

    test('联系方式模式', () {
      for (final name in [
        'QQ123456789.mp4',
        '加微信 abc123.mp4',
        'telegram 123456.mp4',
        '电报群 t.me/abc.mp4',
      ]) {
        final v = scoreAdVideo(
          name: name,
          sizeBytes: 10 * mb,
          durationSeconds: 10,
        );
        expect(v.suspected, isTrue, reason: name);
      }
    });
  });

  group('parseStrmContent', () {
    test('正常单行地址', () {
      expect(
        parseStrmContent('https://cdn.example.com/live.m3u8\n'),
        'https://cdn.example.com/live.m3u8',
      );
    });

    test('空行/BOM/CRLF 容错，取第一个非空行', () {
      expect(
        parseStrmContent('\uFEFF\r\n\n  https://cdn.example.com/a.mp4  \r\n'),
        'https://cdn.example.com/a.mp4',
      );
    });

    test('多行只取第一行（不是播放列表）', () {
      expect(
        parseStrmContent(
          'https://a.example.com/1.m3u8\nhttps://b.example.com/2.m3u8\n',
        ),
        'https://a.example.com/1.m3u8',
      );
    });

    test('非法内容一律返回 null', () {
      expect(parseStrmContent(''), isNull);
      expect(parseStrmContent('\n\n  \n'), isNull);
      expect(parseStrmContent('magnet:?xt=urn:btih:abc'), isNull);
      expect(parseStrmContent('/relative/path.mp4'), isNull);
      expect(parseStrmContent('ftp://x.example.com/a.mp4'), isNull);
      expect(parseStrmContent('https://'), isNull);
      expect(parseStrmContent('not a url'), isNull);
    });
  });

  group('光盘识别', () {
    test('文件判定', () {
      expect(isStrmFile('直播.strm'), isTrue);
      expect(isStrmFile('直播.mp4'), isFalse);
      expect(isIsoFile('电影.iso'), isTrue);
      expect(isIsoFile('电影.img'), isFalse);
      expect(isVobFile('VTS_01_1.VOB'), isTrue);
      expect(isVobFile('VTS_01_1.mp4'), isFalse);
      expect(isDiscMetadataFile('VIDEO_TS.IFO'), isTrue);
      expect(isDiscMetadataFile('VIDEO_TS.BUP'), isTrue);
      expect(isDiscMetadataFile('VIDEO_TS.VOB'), isFalse);
    });

    test('光盘文件夹名精确匹配', () {
      expect(discTypeOfFolder('VIDEO_TS'), 'dvd');
      expect(discTypeOfFolder('video_ts'), 'dvd');
      expect(discTypeOfFolder('  BDMV  '), 'bd');
      expect(discTypeOfFolder('BDMV_backup'), isNull);
      expect(discTypeOfFolder('MY_VIDEO_TS'), isNull);
      expect(discTypeOfFolder('电影'), isNull);
    });
  });

  group('isSuspectedAdVideo', () {
    test('按文件字段判定', () {
      const file = CloudDriveFile(
        id: '1',
        name: '最新地址 www.x.com.mp4',
        isFolder: false,
        kind: CloudFileKind.video,
        sizeBytes: 20 * 1024 * 1024,
        durationSeconds: 25,
      );
      expect(isSuspectedAdVideo(file), isTrue);
    });

    test('正片不判', () {
      const file = CloudDriveFile(
        id: '2',
        name: '电影正片.mp4',
        isFolder: false,
        kind: CloudFileKind.video,
        sizeBytes: 2 * 1024 * 1024 * 1024,
        durationSeconds: 5400,
      );
      expect(isSuspectedAdVideo(file), isFalse);
    });

    test('STRM 指针文件不判（几十字节是常态，大小信号无意义）', () {
      const file = CloudDriveFile(
        id: '3',
        name: '最新地址 www.x.com.strm',
        isFolder: false,
        kind: CloudFileKind.video,
        sizeBytes: 60,
      );
      expect(isSuspectedAdVideo(file), isFalse);
    });
  });

  group('CloudCoverSource', () {
    test('来源标签齐全', () {
      expect(CloudCoverSource.providerThumbnail.label, isNotEmpty);
      expect(CloudCoverSource.sameNameImage.label, isNotEmpty);
      expect(CloudCoverSource.placeholder.label, isNotEmpty);
    });
  });
}
