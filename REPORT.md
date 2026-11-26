# 壳级取流四能力盘点 + 兜底梯子（miniapp-sniff 批）

- 分支：miniapp-sniff，基线 ed69442（v68 组装树顶端）
- 提交：本地提交（见 git log），未推仓、未构建
- 范围：原「小程序模块嗅探」批作废并入本批，按 2026-11-26 17:11 扩围令做
  **壳级**四能力（爬虫/解析/解密/嗅探）盘点补缺，串成一条自动逐级落的
  兜底梯子。用户已于 17:10 在主聊亲口同意继续处理本树。
- （注：此路径原有的直播批报告是基线树已提交内容，git 历史里在，本文件
  按本工作树惯例换成本次报告，不影响那份报告的存档。）

## 一、四能力盘点（以代码为准）

| 能力 | 有无 | 落点 | 程度与缺口 |
|---|---|---|---|
| 爬虫（直取） | 有，主力 | `lib/core_bridge.dart` 的 `_resolveImpl` 按源分发：jar 走 `_jarResolve`、py 走 `_pyResolvePlan`（含红果 Go 接管、who's 本地直链）、JS 走 `_jsCall`／iDuanJu 插件走 `IdjContract`、云盘走云盘引擎、其余走 Go 核 `resolve`；`lib/playback_loader.dart` 前置本地库直链短路 | 完整，本批未动 |
| 解析 | 有，两条 | ①壳侧选中解析接口 `applySelectedParse`（`lib/playback_parse.dart`，jar 源需解析与网页地址分支）；②Go 核 `resolveParse` 管线（非 jar 源，解析接口的 JSON 型与网页型都收，JSON 型只走 Go 不拼给播放器）。触发条件：计划带 `needsParse` 或地址是网页 | 能用；原缺口：解析未配置/全失败只靠异常路径落嗅探（深嗅探开时成立），核播失败侧不落嗅探——后者本批已补 |
| 解密 | 有，形态是「随源实现＋壳侧透传」 | 加密接口响应/加密地址由 Go 核与各蜘蛛在取流时各自解开，结果以 `PlaybackPlan.decryptionKey`（HLS 密钥→强制 MPV 并传 `decryption_key=`）与 `PlaybackDrm`（→强制 EXO）透传给播放器核 | 解密与各源协议绑定，抽不成独立的通用一级，Dart 壳侧没有也不需要通用解密器。注：`lib/content_crypto.dart` 是七猫小说正文解密、`cloud_aes/cloud_m115_crypto` 是网盘域，都与播放取流无关。边界：只做协议解密，不碰付费/VIP 墙 |
| 嗅探 | 有，接法分散 | `lib/playback_sniffer.dart`：`MediaSniffer`（后缀识别＋文本提取）、`SnifferService`（候选打分）、`SniffWebViewPage`（隐藏 WebView 注入探针，XHR/fetch/WebSocket/DOM/资源条目多路截取，带字幕提取）。原接法：主播放器取流失败异常路径自动开（受设置「深度嗅探」控制，默认开）＋错误屏手动按钮；西瓜播放器同构一份；小程序宿主 `MiniAppBridge.resolvePlayTarget` 分流后走嗅探页回填内嵌播放器 | 原缺口四处：①无超时，可无限挂；②候选只按后缀打分，广告/试看可混入、死链直接递播放器；③核播失败、恢复链耗尽不落嗅探；④递送的死链无替补。本批全补（见下） |

## 二、本批补缺（梯子成型）

改动文件：`lib/playback_sniffer.dart`、`lib/playback_sniff_verify.dart`（新增）、
`lib/player_screen.dart`、`lib/xigua/xigua_player_screen.dart`、
`lib/miniapp/mini_app_host_page.dart`。

1. **候选过滤**（`MediaSniffer.isLikelyAdOrPreview`）：进候选前拦下——广告网络
   主机（doubleclick/googlesyndication/adservice/popads/exoclick/juicyads/
   adsterra/propellerads、`ads.` 主机）与路径 token（ad/ads/advert/preroll/
   preview/trailer/sample/trial/teaser，整词命中，`adaptive`、`download`
   这类含子串的正常地址不误伤）。`SnifferService.add` 统一执行。
2. **递送前轻验**（新增 `lib/playback_sniff_verify.dart`）：自动递送前用页面
   请求头探头（Range 0-2047 只读首块）：m3u8 须 2xx 且首段含 `#EXTM3U`；
   直链须 206，或 200 且非 HTML 错误页。判定与 `feed_playability` 的验播
   探针同口径。验死走 `SnifferService.reject` 剔除（剔除集防探针反复上报
   重收），继续嗅下一个候选。三处自动递送全接：主播放器内嵌嗅探、西瓜
   嗅探页、小程序宿主嗅探页。
3. **统一超时 45 秒**（`sniffFallbackTimeout`）：`SniffWebViewPage` 新增
   `sniffTimeout/onSniffTimeout`，只在自动递送模式（autoPlay/embedded）
   计时，手动浏览候选不打扰；不支持 WebView 的平台同样计时收口。
   - 主播放器：超时走 `_onSniffTimeout` 关嗅探，错误屏原文
     「无法获取播放链接：嗅探未找到可播放地址（取流失败），请重试或换一集。」
     （文案刻意避开「超时/网络」词，错误归类落到「站源问题」，不误导成
     网络故障）；有换线回调时同路通知调用方。
   - 小程序宿主：超时与用户手动返回区分（`_sniffTimedOut`），超时出
     SnackBar「无法获取播放链接：嗅探超时，请稍后重试」。
   - 西瓜播放器：超时关页、按未找到收口。
4. **核播失败侧落嗅探**（`player_screen._recover`）：恢复链（同线重解析→
   换线→换后端→核间回退）耗尽后，手里有网页地址（`_lastPageUrl` 优先，
   否则失败计划本身是网页）且深嗅探开、本集未消耗过嗅探级时，自动开
   嗅探，不再让用户自己去点错误屏按钮。新增 `_sniffRungConsumed` 闩锁
   防「嗅探→递送→核播再失败→再嗅探」死循环，只在换集时复位；取流失败
   异常路径自动开嗅探时同步置闩锁。
5. **梯子顺序（成型后）**：本地直链/爬虫直取 → 解析（壳侧选中接口／Go
   解析管线，含各源解密透传 decryptionKey/DRM）→ 播放核恢复链（重解析/
   换线/换核）→ 嗅探兜底（过滤＋轻验＋45 秒超时）。全程自动逐级落，
   用户不选模式。嗅探只取链：截到的地址连请求头递正式播放器
   （EXO/MPV）起播，绝不在内置网页里播放——三处接法原本就都是回填
   播放器，本批未改这一形态。

## 三、覆盖范围

- 片库站点：主播放器全源（py/jar/JS/Go/云盘）走同一条梯子。
- 小程序：宿主嗅探页接过滤/轻验/超时；嗅探结果回填其内嵌播放器
  （小程序自有播放器归属是既有形态，本批未改）。
- 西瓜播放器：嗅探页接过滤/轻验/超时（见对账点，其恢复链侧未动）。
- 演员库在线线路：经主播放器 `PlaybackPlan` 入口进，天然继承整条梯子，
  本批不需为它单独接。

## 四、与演员库批（moyi_actress_whos_ui_20261126）的重叠对账点

- `lib/player_screen.dart`：本批改动点为新增 import、`_sniffRungConsumed`
  字段、`_play` 换集复位、取流失败 catch 置闩锁、`_recover` 止步分支
  嗅探级、内嵌嗅探页新增三参数、`_onSniffTimeout` 新方法。若演员库批
  同改此文件，组装时按上述点位对账合并。
- `lib/playback_sniffer.dart`：共享文件，本批加 `isLikelyAdOrPreview`、
  `SnifferService.reject`、页面新参数三件；演员库批若动过此文件需对账。
- `lib/playback_sniff_verify.dart` 为新增文件，无冲突。
- 小程序宿主页、西瓜页与演员库批不重叠。本批未碰对方工作树。

## 五、测试与检查

- 基线（改动前）：`sniffer_service_test` 6 ＋ `player_sniff_back_test` 3
  ＝ 9/9 通过。
- 改动后同集＋新增共 26/26 通过：sniffer_service 8（新增过滤/剔除 2）、
  `playback_sniff_verify_test` 5（新增）、`player_sniff_timeout_test` 1
  （新增：需解析仓→自动进嗅探→推进 46 秒→关嗅探、错误屏「暂时无法
  播放 · 站源问题」、展开原始错误见「无法获取播放链接」）、
  player_sniff_back 3、playback_loader、mini_app_host_inline_player。
  **0 新增失败。**
- analyze：改动 lib 5 文件＋测试 4 文件，**0 错 0 警**；仅有仓库通有的
  material 弃用等既有 info（lib 10 条均在本批改动行之外），与本批无关。
- 预览（`preview/`）：`sniff_ladder_sniffing.png`（嗅探中：播放区嗅探态、
  左上只有 X、信息区保留；测试环境无 WebView，嗅探区为占位文本，真机
  是网页加载画面）、`sniff_ladder_failed.png`（超时收口错误态）。失败态
  图标题处字形方框是预览子集字体缺粗体字形的环境伪影，真文案已由
  组件测试逐字断言。预览测试 `test/preview_sniff_ladder_test.dart` 按
  仓库惯例单张单独跑、PNG 落地后超时收尾。

## 六、手机终验项

1. 找只回网页地址、且未配置解析接口的站播一集：应自动进嗅探，嗅到后
   切正式播放器出画，不在网页里播。
2. 打开一个无媒体的网页走嗅探：约 45 秒自动收口到「暂时无法播放 ·
   站源问题」，展开原始错误含「无法获取播放链接」。
3. 小程序里播只能嗅探的节目：嗅到即播；无结果时约 45 秒出「无法获取
   播放链接：嗅探超时」提示；手动返回嗅探页则静默取消、无提示。
4. 演员库批组装后：在线线路（who's/123AV/PH）取流失败应同样落嗅探。
5. 鸿蒙容器内 WebView 嗅探、EXO/MPV 出画各验一次；设置里关掉「深度
   嗅探」后自动落嗅探应停用、只剩错误屏手动按钮（开关语义未动）。

## 七、未做与边界

- 西瓜播放器恢复链耗尽落嗅探未补：其取流失败侧已有自动嗅探，核播
  失败侧与主播放器同构缺口，建议后续单独一批对齐，避免本批双改
  两套播放器状态机。
- 直播链是独立链，不在本批范围。
- 解密不设 Dart 通用级（理由见盘点表）；付费/VIP 墙不碰。
