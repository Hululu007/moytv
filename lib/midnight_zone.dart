import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

const midnightActivatedKey = 'midnightActivated';

Future<bool> loadMidnightActivated() async {
  final preferences = await SharedPreferences.getInstance();
  return preferences.getBool(midnightActivatedKey) ?? false;
}

Future<void> saveMidnightActivated(bool value) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.setBool(midnightActivatedKey, value);
}

Future<void> activateMidnightAndExit() async {
  await saveMidnightActivated(true);
  exit(0);
}

bool isAdultSourceName(String name) => name.startsWith('🔞');

List<T> filterSourcesByAdult<T>(
  List<T> sources,
  String Function(T) nameOf,
  bool? adultOnly,
) {
  if (adultOnly == null) return sources;
  return [
    for (final source in sources)
      if (isAdultSourceName(nameOf(source)) == adultOnly) source,
  ];
}
