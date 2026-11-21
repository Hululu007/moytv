// 女优库列表页数据库分类筛选（2026-11-21 用户令“把数据库里面的
// 分类显示出来”）：列表页顶栏分类行只留该分类里有作品的人；
// listPersons(category:) 在 sqflite 与内存两实现上都要生效。
// 分类来自用户库 video_category 主分类，经同步写进 works.category。
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_models.dart';

Future<ActressPerson> _addPerson(
  MemoryActressDatabase db,
  String name,
) async {
  final person = await db.upsertRosterPerson(
    RosterPerson(
      source: ActressRosterSourceId.chaoliu,
      sourceId: 'P-$name',
      name: name,
      sex: 'female',
    ),
  );
  return person!;
}

Future<List<String>> _names(
  MemoryActressDatabase db, {
  String category = '',
}) async {
  final persons = await db.listPersons(
    sex: ActressSexFilter.all,
    sort: ActressSort.nameAsc,
    query: '',
    offset: 0,
    limit: 100,
    category: category,
  );
  return persons.map((p) => p.displayName).toList();
}

void main() {
  group('listPersons category', () {
    late MemoryActressDatabase db;

    setUp(() async {
      db = MemoryActressDatabase();
      final a = await _addPerson(db, '甲');
      final b = await _addPerson(db, '乙');
      final c = await _addPerson(db, '丙');
      await db.upsertWorks(a.localId, const [
        RosterFilm(code: 'SSIS-001', title: '中文字幕一', category: '中文字幕'),
        RosterFilm(code: 'ABP-001', title: '国产自拍一', category: '国产自拍'),
      ], site: 'chaoliu');
      await db.upsertWorks(b.localId, const [
        RosterFilm(code: 'ABP-002', title: '国产自拍二', category: '国产自拍'),
      ], site: 'chaoliu');
      await db.upsertWorks(c.localId, const [
        RosterFilm(code: 'IPX-001', title: '无分类作品'),
      ], site: 'chaoliu');
    });

    test('选分类只留该分类里有作品的人', () async {
      expect(await _names(db, category: '中文字幕'), ['甲']);
      expect(
        await _names(db, category: '国产自拍'),
        // 按名字排：Dart 字符串按码元比，乙（U+4E59）在甲（U+7532）前。
        ['乙', '甲'],
      );
    });

    test('不选分类 = 全部人都在内，无分类作品的人也在内', () async {
      // 码元序：丙（U+4E19）< 乙（U+4E59）< 甲（U+7532）。
      expect(await _names(db), ['丙', '乙', '甲']);
    });

    test('不存在的分类 = 空列表', () async {
      expect(await _names(db, category: '不存在的分类'), isEmpty);
    });
  });
}
