/// 种子播流的虚拟站源标识与 episode 字段键。
///
/// 种子文件播放入口拼一个虚拟 Drama（source 固定为
/// [torrentPlaybackSourceId]，episode.raw 里带 [torrentStreamUrlKey]），
/// 仓库 resolve() 认到这个站源就直接返回该地址，不走蜘蛛取流。
/// 与任何真实站源 id 都不重名。
const String torrentPlaybackSourceId = 'torrent-local';

const String torrentStreamUrlKey = 'torrentStreamUrl';
