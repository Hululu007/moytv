import 'dart:convert';

import 'package:moyi/core_bridge.dart';
import 'package:moyi/hongguo_drama_home.dart';
import 'package:moyi/local_profiles.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/main.dart';
import 'package:moyi/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const drama = Drama(id: 'hongguo:1', source: 'hongguo', title: '合成短剧');
  const denied = Drama(id: 'huangdou:2', source: 'huangdou', title: '受限合成短剧');



  test(
    'native entry points reject denied sources and downloads before native I/O',
    () async {
      SharedPreferences.setMockInitialValues({
        'profiles': jsonEncode([
          const LocalProfile(
            id: 'default',
            name: '管理员',
            admin: true,
            salt: '11111111111111111111111111111111',
            pinHash:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          ).toJson(),
          const LocalProfile(
            id: 'viewer',
            name: '只看红果',
            sources: ['hongguo'],
            download: false,
          ).toJson(),
        ]),
        'activeProfile': 'viewer',
      });
      final store = LocalStore(await SharedPreferences.getInstance());
      final repository = NativeRepository()..access = store;
      expect(repository.supportsDownloads, isFalse);
      for (final request in [
        () => repository.catalog('huangdou'),
        () => repository.cached('huangdou'),
        () => repository.detail(denied),
        () => repository.cover(denied),
        () => repository.resolve(denied, Episode({'id': '1'}, 1)),
        () => repository.enqueueDownloads(DramaDetail(drama, []), [
          Episode({'id': '1'}, 1),
        ]),
        () => repository.localPlayback(drama, Episode({'id': '1'}, 1)),
      ]) {
        await expectLater(
          request(),
          throwsA(
            isA<AppFailure>().having(
              (e) => e.message,
              'message',
              anyOf(contains('权限'), contains('版本不包含')),
            ),
          ),
        );
      }
      store.dispose();
    },
  );

  testWidgets('online-only home hides download navigation and denied sources', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'profiles': jsonEncode([
        const LocalProfile(
          id: 'default',
          name: '管理员',
          admin: true,
          salt: '11111111111111111111111111111111',
          pinHash:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ).toJson(),
        const LocalProfile(
          id: 'viewer',
          name: '只看红果',
          sources: ['hongguo'],
          download: false,
        ).toJson(),
      ]),
      'activeProfile': 'viewer',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MoyiApp(repository: FixtureRepository(), store: store),
    );
    await tester.pumpAndSettle();
    expect(find.text('下载'), findsNothing);
    expect(find.text('黄豆'), findsNothing);
    expect(find.text('黄果 AI'), findsNothing);
    expect(find.byType(HongguoDramaHome), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });
}
