# 软件更新启动弹窗补齐批报告（2026-11-26）

## 任务

用户 2026-11-26 17:31 令「全部修复更新补上」：软件内远程更新的启动弹窗本体补齐。
2026-11-23 定版的同批改动里，更新源改仓（huoyi-releases → moytv）那一行已随 v68 出，
弹窗本体当时没合进组装树，本批补上。本地提交，不推仓、不构建。

## 基线与工作树

- 基线：`~/workspace/moyi_v68_assembly_20261126` 顶端 `ed69442`
- 工作树：`~/workspace/moyi_app_update_popup_20261126`，分支 `app-update-popup`

## 蓝本来源

蓝本是此前 app-update 批的工作树 `~/workspace/moyi_app_update_20261123`（分支
`app-update`，基线为 v61 时代的树）里未提交的成套改动，本批逐件移植到现行基线：

| 蓝本件 | 移植结果 |
|---|---|
| `lib/app_update_prompt.dart`（新增，弹窗本体） | 原样移植 |
| `lib/app_update.dart` 新增段（稍后再说记版 + 启动弹窗判定） | 原样移植，插入点与蓝本一致（`maybeCheckSilently` 之后、`downloadApk` 之前） |
| `lib/home_screen.dart` 启动挂钩（首帧后查一次 + 两行 import） | 按基线现行 initState 结构逐处落位（基线多了 `site_thumb_cache` 等 import、initState 行号已移位，未整段套用蓝本 diff） |
| `test/app_update_prompt_test.dart`（新增，4 条） | 原样移植 |
| `lib/update_config.dart` 改更新源一行 | 基线已含（随 v68 出），本批未动 |

移植前已核对基线依赖齐全：`isForceUpdate`、`cachedLatestVersion`、`fetchLatest`、
`currentVersion`、`AppUpdateChannel.installApk/openUrl`、发布说明 FORCE 窗口解析
（FORCE_AFTER/FORCE_UNTIL）在基线 `app_update.dart` 里都在，蓝本代码零适配即可编译。

## 落点（本批实际改动）

1. **`lib/app_update_prompt.dart`（新增）**：`showAppUpdatePrompt`——
   - 普通更新：标题「发现新版本 X」、当前→最新版本、更新说明、「稍后再说」+主按钮；
   - 安卓主按钮「下载并安装」：框内下载带进度条与字节数，完后调系统安装器，失败在框内红字报错可重试；
   - 非安卓主按钮「打开发布页」：跳该发布版页面；
   - 强制更新（发布说明 FORCE 窗口内）：无「稍后再说」、点框外关不掉、红字强制提示。
2. **`lib/app_update.dart`（新增一段）**：
   - `dismissUpdate` / `isUpdateDismissed`：把点过「稍后再说」的版本号记进偏好
     （键 `app_update_dismissed_version`），只跳过这一版；
   - `pendingUpdatePrompt`：启动判定——静态闩锁保证一次启动最多查/弹一次；
     先看缓存的最新版（缓存比当前新且没被忽略就拉完整发布信息弹窗），
     没有缓存新版时按既有 24 小时节流去拉取；任何失败（没网、源异常）静默返回 null 不打扰。
3. **`lib/home_screen.dart`（两处）**：加 `app_update.dart`、`app_update_prompt.dart`
   两行 import；`initState` 末尾挂首帧回调 `_maybePromptAppUpdate()`，
   拿到待弹版本且页面还在才弹窗。
4. **`test/app_update_prompt_test.dart`（新增）**：弹窗显示、「稍后再说」记版、
   强制更新无「稍后再说」、记版判定共 4 条。
5. **`test/app_update_prompt_preview_test.dart`（新增，仅出预览图用）**：两态各一测。

## 与既有更新检查的衔接

- 更新源读取仍走 `update_config.dart` 的 `kReleaseRepoSlug` 单点（带站点版 moytv /
  空壳版 moytv-shell 由各自树的该常量决定），弹窗逻辑不写死仓库名，两版共用同一套。
- 设置里「软件更新」手动检查入口未动，照旧能查最新版、下载、安装；
  本批只加启动自动弹窗这一条触发路径，判定与下载都复用 `AppUpdateChecker` 既有实现。
- 既有静默检查 `maybeCheckSilently` 与缓存键、节流键都沿用，未改口径。

## 验证

- 功能测试：`test/app_update_prompt_test.dart`（新增 4 条）+ `test/app_update_force_test.dart`
  （既有强制更新测试）共 8 条全过。
- analyze：改动 5 个文件 0 错 0 警（仅仓库通有的 info 级 material 弃用提示，非本批引入）。
- 回归对照：引用 home_screen / app_update 的 33 个测试文件逐块在本树跑，
  失败项逐条在基线同跑定性，结论 0 新增失败，明细见文末补记。
- 预览（版本号与说明为示意数据，字形方框是预览环境子集字体伪影，真文案由组件测试逐字断言）：
  - 普通更新：`preview/app_update_prompt_normal.png`
  - 强制更新：`preview/app_update_prompt_forced.png`

## 手机终验项

1. 装上含本批的下一版后，再发更高一版：冷启动应弹更新框，一次启动只弹一次；
2. 安卓点「下载并安装」：框内进度走完并拉起系统安装器，能覆盖安装；
3. 点「稍后再说」：同版本再启动不弹；再发更高一版后启动重新弹；
4. 发布说明带 FORCE 窗口的那一版：弹窗没有「稍后再说」、点框外关不掉；
5. 断网冷启动：不弹窗、不报错、不卡启动；
6. 设置→软件更新手动检查照旧可用（查版、下载、安装全链）；
7. 空壳版（更新源 moytv-shell）合入后同验 1–5，确认读的是它自己的源。

## 遗留

- 本批基线是带站点版组装树；空壳版组装时把本批提交合过去即可（弹窗逻辑与更新源
  读取共用，空壳树只需其 `update_config.dart` 保持 moytv-shell，不要覆盖）。
- 鸿蒙卓易通容器内框内下载后调安装器是否放行，未实测，列在终验项 2 里以手机为准。

## 回归对照结果（补记）

引用 home_screen / app_update 的 33 个测试文件：整链跑两次均被本机内存杀掉
（OOM，与同机其他批次并行有关），改逐块/逐文件跑完 32 个文件，失败共 10 条，
逐条在基线（组装树 ed69442）同跑复现，全部为基线既有失败，**本批 0 新增失败**：

| 失败项 | 基线定性 |
|---|---|
| bottom_tab_nav「短剧首页 requestedTab 直达女优库页」 | 基线既有（此前批次已实证，演员库入口换页所致） |
| downloads ×3（VIP/quality added=0、added=2、窄屏队列控制） | 基线逐条同挂 |
| empty_state_diagnostics ×2（空状态诊断入口有/无） | 基线同文件同挂 |
| win7_window ×3（女优库窗口家族） | 基线同文件同挂 |
| xp_window ×1（开始菜单女优库单叶） | 基线同名同挂 |

其余文件全过（分块计数：+23、+50、+17、+45 后被 OOM 截断的那块死前 0 失败等）。

唯一未取得结果的文件：`library_features_widget_test.dart`——在本机当前环境下
首个测试即挂死（测试内真异步等不到推进），换不同首测同挂；基线同文件同名实测
同样挂死在 00:00，双向实证为环境/基线既有状况，与本批改动无关。该文件测的是
历史/追剧/目录卡片，与本批改动面（启动弹窗）不相干；待本机负载恢复后可补跑。
