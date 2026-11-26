# 取流梯子补齐批报告（2026-11-26）

基线：壳级四能力批提交 `7eb7d3a`（分支 miniapp-sniff）；本批分支 `ladder-fill`，工作树 `~/workspace/moyi_ladder_fill_20261126`。只在本地提交，未推仓、未构建。（此路径的 REPORT.md 是上一批随基线带入的报告，git 历史里在，本文件按工作树惯例换成本批报告。）

任务来源：用户 2026-11-26 17:31 令「全部修复更新补上」。上一批 REPORT.md 第五节如实标注了两处遗留，本批把这两处补齐，壳级取流梯子（直取 → 解析/解密 → 播放核恢复链 → 嗅探）至此三条播放链全覆盖。

## 一、补了哪两处

### 1. 西瓜播放器：核播失败、恢复手段耗尽后落嗅探

落点：`lib/xigua/xigua_player_screen.dart`

- 新增防循环闩锁 `_sniffRungConsumed`，语义与主播放器同名闩锁一致：换集复位（`_play` 里按集号变化复位）、任一侧落过嗅探即置位、本集内不再重复落。
- `_recover`（核间回退/重解析/重取流的恢复链）走到止步分支时，先按原样停播，再在递错误提示之前插入嗅探一级：当前集有网页地址（上次取流的页面地址优先，其次当前集地址本身是网页）且深度嗅探开着、闩锁未置时，置闩锁并在下一帧自动打开既有嗅探页（`_openSniffer(auto: true)`），嗅到的地址连同请求头递给正式播放器起播；条件不满足时原样落回既有错误提示。
- 取流失败侧的既有自动嗅探同步置闩锁，与恢复侧互斥防循环（此前两侧各落各的，同一集可能嗅两次）。
- 嗅探页本身上一批已接同口径三件：候选过滤（`MediaSniffer.isLikelyAdOrPreview`）、递送前轻验（`sniffCandidateValidator`）、45 秒超时（`sniffFallbackTimeout` + 超时关页收口）。本批未动嗅探页，只补恢复链的落点。

### 2. 直播链：嗅探兜底

落点：`lib/live_playback.dart`（控制器）、`lib/live_screen.dart`（宿主接线）

- 控制器新增可注入钩子 `sniffResolver`（`LiveSniffResolver` typedef：给网页地址与请求头、回嗅到的媒体地址或 null），与控制器既有的播放器工厂注入（createPlayer / buildVideoController）同一风格，控制器本身不持有界面。宿主在 `live_screen` 的 initState 里装配实现：推既有嗅探页 `SniffWebViewPage`（autoPlay、候选过滤与递送前轻验 `sniffCandidateValidator(headers: 频道请求头)`、45 秒超时 `sniffFallbackTimeout`、超时自动关页），嗅到只回地址、由控制器递给正式播放器——只取链，不在网页里播。顶部直播页与全屏页共用同一控制器，钩子一处覆盖两处。
- 触发点一（取流失败）：`play()` 里解析/取流抛错时，若频道带 DRM 直接按原错误收口；否则频道有网页地址候选（上次成功解析出的地址是网页优先，其次频道地址列表里的网页地址）才走嗅探，嗅到后按频道请求头继续原打开流程；嗅不到、无候选、无钩子时一律保留原取流错误提示。
- 触发点二（核播失败）：错误事件驱动的重连梯子（换线路/重连，`_scheduleReconnect`）重试耗尽时，先取消已排定的重连定时器（防梯子中先到的错误事件在嗅探途中把原坏线路重播、冲掉嗅探结果），再走同一条嗅探路：嗅到就用新地址续播，嗅不到或嗅探本身抛错则恢复耗尽时保存的原播放错误提示，不假装有信号。
- 正常频道零影响：解析成功、播放正常的 m3u8 直链频道全程不碰嗅探，不拖慢起播（有专门测试断言钩子零调用）。
- 守卫与主播放器同口径：深度嗅探开关（关时两处触发都不落）、防循环闩锁（切频道/手动重播复位）、睡眠定时已触发或控制器已释放时不落、切频道后旧嗅探结果作废（token 校验）。

## 二、与主播放器梯子的一致性

| 口径 | 主播放器 | 西瓜（本批） | 直播（本批） |
|---|---|---|---|
| 梯子顺序 | 直取→解析/解密→核恢复链→嗅探 | 同（恢复链耗尽落嗅探） | 直取→（取流失败或重连耗尽）→嗅探 |
| 候选过滤 | isLikelyAdOrPreview | 同（嗅探页既有） | 同（嗅探页内 SnifferService） |
| 递送前轻验 | sniffCandidateValidator | 同 | 同（带频道请求头） |
| 超时 | 45 秒 sniffFallbackTimeout | 同 | 同 |
| 防循环闩锁 | _sniffRungConsumed，换集复位 | 同名同义，换集复位 | 同义（控制器字段），切频道/重播复位 |
| 深度嗅探开关 | 关则不自动落 | 同（两侧都受管辖） | 同 |
| 只取链递播放器 | 是 | 是 | 是 |
| 失败收口 | 原错误提示 | 原错误提示 | 原错误提示（取流错误/耗尽时播放错误） |

## 三、差异（如实标）

1. **直播不做「网页地址短路嗅探」**：主播放器对网页型地址在取流阶段就短路去嗅探，直播没有照搬。原因是直播有大量无后缀直链，`looksLikeWebPage` 的判据（无媒体后缀即网页）会把这类正常直链误判成网页、短路嗅探反而拖慢甚至嗅错。直播改为纯失败触发：只有取流真失败或重连梯子真耗尽、且频道确有网页地址候选时才落嗅探，正常频道零影响。
2. **直播嗅探经宿主钩子注入**：控制器不持界面（与既有测试注入风格一致），嗅探页由 live_screen 推；钩子未注入（如纯控制器测试）时行为与改前完全一致。
3. **西瓜嗅探是推页式、主播放器是内嵌式**：这是两边既有形态差异，本批未改形态，只补恢复链落点；过滤/轻验/超时/闩锁口径已对齐。
4. **直播 DRM 频道全程排除嗅探**：DRM 频道原有口径就是失败直接报「DRM 频道播放失败」不进重连梯子，本批两处触发都加了 hasDrm 守卫，不让嗅探把 DRM 频道拖进网页路。
5. **西瓜恢复级没有专属 widget 测试**：西瓜全屏页的挂载脚手架在仓库里不存在（既有西瓜测试只测手势层与路由参数），驱动恢复链耗尽还需给核间回退窗格做平台视图替身，成本与风险不成比例；上一批主播放器的恢复级同样没有专属 widget 测试（靠共享件测试覆盖）。本批西瓜侧靠与主播放器同构的代码 + 共享件测试（sniffer_service / playback_sniff_verify / player_sniff_timeout）兜底，恢复级落点本身列入手机终验。直播侧有控制器级专属测试（下节）。

## 四、测试与基线对照

环境：Flutter 3.50.0（`~/workspace/tools/flutter-3.50.0`）、`--no-pub`、TMPDIR 指 workspace 大盘、同树单 flutter 串行。

- 新增 `test/live_sniff_fallback_test.dart` 7 条全过：①取流失败＋网页频道→嗅探取链递播放器起播（断言钩子收到频道页地址与请求头）；②嗅不到→原取流错误保留；③直链频道取流失败→不嗅探；④正常直链→不嗅探照常播；⑤未注入钩子→原错误保留；⑥核播失败重连耗尽→落嗅探续播且只落一次（闩锁）；⑦耗尽＋嗅不到→原播放错误保留、坏线路不再重播。
- 对照套件一次跑完 **180/180 全过、0 失败**：上一批 26 条（sniffer_service 8、playback_sniff_verify 5、player_sniff_timeout 1、player_sniff_back 3、playback_loader、mini_app_host_inline_player）+ 直播存量 147 条（live_drm_exo、live_drm、live_resume、live_import_epg、live_layout、live_tv_redesign、live_api_sources、live_settings、live_http_stability、live_parser_stability、live_m3u_builtin、live_fullscreen_exit、live_subscription_dual_entry）+ 本批新增 7 条。与基线 7eb7d3a 对照 **0 新增失败**。
- 直播预览冒烟：`preview_live_fix_normal_test.dart` 单独跑，本体通过、日志打印「preview landed: live_capsule_normal」（直播页改动后渲染正常）；进程在收尾阶段挂起、按预览测试惯例超时杀掉，属已知形态。直播页既有定版（本页深色、右下角 + 导入、信息行版式）本批一字未动。
- 静态检查：改动 4 个文件（lib/live_playback.dart、lib/live_screen.dart、lib/xigua/xigua_player_screen.dart、test/live_sniff_fallback_test.dart）analyze **0 错 0 警**；仅 5 条 info（2 条 material 弃用提示为仓库通有，3 条在 xigua 既有代码行、本批改动行之外）。

## 五、手机终验项

1. 西瓜：找一集「核播必失败但有网页版地址」的资源，恢复手段跑完后应自动进嗅探页，嗅到地址后切回正式播放器出画（不是停在网页里播）；嗅不到时 45 秒内收口、错误提示与改前一致。
2. 西瓜：同一集内取流失败侧与恢复侧不要重复嗅两次；换到下一集后嗅探机会恢复。
3. 直播：网页型频道（地址是播放页的）应能经嗅探出画；嗅探中切频道，旧结果不应串到新频道。
4. 直播：直链坏掉的频道，重连几次后应落嗅探续播；嗅不到时最终提示仍是原来的播放失败文案，不出现假信号。
5. 直播：正常 m3u8 频道起播速度与改前无差别（不应先闪嗅探页）；DRM 频道失败仍直接报 DRM 失败、不进嗅探。
6. 设置里关掉「深度嗅探」后，西瓜与直播都不应再自动落嗅探（手动嗅探入口不受影响）。

## 六、组装提示

与演员库批的对账点不变（lib/player_screen.dart、lib/playback_sniffer.dart 本批未动，无新增冲突面）。本批动了 lib/live_screen.dart 与 lib/xigua/xigua_player_screen.dart，组装时若其他批次也动过这两处，按函数级合并即可：直播侧改动集中在 LivePlaybackController 与 live_screen 的 initState 接线，西瓜侧集中在 _recover 止步分支与 _play 的闩锁复位/置位。
