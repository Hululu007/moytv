# 演员库无权访问修复 + 右上角调整报告（第一阶段）

- 工作树：`~/workspace/moyi_javdb_gate_topbar_20261126`，分支 `javdb-gate-topbar`
- 基线：`b0e196d`（已含 JavDB 演员 type=0 与搜索 q 参数修复）
- 修法依据：`~/workspace/moyi_noperm_diag_20261126/REPORT.md`（诊断定版）
- 本批只本地提交，不推仓、不构建。

## 一、任务一：6 个未登记源 id 的门禁修复

### 根因（诊断实证，复核无误）

演员库整批新接的 6 个源 id——`javdb`、`av123`、`ph`、`av01`、`jable`、`pan115`——从没在任何登记表登记过。`LocalStore.allowsSource` 先过 `SourceSite.isAvailable`（只认内置 / 自定义 / 导入 / 网盘四张表），对这 6 个 id 恒假，`DetailScreen` 进页校验不过就整页只画「当前用户无权访问，请返回剧库后重新选择。」面板。后果：JavDB/123AV/PH/AV01/Jable 源页签点开任何作品 100% 落面板；本地库作品点播竞速赢家是 115 线（pan115）或上述在线线时也翻面板。

### 修法落点（按诊断定版，未放宽 allowsSource 本身）

只改 `lib/models.dart` 一处：

- 在 `cloudDriveSites` 之后新增演员库专用登记表 `SourceSite.actressOnlySites`，6 条：`javdb→JavDB`、`av123→123AV`、`ph→PH`、`av01→AV01`、`jable→Jable`、`pan115→115`，全 `section: sectionVideo`。注释写明：`pan115`（演员库 115 离线线）与网盘已登记的 `cloud:pan115` 是两个不同的 id，互不影响。
- `isAvailable` / `isKnown` 各加一条 `|| actressOnlySites.containsKey(id)`。
- `byId` 在 `importedSites` 查找之后加一层 `actressOnlySites` 查找——此前这 6 个 id 会回落到红果站显示名，现在返回各自正确名字，不再回落红果。

没有动的东西：

- `allowsSource` 本身一行未改——未注册源拦截的既有安全口径保留，随机未注册 id 仍然被拦（有回归测试守着）。
- 这 6 个 id 不进 `LocalStore.sources` 选站列表、不出现在片库站点里（`sources` 的拼装逻辑未动；有回归测试断言 6 个 id 不在选站列表里）。
- 空壳版 `values=[hongguo]` 时这 6 个 id 同样可用——演员库在两版都保留，属预期行为。

影响面复核：`isAvailable` 的其它调用点（`core_bridge` 的 `_authorize`、`profiles_screen` 的标签过滤）对这 6 个 id 由「不认」变「认」，均为放行演员库自有源的正确方向，无收紧副作用。

### 回归测试（按正式 App 真实状态跑，不做测试侧登记）

新增 `test/actress_source_gate_test.dart`，全程不调用任何登记 API，用的就是正式 App 的静态登记表与真实 `LocalStore` / `DetailScreen`：

- 单元层：6 个 id 的 `isAvailable` / `isKnown` / `byId`（名字对位、不回落红果）；`allowsSource` 对 6 个 id 放行、对随机未注册 id 仍拦截；6 个 id 不进 `LocalStore.sources` 选站列表；`cloud:pan115` 的可用性与名字不受牵连。
- 组件层：6 个 id 各造一部 `Drama` 进 `DetailScreen`，断言出正常详情内容、不落无权访问面板；随机未注册 id 仍落面板。
- 115 线赢家：按 `actress_detail_page` 的真实造法（direct 直链集）造 `pan115` 的 `DramaDetail` 进详情页，注入播放器替身后点海报播放键，断言 `PlayerScreen` 出现——即 115 线赢家能正常起播。

结果：与改版后的 `actress_entry_restore_test` 同跑 **+13 全过**。

## 二、任务二：演员库右上角调整（用户 23:00 令）

### 改前现状（如实记录）

演员库页 `lib/actress/actress_nvku_page.dart` 顶栏改前有三处入口：

1. 标题行（独立模式 `showTitle=true` 时）：「女优库.db」标题 + 在线徽标 + 刷新钮 + 一个「管理」文字钮（key `nvku-manage-open`），点开底部管理弹层。
2. 搜索行右端：「影片库」药丸钮（key `nvku-open-film-library`），跳 `FilmLibraryPage`（影片库页）。
3. 管理弹层三行：「数据库管理」（进数据库管理整页）、「影片库」（同上跳转）、「重新加载数据库」。

### 改后

口径：右上角只留设置齿轮，其余入口删除；点齿轮仍开原管理弹层，数据库管理整页内容一项不少。

- 删除 `_openFilmLibrary()` 方法与弹层里的「影片库」行；管理弹层只剩「数据库管理」+「重新加载数据库」两行。
- 标题行的「管理」文字钮删除。
- 搜索行右端的「影片库」药丸钮换成设置齿轮图标钮：key 沿用 `nvku-manage-open`、提示文字「设置」、图标 `Icons.settings_outlined`、点开仍是同一个管理弹层。放搜索行而不是标题行，是为了独立模式与内嵌模式（`showTitle=false`、标题行不画）都可见、都只有一个入口。
- 没动的：`_loadFilmLibrary` 数据加载、`actress_film_library.dart` 与 `FilmLibraryService` 本体（影片库数据服务还有其它使用者，本令只删演员库页面的入口）。

### 同步更新的既有测试

`test/actress_entry_restore_test.dart`：原断言「影片库入口在位」是旧口径，已按 23:00 新令改断言为——`nvku-open-film-library` 不存在、页面无「影片库」文字、`nvku-manage-open`（齿轮）存在；头部注释同步改述。另顺手删了该文件一条基线就存在的未用导入（`models.dart`）。

### 预览图（工作树 preview/）

- `preview/actress_topbar_gear_home.png`：主页顶栏——标题行只剩标题+徽标+刷新钮；搜索行右端是齿轮位（预览环境图标字体不加载、图标显示为方框，是既有预览通病，真机上是齿轮图标）；源切换条 女优库/JavDB/123AV/PH；无「影片库」药丸。
- `preview/actress_topbar_gear_sheet.png`：点齿轮打开的管理弹层——只剩两行（数据库管理 / 重新加载数据库），无「影片库」行。弹层行标题在预览图里是方框字（同上字体通病），行数与结构可辨；文字内容由同测试内的断言逐字验过（数据库管理、重新加载数据库在位，影片库不在）。

两张图各由一个单测文件产出（`test/actress_topbar_gear_preview_test.dart`、`test/actress_topbar_sheet_preview_test.dart`），一测一图：本机预览渲染在拍完图后收尾挂起是既有通病，靠 PNG 落盘判成败。

## 三、测试结果（与 b0e196d 基线对照，0 新增失败）

基线（未改代码的 b0e196d，共 9 条既有失败）：

| 批 | 结果 | 失败 |
|---|---|---|
| A（JavDB/在线/起播 9 文件） | +108 −2 | actress_play_fallback「第一档本地 db 活的」、actress_play_missav_first「MissAV 提前探」 |
| B（详情簇 11 文件+预览 1） | +43 −2 | app_build「DSD only in all-source build」、detail_cast_row 预览 10 分钟超时 |
| C1（演员库 19 文件） | +206 −2 | actress_code_search_group ×2 |
| C2（演员库 17 文件） | +180 −3 | actress_test 界面 ×3 |
| actress_entry_restore（单跑） | +2 全过 | — |

改后：

| 批 | 结果 | 对照 |
|---|---|---|
| A | +108 −2 | 失败集与基线逐条相同 |
| B（不含预览文件） | +42 −1 | 只剩基线 DSD 一条；预览文件单独跑见下 |
| C1（20 文件，含改版 entry_restore） | +206 −2 | 失败集与基线逐条相同 |
| C2 | +180 −3 | 失败集与基线逐条相同 |
| 新门禁测试 + entry_restore | +13 全过 | 新增回归全绿 |

静态检查：`lib/models.dart` + `lib/actress/actress_nvku_page.dart` analyze 0 错 0 警（仅 2 条既有 info，非本次改动区）；新增/改动的 4 个测试文件 analyze 0 错 0 警（仅全仓通有的 material 导入 deprecated info）。

既有预览文件的本机表现（如实记录）：`actress_online_preview_test`、`preview_json_import_test`、`actress_works_cards_preview_test` 在本机本次会话里均为「第一张图落盘后收尾挂起、超时杀掉」——基线时 `detail_cast_row_test` 同样是 10 分钟超时，属本机预览渲染环境的既有通病，非本次改动引入。其中 `actress_online_preview_test` 重新产出的主页图已核对：新顶栏（齿轮位、无影片库药丸）渲染正确。门禁行为本身由非预览的新回归测试全覆盖，不靠预览文件下结论。

## 四、未验项（照实）

- JavDB / 123AV / PH / AV01 / Jable / 115 各源的真实拉取与真播：本机出口连不上相关站点（JavDB 的 jdforrepam.com 全天不通），本批只验到「进页门禁放行 + 详情出画 + 115 线起播链路（替身）」，真拉真播待手机验。
- 齿轮图标在真机的实际样子：预览环境图标字体不加载，只能证明位置与点击行为，图标本体待手机验。
- 演员作品页 `api/v1/actors/{id}` 无参照客户端实证一事与本批无关，仍按原状待手机实测。
