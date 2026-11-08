import 'package:moyi/content_http.dart';
import 'package:moyi/content_lrts.dart';
import 'package:moyi/content_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('懒人听书源', () {
    test('身份与分区', () {
      final source = LrtsSource(ContentHttp());
      expect(source.id, 'lrts');
      expect(source.name, '懒人听书');
      expect(source.section, ContentSection.audio);
      expect(source.note, contains('免费'));
      expect(source.note, contains('搜索需登录'));
    });

    test('分类表 35 项且 id 唯一', () async {
      final source = LrtsSource(ContentHttp());
      final categories = await source.categories();
      expect(categories, hasLength(35));
      expect(categories.map((c) => c.id).toSet(), hasLength(35));
      expect(categories.first.id, '11');
      expect(categories.first.name, '玄幻奇幻');
      expect(categories.map((c) => c.name), contains('戏曲名家'));
    });
  });
}
