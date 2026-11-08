import 'package:moyi/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

AppReleaseInfo release(String notes) {
  final info = AppReleaseInfo.fromGithubJson({
    'tag_name': 'v1.4.26',
    'name': '1.4.26',
    'body': notes,
    'html_url': 'https://example.test/releases',
    'assets': [],
  });
  expect(info, isNotNull);
  return info!;
}

void main() {
  test('force window markers parse from notes', () {
    final info = release(
      '修复若干问题\nFORCE_AFTER: 2026-10-01\nFORCE_UNTIL: 2026-12-31\n',
    );
    expect(info.forceAfter, DateTime(2026, 10, 1));
    expect(info.forceUntil, DateTime(2026, 12, 31, 23, 59, 59, 999));
  });

  test('invalid markers are ignored', () {
    final info = release('FORCE_AFTER: not-a-date\nFORCE_UNTIL: 2026-13-40\n');
    expect(info.forceAfter, isNull);
    expect(info.forceUntil, isNull);
    final plain = release('没有标记的说明');
    expect(plain.forceAfter, isNull);
    expect(plain.forceUntil, isNull);
  });

  test('force window bounds are inclusive', () {
    final current = AppVersion(1, 4, 25, 118);
    final info = release('FORCE_AFTER: 2026-10-01\nFORCE_UNTIL: 2026-12-31\n');
    expect(
      AppUpdateChecker.isForceUpdate(
        current,
        info,
        DateTime(2026, 9, 30, 23, 59),
      ),
      isFalse,
    );
    expect(
      AppUpdateChecker.isForceUpdate(current, info, DateTime(2026, 10, 1)),
      isTrue,
    );
    expect(
      AppUpdateChecker.isForceUpdate(current, info, DateTime(2026, 11, 15)),
      isTrue,
    );
    expect(
      AppUpdateChecker.isForceUpdate(
        current,
        info,
        DateTime(2026, 12, 31, 23, 59),
      ),
      isTrue,
    );
    expect(
      AppUpdateChecker.isForceUpdate(current, info, DateTime(2027, 1, 1)),
      isFalse,
    );
  });

  test('no force without markers or without a newer version', () {
    final current = AppVersion(1, 4, 25, 118);
    final plain = release('普通更新');
    expect(
      AppUpdateChecker.isForceUpdate(current, plain, DateTime(2026, 11, 1)),
      isFalse,
    );
    final info = release('FORCE_AFTER: 2026-10-01\nFORCE_UNTIL: 2026-12-31\n');
    expect(
      AppUpdateChecker.isForceUpdate(
        AppVersion(1, 4, 26, 119),
        info,
        DateTime(2026, 11, 1),
      ),
      isFalse,
    );
    final afterOnly = release('FORCE_AFTER: 2026-10-01\n');
    expect(
      AppUpdateChecker.isForceUpdate(current, afterOnly, DateTime(2026, 9, 1)),
      isFalse,
    );
    expect(
      AppUpdateChecker.isForceUpdate(current, afterOnly, DateTime(2027, 6, 1)),
      isTrue,
    );
    final untilOnly = release('FORCE_UNTIL: 2026-12-31\n');
    expect(
      AppUpdateChecker.isForceUpdate(current, untilOnly, DateTime(2026, 1, 1)),
      isTrue,
    );
    expect(
      AppUpdateChecker.isForceUpdate(current, untilOnly, DateTime(2027, 1, 1)),
      isFalse,
    );
  });
}
