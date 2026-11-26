import '../models.dart';
import 'actress_online_parse.dart';
import 'actress_online_sources.dart';

/// 在线源一张卡 + 已取流结果 → 可直接进详情页/播放器的详情。
/// 在线视图点卡、详情页在线线路区、女优详情页竞速三处共用同
/// 一份构造，保证三条入口的详情口径一致：
/// - 剧照只用详情页自带的（detail.stills），不拿封面冒充；
/// - 信息行只带页里真有的字段（发行日期/长度/制作商）；
/// - 播放集是 direct 直链 + 播放请求头（经 playback_loader
///   的 direct 分支透传给播放器）。
({Drama drama, DramaDetail detail}) actressOnlinePlayDetail({
  required ActressOnlineSource source,
  required OnlineVideoCard card,
  required ActressOnlinePlay play,
}) {
  final info = play.detail;
  final title = info.title.isNotEmpty ? info.title : card.title;
  final poster = info.poster.isNotEmpty ? info.poster : card.cover;
  final drama = Drama(
    id: card.pageUrl,
    source: source.id,
    sourceId: card.pageUrl,
    title: title,
    cover: poster,
    onlineDate: info.date,
    category: info.maker,
    tags: [
      if (source.id == 'av123') av123CodeOf(card.pageUrl),
      ...info.actresses,
    ],
  );
  final detail = DramaDetail(
    drama,
    [
      Episode({
        'id': play.streamUrl,
        'title': '正片',
        'direct': true,
        'headers': play.headers,
      }, 1),
    ],
    backdrop: poster,
    stills: info.stills,
    tags: [for (final tag in info.tags) DetailTag(id: tag, name: tag)],
    extraInfo: [
      if (info.date.isNotEmpty) ('发行日期', info.date),
      if (info.duration.isNotEmpty) ('长度', info.duration),
      if (info.maker.isNotEmpty) ('制作商', info.maker),
    ],
  );
  return (drama: drama, detail: detail);
}

/// 番号归一化（去分隔符、大写）：123AV/PH 搜索命中判定用。
/// 空番号不参与匹配（返回空串，调用方按未找到处理）。
String actressCodeKey(String code) =>
    code.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// 一张在线卡是否就是这部片：
/// - 123AV：详情页地址里的番号与目标番号归一化后相等；
/// - PH：没有番号体系，只认标题里带目标番号（归一化后包含），
///   对不上不算找到——不拿别的片充数（2026-11-26 用户令）。
bool actressOnlineCardMatches({
  required ActressOnlineSource source,
  required OnlineVideoCard card,
  required String code,
}) {
  final target = actressCodeKey(code);
  if (target.isEmpty) return false;
  if (source.id == 'av123') {
    return actressCodeKey(av123CodeOf(card.pageUrl)) == target;
  }
  return actressCodeKey(card.title).contains(target);
}
