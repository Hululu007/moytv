import 'package:moyi/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 30, 9, 30);
  test('no fetch record always refreshes on restore', () {
    expect(shouldSilentRefreshOnRestore(null, now), isTrue);
  });
  test('fresh snapshot skips silent refresh on restore', () {
    expect(
      shouldSilentRefreshOnRestore(
        now.subtract(const Duration(minutes: 1)),
        now,
      ),
      isFalse,
    );
    expect(
      shouldSilentRefreshOnRestore(
        now.subtract(const Duration(minutes: 4, seconds: 59)),
        now,
      ),
      isFalse,
    );
  });
  test('stale snapshot refreshes on restore', () {
    expect(
      shouldSilentRefreshOnRestore(
        now.subtract(const Duration(minutes: 5)),
        now,
      ),
      isTrue,
    );
    expect(
      shouldSilentRefreshOnRestore(
        now.subtract(const Duration(minutes: 30)),
        now,
      ),
      isTrue,
    );
  });
}
