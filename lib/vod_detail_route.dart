enum VodOpenAction { detail, directPlayback }

/// 列表卡片点按的落点（用户定版口径）：普通点按进详情页、先停着
/// 不播，点海报/选集才播；只有明确的“继续”动作（追剧/
/// 最近观看里的继续、动作表里的继续）才直通播放续播。分区不改变
/// 这个决定：点播区与短剧区的卡片都先走详情页。
VodOpenAction vodOpenAction({required bool isVodZone, required bool resume}) {
  if (resume) return VodOpenAction.directPlayback;
  return VodOpenAction.detail;
}
