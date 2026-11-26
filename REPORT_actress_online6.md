# 演员库在线线路六源扩线（第四批）报告

分支 `actress-whos-ui`，基线 6511c40（123AV 修复批）之上。本批只本地提交，不推仓、不构建。

把演员库在线线路从 who's/123AV/PH 扩到 AvPlay「在线播放」六源：AVDB、JavMenu、AV01、MemoJav、MissAV、Jable。六源全部并入详情页「在线线路」区的并行查询与女优页点播竞速（起播口径以第三批定版为准：115 优先窗 > 在线/本地库同尺竞速；本批只扩在线这一方的人数，不动 115 与库的规则）。

## 逐站走哪条链

| 源 | 链路 | 说明 |
|---|---|---|
| AVDB | **复用 py 链** | 组装树现成 `assets/py_spiders/avdb.py`（KEY=avdb，MacCMS provide 接口蜘蛛），不新写 Dart |
| JavMenu | **复用 py 链** | 现成 `javmenu.py`（KEY=javmenu） |
| MemoJav | **复用 py 链** | 现成 `memojav.py`（KEY=memojav；其签名切取逻辑在蜘蛛本体里，Dart 侧不用重写——API_MAP 第 8 节的 sig/sts 切法是蜘蛛内部实现） |
| MissAV | **复用 py 链** | 现成 `missav.py`；线路查询按番号直达详情（蜘蛛 detailContent 吃番号，与女优页竞速 who's/B 路同口径），不走搜索 |
| AV01 | **新写 Dart** | 照 AvPlay 反编译 Av01Parser/Av01UrlUtils 逐条移植，见下 |
| Jable | **新写 Dart** | 照 AvPlay 反编译 JableParser 逐条移植，见下 |

py 复用链落法（新文件 `lib/actress/actress_py_lines.dart`）：统一走仓库 searchProgress（蜘蛛 searchContent）→ detail（detailContent）→ resolve（playerContent）——与 who's py 链同一条路；命中判定 = 搜索结果标题或 id 归一后含番号（对不上不算找到）；resolve 出解析型计划（needsParse）或空地址不算线路（只认 parse=0 真直链）。命中后组装 direct 直链详情（地址+播放头）交给正式播放器。

## AV01 新写链（证据：avplay_source_20261126 反编译源码逐字）

- 搜索：GET `https://www.av01.media/cn/search?q={番号}`（语言段 AvPlay 按界面语言取 cn/tw/en，我们固定 cn），扫 `a[href*=/video/]`：地址补绝对、路径段取视频 id（'video' 段下一段数字）、slug 命中番号才留（isAv01CandidateMatch：slug 规整后相等或以「番号 slug + '-'」开头），去重最多 8 条。
- 详情校验（validateDetailPage 移植）：canonical 的 id/slug 必须与详情页地址一致；h1 归一（小写只留字母数字）必须以 slug 归一开头；三关全过才取第一条命中主清单规则的 `source[src]`——主清单 = `{站根}/api/v1/videos/{id}/manifest/master.m3u8`（可带查询串）。
- 凭证流（getGeoData + 缓存刷新已接、换凭证端点未还原）：取流前先 GET `{站根}/edge/geo.js?json` 拿地理（{token_v2, expires, ip, ttl, country}），按 ttl 缓存、失败不挡取流。**卡点如实记**：AvPlay 第二步 requestCdnAccess（向服务端换 access_token）的接口地址在反编译里没还原出来（jadx 对 Av01Service 该方法解码失败），不编造端点；从 OnlinePlaybackProviderKt 可见 token 的用法是播放时只给 `customers.iw01.xyz` 域名的请求加 `access_token` 查询参，而详情页渲染出的主清单在 `www.av01.media` 域名上、不吃这个 token——页面路径本身自洽。若手机实测发现 www 主清单也要凭证，此处即为卡点，届时按真响应再补。

## Jable 新写链（证据：JableParser.java 逐字）

- 搜索：GET `https://jable.tv/search/{番号大写、_换-}/`，扫 `a[href*=/videos/]`，slug 与番号**相等**才认（不认前缀近似），详情页地址统一拼 `https://jable.tv/videos/{slug小写}/`。
- 取流：详情页先把 `\/` 还原，再正则取 `hlsUrl = 'https://….m3u8'`，只认 https 且路径以 .m3u8 结尾。
- 有盾口径：AvPlay 走 WebView 过盾，我们纯 HTTP 撞挑战页（特征词识别）时如实标「搜索失败 · 点按重试」，不冒充未找到、不网页内播；播放层另有壳级嗅探兜底（梯子批已落）。默认懒查询。

## 并入方式

- **线路区**（actress_online_lines.dart）：新增 `idle` 态（懒查询：Jable、MissAV 默认 idle、行标「点击查询」，点按才查；其余自动查）；新增 py 线路行（仓库在场才出现——DetailScreen 构造时传 `widget.repository`；不传仓库时行为与扩线前完全一致）。每行状态如实：已找到「线路 · 点播」/未找到/搜索失败可重试。DetailScreen 传 `sources: kActressLineSources`（123AV/PH/AV01/Jable）。
- **竞速**（actress_detail_page.dart）：Dart 直连路改走 kActressLineSources（+AV01、+Jable）；新增 py 三路 `_racePySource`（AVDB/JavMenu/MemoJav，同一把轻验活尺：计划地址验活通过才算线路，赢家详情与 MissAV 路一样是仓库详情）；MissAV 仍走既有 who's 直达 B 路不重复。总路数 3（库/who's/115）+ 4（Dart）+ 3（py）= 10。
- **源切换条不变**：nvku 页可浏览源仍是 123AV/PH（kActressOnlineSources 未动），六源只进线路与竞速——本批任务范围就是「在线播放」线路，不是加可浏览站。
- 命中判定补两源（actress_online_detail.dart 的 actressOnlineCardMatches）：av01 走 slug 命中规则、jable 走 slug 相等。

## 改动文件

- `lib/actress/actress_online_parse.dart`：AV01/Jable 解析函数群 + 盾页特征识别 `actressPageLooksChallenged`。
- `lib/actress/actress_online_sources.dart`：`ActressOnlineSource.lazySearch`（默认 false）、`Av01ActressSource`、`JableActressSource`、`kActressLineSources`。
- `lib/actress/actress_py_lines.dart`（新）：py 线路表、`actressPyLineHit`、`actressPyLineDetail`。
- `lib/actress/actress_online_lines.dart`：idle 态、py 行、懒查询点查。
- `lib/actress/actress_online_detail.dart`：av01/jable 命中判定。
- `lib/actress/actress_detail_page.dart`：竞速扩路（Dart 全集 + py 三路）。
- `lib/detail_screen.dart`：线路区传 kActressLineSources + repository。
- `test/actress_online6_test.dart`（新，19 例）。

## 验证

- 新测试 19/19 全过：AV01 搜索/详情三关校验（含 canonical 对不上、h1 对不上、无主清单三个反例）、Jable 搜索相等判定与 hlsUrl 提取、盾页识别、两源假取数全链、py 链命中/未命中/解析型剔除/MissAV 不走搜索、线路区 py 行与懒查询点查部件测试。
- 回归 8 文件 77/77 全过（online_lines / online_parse / detail_sections / pan115 / javdb_extra / javdb_stills / javdb_api / db_play_code）。
- analyze 改动文件 0 错 0 警。与基线 9dab199 对照口径不变：存量失败仍是 play_fallback、play_missav_first 两条（第三批已 worktree 实证同名同因），本批 0 新增失败。

## 未验项（如实）

- **六源真页验播全部未验**：本机出口断，AV01/Jable 的真搜索页/详情页形状、py 四源在本机 py 桥里的真跑结果，都等手机终验或出口恢复；解析层已按反编译源码的真形状造夹具验真。
- AV01 换 CDN 凭证端点未还原（见上卡点）：页面主清单若被凭证拦，手机上会表现为 AV01 线路验活不过、竞速自动落其他源，不会硬播。
- MemoJav 蜘蛛的签名切取（API_MAP 第 8 节）是蜘蛛内部实现，本批未改蜘蛛、未在本机真跑验证。
