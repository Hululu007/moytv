import '../models.dart';
import 'actress_database.dart';
import 'actress_film_library.dart';
import 'actress_models.dart';

/// 播片自动记录（2026-11-25 用户令：写的那边也走新方法）：
/// 播放器真播起来后，把这集按视频库合并规则写进内部工作库
/// （.sql 导入落成的库），不再写 MYTV/db/站点库.db 那个文件。
///
/// 合并规则与老站点库同一套（见 [videoLibraryMergeAction]，
/// 实现在 [SqfliteActressDatabase.upsertVideoEntries] 里）：
/// 同番号同地址跳过、同番号换地址只更新、新番号插入；
/// 重复播只留一条，绝不追加。
///
/// 记进工作库的片直接进演员库的影视库列表（videos 直读，
/// 不依赖女优关联），能看见、能播；没有女优名时不写
/// video_actress，所以不挂在任何一个人名下（与老站点库同口径）。
///
/// 注意：下次重新导入 .sql 会整体换库，这批记录随旧库一起被
/// 换掉（换库前备份的 .bak 里还有），不是永久保存。
/// 写失败静默跳过、不挡播放、不弹错。
class ActressPlayRecorder {
  ActressPlayRecorder({
    Future<void> Function(List<VideoLibraryEntry> entries)? writer,
  }) : _writer = writer ?? SqfliteActressDatabase.instance.upsertVideoEntries;

  /// 默认实例：写进内部工作库。
  static final ActressPlayRecorder instance = ActressPlayRecorder();

  final Future<void> Function(List<VideoLibraryEntry> entries) _writer;

  /// 记一条播过的片：只在播放器真播起来后调（调用方保证地址已验活）。
  /// 返回 true 表示写进去了，false 表示跳过（地址不合法/番号空）
  /// 或写失败。
  Future<bool> recordPlay({
    required Drama drama,
    required String playUrl,
  }) async {
    try {
      final url = playUrl.trim();
      if (url.isEmpty) return false;
      final uri = Uri.tryParse(url);
      if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
        return false;
      }
      final vodId = videoLibraryVodId(drama.id);
      if (vodId.isEmpty) return false;
      await _writer([
        (
          vodId: vodId,
          title: drama.title,
          picUrl: drama.cover,
          playUrl: url,
          remarks: '高清',
          pubdate: drama.onlineDate,
          area: '',
          year: '',
          content: drama.description,
          playFrom: filmSiteId(drama.source),
          typeName: drama.category,
          category: drama.category,
          actressName: '',
        ),
      ]);
      return true;
    } catch (_) {
      // 写库失败（库还没导入/磁盘满/库被占）：静默跳过，
      // 不挡播放、不弹错。
      return false;
    }
  }
}
