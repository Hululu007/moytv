import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/midnight_zone.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:moyi/settings_screen.dart';
import 'package:moyi/signature_check.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _SourceManagedRepository extends FixtureRepository {
  @override
  bool get supportsSourceManagement => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('adult source names carry the prefix', () {
    expect(isAdultSourceName('🔞快猫'), isTrue);
    expect(isAdultSourceName('🔞'), isTrue);
    expect(isAdultSourceName('HGTV'), isFalse);
    expect(isAdultSourceName(''), isFalse);
  });

  test('adult filter keeps only the selected side', () {
    const names = ['HGTV', '🔞快猫', '红果', '🔞撸先生'];
    expect(filterSourcesByAdult(names, (name) => name, true), [
      '🔞快猫',
      '🔞撸先生',
    ]);
    expect(filterSourcesByAdult(names, (name) => name, false), ['HGTV', '红果']);
    expect(filterSourcesByAdult(names, (name) => name, null), names);
  });

  test('signature verdict allows unknown and expected values only', () {
    expect(isSignatureAllowed(null), isTrue);
    expect(isSignatureAllowed(releaseSignatureSha256), isTrue);
    expect(isSignatureAllowed('0' * 64), isFalse);
    expect(releaseSignatureSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    VoidCallback? onHideAdult,
  }) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          repository: _SourceManagedRepository(),
          store: store,
          onHideAdult: onHideAdult,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('settings has no separate midnight entry after the merge', (
    tester,
  ) async {
    await pumpSettings(tester, onHideAdult: () {});
    // 午夜区已并入统一站点区：设置里不再有午夜区入口。
    expect(find.text('午夜区'), findsNothing);
    // 未成年保护始终在设置里，统一站点区是唯一的管理入口。
    expect(find.text('未成年保护'), findsOneWidget);
    expect(find.text('站点区'), findsOneWidget);
    expect(find.text('站源管理'), findsNothing);
    expect(find.text('软件更新'), findsOneWidget);
  });

  testWidgets('shell bar has no midnight entry', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox.shrink(),
          bottomNavigationBar: NeonCapsuleBar(
            entries: const [
              (LucideIcons.clapperboard, '片库'),
              (LucideIcons.tv, '直播'),
              (LucideIcons.headphones, '听书'),
              (LucideIcons.bookOpen, '阅读'),
              (LucideIcons.hardDrive, '多媒体'),
              (LucideIcons.layoutGrid, '小程序'),
              (LucideIcons.user, '我的'),
            ],
            index: 0,
            onSelect: (_) {},
            onCenter: () {},
            centerAfter: 3,
          ),
        ),
      ),
    );
    await tester.pump();
    for (final label in ['片库', '直播', '听书', '阅读', '多媒体', '小程序', '我的']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('午夜区'), findsNothing);
  });

  testWidgets('settings guardian switch hides adult sites once', (
    tester,
  ) async {
    var hideCalls = 0;
    await pumpSettings(tester, onHideAdult: () => hideCalls++);
    expect(find.text('未成年保护'), findsOneWidget);
    await tester.tap(find.text('未成年保护'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(hideCalls, 1);
  });
}
