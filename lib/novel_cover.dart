import 'package:flutter/widgets.dart';

const List<String> novelDefaultCovers = [
  'assets/novel_covers/cover_1.png',
  'assets/novel_covers/cover_2.png',
  'assets/novel_covers/cover_3.png',
  'assets/novel_covers/cover_4.png',
  'assets/novel_covers/cover_5.png',
  'assets/novel_covers/cover_6.png',
  'assets/novel_covers/cover_7.png',
  'assets/novel_covers/cover_8.png',
];

String novelDefaultCoverFor(String id) {
  if (id.isEmpty) return novelDefaultCovers.first;
  return novelDefaultCovers[id.hashCode.abs() % novelDefaultCovers.length];
}

Widget novelCoverFallback(String id, double width, double height) {
  return Image.asset(
    novelDefaultCoverFor(id),
    width: width,
    height: height,
    fit: BoxFit.cover,
  );
}
