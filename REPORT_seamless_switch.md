# 无缝换集实现报告（魔蚁TV）

- 工作树：`~/workspace/moyi_seamless_switch_20261126`，分支 `seamless-switch`，基线 `efd0049`（v67）。
- 口径来源：用户 2026-11-26 07:45 别家 v1.2.2「三内核无缝换集」截图。本地提交，不推仓、不构建。
- 注：工作树根目录的 `REPORT.md` 是基线提交自带的旧报告（.sql 导入修复线），与本批无关，未动；本批报告用本文件名。

## 一、逐核可行性结论

| 核 | 结论 | 依据 |
|---|---|---|
| EXO（TvboxPlayerPlugin，Kotlin/Media3） | **真无缝** | 插件按 PlatformView 逐个建独立 ExoPlayer、按 viewId 分通道，无单例限制，双实例可并存。原缺口只有「首帧已渲染」事件没转发到 Dart——本批补上（见 Kotlin 改动）。待命面以暂停态预加载备首帧，切换时晋升为正式面出画。 |
| MPV（media_kit） | **真无缝** | media_kit 的 Player 是纯 Dart 对象，可多实例并存。主屏原把单个 Player 绑死在增强/画质/手势三个辅助对象与引擎流订阅上，本批改为「双装置槽位 + 对调重绑」：待命 Player 静音暂停预热到出画面尺寸，对调时翻槽位、重绑流与辅助对象，旧 Player 转待命。代价是预热期多一个解码器实例的内存占用（真机量级待验，见手机待验项）。 |
| IJK（IjkPlayerPlugin） | **降级现行换集** | 插件 prepare 完成即自动开播，没有「暂停预热待命」模式，也没有首帧事件；mediacodec 双实例在本机型谱上不可靠。无缝开着时 IJK 不预热、切集走现行路，播放与其余功能完全不受影响。设置文案里已明说这一点，不假装支持。 |

覆盖范围：主播放器页（`lib/player_screen.dart`，含内嵌模式与电视模式）全覆盖。**西瓜页**（`lib/xigua/`，自有播放器与 preloader）与**一起看 watchroom**（多端同步语义，对调会破坏同步基准）本批不覆盖；红果 `hongguo_preload.dart` 未动。

## 二、实现方式

### 设置与联动（单向依赖）
- `PlaybackPreferences` 加 `seamless` 字段，默认 `false`，随 JSON 持久化；存量数据里若出现「无缝开但预加载关」的矛盾组合，读取时归一化为无缝关。
- 联动收敛到两个方法，全应用只走它们：`withSeamless(true)` 连带 `preload=true`；`withPreload(false)` 连带 `seamless=false`（关无缝不动预加载，反向不成立）。
- 露出位置与现有「下一集预加载」开关并排三处，状态同源一致：播放设置页（`viewing_experience_screen.dart`，key `viewing-seamless-switch` / `viewing-preload-switch`）、播放器菜单（`player_menu.dart`，key `player-seamless-enabled` / `player-preload-enabled`）、电视设置弹窗（`television_controls.dart`，key `tv-seamless-enabled`）。

### 预加载复用（不重写）
- 复用既有 `PlaybackPreloader`（播到后段预解析下一集 plan + 少量字节预取，覆盖嗅探/解析类源的解析环节）。新增只读 `peekReady(...)`：身份（剧/集/画质/线路/在线/去广告）与未过期都对上才返回已备 plan，不消费；正式换集仍走原 `take` 路。

### 待命管理（`lib/seamless_switch.dart`，新建）
- `SeamlessStandbyManager` 只做记账：预热目标 = 预加载备好的下一集 plan；键 = plan 会话（无会话时用地址）+ 集序号；状态 idle/warming/ready/failed；首帧等待 8 秒超时即 failed；代次号防迟到结果污染新一轮预热；同键去重、异键顶替。
- 可预热判定 `seamlessPlanWarmable`：本地文件、空地址、需解析（needsParse）、带解密密钥、纯音频/网页地址一律不预热——这类 plan 待命播放器独立打开会与主链语义不一致，宁可走常规路。嗅探/解析类源的「解析等待」已由预加载层吃掉，切集不再等解析；只是其最终流仍走常规开播。
- 驱动：主屏 1 秒健康定时器调 `_syncSeamlessWarm`（原生核进度不走 MPV 流，只能靠定时器统一驱动三核），门槛与既有预加载同构（播过 2 秒且过半，或剩余 ≤45 秒）。喂待命前对 plan 做与正式开播相同的自定义请求头变换，保证待命打开的就是最终要播的那条流。

### 对调切换（`lib/player_screen.dart`）
- EXO：正式面之外挂一层 headless 待命面（`TvboxVideoPane` 新增 headless 模式：只渲染平台视图，不画控制/字幕/缓冲、不起实时字幕；新增 `onFirstFrame` 回调与句柄 `firstFrameReady`/`stop()`）。待命面暂停加载下一集备首帧；切换时翻装置号，待命面晋升（plan/autoplay 落位、按意图 play/pause、补起实时字幕），旧面 stop 后拆掉。两个面的平台视图 key 按装置号固定，对调不重建平台视图。
- MPV：正式 Video 之下挂待命 Video（无控制层、字幕关）。待命 Player 打与正式开播完全相同的平台属性、音量 0、暂停打开、等画面尺寸事件确认首帧。对调 = 翻槽位 + 退订/重绑引擎流 + 用新装置重建增强/画质/手势三辅助对象 + 旧 Player stop + 恢复音量与倍速。控制层（PlayerControls/TelevisionControls）按装置号 keyed，对调时强制重建以重订新 Player 的流（这两控件只在 initState 订阅、不重绑，必须靠 key）。
- 命中判定在 `_play` 里 plan 定稿后拦截（`_trySeamlessSwap`）：无缝开、非音频模式、非恢复/换线/外带 plan、从头播、意图为播放、管理器 ready 且目标集与内核都对得上，才消费待命对调；任一不符原样落回常规安装路。
- 不黑屏衔接：待命已就绪且目标对得上时（`seamlessCandidate`），本次切集全程不停当前播、不置加载态（无黑罩无转圈）、不做 302 预解析（待命播放器自己跟跳转，落地按会话命中）；对调未命中再回常规路（此时 plan 未预解析，播放器原生跟跳转，无功能损失）。
- 待命丢弃点：切到非预热目标的集（走 `_play` 未命中即原路，且预热目标随新集重新计算）、访问状态变化、预加载被清、画质/去广告/无缝开关变化、切换内核。

### 失败回落
- 预热超时（8 秒）/首帧失败/待命面报错/计划过期/身份不符：一律记账为 failed 并拆待命，换集走常规路；全程不弹错、不打断当前播放。对调落地中途失败同理回落（待命已被消费时先拆内核待命再走常规安装）。

## 三、状态衔接清单（逐项结论）

- **自动连播**：播完回调仍走 `_play(下一集)` 同一入口，命中待命即对调，未命中原路；对调后 `_openedIndex`、健康检查、弹幕 plan、生命周期可见性与正式路逐项等价落位。✔
- **切后自动播放**：对调尾巴按播放意图 play/pause，并恢复倍速与（MPV）音量。✔
- **画面比例**：比例由 Video/面板的 videoParams 流驱动，对调后引擎流已重绑到新装置，尺寸事件来自新 Player；待命 Video 与正式 Video 同尺寸铺满，下层待命不会改变上层比例。✔
- **缓冲圈/解码器实况**：缓冲与测速读的都是当前装置的播放器状态与 plan 测速闭包，对调时 `_plan` 与后端管理已按正式路落位；加载态在候选路径不置位，无假转圈。✔
- **字幕/音轨**：内嵌字幕/音轨轨由各播放器实例自带，待命 Player 打开时即带轨，对调后轨列表随新装置的流重绑刷新；实时（外挂）字幕：MPV 对调后重启，EXO 晋升时补起（headless 待命期不起）。✔（轨的「用户已选轨」是否跨集保持与现行换集行为一致——现行也是新实例默认轨，本批不改变这一语义。）
- **跳过片头片尾**：基线主屏尚无此功能（在未合入的 easytv 学习批分支上）。对调走 `_play` 同一入口，将来该功能合入后对两条路自动同等适用，无需再改。—（本批无可验项，已核对入口同构。）
- **核间回退链**：对调只发生在「全新正播」这一窄门槛内；恢复、换线、换核、嗅探兜底全部绕开对调，且这些路径开始前待命已先丢弃，不会被旧待命污染。✔
- **已知小账**：切集时若正处后台音频轨关闭状态（MPV 视频轨关），对调后的新 Player 视频轨是开着的，回到前台时既有 `_syncVideoTrack` 会自愈对齐；后台期间多解码一路视频轨，无功能错误。

## 四、Kotlin 改动清单（仅 1 处）

- `android/app/src/main/kotlin/moyi/TvboxPlayerPlugin.kt`：EXO 监听器新增 `onRenderedFirstFrame()` 覆写，向 Dart 转发 `onFirstFrame` 事件。仿既有 `onIsPlayingChanged` 等覆写的同一写法（同一监听器对象、同一 channel.invokeMethod 形态），Media3 `Player.Listener` 的标准回调，无新接口、无签名变化——这是本批唯一的 Kotlin 改动，有把握。配套 Dart 侧：`tvbox_player_bridge.dart` 加 `firstFrameStream`（release 时关流），`tvbox_video_pane.dart` 句柄加 `firstFrameReady`/`stop()`、面板加 headless 与 `onFirstFrame`。
- 本机编不了 Kotlin，此改动靠云构建编译验；Dart 侧 analyze 已过。

## 五、测试对照

- 基线：改动前在 `efd0049` 同集 23 个文件串行实测，21 条老失败（local_persistence 5、player_back_arrow 2、player_screen 10、player_unified_page 1、television_player 3，多为 pumpAndSettle 超时、与当时多工人并行抢 CPU 有关），逐名清单留档。
- 新测试 23 条全过：`seamless_standby_manager_test.dart`（键生成/可预热判定/命中对调/错键不消耗/首帧失败·超时·抛错回落/去重/异键顶替迟到不污染/丢弃迟到丢弃）、`playback_preferences_seamless_test.dart`（默认关/JSON 往返/开无缝连带开预载/关预载连带关无缝/矛盾数据归一化/老数据默认关）、`playback_preloader_peek_test.dart`（peek 不消费/take 仍可取/身份不符返回 null）、`player_menu_seamless_test.dart`（菜单开关存在/点开连带预载/关预载连带关无缝/默认关态）。
- 改动后同集 23 文件重跑：失败 15 条，**逐名比对全部在基线清单内，0 新增失败**；基线中 6 条这次转过（抖动项）。定稿代码再复跑最受影响三文件（player_screen / player_unified_page / television_player）：8 条失败，仍 0 新增。
- analyze（全工程）：0 错 0 警告；info 563 条 = 基线 562 + 新测试文件 1 条（与全仓每个文件同类的 material 弃用提示）。

## 六、手机待验项

1. 真机双播放器并存的内存/发热（MPV 预热期多一个解码实例、EXO 双 ExoPlayer），低端机型尤其要看。
2. 鸿蒙卓易通容器内 EXO 双实例行为与「暂停态备首帧」的真实渲染（首帧事件到了是否真能晋升即出画）。
3. Kotlin 首帧事件改动靠云构建编译验（本机编不了）。
4. 无缝开/关与预加载联动在真机设置页、播放器菜单、电视弹窗三处的实际手感与状态一致性。
5. 自动连播连续多集时待命链是否逐集接续（对调后旧 Player 转待命预热再下一集）。
