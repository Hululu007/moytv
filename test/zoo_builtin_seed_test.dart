import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/zoo_builtin_data.dart';
import 'package:moyi/zoo_builtin_seed.dart';

void main() {
  test('builtin config seed data is empty after builtin removal', () {
    final decoded = jsonDecode(zooBuiltinConfigsJson);
    expect(decoded, isA<List>());
    expect((decoded as List), isEmpty);
    expect(ZooBuiltinSeeder.dataConfigs(), isEmpty);
  });

  test('builtin config predicate covers zoo and luna seeds', () {
    expect(ZooBuiltinSeeder.isBuiltinConfig('zoo_abcdef123456'), isTrue);
    expect(ZooBuiltinSeeder.isBuiltinConfig('luna_abcdef123456'), isTrue);
    expect(ZooBuiltinSeeder.isBuiltinConfig('a1b2c3d4e5f6'), isFalse);
    expect(ZooBuiltinSeeder.dataConfigs().length, 0);
  });
}
