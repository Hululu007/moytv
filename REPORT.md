# 插件安装免确认 + 插件列表三列网格 —— 交卷报告

- 工作区：`~/workspace/moyi_plugin_ui_20261125`（worktree，分支 `plugin-list-ui`，基线 main 246378a / v66）
- 状态：**树内改完、测试过、只本地提交；未推仓、未构建、未上手机。**
- 本批范围：只碰 idj 插件线（`lib/idj_plugin_store.dart`、`lib/miniapp/idj_plugin_tab.dart`）与技能/检查器；未动 plugin_manager（剥离批范围）、未动演员库（导入批范围）。

## 一、安装免确认：拆了哪几个确认（逐个列原位置）

装一个插件原来要过的「点头关」共 3 处，现已全拆：

1. **安装确认 sheet（订阅市场点安装、本地文件安装、粘贴安装、更新检查点更新——四条路径共用）**
   - 原位置：`lib/miniapp/idj_plugin_tab.dart` 的 `IdjInstallConfirmSheet` 组件 + `showIdjInstallConfirmSheet()` 函数，由 `IdjPluginActions.installBundleText()` 在真正安装前弹出，等用户点「安装」按钮（key `idj-confirm-install`）才继续。
   - 改法：整个 sheet 组件与弹出函数删除；`installBundleText` 解析完直接装到底。装完用一条 SnackBar 给结果：新装显示「已安装「名」」+ 分区分区文案（短剧/午夜等口径不变）；更新显示「已更新「名」到 vX」。
2. **升级「多申请域名」权限确认（store 层拦截）**
   - 原位置：`lib/idj_plugin_store.dart` 的 `installBundleText({bool permissionConfirmed})`——更新时若 `IdjPermissionDiff.needsConfirmation` 为真且未确认，抛错「新版本申请了更多权限，请确认后再更新」逼用户走确认。
   - 改法：删 `permissionConfirmed` 参数与拦截抛错（`installBundleBytes`、`installFromSubscriptionPlugin` 同步删参）；`IdjPermissionDiff` 计算保留，只作装完后的提示来源——升级多申请了域名时，结果提示后括号带一句「新版本多申请了 N 个域名」，不拦路。
3. **本地导入的确认步**：即第 1 条的同一 sheet（本地文件/粘贴/网址三条入口都汇到 `IdjPluginActions.installBundleText`），拆 sheet 后一并免确认：选完文件/贴完内容直接装，失败照实弹原因。

**没动的（拒装不是确认，不在本令范围）**：卸载确认框保留（删东西的确认与「安装确认」是两回事，简报只拆安装侧）；硬拒照旧——带 TG 的站、指向未成年题材、域名/IP 校验不过、integrity 哈希对不上、包损坏、下载失败，全部照旧拒装/报错并给原因。

## 二、签名口径变更专节（2026-11-25 21:36 用户令，覆盖原红线）

用户原话：「带签名的包正常安装」「只认包不认签名」。原先「带 integrity.signature 直接拒装」作废。三处落点：

1. **App 安装校验**（`lib/idj_plugin_store.dart`）：删 `_checkSignature()` 拒装方法与其在 `parseBundleText` 里的调用、删 `IdjPluginManifest.signatureBlock()`、删 `problems()` 里「签名算法只支持 ed25519」一条。原位置留注释记新口径。现安装校验只剩包本身：manifest 合法性 + integrity 哈希 + 域名清单。查实签名拒装只在这一处（Go 侧的 signature 是 host.crypto 接口、main.dart 的 `_checkSignature` 是 App 自身签名校验，均无关、未动）。
2. **技能**（`~/workspace/custom-skills/iduanju_plugin_build/SKILL.md` + `references/repo-vs-moyi.md`）：共 5 处措辞改新口径——打包须知第 5 条、字段表 `integrity.signature` 行、翻车表「带 signature 的包」行、检查清单第 5 条、repo-vs-moyi 对照第 5 行；统一写「只认包不认签名，带签名的包正常安装；本技能产出可不写，外部包带了照常装」。
3. **检查器**（`~/workspace/custom-skills/iduanju_plugin_build/tools/check_idj_plugin.py`）：signature 不再判 FAIL——`check()` 里的拒装 FAIL 改为一条提示级 WARN；`problems()` 里「签名算法只支持 ed25519」整条删除。实测：造一个带 `integrity.signature`（ed25519）的合法包跑检查器，结果 **PASS（exit 0），仅 1 条 WARN 提示**。

## 三、三列网格落法

落点：小程序「插件」tab（`lib/miniapp/idj_plugin_tab.dart`）。两个列表都从单列长条改三列网格、纵向滚动（网格嵌在原整页滚动里，shrinkWrap + 不自滚，页面还是一条上下滑到底）：

- **已安装网格**（key `idj-installed-grid`）：GridView 3 列，卡片高宽比 0.70。卡片 = 首字头像（无图标资源时用名字首字占位，带 🔞 的名字首字即 🔞，不空白）+ 名字（最多 2 行、放不下省略号）+ 版本号 + 状态小标签（已启用/已停用置灰/已损坏标红）。管理动作收进卡片右上角「⋯」小菜单：详情、启用/停用、检查更新、重新安装、卸载（菜单项沿用原 key，损坏插件照旧只给重新安装/卸载）。原有的已安装区折叠（点标题收起、状态持久化）保持。
- **市场（订阅）网格**（key `idj-sub-grid-<订阅地址>`）：订阅卡展开后插件改 3 列网格，卡片高宽比 0.58。卡片 = 头像 + 名字 + 版本 + 整宽按钮，三态：安装 / 更新 / 已安装（置灰），安装中显示「安装中…」。简介不进卡片（卡面放不下，详情仍可看）。CMS 行保持原样。
- 原有能力保持：订阅刷新/删除/添加、内置仓库徽标与默认展开、更新检查、空态文案（「还没有安装任何插件」「这个订阅里没有插件」）都在；搜索本来就没有（tab 内无搜索框），未新增。
- **范围裁定**：网格只落 idj 插件 tab——简报的卡片规格（已装状态、启用开关、升级多申请域名）全是这条线的。jar/py 的插件市场页（plugin_market_screen.dart）安装本来就没有确认弹窗（只有卸载确认，不在范围），其列表本批未改。

小屏适配：360 宽实测无溢出（卡片比例经两轮实测收敛：订阅卡 0.72→0.58、已安装卡 0.75→0.70，初版在测试字体下溢出 16px/7.3px 已修）。

## 四、预览图（演示数据、图上带标注横幅）

- 已安装网格：[preview/installed_grid.png](sandbox://workspace/moyi_plugin_ui_20261125/preview/installed_grid.png)（390 宽：5 张卡三列排布，启用/停用置灰/损坏标红三态齐）
- 市场网格：[preview/market_grid.png](sandbox://workspace/moyi_plugin_ui_20261125/preview/market_grid.png)（订阅展开 6 张卡：已安装/更新/安装三态按钮齐）
- 生成方式：`test/idj_plugin_grid_preview_test.dart` 真实组件渲染截图（单跑、PNG 落地为准；测试字体缺 emoji 与部分符号，图中 🔞 与「⋯」显示为方框/空白，是测试字体问题，真机正常）。
- 旧预览 `test/idj_preview_test.dart` 里两条确认 sheet 的图（install_confirm_sheet、local_import_flow）已随 sheet 删除一并删测试并在文件头注明；其余预览逐条单跑复验：site_picker_dialog、miniapp_plugin_tab、idj_builtin_repo 三条已重新出图且断言过、无溢出；library_with_idj 一条不碰本批改动面（文件编译已随同文件其他用例验证）。

## 五、测试结果

全部用 `~/workspace/tools/flutter-3.50.0`、`--no-pub`、TMPDIR 指 workspace 大盘，串行跑：

| 测试文件 | 结果 |
|---|---|
| test/idj_plugin_store_test.dart | 49/49 全过（含新增「只认包不认签名」组 3 条：ed25519 签名包正常装、alg 写 rsa 也装、带签名但哈希错仍按哈希拒装；原「权限扩大未确认时安装被拒」改为直接装成） |
| test/idj_plugin_tab_test.dart | 13/13 全过（含新增「免确认直装」组 2 条：点安装直接装完、无 BottomSheet 出现、结果提示带分区文案；升级多 2 个域名直接装成、提示带「新版本多申请了 2 个域名」；新增「三列网格排布」1 条：360×740 下两网格 crossAxisCount 均为 3、无溢出异常；三态/启停/卸载旧用例改走卡片菜单后全过） |
| test/idj_contract_test.dart + test/site_picker_plugin_uninstall_test.dart | 13/13 全过 |
| test/idj_preview_test.dart（改后） | 逐条单跑：site picker / plugin tab / builtin repo 三条出图且断言过；library 一条不碰本批改动面、文件编译已随同文件验证 |
| test/idj_plugin_grid_preview_test.dart | 两条单跑，PNG 落地且肉眼核验排布正确（该类测试收尾挂起是已知行为，按 PNG 落地判过） |

analyze：改动的 6 个文件（2 lib + 4 test）**0 错 0 警告**；22 条 info 全为既有类别（use_build_context_synchronously、material 导入弃用提示），与基线对照无新增（两 lib 文件基线 20 条 info、改后 19 条）。

## 六、已撤事项

「插件索引冷启动兜底」（assets 快照 + 订阅落盘缓存）是父侧听岔后追加、随后撤回的一件：**撤回时尚未动手写任何兜底代码**（只做了现状调研与一次取线上 index 的尝试，出口超时未取到），`loadSubscriptions` 保持现状，无代码需要回退。本节如实记录。

## 七、手机终验点（装上含本批的版本后）

1. 插件市场点任一插件「安装」：不弹任何确认、直接装完，只出一条结果提示；本地「从文件安装」「粘贴插件」同样直装。
2. 装一个有新版且新版多申请域名的插件：直接更新成功，结果提示里带一句域名变化。
3. 拿一个带 integrity.signature 的包安装：正常装上，不报签名错。
4. 已安装与市场列表都是三列网格、上下滑顺畅；长名字卡片省略号不溢出；已停用卡置灰、损坏卡有红色标记；卡片右上角菜单里详情/启停/检查更新/重装/卸载都可用。
5. 硬拒仍在：域名写了带协议头/端口的包、哈希对不上的包，仍装不上并给出原因。


---

# 续批：idj 插件合同扩 DRM + 选文件同款毛病三处修齐 —— 交卷报告

- 工作区：同上（分支 `plugin-list-ui`），新增两个本地提交：`5d6ab9a`（任务一）、`02cc4bd`（任务二）。未推仓、未构建、未上手机。
- 重要前提订正：简报说 d0c62be 已给 PlaybackPlan 加 drm 字段——那是在 `live-page-fix` 分支上，**本工作树基线（main 246378a）里没有**（PlaybackPlan 无 drm、无 hasDrm、播放器路由不认 drm）。已核对：本树 models.dart 等 7 个相关文件与 d0c62be 的父版本 md5 逐一一致，故把 d0c62be 的点播侧 Dart 链 + EXO 原生侧（TvboxPlayerPlugin.kt 的 drm 参数、build.gradle 的 media3-exoplayer-dash 模块）**逐字原样套入本树**（补丁 `git apply` 一次过），内容与 live-page-fix 完全相同，收口合并两分支时同内容不冲突；没有另起一套。

## 一、任务一：idj 插件合同扩 DRM 字段（提交 5d6ab9a）

- **宿主侧**：`IdjContract.planFromResult` 新增 drm 解析——play 结果级 `drm` 或命中流自带的 `drm`（流级优先），形态 `{key, type, header}`（header 认 Map 或 JSON 字符串，与 FongMi 形态对齐），经 `PlaybackDrm.fromJson` 解析进 `PlaybackPlan.drm`。key/type 缺一视为无 DRM、不抛错不硬造；不带 drm 时计划与旧行为完全一致（drm=null、hasDrm=false）。core_bridge 里 idj 的 play/playback 两处调用都走 `planFromResult` 这一条，无第二入口。
- **直达 EXO**：复用点播侧现成链——`PlaybackPlan.hasDrm` 为真时 player_screen 的 `useNativeForPlan` 与西瓜页强制走 EXO（tvbox 核），tvbox_player_bridge/pane 把 drm 透传给原生侧 MediaItem 的 DrmConfiguration / ClearKey 本地会话；decryptionKey 强制 mpv 的既有口径不变、互斥时后者优先。以上均与 d0c62be 逐字一致。
- **技能同步**（`~/workspace/custom-skills/iduanju_plugin_build/`）：SKILL.md 的 play 合同行加 `drm?`、新增 DRM 合同条（位置/字段/type 合法值/key 两种形态/header 写法/缺字段静默忽略的后果）、检查清单第 4 条加 drm 样本核对；`references/repo-vs-moyi.md` 第 12 行改口径（drm 从「全部忽略」里摘出、标注已消费）。
- **检查器**（`tools/check_idj_plugin.py`）：新增 `drm_problems()` 静态校验——脚本里出现 drm 对象字面量时，缺 key 或 key 为空串 → FAIL、缺 type → FAIL、type 字面量不在 {com.widevine.alpha, org.w3.clearkey, com.microsoft.playready, widevine, clearkey, playready} → FAIL；key/type 是动态值 → WARN 人工核；drm 非字面量（动态拼装）→ WARN；不出现 drm 不报错。
- **检查器三测**（实测输出）：
  1. 现成合法包 `~/workspace/plugin_fix_20261125/huanyingai/huanyingai.idjplugin`（幻影AI 1.0.0）：**PASS，exit 0**（改检查器后仍过）。
  2. 合法 drm 样本（基于幻影AI 包在脚本里加 Widevine drm 字面量、许可证域名补进 permissions、重算 integrity）：**PASS，exit 0**。
  3. 坏 drm 样本（drm 只有 `type: 'aes-128'`、无 key）：**FAIL，exit 1**，两条 drm 原因齐出（缺 key + type 不合法）。
  - 附注：`~/workspace/user/files/` 下几个用户侧旧包（潮流/爱果/橙果/2048）跑检查器有「能力函数找不到」的 FAIL，是检查器函数识别的既有问题（改 drm 前就存在，与本批无关），故三测用技能自家打包的幻影AI 包做基线。
- **测试**：`test/idj_contract_test.dart` 新增 4 条——结果级 drm → drm 字段正确 + hasDrm 为真（钉死强制 EXO 的判定旗）、流级优先于结果级 + header JSON 字符串形态、不带 drm 行为不变、残缺 drm（缺 key/缺 type）视为无 DRM。合同测试 16/16 全过。

## 二、任务二：选文件同款毛病三处修齐（提交 02cc4bd）

先去主检出看了 9395cf3 的改法（选择器调用包进 try/catch、取消静默、打不开立刻弹错），三处按同款修齐：

| 处 | 原毛病 | 改法 |
|---|---|---|
| `lib/import_center_screen.dart` 的 `_importFromFile` | `FilePicker.pickFile` 在 try 外，抛错漏出无提示 | pickFile 进 try（取消=null 静默返回、抛错 SnackBar 弹「打开文件选择器失败：…」）；选完后的读取/分流抽成 `_importPickedFile` 整段进 try，漏出异常统一弹「导入所选文件失败：…」 |
| `lib/plugin_market_screen.dart` 的 `_pickAndInstallFile` | pickFile 与 `readAsBytes` 都在 try 外 | 两步各自进 try：取消静默、选择器失败 toast「打开文件选择器失败：…」、读不出 toast「无法读取所选文件：…」 |
| `lib/miniapp/idj_plugin_tab.dart` 的 `IdjPluginActions.installFromFile` | `FilePicker.pickFiles` 在 try 外 | pickFiles 进 try：取消（空列表）静默回 false、抛错弹错误框「打开文件选择器失败：…」并回 false |

- **回归测试**：新增 `test/file_picker_guard_test.dart` 6 条——装假 `FilePickerPlatform`（抛错 / 回空模拟取消），三处各两条：抛错时不崩且有明确提示（idj 是错误弹窗、另两处是 SnackBar）、取消时静默无提示。**有效性验证**：stash 掉三处修复后恰好 3 条抛错用例失败（取消用例本就过），恢复修复后 6/6 全过。

## 三、测试与 analyze 汇总

全部用 `~/workspace/tools/flutter-3.50.0`、`--no-pub`、TMPDIR 指本工作树下（完事已清），串行跑：

| 测试 | 结果 |
|---|---|
| test/idj_contract_test.dart | 16/16 全过（新增 DRM 4 条） |
| test/file_picker_guard_test.dart | 6/6 全过（新增） |
| test/idj_plugin_store_test.dart + idj_plugin_tab_test.dart + site_picker_plugin_uninstall_test.dart + import_center_test.dart + import_center_compact_test.dart（与合同测试合跑两轮） | 合计 101 + 23 全过，0 新增失败 |

analyze：本批全部改动文件（9 个 lib + 2 个 test）**0 错 0 警告**；info 与基线同类（use_build_context_synchronously 等既有类别），新测试文件只带全树通有的 material 弃用 info 一条，无新增类别。

## 四、手机终验点（装上含本批的版本后）

1. 拿一个返回带 drm 的插件站播 DRM 流：应强制走 EXO 核并能出画面（Widevine/ClearKey 各验一条更稳）。
2. 不带 drm 的插件站播放与旧版无差别。
3. 导入中心 / 插件市场 / 插件 tab 三处「从文件安装」：在选择器里点取消——什么都不发生、不闪退；选择器打不开时（可断开存储权限模拟）——弹明确提示、不闪退。
