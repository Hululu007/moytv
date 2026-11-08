import 'dart:io';

import 'package:moyi/app_update.dart';
import 'package:moyi/update_download.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('AppVersion', () {
    test('parses tags and build numbers', () {
      expect(AppVersion.tryParse('v1.4.10'), const AppVersion(1, 4, 10, 0));
      expect(
        AppVersion.tryParse('release-1.4.9+102'),
        const AppVersion(1, 4, 9, 102),
      );
      expect(AppVersion.tryParse('v1.4.8-101'), const AppVersion(1, 4, 8, 101));
      expect(AppVersion.tryParse('no-version'), isNull);
    });

    test('compares version before build', () {
      expect(
        AppVersion.tryParse('1.4.10+1')! > AppVersion.tryParse('1.4.9+999')!,
        isTrue,
      );
      expect(
        AppVersion.tryParse('1.4.9+103')! > AppVersion.tryParse('1.4.9+102')!,
        isTrue,
      );
      expect(
        AppVersion.tryParse('1.4.9+102')! == AppVersion.tryParse('v1.4.9+102')!,
        isTrue,
      );
    });
  });

  group('AppReleaseInfo.fromGithubJson', () {
    test('selects the arm64 apk and its digest', () {
      final info = AppReleaseInfo.fromGithubJson({
        'tag_name': 'v1.4.10',
        'name': '1.4.10',
        'body': 'notes',
        'html_url': 'https://example.invalid/release',
        'assets': [
          {
            'name': 'app-x86_64.apk',
            'browser_download_url': 'https://example.invalid/x.apk',
            'size': 10,
          },
          {
            'name': 'app-arm64-v8a.apk',
            'browser_download_url': 'https://example.invalid/a.apk',
            'size': 20,
            'digest': 'sha256:ABCDEF',
          },
        ],
      });
      expect(info?.version, const AppVersion(1, 4, 10, 0));
      expect(info?.apkName, 'app-arm64-v8a.apk');
      expect(info?.apkSize, 20);
      expect(info?.apkSha256, 'abcdef');
    });
  });

  group('release selection against the mirror repo shape', () {
    final releases = [
      {
        'tag_name': 'core-1.4.9',
        'name': 'core 1.4.9',
        'draft': false,
        'prerelease': false,
        'html_url': 'https://example.invalid/core',
        'assets': [
          {
            'name': 'core-manifest.json',
            'browser_download_url': 'https://example.invalid/manifest.json',
            'size': 900,
          },
          {
            'name': 'libmoyi_core.so',
            'browser_download_url': 'https://example.invalid/core.so',
            'size': 5000,
          },
        ],
      },
      {
        'tag_name': 'v1.4.8-101',
        'name': 'jianhuang 1.4.8+101',
        'draft': false,
        'prerelease': false,
        'html_url': 'https://example.invalid/app',
        'assets': [
          {
            'name': 'quanjushijie-1.4.8.101-arm64-v8a.apk',
            'browser_download_url': 'https://example.invalid/app.apk',
            'size': 101718689,
            'digest':
                'sha256:771ce92d3adfda60cc9cc22d9df0dbd0c7fd5be38a5a981fbef518b9f9071193',
          },
          {
            'name': 'quanjushijie-1.4.8.101-ios-unsigned.ipa',
            'browser_download_url': 'https://example.invalid/app.ipa',
            'size': 55515092,
          },
        ],
      },
    ];

    test('app selection skips core releases and reads dash build tags', () {
      final info = AppUpdateChecker.selectAppRelease(releases);
      expect(info?.version, const AppVersion(1, 4, 8, 101));
      expect(info?.apkName, 'quanjushijie-1.4.8.101-arm64-v8a.apk');
      expect(info?.apkSha256, startsWith('771ce92d'));
    });
  });

  group('ResumableDownloader', () {
    test('downloads fully and resumes with a Range request', () async {
      final payload = List<int>.generate(10000, (i) => i % 251);
      final ranges = <String?>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        final range = request.headers.value('range');
        ranges.add(range);
        if (range != null && range.startsWith('bytes=')) {
          final start = int.parse(range.substring(6, range.indexOf('-')));
          request.response.statusCode = 206;
          request.response.headers.set(
            'content-range',
            'bytes $start-${payload.length - 1}/${payload.length}',
          );
          request.response.add(payload.sublist(start));
        } else {
          request.response.add(payload);
        }
        request.response.close();
      });
      final dir = await Directory.systemTemp.createTemp('dl_test');
      addTearDown(() => dir.delete(recursive: true));
      final url = 'http://127.0.0.1:${server.port}/file.bin';
      final target = File(path.join(dir.path, 'file.bin'));
      final downloader = ResumableDownloader();
      final file = await downloader.download(url: url, target: target);
      expect(await file.readAsBytes(), payload);
      expect(ranges.first, isNull);

      final target2 = File(path.join(dir.path, 'file2.bin'));
      await File('${target2.path}.part').writeAsBytes(payload.sublist(0, 4000));
      final file2 = await downloader.download(url: url, target: target2);
      expect(await file2.readAsBytes(), payload);
      expect(ranges.last, 'bytes=4000-');
    });
  });
}
