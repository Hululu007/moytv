import 'package:moyi/content_models.dart';
import 'package:moyi/content_registry.dart';
import 'package:moyi/content_zone_binding.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('content source ids are known and never collide with core sites', () {
    for (final source in ContentRegistry.allSources) {
      expect(ContentRegistry.isKnownId(source.id), isTrue, reason: source.id);
      expect(
        SourceSite.isKnown(source.id),
        isFalse,
        reason: 'id collision: ${source.id}',
      );
    }
    expect(ContentRegistry.isKnownId('not-a-source'), isFalse);
  });

  test('audio zone exposes its built-in source for management', () {
    expect(ContentRegistry.sourcesFor(ContentSection.audio).map((s) => s.id), [
      'tingshuwang',
    ]);
  });

  test('hidden content ids are honored by siteVisible', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    expect(store.siteVisible('tingshuwang'), isTrue);
    expect(store.siteVisible('hongguo'), isTrue);
    store.dispose();
  });

  test('zone binding provider filters hidden sources live', () {
    final hidden = <String>{'tingshuwang'};
    final binding = ContentZoneBinding(
      sourcesProvider: (section) => [
        for (final source in ContentRegistry.sourcesFor(section))
          if (!hidden.contains(source.id)) source,
      ],
      readPersisted: (_) => null,
      writePersisted: (_, _) async {},
    );
    final audioIds = [
      for (final source in binding.sourcesFor(ContentSection.audio)) source.id,
    ];
    expect(audioIds, isNot(contains('tingshuwang')));
    hidden.clear();
    final restoredIds = [
      for (final source in binding.sourcesFor(ContentSection.audio)) source.id,
    ];
    expect(restoredIds, contains('tingshuwang'));
  });
}
