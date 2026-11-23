// nvku 首页/分类同一份内容（2026-11-23 用户报）：
// 站点分类 c0/c1 点了没用，本地兜底一律回「最新」，首页与分类
// 两页签看起来一模一样。根因是 _localCategoryFor 把站点分类
// 全映回 'new'，本地兜底永远只出最新。
// 本测验纯映射逻辑（站点分类 id → 视频主分类名、标签合并去重）；
// 按主分类筛库的 SQL 在 nvku_cat_test.db 上用 python sqlite3
// 按原文重放验证（flutter test 里 sqflite 打不开）。
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_nvku_page.dart';
import 'package:moyi/models.dart';

const _siteCats = [
  CatalogCategory('new', '最新上架'),
  CatalogCategory('c0', '有码 · 100'),
  CatalogCategory('c1', '无码 · 50'),
];

const _localCats = [
  CatalogCategory('new', '最新作品 · 6'),
  CatalogCategory('rank', '排行榜 · 6'),
  CatalogCategory('brand:sdam', 'SDAM · 2'),
];

const _mainCats = [
  CatalogCategory('main:有码', '有码 · 200'),
  CatalogCategory('main:无码', '无码 · 150'),
  CatalogCategory('main:国产', '国产 · 300'),
];

void main() {
  group('分类名去尾数', () {
    test('带数字尾数去掉', () {
      expect(cleanNvkuCategoryName('有码 · 251867'), '有码');
      expect(cleanNvkuCategoryName('最新上架 · 6'), '最新上架');
    });

    test('没尾数原样返回', () {
      expect(cleanNvkuCategoryName('有码'), '有码');
      expect(cleanNvkuCategoryName('最新上架'), '最新上架');
    });

    test('尾数不是数字不误伤', () {
      expect(cleanNvkuCategoryName('有码 · 特别版'), '有码 · 特别版');
    });
  });

  group('选中分类 → 视频主分类名', () {
    test('站点分类 c0/c1 映到主分类名', () {
      expect(nvkuVideoCategoryFor('c0', _siteCats), '有码');
      expect(nvkuVideoCategoryFor('c1', _siteCats), '无码');
    });

    test('最新/排行/厂牌不过滤', () {
      expect(nvkuVideoCategoryFor('new', _siteCats), '');
      expect(nvkuVideoCategoryFor('rank', _siteCats), '');
      expect(nvkuVideoCategoryFor('brand:sdam', _siteCats), '');
    });

    test('主分类标签直接取冒号后', () {
      expect(nvkuVideoCategoryFor('main:国产', _siteCats), '国产');
      expect(nvkuVideoCategoryFor('main:有码', _siteCats), '有码');
    });

    test('不在站点分类里的 id 不过滤', () {
      expect(nvkuVideoCategoryFor('c9', _siteCats), '');
    });
  });

  group('全部可点标签合并', () {
    test('站点分类打头，本地分类随后，主分类补在最后', () {
      final cats = nvkuAllCategories(_siteCats, _localCats, _mainCats);
      expect(
        cats.map((c) => c.id).toList(),
        ['new', 'c0', 'c1', 'rank', 'brand:sdam', 'main:国产'],
      );
    });

    test('站点已有的主分类不重复摆', () {
      final cats = nvkuAllCategories(_siteCats, _localCats, _mainCats);
      // 有码/无码站点里已有，只留站点那份；国产站点里没有才补 main:国产。
      expect(cats.where((c) => c.id == 'main:有码'), isEmpty);
      expect(cats.where((c) => c.id == 'main:无码'), isEmpty);
      expect(cats.where((c) => c.id == 'main:国产'), hasLength(1));
    });

    test('站被挡（站点分类为空）时主分类标签照样全在', () {
      final cats = nvkuAllCategories(const [], _localCats, _mainCats);
      expect(
        cats.map((c) => c.id).toList(),
        ['new', 'rank', 'brand:sdam', 'main:有码', 'main:无码', 'main:国产'],
      );
    });
  });
}
