import 'dart:convert';

import 'package:moyi/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> open(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    final prefs = await SharedPreferences.getInstance();
    return LocalStore(prefs);
  }

  test('snapshot without profiles does not lock, switches stay writable', (
    ) async {
    final store = await open({
      'localSnapshot.v1': jsonEncode({
        'version': 1,
        'values': {'hideVip': true},
      }),
    });
    expect(store.configurationError, isNull);
    expect(store.locked, isFalse);
    await store.setPythonCfDisguise(false);
    expect(store.pythonCfDisguise, isFalse);
    await store.setCustomHeadersEnabled(true);
    expect(store.customHeadersEnabled, isTrue);
    store.dispose();
  });

  test('corrupt profiles record falls back to default admin, no lock', (
    ) async {
    final store = await open({
      'localSnapshot.v1': jsonEncode({
        'version': 1,
        'values': {'profiles': 'not-json{{'},
      }),
    });
    expect(store.configurationError, isNull);
    expect(store.locked, isFalse);
    expect(store.profile.admin, isTrue);
    await store.setJarFingerprintEnabled(false);
    expect(store.jarFingerprintEnabled, isFalse);
    store.dispose();
  });

  test('legacy profile keys without a profiles record do not lock', () async {
    final store = await open({'profile.guest.history': '[]'});
    expect(store.configurationError, isNull);
    expect(store.locked, isFalse);
    await store.setCustomHeadersEnabled(true);
    expect(store.customHeadersEnabled, isTrue);
    store.dispose();
  });
}
