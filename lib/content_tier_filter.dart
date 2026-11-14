import 'package:moyi/app_theme_config.dart';
import 'package:moyi/models.dart';

/// 内容档对应的短剧首页频道键（复用 HongguoDramaHome._channels 的 key）。
/// 全部内容档不锁频道，返回 null。
String? tierChannelKey(ContentTier tier) => switch (tier) {
  ContentTier.manhua => 'comic',
  ContentTier.liveAction => 'real',
  ContentTier.adult => 'adult',
  ContentTier.all => null,
};

/// 内容档在给定分类里命中的分类 id。
/// 选择器与短剧首页 _channels 完全一致：漫剧看 name == '漫剧' 或
/// id == 'comic_series'，真人剧看 name == '真人剧' 或 id == 'short_play'。
/// 全部内容档与成人档不对应任何分类，返回 null；命中不到也返回 null
/// （调用方显示诚实空态，绝不拿别的分类冒充）。
String? tierCategoryId(ContentTier tier, List<CatalogCategory> categories) {
  final wanted = switch (tier) {
    ContentTier.manhua => (name: '漫剧', id: 'comic_series'),
    ContentTier.liveAction => (name: '真人剧', id: 'short_play'),
    ContentTier.all || ContentTier.adult => null,
  };
  if (wanted == null) return null;
  for (final category in categories) {
    if (category.name == wanted.name || category.id == wanted.id) {
      return category.id;
    }
  }
  return null;
}

/// 内容档下的显示分类集合：漫剧/真人剧档只留命中的那一个分类，
/// 命中不到返回空列表；全部内容档与成人档原样返回（成人档走频道聚合，
/// 不依赖分类集合）。
List<CatalogCategory> tierCategories(
  ContentTier tier,
  List<CatalogCategory> categories,
) {
  final id = tierCategoryId(tier, categories);
  if (id == null) {
    return (tier == ContentTier.manhua || tier == ContentTier.liveAction)
        ? const []
        : categories;
  }
  return categories.where((category) => category.id == id).toList();
}
