# 演员库 115 离线 + 直达播放 + 起播竞速（第三批）报告

分支 `actress-whos-ui`，基线 e1b06e1（第二批）之上。本批只本地提交，不推仓、不构建。

## 一、接口参照（两份实证，不再用拼接推定/泛研）

### 星辰115 源码（com.lin.pan115，用户发来的源码，本 App 一期/二期 115 修复的同一参照源）

- **加离线任务**：POST `https://clouddownload.115.com/lixianssp/`，表单只有一个字段 `data` = `m115RsaEncrypt(JSON{url, wp_path_id, ac:"add_task_url", app_ver})`（ac 在加密载荷里、不在 URL 上，所有值转字符串）；UA = `Mozilla/5.0 115disk/36.2.28 115Browser/36.2.28 115wangpan_android/36.2.28`（ver 与其 APP_VERSION 对齐）。响应先 `contentMaybeDecrypt`，`state==true` 才算成功；`data` 是 RSA 加密字符串时再解一次取 `info_hash`（拿不到不影响成功判定）。RSA 底座复用 App 现行 `cloud_m115_crypto.dart`（与取链同一套，已有夹具测试覆盖）。
- **任务列表**：GET `https://clouddownload.115.com/web/?ac=task_lists&page=1&page_size=30&stat=0`（明文 web 路）；`tasks` 在响应顶层。任务字段照其 `toOfflineTask`：`info_hash / name / size / url / status`（0 等待、1 下载中、2 已完成、-1 失败）`/ percentDone`（0–100，数字或字符串）`/ wp_path_id`。完成判定以 `status==2` 为主、进度满格为兜底。
- **配额**：GET `https://clouddownload.115.com/?ac=get_quota_info`，总/已用/剩余键名多路兜底（照其键表），凑不齐总数回 null、不糊弄。客户端有方法，界面未用。
- **删任务**（本件不用，备查）：POST `/web/` 表单 `{hash[0]…, flag:"0", ac:"task_del"}`。
- **保存目录**：`wp_path_id` 提交前先读默认云下载目录（GET `webapi.115.com/offine/downpath`，offine 是站方原拼写）取其 id；读不到回落 `"0"`（星辰重试路同款兜底），读到后缓存。
- **番号提码**：`pan115ExtractCode` 照其 `data/CodeExtractor.kt` 逐条移植——全角转半角、去扩展名、剥方括号段与括号年份、分隔符空格收紧、ISO 日期并形；制式顺序 FC2-PPV / FC2 / HEYZO / 日期型 8 位与 6 位（月日合法性校验）/ Heydouga（19/20 开头排除）/ 数字开头型 / 标准型（年份点分隔与 BIT 位深排除）/ 前缀带数字型 / 无分隔符型 / Tokyo-Hot；屏蔽前缀表（H264/H265/HEVC/SDR/HDR 等 41 词）逐字抄录。原规则的后视断言用「逐个候选校验前一字符」等价实现（Dart 正则后视支持不稳）。每条制式只看第一个候选、校验不过落下一条，与原实现一致。
- 注：先前按 p115client 泛研的 web 明文提交路（`/web/?ac=add_task_url`）已按用户令作废，全换 ssp 路。

### jar 版 JavDB 蜘蛛 ZakaJavdbAmns（zakatv.jar 反编译，3684 行）——流程对照

| jar 版流程 | 我们这边的落法 |
|---|---|
| 详情打开即拉 `/api/v1/movies/{id}/magnets`，`rankMagnets` 排序取第一名，已登录+预取开就自动提交离线 | 同：详情页后台链拉磁力（已排序），115 区确认「已登录、网盘无此文件、无同 hash 在跑任务」后自动提交排名第一条，页面明示「已提交 115 离线」 |
| `rankMagnets`：`normHash`（只认 40 位十六进制、磁力链抽 btih）去重留分高者，`score()` 降序：做种数×1e9 主导、中文字幕（标记或名含中文字幕/中字/中文/chinese/chs/cht）+1e7、高清（标记或名含 2160p/4k/1080p/高清/hd）+1e6、大小 500–8000 MB +1e5、日期拼数×0.001、减 \|大小MB−2500\|×1e-6 | `javdbMagnetScoreOf` / `javdbRankMagnetJsons` / `javdbNormHashOf` 逐项对照移植，`movieMagnets` 返回前先排序去重——磁力区展示顺序与自动离线选的都是排名后第一名 |
| 磁力链接 `magnetUri`：`magnet:?xt=urn:btih:{hash}`，有名带 `&dn=` 编码后的「[javdb.com]」+名 | `javdbMagnetLinkOf` 同拼法（url 字段已是现成磁力链时照原样） |
| 磁力接口路径与信封：GET `/api/v1/movies/{id}/magnets` → `data.magnets`（每条 hash/name/size(MB)/created_at/hd/cnsub/files_count/seeders 等） | 路径与信封由「拼接推定」升级为 jar 原文实证（解析键原本已含 magnets，本批把注释口径改实）；`_getJson` 成功门放宽：没给 success 字段时以 data 在场为准（jar 的 api() 就是只认 data 在场），success 明确为假照旧拒绝 |
| 播放时 `tryDirect`：按 infohash 查任务目录文件 → pickcode → 取下载直链秒开（它走 proapi android/2.0/ufile/download） | 等价替换：按番号在网盘全盘搜已存文件（提码精确匹配）→ 现行 m115 `Pan115Provider.directLink` 取链（与一期/二期取链同一条） |
| 没有才 `submitMagnet`（ssp add_task_url）；`waitPlayable` 每 2.5 秒重试 tryDirect、约 22 秒等不完就返回百分比提示「过 1~2 分钟再点一次就是秒开」；单任务进度走 ssp `ac=get_user_task`+info_hash | 提交同 ssp 路（星辰写法，载荷不带 jar 的 `app:"android"` 字段，以星辰为准）；进度改走星辰的任务列表轮询（10 秒一轮、页面开着持续跟随，比 jar 的 22 秒窗口更贴详情页场景）；等不完的回话照 jar 口径落成可点提示：海报/下载行点按出「正在存到 115（已 X%），过 1~2 分钟再点一次就是秒开」，不硬播 |
| 直链按 infohash 内存缓存带 TTL（URL_CACHE） | 网关层按文件 pickcode（extra 里）内存缓存直链，TTL 10 分钟，等价替换 |
| 按番号分类建夹保存（saveByCat/folderForOffline）、浏览列表后台预存池、服务端排队接口 | **不接**：演员库只做「打开详情自动提交第一名 + 播放先查已有再轮询等下完」一段（用户令明确只要这一段）；保存落默认云下载目录，不另建分类夹与设置 |
| 登录是另一个站写共享 cookie、蜘蛛只读 | 不用这套：见第二节分工 |

## 二、115 设置/登录分工（照 jar 分工落）

- 演员库**不新建任何 115 登录界面、不另起一套设置**：直接用 App 现行 115 登录态（网盘页那套 qandroid 扫码登录、凭证存 CloudCredentialStore 的 pan115 项）。离线客户端只拿 cookie 干活，自己不做登录。
- 详情页 115 区发现未登录：只留一行轻提示——「115 未登录，登录后可自动离线并在本页播放（去网盘页登录）；未登录不影响在线与本地线路播放」——不弹窗、不提交、不轮询。
- 自动离线的保存目录不做成演员库设置：用默认云下载目录（downpath 读 id、回落 "0"），没有新增任何开关/目录选择界面。

## 三、115 不是播放前置条件（用户令）

未登录 115 时完整播放链照常成立：在线各源（who's/123AV/PH 及后续六源）与本地数据库线路照常竞速、照常兜底，海报播放键与各播放入口都不挂在 115 登录后面。115 那一路只在已登录时才参与（自动离线、查存货、等下完）；未登录时竞速 E 路在本地查凭证即返回空，不拖慢、不拦其他路。

## 四、详情页 115 区状态机（演员库链 DetailScreen，通用详情页磁力区未动）

落点：`lib/cloud_drive/cloud_115_offline.dart`（新文件：离线客户端/网关/提码/解析）、引擎公开方法（`cloud_drive_engine.dart`）、`NativeRepository.actressPan115Gateway()`（`core_bridge.dart`，懒建单例）、详情页注入点 `DetailScreen.pan115Gateway`（演员库三处入口构造时注入：本地/who's 链、123AV/PH 链、JavDB 链）。

- 未登录：一行轻提示（见上），整链收手。
- 已存该番号文件：出「115 播放」行，本页点按取直链直达正式播放器，不跳网盘页/浏览器/选线列表。
- 没存、有磁力：自动提交排名第一条一次。去重三道：①本地已提交记录（SharedPreferences 按 infohash 记）；②提交前查任务列表同 hash；③网盘已有文件不提交（开页查过、提交前再兜一次）。提交后明示「已提交 115 离线」并 10 秒轮询进度（百分比+进度条），文件出现即转播放行并停轮询。
- 没存也没磁力：整区不显示。
- 失败口径：115 链任何失败只让本区不显示/不提交，不挡详情页、不弹窗。

番号匹配分档（`pan115FileForCode`）：第一档——文件名提码与详情番号归一后精确相等；第二档（弱）——提不出码的文件退回文件名归一包含匹配；提码提出别的番号的文件不回退包含档（防 SSIS-0010 串到 SSIS-001）。

## 五、起播口径定版（2026-11-26 20:10 令，覆盖 19:28 顺序兜底与 20:09 无优先权）

女优页点播竞速（`actress_detail_page.dart` 的 `_racePlayableDetail` + `_playWork`）：

- **115 短优先窗优先**：115 已登录且网盘已存该番号、取链并经同一把快验尺（`_verifyFetch` + `feedProbePlayable`，只拉播放列表/首段）验活通过时优先起播——实现为 2 秒优先窗：窗口内 115 线路一到即赢；其他路先验活的先扣住，窗口结束没等到 115 就放扣住的第一名起播，不让 115 干等满全场、也不让别人白等超过 2 秒。
- **其余两方同尺竞速**：在线各源与本地数据库地址并行取址、同一把快验尺验活，谁先验活谁先起播，无人为优先。
- **与原「库第一条即开」机制的差异**（按令注明）：此前对标早上发布版——库里第一条地址不验活直接开播、在线竞速在后台换线。本批起库地址改走 A 路同尺验活后参与竞速，不再未验活直开；验活只拉播放列表/首段，通常仍是亚秒级，换来不起播死地址。同一番号竞速赢过时仍用缓存的已验活地址秒开，这点不变。
- **落败方不丢弃**：全部验活线路按到达顺序收进 verifiedLines，换线链先出已验活线路（按到达顺序）、耗尽后才出库里未验活的下一条地址兜底；报错屏重试同序。
- **边界**：115 还在离线下载中的不算竞速选手（下完后由详情页 115 区转成播放行补进）；未登录 115 时就是在线与本地库两方竞速，播放不受影响（见第三节）；三方全灭才如实报「暂无可播线路」，不硬播、不跳转。
- 详情页海报播放键同口径：115 已存货时优先落 115 线路，否则播当前详情线路，115 下载中点按给百分比提示（见第一节 waitPlayable 行）。

## 六、改动文件

- 新增 `lib/cloud_drive/cloud_115_offline.dart`：`Pan115OfflineClient`（ssp 提交/任务列表/配额/downpath）、`Pan115Gateway` + `EnginePan115Gateway`（登录判定、按番号搜文件、直链 TTL 缓存、已提交记录）、`pan115ExtractCode`、`pan115FileForCode`、`pan115SubmitResultOf`、`pan115SubmitPayloadOf`、`pan115TasksOf`、`pan115QuotaOf`、`pan115InfoHashOf` 等。
- `lib/cloud_drive/cloud_drive_engine.dart`：公开 `pan115LoggedIn / pan115OfflineClient / searchPan115Files / pan115DirectLink`。
- `lib/core_bridge.dart`：`NativeRepository.actressPan115Gateway()` 懒建单例；`actress_online_detail.dart` 加共用助手 `actressPan115GatewayOf`（非 NativeRepository 回 null）。
- `lib/detail_screen.dart`：115 区状态机与轮询、海报 115 优先、下载中点按提示、三处内部 DetailScreen 构造转发网关。
- `lib/actress/actress_detail_page.dart`：竞速 E 路（115 已存才参与、本批加优先窗）、首播改等竞速赢家、换线链已验活优先。
- `lib/actress/actress_online_view.dart`、`lib/actress/javdb_view.dart`：构造 DetailScreen 时注入网关。
- `lib/actress/javdb_api.dart`：磁力排序/归一/dn 拼法、成功门放宽（属第二批文件的流程对照修正，随本批提交）。
- 测试：新增 `test/actress_pan115_offline_test.dart`；`test/actress_javdb_extra_test.dart` 夹具改 40 位真 hash 并加排序用例。

## 七、验证

- 新测试 `actress_pan115_offline_test.dart` 19 例全过：ssp 载荷（注入 encrypt 替身验明文：字段/ac/app_ver/wp_path_id 回落）、提交响应判读（注入 decrypt 替身验 data 分支；RSA 原语本身由 `cloud_m115_crypto_test` 夹具覆盖）、任务列表真实字段解析、配额、提码各制式与挡假番号、番号分档匹配、已提交记录、详情页 115 区四态（未登录提示/已存出播放行/自动提交一次并明示/无磁力不显示）。
- `actress_javdb_extra_test.dart` 10 例全过（含新增 rankMagnets 排序/去重/坏 hash 丢弃、normHash、dn 拼链断言）。
- 回归：演员库组 8 文件（play_fallback / play_missav_first / poster_play / javdb_api / javdb_stills / online_lines / online_parse / detail_sections）60 过 2 挂；云盘组 7 文件 152 例全过。
- 2 个挂与基线 e1b06e1 **同名同因**（临时 worktree 对照实证：`actress_play_fallback_test` 的「第一档本地 db 活的」在基线同一行 1009、同一断言失败——该测试前提即旧「库第一条直开」机制、且基线时已挂；`actress_play_missav_first_test` 的站点探查顺序一条同为存量失败），**0 新增失败**。前者建议后续按新起播口径单独修测试，本批未动。
- analyze 改动文件 0 错 0 警（仅余全树共有的 info 级弃用提示）。

## 八、未验项（如实）

- **115 真提交未验**：要真 115 账号登录态 + 本机出口，本机出口断、属手机终验——ssp 提交的真实响应形状（state/data 加密串）、任务进度真值、downpath 真实 id 都等手机上验。
- **JavDB 接口真拉未验**：同出口问题；磁力路径/信封/字段已由 jar 原文实证，解析与排序层已夹具验真。
- 起播优先窗 2 秒为实现取值：真机网络下 115 取链+验活若常超 2 秒，115 会退化成普通竞速（仍能赢），不影响正确性；是否调窗长等手机实测。
