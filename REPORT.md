# 直播页撤频道信息钮与分辨率显示（用户 2026-11-26 07:15 令）

- 分支：live-info-remove，基线 efd0049（v67 最终 main）
- 提交：**e78251e**（本地提交，未推仓、未构建）
- 改动：7 个文件，+99 / −258
- （注：此路径原有的 v66 .sql 导入修复报告是主树已提交内容，git 历史里在，本文件按本工作树惯例换成本次报告，不影响那份报告的存档。）

## 改了什么（全在 lib/live_screen.dart）

1. **顶栏 `_videoHeader`**：删掉分辨率/帧率读数 Text（key `live-video-resolution`，形如 `[ 720 x 1280 · 15 帧/秒 ]`）和右上角 ⓘ 信息钮（key `live-video-info`，onPressed 原指向 `_showChannelInfo`）；顺删不再用的局部变量 `size`/`fps`。顶栏只剩左边频道名（key `live-video-title` 不变）。上方两处注释（播放区叠层说明、顶栏文档注释）已改成与新版式一致的说法。`live_playback.dart` 的 `videoSize`/`videoFps` 字段按令保留，只是不再显示。
2. **整段删 `_showChannelInfo`**（含文档注释，原 908–1034 行）：它唯一调用方就是被删的信息钮（已 grep 亲验）。连带删掉信息单里全部 `live-info-*` 条目 key。
3. **删 `_openSleepTimer`**：唯一调用方是信息单的「睡眠定时」格，删单后成死代码。`showSleepTimerSheet` 在本文件仍被频道条上的睡眠定时钮（key `live-sleep-timer`）使用，import 保留未动。
4. **节目单/回看入口保住**：信息行节目卡（key `live-epg-card`，`_infoCards` 内）加 InkWell 层：当前频道有节目单数据（`epgMatched` 为真）时点卡打开 `_showProgrammeSheet(channel)`；无节目单数据时 onTap 为 null、点按无反应，不给假入口。卡的尺寸（信息行 80 高、flex 75）、圆角 12、两行文字与 key 全部不变。
5. 顺手修正一处过时注释：DRM/EXO 频道手势层原注释写「全屏走信息单入口」，信息单已撤，改成「全屏走 pane 自带控制条」（EXO pane 本来就自带控制条，行为未变）。

没动的东西：信息行 80 高、左槽预览帧、三列胶囊、左下角 + 导入、切源钮 `live-source-button`、刷新钮、全屏手势与频道条全屏钮、收藏钮，一律未动。

## 测试改齐（5 个文件）

- `test/live_layout_test.dart`：顶栏用例改名「只有频道名、无信息钮…」，`live-video-info` 由 findsOneWidget 改 findsNothing（`live-video-resolution` 原本就是 findsNothing，保持）。
- `test/live_tv_redesign_test.dart`：
  - 「顶栏：分辨率与帧率拼一行」→ 改写为「有真实分辨率与帧率也不显示读数」：setVideoParams(1920x1080, 25fps) 后断言读数 key 与文本都不存在，无帧率时同样不存在；
  - 「右上角：信息钮在…」→ 「信息钮与设置齿轮都没有，报错态也一样」：正常/报错两态 info 均 findsNothing；
  - 「频道信息单：真实字段在、入口全在」→ 改写为「频道信息单已撤：钮与单子都不存在，节目卡无节目单数据时点了不弹单」：原单内字段/入口 key 全部 findsNothing，再点节目卡断言不弹节目单。本文件测试桩没有节目单数据，「点卡开真节目单」的路径改在 live_import_epg_test 里验（见下），没有无声删。
- `test/live_fullscreen_exit_test.dart`：`_enterFullscreen` 原走信息钮→`live-info-fullscreen`，改走点视频区手势（tap `live-stage`，手势层 onTap 即 `_openFullscreen`），测试目的（进全屏再退出、画面不卸载）不变。
- `test/source_picker_wiring_test.dart`：原经信息单点「切换直播源」，改点切源直达钮 `live-source-button`。另在用例末尾补泵 2 秒：切源后新源加载失败会排一次 1.5 秒后的自动补拉，旧路径经信息单时中间多泵的约 700 毫秒恰好替它走完，直达路径下收尾会挂着未触发的 Timer 被判失败（首跑实测如此，基线同文件是通过的，已按此修好并复跑通过）。
- `test/live_import_epg_test.dart`：原点信息钮→`live-info-epg`→节目单，改成点 `live-epg-card` 直接开节目单；后续对 `live-epg-list`、点已播节目回看起播的断言保持不变。

## 测试结果（逐组对照，基线 = 另开 efd0049 工作树同批跑）

| 文件 | 基线 efd0049 | 本分支 e78251e |
|---|---|---|
| live_layout_test.dart | 7 过 | 7 过 |
| live_tv_redesign_test.dart | 8 过 | 8 过（3 条按新口径改名/改写，见上） |
| live_fullscreen_exit_test.dart | 5 过 | 5 过 |
| live_import_epg_test.dart | 21 过 | 21 过 |
| live_api_sources_test.dart + live_drm_exo_test.dart + live_drm_test.dart + live_settings_test.dart | 37 过 | 37 过 |
| live_http_stability_test.dart + live_m3u_builtin_test.dart + live_parser_stability_test.dart + live_resume_test.dart | 43 过 | 43 过 |
| live_subscription_dual_entry_test.dart + live_subtitle_* ×5 + source_picker_sheet_test.dart | 49 过 | 49 过 |
| source_picker_wiring_test.dart | 1 过 2 跳过 | 1 过 2 跳过 |

合计两边同为 **171 过、2 跳过、0 败 → 0 新增失败**。

- 基线老失败清单：**无**。本批 20 个文件基线全部通过；2 个跳过是 source_picker_wiring_test 里 `skip: !allSourcesEnabled` 的既有跳过（短剧区/影视区两条），两边一致、与本次改动无关。
- 全部测试日志在 ~/workspace/tmp_live_info/（t_*.log 为本分支、b_*.log 为基线）。

## analyze

全工程 `flutter analyze --no-pub`（CI 钉版 Flutter 3.50.0）：**0 错 0 警告**；562 条 info 级提示均为既有（定制 SDK 对 material.dart 的弃用 info 等，几乎每个文件都有一条，非本次引入）。改动文件单独复查同样 0 错 0 警告。

## 预览图

`preview/live_no_info_normal.png`（已随提交入库）：照既有 preview_live_fix_normal 的路子单跑出图（临时复制测试指向本工作目录，出图后已删临时测试文件，未入库）。假播放器给的是 1920x1080、25 帧的流参数——图里顶栏只有左边的频道名，右上角没有 ⓘ、没有任何分辨率字样；信息行、三列胶囊、左下角 + 都在。已亲眼验图。

## 意外发现

1. DRM/EXO 频道在直播页的「全屏」此前注释口径是走信息单，现信息单撤掉后，EXO 频道全屏只剩 pane 自带控制条这一条路（普通频道仍有点击手势与频道条全屏钮）。本次只改了注释、没动行为；鸿蒙容器里 EXO pane 自带控制条的全屏是否好用，要等手机实测 DRM 频道时一并看。
2. 睡眠定时在直播页仍有两个活入口（软件设置页「直播设置」节 + 频道条上的睡眠定时钮），删信息单不影响。

---

# 第二批：撤顶栏频道名 + 直播页配色改深（用户 2026-11-26 07:41 令）

- 在 e78251e 之上追加（分支 live-info-remove，未推仓、未构建）。前一名工人已落码未验，本批由收尾工核对 diff、补验、补图后提交。

## 改了什么（全在 lib/live_screen.dart）

1. **顶栏整个撤掉**：`_videoHeader` 方法与挂载点整段删除，key `live-video-title` 在 lib 内无任何引用（grep 亲验，只剩测试里一条 findsNothing 断言）。手机端视频区叠层只剩中间居中转圈/速率（且仅无错时显示），视频区顶部彻底干净。
2. **直播页专属深色层 `_liveDarkTheme`**：`build` 用 `Theme(data: _liveDarkTheme) + Material(近黑底) + Builder` 包整页，页面内各方法 `Theme.of` 读到的都是这一层。从应用主题派生、只换取色：
   - 页面底 `0xFF0D0E10`（近黑）；`surface 0xFF17181B`、`surfaceContainer 0xFF1D1E22`、`surfaceContainerHigh 0xFF26282D`、卡面 `surfaceContainerHighest 0xFF232529`；
   - 主文字白、次文字 `0xFFB9BDC6`、分隔线 `0xFF2E3036`；
   - 选中胶囊底 `primaryContainer 0xFF372A52`（深紫）衬既有黄字 `_liveSelectedText 0xFFFFDF00`——「选中变黄」口径不变；
   - 左下角 + 钮仍用主题主色（饱和色，在黑底上是强调点、不是浅色块）。
   - 取色点已逐个 grep 核对：信息卡、节目卡、当前频道卡、三列胶囊（分组/频道/线路）、频道列表格、台标占位、预览槽（黑底+半透明黑底白字角标）、切源小方钮、+ 钮——全部落进深色层，无残留浅色块。
   - 不动的：全应用主题与其他页面；走根导航器的弹层（选源弹窗=共用件按口径不动、节目单、导入菜单）保持跟随应用主题。
3. **收尾工补修一处**：前一名工人把 `build` 的 `@override` 误挂到 `_liveDarkTheme` 头上，analyze 报 1 条 warning（override_on_non_overriding_member）+ build 多 1 条 annotate_overrides info；已把注解挪回 `build`，analyze 回到基线。

## 测试改动（逐条说明）

- `test/live_layout_test.dart`：顶栏用例改名「视频区顶栏：整个撤掉、无频道名、…」，`live-video-title` 断言由 findsOneWidget 改 findsNothing；其余断言（信息钮/齿轮/分辨率/网速均不存在）不变。
- `test/live_tv_redesign_test.dart`：只改文件头注释（「顶栏只有频道名」→「顶栏整个撤掉」），断言未动。

## 测试结果

- 受影响 20 个 live_* / source_picker_* 文件全跑：**171 过、2 跳过、0 败**，与基线 e78251e 逐组同数（2 跳过仍是 source_picker_wiring 既有 skip），**0 新增失败**。日志 harness/live_dark_tests.log。
- analyze（Flutter 3.50.0，--no-pub）：**0 错 0 警告**，562 条 info 与上一批基线同数、均为既有。日志 harness/analyze_dark2.log。

## 预览图

`preview/live_dark_normal.png`（随本批提交入库）：照 preview_live_fix_normal 路子复制临时测试出图后删临时文件。特意选**浅色主题 lightClean** 渲染——正是用户嫌灰白的场景：图里视频区顶部无频道名，下半部近黑底、深灰卡面、白字可读，选中胶囊深紫底黄字，+ 钮为主题蓝圆钮，无残留浅色块。已亲眼验图。与上一批浅色图 preview/live_no_info_normal.png 对照即见差别。
