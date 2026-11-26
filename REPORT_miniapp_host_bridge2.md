# 小程序宿主数据桥二期：JS 与插件站接线 — 交卷报告

- 批次：小程序宿主数据桥二期（用户 2026-11-26 17:31 令「全部修复更新补上」；一期 b773e41 如实标注的残留，本批补齐；工作树经用户 17:38 主聊亲口同意放行）
- 基线：`b773e41`（一期提交），分支 `miniapp-host-bridge2`，工作树 `~/workspace/moyi_miniapp_host_bridge2_20261126`
- 状态：**本地提交，未推仓、未构建**
- 改动文件：`lib/core_bridge.dart`、`lib/miniapp/mini_app_sources.dart`、`lib/miniapp/mini_app_home_page.dart`、`lib/miniapp/mini_app_host_page.dart`、`lib/home_screen.dart`、`lib/hongguo_drama_home.dart`、`test/mini_app_sources_test.dart`

## 一、一期残留是什么

一期把 `HostMiniAppSourceProvider` 汇合到内置 + jar 桥已注册站 + 注册表 py/jsonlist 站，但 **JS 蜘蛛站与 idj 插件站没接**：其取数链是 `NativeRepository` 的 Go 核调用（`_jsCall`/`_idjCall`），`_authorize` 用户权限校验与 idj 插件看门狗都绑在那条链内部，一期两条静态链（JarBridge/PyBridge）够不着，当时按不冒充可达处理（不进清单、解析报 SITE_NOT_FOUND）。空壳版的站主要靠插件市场装回、全站转插件产的正是 idj 包——不补这块，空壳版小程序对市场装回的主力站仍拿不到数据。

## 二、接线路径（本批实现）

### 1. NativeRepository 新增两个公开入口（lib/core_bridge.dart）

不新开任何调用通道，只把主界面自己在用的私有链包一层公开签名：

- **`spiderRawCall(source, operation, {...})`**：与主界面 categories/catalog/detail 对 js/idj 站走的是同一条 `_jsCall`/`_idjCall`。operation 两边同名（home/category/search/detail/player），参数按各自口径转交——js 走 `_jsCall` 的命名参数；idj 在内部组装 args（category→`{id, page}`、search→`{keyword, page}`、detail→`{id}`、player→`{flag, playId}`，与主界面各调用点逐字一致）。返回原始结果，形状翻译归调用方。
- **`idjPlaybackPlan(source, {flag, playId})`**：与 resolvePlayback 的 idj 分支同一口径——`_idjManifest` 的 media 白名单 + `_idjCall('player')` + `IdjContract.planFromResult` 翻译，直接回 `PlaybackPlan`（idj 取流结果是 streams 形状，不能走原始结果通道）。

### 2. 权限校验与看门狗的复用方式（硬约束落实）

- `_authorize(source)` 就在 `_jsCall`/`_idjCall` 内部第一行，本批两个新入口都经它们调用，**校验一次不少**；idj 的看门狗计数（成功清零、失败 +1、连续 3 次自动停用并注销注册表）也在 `_idjCall` 内部，同样原样生效。提供者侧没有出现任何绕过这两处的直调 Go 核代码。
- **实例来源与主界面同一**：`access`（LocalStore）全 App 只在 `main.dart` 给启动装配的那个 `NativeRepository` 实例赋过值（`repository.access = store`），自建新实例会让 `_authorize` 在 `access == null` 时直接放行——所以本批不自建实例，而是把启动实例一路穿线注入：`_AppBootstrapState.repository` → HomeScreen / HongguoDramaHome（两页本就持有 `widget.repository`）→ `MiniAppHomePage`（新增可选字段）→ `MiniAppHostPage`（新增可选字段）→ 提供者构造参数 `repository`（宿主页处做 `is NativeRepository` 判断，不是则按无链处理）。穿线全是可选参数，未传的入口（测试、其它构造点）行为与一期一致。

### 3. 提供者三处（lib/miniapp/mini_app_sources.dart），小程序侧接口签名一字未动

- **listSites()**：在内置段、汇合段之后追加第三段「原生段」——注册表里 importType 为 `js` 的站，type 记 `js`（JS 蜘蛛）或 `idj`（`idj_` 前缀的插件站），全表仍按站 id 去重先到先留，前两段构成与顺序一字不变。available 口径：idj 记 true（看门狗停用会把站注销出注册表，在场即与看门狗状态一致，与汇合段 jar 同口径）；JS 按脚本文件已落盘或远程地址已登记记（与 py 口径一致，远程站首次取数懒加载）。
  - **能力门控**：原生段仅在提供者注入了仓库实例（或测试替身 nativeCall）时出现。没链时列了也取不到数，不冒充可达——一期默认构造（无注入）下 js/idj 不进清单、解析报 SITE_NOT_FOUND 的行为与测试断言保持不变。
- **_resolveSite()**：注册表 js 站在有链时认作原生段（按 `idj_` 前缀细分），其余口径不变。
- **取数归一**（60 秒超时、并发 3 上限、错误码不变，仍走 `_guarded`）：
  - **JS 蜘蛛**：结果是 TVBox 形状，与 py 同口径归一——home 过 `withClassesAlias`、category/search 原样、detail 过 `normalizeDetailResult`、player 过 `normalizePlayResult`。筛选 ext 与主界面 catalog 的 js 分支一样不下传。
  - **idj 插件**：结果是 idj1 形状，在提供者内翻译成契约形状——home 的 `categories` 转 `class`（前置「全部」，无 id 行跳过、name 空以 id 顶上，与 `IdjContract.categoriesFromHome` 同口径）、`items` 转 vod 行（remarks 为空才以 duration 顶上，与 IdjContract 条目翻译同口径）、detail 的 `lines/episodes` 拼成 vod 的 play_from/play_url 再过 `normalizeDetailResult` 切数组（线路名进 flag、分集键是 episodes[].id、无有效分集的线路不进结果）、search/category 的 items 同列表翻译并带 `hasMore`。category 空 tid 与宿主 catalog 同口径：不调 `category({id:''})`（部分插件抛 E_ARGS），改调 home 取首页内容且只取第一页。
  - **idj 取流**：走 `idjPlaybackPlan` 拿 `PlaybackPlan` 后映射为 `{url, header, parse}`；计划带有效 DRM 时如实报 SOURCE_FAILED（小程序播放链表达不了 DRM，主界面靠 DRM 信息强制走 EXO，不许只回裸地址冒充可播）；字幕等契约外字段不编。

### 4. proxyFetch：如实维持不可用

JS/idj 站在宿主主链里没有 localProxy 式取图路径（idj 封面是插件直给的 https 地址、JS 站封面同样是页面直链，都不经代理），本批不编代理通道：proxyFetch 对这两类站维持 SITE_NOT_FOUND，提供者注释已写明。小程序里这两类站的封面走结果里的直链原样加载（提供者对原生段不做 proxy:// 改写，与 jar 段同口径）。

## 三、两版清单构成变化

| | 带站点版 | 空壳版 |
|---|---|---|
| 一期后 | 内置段 + 汇合段（导入/配置/市场装回的 py/jar/jsonlist 站）；JS/idj 站不可见 | 内置段为空；汇合段同左；JS/idj 站不可见 |
| 二期后 | 前两段**不缩水、不变序**；其后追加原生段：导入的 JS 蜘蛛站、市场装回的 idj 插件站 | 内置段仍为空；汇合段之后追加原生段——**市场装回的 idj 插件站（空壳版主力站）进入清单并可取数**，导入的 JS 站同列 |

## 四、验证

- 基线留底（本工作树、改动前）：`mini_app_sources_test` + `mini_app_server_test` + `mini_app_test` 共 **59/59 全过**。
- 改后同三件套：**64/64 全过**（新增 5 条：原生段清单与顺序、JS 五操作路由与参数、idj 四类形状翻译 + 空 tid 走 home 口径、idj 取流走计划映射 + DRM 如实失败、原生链报错归一 SOURCE_FAILED + proxyFetch 维持关闭）。
- 相邻文件：`mini_app_home_warm_start_test`、`mini_app_host_inline_player_test` 改后全过；`mini_app_builtin_test`「内置包资产完整性（磁盘实测）」1 条与 `bottom_tab_nav_test`「短剧首页 requestedTab 直达女优库页」1 条失败——**stash 后在干净基线 b773e41 同文件复跑同挂**，均为基线既有失败（前者一期报告已记录为工作树资产实测环境问题），**0 新增失败**成立。
- analyze（改动 7 文件）：**0 错 0 警**；info 级 16 条均为基线原有风格（core_bridge 的 annotate_overrides、material 弃用提示、提供者构造函数的 prefer_initializing_formals——其中 3 条是一期原样、本批新增 3 条同款式跟随文件既有写法）。
- 测试按仓库惯例：`flutter test --no-pub`、TMPDIR 指 workspace 大盘、同树单 flutter 串行（新工作树首次跑前用 `flutter pub get --offline` 备齐包配置）。

## 五、手机终验项

1. **空壳版（本批主验）**：从插件市场装一个 idj 插件站后，打开一个靠宿主站取数的小程序（source.* 清单类），清单里应出现该插件站（排在内置/汇合段之后），且能打开分类、详情、取流出画。
2. **空壳版**：导入一个 JS 蜘蛛站后，同上验清单出现该站、分类/详情/播放能走通。
3. **带站点版回归**：小程序宿主站清单里内置段与汇合段的构成、顺序与二期前一致，原生段只在其后追加；内置站、py/jar 站取数照常。
4. **权限与看门狗回归**：被看门狗自动停用的插件站应从小程序清单里消失（随注册表注销）；无权限的站经小程序取数应与主界面一样被拒（SOURCE_FAILED），不能绕过去。
5. 已知边界（预期行为、非故障）：JS/idj 站的封面不走 /pyproxy 代理（直链加载）；idj 站返回 DRM 加密流时小程序里会报取流失败（主界面播放不受影响）。
