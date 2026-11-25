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
