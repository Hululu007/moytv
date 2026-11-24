# 魔蚁 iDuanJu 插件系统 · 设计文档

> 状态：设计稿（只设计，不含实现代码）。工作树 `~/workspace/moyi_idjplugin_20261124`（分支 `idjplugin-adapt`，基线 main `d94a7fb`）。实施计划见 `~/workspace/idjplugin_adapt_20261124/adapt_plan.md`（路线图 + 接线点全表）；逆向结论见 `~/workspace/idjplugin_adapt_20261124/RE_REPORT.md`（下称 RE 报告）；P0 探针结论见 `~/workspace/idjplugin_adapt_20261124/probe_report.md`（下称探针报告）。
>
> 方向（用户 2026-11-24 11:05 亲口令）：把 iDuanJu 整套插件安装方法移植过来，魔蚁原生支持安装 `.idjplugin` 插件。**不是**把 4 个插件逐个翻译成站；原先“逐个翻译成站”的路线作废。
>
> 落点（用户 2026-11-24 11:08 亲口定）：安装入口在**小程序里的市场**，装好的插件落到**片库里当站用**（进片库的站点列表，片库里能看到它、能切站、能进分类/详情/播放）。成人插件仍走午夜门禁、短剧站仍按短剧区分区。
>
> 分类（用户 2026-11-24 11:09 截图 + 亲口令）：两点别混成一件事——A. **站点切换弹窗改成分组样式**（组标题 + 数量 + 三列网格 + 选中高亮，分组按站分区）；B. **站内视频分类按插件自己的来**（`home()` 返回的 `categories`，`category({id, page})` 翻页，分类名不写死、不改名）。
>
> 回复语言：中文（用户看不懂英文）。本文所有文件路径 + 函数名均已在工作树实地核对；凡写“待定”的，一律不等实现工人擅自定。

## 目录

- [0. 一句话设计](#0-一句话设计)
- [1. 解析与安装](#1-解析与安装)
- [2. Go 核宿主](#2-go-核宿主)
- [3. 插件变站点桥接（片库）](#3-插件变站点桥接片库)
- [4. 市场 UI（小程序内）](#4-市场-ui小程序内)
- [5. 站点切换弹窗改成分组样式](#5-站点切换弹窗改成分组样式)
- [6. 站内视频分类](#6-站内视频分类)
- [7. GPL-3.0 干净复写规则](#7-gpl-30-干净复写规则)
- [8. 实施顺序、测试计划与预览图计划](#8-实施顺序测试计划与预览图计划)
- [9. 待父级/用户定的事项清单](#9-待父级用户定的事项清单)
- [附录：接线点速查](#附录接线点速查)

---

## 0. 一句话设计

Dart 侧新增一套插件安装器（解析 `.idjplugin` → manifest 校验 → integrity 核对 → Go probe 试加载 → 写盘 + 索引 → 动态注册进片库），Go 核新增 `app_js_idj.go`（goja 沙箱 + 冻结的 `host.*`，先保三入口、再补齐其余），桥接层把插件的 `home/category/search/detail/play` 翻译成魔蚁站点体系（新文件 `lib/idj_contract.dart` + `core_bridge.dart` 五处分流），市场落在小程序内的「插件」标签页，切换弹窗改按内容分组。**树里不内置任何一个插件站**：4 个插件（橙果短剧、潮流AV、爱果短剧、2048AI，作者 @yydsys）全部走安装流程装进来跑。

### 0.1 角色分工（哪边管什么）

| 层 | 管什么 | 不管什么 |
|---|---|---|
| Dart 侧（`lib/idj_plugin_store.dart`，新建） | 解析、校验、完整性核对、订阅、写盘、索引、动态注册/注销/启用/停用、启动恢复、安装 UI 的数据 | 不跑 JS、不直接发插件的站方请求（联网只做安装器自己的下载：取包、取订阅、取 update manifest） |
| Go 核（`native/core/app_js_idj.go`，新建） | 跑插件：prelude、host 桥、HTTP、存储/Cookie 持久化、域名白名单、限额、超时 | 不碰 Dart 的站点登记、不碰播放器 |
| 桥接（`lib/idj_contract.dart`，新建 + `core_bridge.dart` 五处分流） | 形状翻译：插件返回 ⇄ 魔蚁 `CatalogCategory` / `CatalogPage` / `DramaDetail` / `PlaybackPlan` | 不改 `PyContract`（现有 JS 蜘蛛继续走 TVBox 形状） |
| 市场 UI（`lib/miniapp/mini_app_home_page.dart` 加 tab） | 安装入口、已安装管理、订阅、更新检查 | 不直接写盘、不直接调 Go（经 `IdjPluginStore`） |
| 切换弹窗（`lib/source_picker_sheet.dart` + `lib/home_screen.dart`） | 按内容分组展示站点、切站 | 不管站内分类（那是 §6 的事） |

### 0.2 不做的事（v1 明确不做）

- 不内置任何插件站（不建 `builtin_js_sites.dart`，不往 `assets/` 里放 `main.js` / `.idjplugin`，不改 `pubspec.yaml` 加 assets）。
- 不改 `PyContract`、不改现有 JS 蜘蛛（`app_js_spider.go` / `app_js_spider_compat.go` 只复用、不修）。
- 不做 `host.image.stripes/aes`（iDuanJu Android 也没有；4 个插件没用到）。
- 不做 `proxy` 字段的分片处理（4 个插件的 `play` 返回里没有；位置已留好，见 §3.5）。
- 不做内容过滤（iDuanJu 有 `ContentFilter`，魔蚁没有；是否补由用户定，见 §9）。
- 不做定时自动刷新订阅 / 自动检查更新（只手动触发，与 iDuanJu 一致）。
- 不做插件设置 UI（4 个插件 `settings` 全空；`host.settings` v1 返回 `{}`）。
- 不做 secret 设置（iDuanJu Android 侧替换为空；魔蚁 v1 同样置空）。

---

## 1. 解析与安装

### 1.1 落点：安装流程放 Dart 侧，Go 侧只负责 probe

安装流程放 **Dart 侧**。理由：解析 JSON、读文件、写盘、记索引、注册站点全是 Dart 侧已有能力（`MiniAppStore`、`ImportFileStore`、`PluginManager`、`LocalStore` 都是 Dart 侧）；Go 侧只在安装的 probe 一步被调用一次（跑一次 `init`，验证插件能加载），以及运行期每次调用插件。Go 侧不参与下载、校验与写盘。

新文件 **`lib/idj_plugin_store.dart`**（一个文件装下三样东西，互相引用多、拆开反而碎）：

| 类 | 职责 |
|---|---|
| `IdjPluginManifest`（纯数据类 + `problems()` 校验） | manifest 模型与校验（§1.3） |
| `IdjPluginStore` | 解析、下载、校验、完整性核对、probe、写盘、索引读写、订阅拉取、更新检查 |
| `IdjPluginRegistry` | 动态注册/注销/启用/停用、启动恢复（`restoreAll()`）、站 key 生成 |

### 1.2 插件存哪、索引存哪（已查实魔蚁现有机制再定）

查实的现有机制：

- 偏好（SharedPreferences）：`PluginManager.uninstalledPrefsKey = 'moyi_plugin_uninstalled'`、`marketUrlPrefsKey = 'moyi_plugin_market_url'`（`lib/plugin_manager.dart`）；`MiniAppSettings` 各键（`moyi_miniapp_market_url` 等，`lib/miniapp/mini_app_settings.dart:22`）。
- 文件落盘：`ImportFileStore.directory()` = `getApplicationDocumentsDirectory()/imported_spiders`（`lib/import_file_store.dart:9-14`），`save(id, extension, bytes)` 会清洗 id（`[^a-zA-Z0-9_-]` → `_`）；`MiniAppStore.root` = `getApplicationDocumentsDirectory()/miniapps`（`lib/miniapp/mini_app_store.dart:18-25`），安装用 staging 目录 `.staging-<appId>` + 原子改名 `_promote()`。
- 引擎目录（Go 侧）：`core_bridge.dart:2215` `initialize()` 传 `getApplicationSupportDirectory()` 给 Go 核，`engine.directory`（`native/core/app_runtime.go:232`）是 Go 侧存储根。

**定法**：

| 东西 | 落点 | 理由 |
|---|---|---|
| 插件包文件 | `getApplicationDocumentsDirectory()/idj_plugins/<pluginId>/bundle.idjplugin`（整包原文，一字不改） | 照 iDuanJu 的 `files/plugins/<id>/bundle.idjplugin`（RE §8.3）；与 `imported_spiders/` 分开，避免 `_jsSpiderScript` 把包 JSON 当成 `.js` 文件误读；与 `miniapps/` 分开，避免与小程序安装器混淆 |
| 索引 | SharedPreferences，键 `moyi_idj_plugins`，值是一个 JSON 对象字符串：`{pluginId: {name, version, type, adult, enabled, origin, fileHash, siteKey, installedAt}}` | 照 `PluginManager` 的偏好键做法；索引只做轻量登记（查得到列表、启用态、版本比对就够），**manifest 本体不进 prefs**，用时读包文件——包文件是唯一事实来源，索引与包文件不一致时以包文件为准（包文件缺失/损坏的条目标记损坏，不拦启动、不拦列表） |
| Go 侧运行态 | `engine.directory/idj/<pluginId>/storage.json` + `cookies.json` | 见 §2.4；与 Dart 侧包文件分开（运行态是 Go 核写的，Dart 侧不碰） |

写盘手法照抄 `MiniAppStore`：先写 staging 目录 `.staging-<pluginId>`，写完校验通过后再原子改名成目标目录（`_promote` 同款）；同 id 覆盖安装时**保留原 enabled 状态**，新装默认启用（与 iDuanJu `PluginStore.commit` 一致，RE §6.1）。

### 1.3 manifest 校验：按 RE §6 的 problems() 规则，Android 宽松口径

校验规则抄 iDuanJu `problems()`（RE §5、§8.3），但按 **Android 宽松口径**执行——关键区别只有两处，其余照抄：

| 校验项 | 规则 | 宽松点 |
|---|---|---|
| id | 反向域名小写：`^[a-z0-9]+(\.[a-z0-9-]+){2,}$` | — |
| version | `x.y.z` 三段 semver | — |
| entry | `^[A-Za-z0-9_-]+\.js$` | — |
| type 与必需能力 | video/shortdrama 须 detail+play；comic 须 detail+pages；live 须 play | — |
| http 域名 | 只许 `example.com` 或 `*.example.com` 形态 | — |
| update.url | 必须是 https | — |
| integrity.signature.alg | 若出现则必须为 `ed25519` | — |
| minAppVersion | 与宿主规格水平比对（见 §2.2，`host.version.app` 定为 `"1.5.2"`，4 个插件要求 1.5，通过） | — |
| **integrity 形态** | **扁平字符串接受**：`"integrity": "sha256-…"` 与对象形态 `{"files": {"main.js": "sha256-…"}}` 都接受 | iOS 宿主用 JSONDecoder 解 struct，字符串会 `typeMismatch` → 拒装；Android 宿主用 `optJSONObject`，字符串时返回 null、直接忽略。魔蚁按 Android 口径：**不做结构解码**，只取值核对（§1.4） |
| **files 数量** | **多文件不拒绝**：只取 `files[entry]` 当源码，其余文件忽略并记日志 | iOS 要求 bundle 只能含一个脚本（`files.count > 1` 拒绝）；Android 不检查。魔蚁按 Android 口径 |

校验失败时报错必须指明是哪一条（如“插件 id 不是合法的反向域名”“缺少 play 能力”），不要只报“manifest 不合法”。

### 1.4 integrity 核对：扁平串兼容 + 自己算 SHA-256

- 两种形态都接受（§1.3）。取值：对象形态取 `integrity.files[entry]`；扁平字符串形态直接取整个字符串；去掉 `sha256-` 前缀后比对。
- 核对方法：取 `files[entry]` 的字符串，按 UTF-8 算 SHA-256 再 base64，与 manifest 的值逐字节比对。**4 个插件的值已亲验全对**（RE §9.2）：橙果 `QbFfoYprCteWlpXCk/wG8/sGboVWRZB+8nCko6SSFiw=`、潮流 `n/H79wQx6D3FnIk/H11pxDU4g+GdielL1IA6aTLSA98=`、爱果 `ld6e8PbCa+IVDg1apXdddeluJBkmirBAKIbvkKF76LY=`、2048 `prHUOZ4qAOb5YEtFc3UUOTVbujamWjnBfKXDuXgJEg0=`。实施时以 `plugins/*.idjplugin` 原文件重算为准，报告里的值只作核对参照。
- 不符**拒装**，报错写明插件 id 与“文件哈希与 manifest 不一致”（不要把完整哈希打进用户可见文案，日志里可记）。
- 安装时把算出的哈希钉进索引（`fileHash` 字段）；运行期加载前重算一次，包文件被改过就拒绝加载（与 iDuanJu“运行期文件被改就拒绝加载”一致，RE §1）。
- Ed25519 签名：4 个插件都没有。v1 只做哈希钉死；**有签名时**按 iOS 行为验签：`signingPayload = "idj1\n<id>\n<version>\n<file>:<hash>…"`（按文件名排序），验签失败拒装；首次签名安装钉死公钥（TOFU，记进索引），后续更新必须同一作者签（RE §5、§8.5）。Android 不验签是安全缺口（RE §10 风险 ⑨），魔蚁不照抄这点。

### 1.5 probe 试加载：用 Go 引擎跑一次 init

安装链：`解析 → problems() 校验 → integrity 核对 → 验签（有签名时）→ probe 试加载 → 写盘 + 更新索引 + 注册`。probe 失败，坏插件装不进去（RE §8.3 的安装链同款）。

probe 的做法：Dart 调 Go `"idjCall"`（见 §2.1），用一个 probe 模式（`fn: "__probe"` 或独立 action 字段，由实现工人定，二选一）：新建 runtime → 跑 prelude → 加载入口脚本 → 若插件导出了 `init` 则调一次 `init({})` → 检查 `export default` 里是否齐 manifest.capabilities 声明的能力函数（缺失的记为 probe 失败，报错写明缺哪个函数）。probe 不联网取站方数据（`host.http.request` 在 probe 里走真实 client 也可以，但 probe 的验收标准只是“能加载、函数齐全”，不判站方通不通）。

超时：初始化 15 秒（iDuanJu 值，RE §8.4），在 Dart 70 秒总预算内（`core_bridge.dart:2155` `_call()` 的 timeout）。

### 1.6 输入解释器 interpret：粘贴文本或链接统一分流

照 iDuanJu `PluginInstaller.interpret`（RE §6.1、§8.3）做一个 Dart 侧解释器（`IdjPluginStore.interpret`），输入是粘贴文本或链接，输出是安装动作。分流规则：

| 输入 | 分流 |
|---|---|
| M3U 频道列表文本 | **不走 idj 安装器**。M3U 导入是另一条既有流程（iDuanJu 是 `installM3U` 生成静态视频插件；魔蚁侧 M3U 走现有直播导入，不在本设计内）——解释器识别到 M3U 时报“这是 M3U 频道列表，请走直播导入”，不静默吞掉 |
| TVBox JSON（含 `sites` / `spider` / `lives`） | **拒绝**（与 iDuanJu Android 同款文案思路：“这是 TVBox 配置，不是 idj1 插件；不支持直接运行 JAR / CatVod / Python 源”，RE §7）。魔蚁侧 TVBox 导入走现有导入中心，不混进 idj 流程 |
| 含 `plugins` / `cms` 的 JSON | 订阅：按 §4.4 走订阅流程（展示、不自动装） |
| 含 `manifest` + `files` 的 JSON | `.idjplugin` 包：走 §1.3–§1.5 安装链 |
| 含 `schema` 的单个 manifest JSON | 裸 manifest：按 `entry` 从同目录下载脚本，拼成包再走安装链（`bundleFromManifest` 同款，RE §7） |
| http(s) 链接 | 先下载正文（下载器规则见 §1.7），再按以上内容分流 |
| 都不是 | 报错“这个链接不是插件 manifest / .idjplugin / 订阅列表 / M3U”（RE §6.1 同款文案） |

### 1.7 下载器规则（照 iDuanJu 的下载器，Dart 侧实现）

- 只接受无凭证的 HTTPS 公网域名、443 端口、非 IP 字面量；不自动跟随跳转（手动最多 6 跳，每跳重验规则）；请求 20 秒、资源 30 秒超时；解析到本机/内网的地址直接拒绝；UA 是 `Moyi/<版本> plugin-installer`（版本取 App 真实版本，不要编）；单文件上限：订阅 1MB、链接识别 2MB、插件包 2MB（RE §6.1、§8.3 的值；插件包上限与链接识别同值，够装 4 个插件——最大 42,129 字节——且留有余量）。
- Dart 实现注意：`package:http` 的 `get` 默认自动跟随跳转，**不能直接用**；用 `dart:io` 的 `HttpClient`（`followRedirects = false`）手动循环，每跳重验 https/443/非 IP/非内网。

### 1.8 安装确认与权限差异（PermissionDiff）

- 新装：安装确认 sheet（见 §4.3）展示 manifest 摘要：名、版本、作者（`description` 里有就展示，没有不编）、类型、adult 标记、域名数、存储需求、update.url 有无。用户点“安装”才走安装链。
- 更新：同 id 覆盖安装时算 PermissionDiff——多了域名、开了 CF/登录/存储、adult 由 false 变 true，**都要用户再确认**（列出差异项，点“确认更新”才装；RE §6.1 同款）。无差异的更新直接装。
- 卸载：删包目录、清索引条目、注销站点登记、从站点列表移除；Go 侧的 `storage.json` / `cookies.json` **保留**（重装回来状态还在）还是删除，由用户在卸载确认框里选（默认保留；选“同时清除插件数据”才删运行态目录）。停用：只改索引 `enabled` 并注销登记（Go 侧不删数据）；再启用时重登记，不用重装。
- `clearData`（清 cookies/storage/WebKit 数据，不卸载插件）：v1 只做前两项（删 Go 侧 `cookies.json` + `storage.json`），WebKit 数据魔蚁侧没有对应物，不做。

### 1.9 失败时报什么错（分阶段、中文、带定位信息）

| 阶段 | 报错文案（用户可见） | 补充 |
|---|---|---|
| 下载 | “下载失败：HTTP 404” / “下载超时（20 秒）” / “这个地址不是合法的插件下载地址（只支持 HTTPS 公网地址）” | 含 URL（去凭证后） |
| 解析 | “不是合法的 .idjplugin（缺少 manifest 或入口脚本）” / “这个链接不是插件 manifest / .idjplugin / 订阅列表 / M3U” | 含输入来源（网址/文件/粘贴）；本地导入解析失败时在插件 tab 内以对话框/SnackBar 展示，不闪退、不留半成品（§4.2.1） |
| manifest 校验 | “manifest 校验失败：插件 id 不是合法的反向域名” / “…缺少 play 能力” / “…minAppVersion 1.6 高于本机支持的 1.5.2” | 逐条指明 |
| integrity | “完整性校验失败：文件哈希与 manifest 不一致，已拒绝安装” | 含插件 id；完整哈希只记日志 |
| 签名 | “签名验证失败” / “更新签名者与首次安装不一致，已拒绝” | 含插件 id |
| probe | “试加载失败：插件报错 <message> (<code>)” | code 与 message 原样透传（插件的 `host.error`，见 §2.5） |
| 写盘/索引 | “安装失败：写入失败（存储空间不足？）” | 含底层错误，staging 残留要清掉 |
| 域名/权限 | 更新时权限扩大未确认 → 不装，提示“新版本申请了更多权限，请确认后再更新” | 列出差异项 |

安装失败不留半成品：staging 目录删除、索引不写、站点不注册。任何一步失败都不出现“装了一半的站”。

---

## 2. Go 核宿主

### 2.1 落点：新文件 `native/core/app_js_idj.go`，新 action `"idjCall"`

- **新 Go 文件 `native/core/app_js_idj.go`**：`idjCall` 入口 + prelude + host 桥 + 存储/Cookie 持久化。配套测试 `native/core/app_js_idj_test.go`。P0 探针文件 `native/core/app_js_idj_probe_test.go`（未提交）保留作证据。
- **不动** `app_js_spider.go` 与 `app_js_spider_compat.go`。`jsStripModuleSyntax`（`app_js_spider_compat.go`）、`jsFindFunction`（`app_js_spider.go:779`）、`jsExportValue`（`:763`）只复用。
- **新 action `"idjCall"`**：`native/core/app_runtime.go:435` `nativeDispatch` 里、**引擎初始化之后**另加 `case`。`"jsSpider"`（`:449`）先于引擎初始化处理、拿不到 `engine.directory`，**不要复用**。`nativeInput`（`app_runtime.go:105`）加四个字段：`pluginId` / `fn` / `args` / `manifest`（JSON 标签同名小驼峰）。
- Dart 侧新增 `_idjCall()`（照抄 `_jsCall`，`core_bridge.dart:874` 的结构，action 改 `'idjCall'`）。脚本与 manifest 由 Dart 侧从包文件读出、随请求传给 Go；**不走** `_jsSpiderScript()`（`core_bridge.dart:841`，它读 `ImportFileStore` 的 `imported_spiders/`，idj 包不在那里）。

调用形态（Go 侧伪代码，定接口、不定实现细节）：

```
idjCall(pluginID, script, manifestJSON, fn, argJSON) (map[string]interface{}, error)
  ├─ idjRuntime(pluginID, manifest) *goja.Runtime   // 每次调用新建，与现有模式一致
  │    ├─ jsStripModuleSyntax(script)               // 复用
  │    ├─ 行级兜底（§2.2）：hadDefault 为 false 且原文含顶层 export default 时改写
  │    ├─ rt.RunString(preludeJS)                   // 注入冻结的 host + console
  │    ├─ rt.RunString(script)                      // 加载 main.js
  │    └─ 绑定 Go 回调：host.http.request/get/post/allowed、host.storage.*、
  │         host.error、host.log、host.has、host.version …
  ├─ fn := jsFindFunction(rt, fn)                   // 复用（module.exports 里找）
  ├─ out := fn(goja.Undefined(), rt.ToValue(argMap))// 单对象参数
  ├─ awaitPromise(out)                              // 机制 A（§2.3）
  └─ jsExportValue(rt, out)                         // 复用
```

### 2.2 加载器：行级兜底必须先落（探针已证实的问题）

探针结论（探针报告 §3–§4）：`jsStripModuleSyntax` 不识别正则字面量——插件是手写正则解析 HTML 的，正则里的引号会被当字符串开头、正则结尾 `\/` + 终结 `/` 会拼成 `//` 被当行注释，花括号计数失同步，顶层 `export default` 没被转成 `module.exports`。实测：橙果直接通过，潮流/爱果/2048 全部报 `SyntaxError: (anonymous): Line 2:1 Unexpected reserved word`。

**正式修复用探针 §4.3 的方案 A（推荐，改动最小）**：idj 加载器里，`jsStripModuleSyntax` 之后检查 `hadDefault`；为 false 且原文含顶层 `export default` 时，用验证过的行级改写兜底（逐行找 `export default ` 开头的行，改写成 `module.exports = …`，约 10 行）。只影响 idj 路径，现有 JS 蜘蛛零风险。方案 B（给共享剥离器加正则识别）不动共享代码，本批不做。

### 2.3 超时模型与 Promise 结算：机制 A（探针已证实）

探针结论（探针报告 §1）：该 goja 版本能跑 `async/await` + `Promise`，**不需要事件循环**。`host.http.request` 在 Go 回调里同步做完请求再 `resolve`，async 函数就能完整结算（顶层调用返回时 `leave()` 排空 job 队列）。

- v1 只用**机制 A**：Go 回调内同步发请求（沿用 `jsDoFetch` 的同步风格）→ 拿到响应后立即 `resolve` → 把 Promise 交回 JS。`awaitPromise` 里先查 `State()`，pending 才泵一次空的顶层 `RunString("0;")`（机制 B 兜底）。
- 硬规则：`Runtime` 不是 goroutine 安全的，`resolve`/`reject` 与一切 `rt.*` 调用必须在 runtime 所在 goroutine 上做；`*Promise` 不是 `goja.Value`，交回 JS 必须用 `rt.ToValue(p)`。
- 超时（iDuanJu 值，RE §8.4）：初始化 15 秒、`has` 5 秒、调用默认 30 秒（Go 侧调用级预算）；Dart 层 70 秒总兜底（`core_bridge.dart:2155` `_call()`）。**超时后无中断**——goja 没有中断钩子，超时即废弃整个 runtime（本来每次调用新建，已天然满足），抛 `E_TIMEOUT`；在途 goroutine 靠 client 25 秒单请求超时自行结束。
- 看门狗：连续 3 次超时/内存超限自动停用并记日志（iDuanJu 规则，RE §6.3）。实现：索引里记 `failures` 计数，成功清零；到 3 次把 `enabled` 置 false、注销登记、记日志，用户在插件 tab 里可手动再启用（计数随启用清零）。
- 内存：QuickJS 64MB 上限、1MB 栈（RE §8.4 的 Android 值）；节点上限 300,000（`host.html.parse` 用，超了抛 `E_MEMORY`）。

### 2.4 host 全表与实现顺序

host 注入方式：iDuanJu 是 `globalThis.__host(name, json)` + prelude 拼对象后 `delete __host`（RE §3.1）。goja 侧更简单：直接用 `rt.Set("host", hostObj)`，在 prelude JS 里 `Object.freeze(host)` 及各子对象；`console`（log/info/warn/error）接到 Go 日志（带插件 id 前缀；v1 不做 UI 里的日志查看器，那是后续项）。

**实现顺序（4 个插件实际只用 3 个入口，先保证这三个，再把其余补齐）**：

| 阶段 | 入口 | 说明 |
|---|---|---|
| 第一阶段（4 个插件跑通必需） | `host.http.request` / `.get` / `.post` / `.allowed` | 唯一联网方式；语义见 §2.5 |
| 第一阶段 | `host.error(code, message)` | 返回带 `.code` 的 Error；见 §2.5 |
| 第一阶段 | `host.storage.get/set/remove` | 本插件私有 KV；持久化见下 |
| 第二阶段（补齐） | `host.html.parse` | 复用 `jsParseHTML` / `jsSelectAll` 等（`app_js_spider.go:377` 起）；**选择器是子集**：只支持 tag / `.class` / `#id` / `[attr=val]` / 后代 / `>` 子代 / 逗号分组，**不支持伪类、属性包含/开头匹配、`:nth-child` 等**——实现时把缺口写进注释与测试（旧 adapt_plan R9） |
| 第二阶段 | `host.crypto.*`（md5/sha1/sha256/sha512、hmac、aes cbc/ecb/ctr/gcm、rsa、randomHex） | Go 标准库：`crypto/aes` + `crypto/cipher`（PKCS7 填充自写约 10 行，Go 标准库没有；先例 `app_cenc_stream.go:513` `aes.NewCipher`）；哈希 `crypto/md5` / `crypto/sha256`（先例 `app_legado_script.go:4`） |
| 第二阶段 | `host.codec.*`（base64Encode/Decode、hexEncode、convert、gunzip、unpackPacker） | `encoding/base64`、`encoding/hex`（`app_js_spider.go` 的 `btoa`/`atob` 已有现成实现可抄）；`gunzip` 用 `compress/gzip`；`unpackPacker` 是纯字符串解包 |
| 第二阶段 | `host.m3u8.parse(text, baseUrl)` | 完整解析需新写（master/media 两级、相对地址补全、`#EXT-X-KEY` 提取）；`media_playlist.go:11` 只有 `m3u8Duration()`，不是解析，别认错 |
| 第二阶段 | `host.url.resolve/encodeForm` | Go `net/url`（`url.Parse` + `ResolveReference`；`url.Values.Encode()`） |
| 第二阶段 | `host.settings`（真值） | 4 个插件 `settings` 全空；v1 返回 `{}`；以后有设置的插件在 `idjCall` 的 `manifest` 入参里带设置表 |
| 第二阶段 | `host.log` / `console.*` | 接 Go 日志（带插件 id 前缀） |
| 不做 | `host.image.stripes/aes` | iDuanJu Android 也没有（走 `idjimg://` + 原生变换）；4 个插件没用到 |
| 固定 | `host.version` | 返回 `{app: "1.5.2", spec: "idj1"}`（见 §2.2 下面的说明） |
| 固定 | `host.has(cap)` | 按实际实现情况诚实返回 true/false（v1 实现的返回 true，未实现的返回 false；4 个插件没调 `has`，但以后插件会调，诚实返回比全 true 重要） |

**`host.version.app` 取 `"1.5.2"` 的理由（待父级确认，见 §9）**：1.5.2 是所实现的 idj1 宿主规格水平（RE §8.5：`host.version` 返回 `{"app": "1.5.2", "spec": "idj1"}`）；4 个插件的 `minAppVersion` 都是 1.5，若用 Go 核版本 `0.2.19` 会判 0.2.19 < 1.5 而拒装全部 4 个。不要编一个假 App 版本号——1.5.2 不是编的，是 iDuanJu 宿主在 `problems()` 里比对的那个规格版本。

**`host.storage` 与 Cookie 罐持久化（P0 级设计）**：

- 落点：`filepath.Join(engine.directory, "idj", pluginID)`（`engine.directory` 是 Dart `initialize()` 传进来的 `getApplicationSupportDirectory()`，`core_bridge.dart:2215`）。
  - `storage.json`：整包 KV（`map[string]string`），读写整文件；1MB 上限——写入前算字节，超了拒绝并回滚（与 iDuanJu 行为一致，RE §8.3）。`get/set/remove` 三个都实现（`remove` 4 个插件没用，但便宜）。
  - `cookies.json`：Cookie 罐持久化。Go 的 `cookiejar.Jar` 没有内置序列化：每次调用结束时调 `jar.Cookies(u)` 对插件 manifest 里各域名取 cookie，存成 `[{name, value, domain, path, expires, secure, httpOnly}]`；下次调用建 client 时 `jar.SetCookies(u, cookies)` 恢复。`cookiejar.New(nil)` 不带 PublicSuffixList 也能用（现有代码就这么用），不引入新依赖。
- 并发保护：同一插件的两次调用可能并发（聚合搜索 6 路 + 用户点播），`storage.json` 与 `cookies.json` 的读写加包级分锁（按 pluginID 一把 `sync.Mutex`，调用量小，够用）。
- 写盘时机：`set` 即写盘（成本小）；超时调用已写入的键不回滚（与 iDuanJu“超 1MB 拒绝并回滚”只针对超限那次写入一致）。
- 同步还是异步（旧 R17）：RE §9.1 的用法是同步取值（`const x = host.storage.get(k)`）。**实现工人写 `app_js_idj.go` 之前，必须以 `plugin_js_analysis.md` 里的解码源码为准再确认一次**：若是同步，Go 回调直接返回值；若是 `await storage.get(...)`，Go 回调返回 Promise。返工成本小但位置关键。
- 插件依赖的状态（RE §9.1）：橙果 `cg_ep_map_v1`（分集映射）、`cg_last_v1`、`cg_cats_v1`（分类缓存）；潮流 `"site"`（当前域名）、`"cookie"`、`"gateAt"`；爱果 `ag_last_v1`、`ag_eps_v1`（分集表）；2048 只写 `storage.set("last", id)`、从不读。注意潮流自维护的 `COOKIE` 字符串变量与 `"cookie"` 存储键**发不出去**（禁发头剥掉，见 §2.5），真正生效的是宿主 Cookie 罐——`Set-Cookie` 响应头必须进罐（`http.Client` + `cookiejar` 自动做），下次请求自动带。

### 2.5 `host.http.request` 必须实现的语义（逐条）

插件实际调用形态（RE §9.1）：`host.http.request({url, method, headers, body, timeout})` → Promise → `{status, url, headers, body}`。

| 要求 | 做法 |
|---|---|
| 返回 Promise（插件 `await` 它） | Go 回调返回 `*goja.Promise`，回调内同步发完请求再 `resolve`（机制 A，§2.3） |
| `method` 省略默认 `GET` | 复用 `jsFetchParseArgs` 的解析逻辑（`app_js_spider.go:77`） |
| `timeout` 单位毫秒 | 每插件建 client 时 `Timeout = timeout`（插件用 15000/20000/25000）；无 timeout 时默认 25 秒；**不得超过 Dart 70 秒总预算** |
| 响应头键小写 | 返回前把键统一 `strings.ToLower`（2048 的 `follow()` 读 `location` 就靠这个） |
| `body` 是字符串 | 保持；非 UTF-8 体按原字节转字符串，不做转码 |
| 禁发头剥离 | 发请求前删掉：`cookie`、`cookie2`、`host` 及 iDuanJu 禁发表其余项（以 `repo/STV/Plugins/PluginNet.swift:207-208` 的 12 项为准抄全表，**不要猜**——唯独 `authorization` 不在内，用户 2026-11-24 18:40 令宿主放行它，妻友社站方要这个头）。**这是潮流年龄验证的前提**：插件自带的 `Cookie:` 头必须剥掉，改由 Cookie 罐自动带 |
| 每插件独立 Cookie 罐自动带 Cookie | 见 §2.4（持久化设计） |
| 域名白名单（manifest.http，含 `*.` 通配；跳转落点也查） | 见 §2.6 |
| 单次调用请求数上限 | 每调用计数，上限 60，超了返回 `host.error('E_RATE_LIMIT', …)`（信息带插件名与已用次数，方便定位；潮流最坏情况会撞线，见 §9） |
| 每分钟请求数上限 | 120 次/分钟滑动窗口（RE §8.4） |
| 响应体上限 | 20MB（iDuanJu 值；`jsDoFetch` 是 8MB，idj 路径提到 20MB） |
| `host.http.get(url, opts)` / `.post(url, body, opts)` | 薄包装转 `request`（4 个插件没用，但 `host.has('http')` 语义上应有；成本低，顺手做） |
| `host.http.allowed(url)` | 查 manifest 白名单返回 bool（便宜，顺手做） |
| HTTP 接哪层 | v1 **不接** `Downloader` 统一请求口（它在 `nativeEngine` 里，带票据/指纹/限流器；`jsSpider` 路径本来就绕过引擎）。v1 用 `jsSpiderHTTPClient()` 同款独立 client（直连、`Proxy=nil`、25 秒超时）+ 每插件持久 Cookie 罐。理由：4 个站的 manifest 都是 `cloudflare: false`，直连即够；以后某插件站上盾，再评估切到 `Downloader.doPreparedCatalogRequest`（`native/core/network_limiter.go:236`） |

**`host.error` 映射**：`host.error(code, message)` 返回一个带 `.code` 属性的 JS `Error` 对象（goja 里 `rt.NewObject()` + `Set("code", …)`，或 `goja.NewGoError` 包装——以能 `throw` 且 `.code` 可读为验收标准）。插件 `throw host.error(...)` 后，goja 调用返回 Go error，经 `NativeRequest` 信封回到 Dart，`_call()` 抛 `AppFailure(message)`。码表：规范码（RE §4）`E_NETWORK / E_TIMEOUT / E_HTTP / E_CF_REQUIRED / E_LOGIN_REQUIRED / E_PARSE / E_NOT_FOUND / E_GEO / E_RATE_LIMIT / E_UNSUPPORTED / E_PERMISSION / E_INTERNAL` 原样透传；插件自用的规范外码（`E_NET / E_AUTH / E_EMPTY / E_ARGS / E_PARAM / E_NO_SOURCE / E_BLOCKED / E_DNS / E_DOMAIN`，RE §9.8-1）**不要改写**，Dart 侧显示为 `"<message> (<code>)"`（与 iDuanJu `PluginError.describe` 的默认分支一致）。Go 侧自己的错误也要包成带码的错误：白名单 → `E_PERMISSION`；单请求超时 → `E_TIMEOUT`；响应体超 20MB → `E_INTERNAL`（实施时定一个并写进测试）。

### 2.6 域名白名单与 CF 处理

**白名单**：来源是 manifest 的 `permissions.http`（插件 JS 请求）与 `permissions.media`（播放器直接取的流/分片/图片）。4 站实测值（RE §2.2；实施时以包文件为准）：

- 橙果 http：`api2.chengguodj.com`、`chengguodj.com`、`www.chengguodj.com`、`hls.ohjzmm.cn`、`*.ohjzmm.cn`、`mts.hhjd.mobi`、`*.hhjd.mobi`；media：`chengguodj.com`、`www.chengguodj.com`、`hls.ohjzmm.cn`、`*.ohjzmm.cn`、`mts.hhjd.mobi`、`*.hhjd.mobi`。
- 潮流 http：`mjv001–015.com`（及 `*.`）、`mavrtracktor.com`（及 `*.`）、`go.mavrtracktor.com`、`stripchat.com`（及 `*.`）；media：`mjv001–015.com`（及 `*.`）+ `eemmhh01.com`、`imgstream1.com`、`ddaa4.com`、`streamfastpro.com`（及各自 `*.`）。`stripchat.com` / `go.mavrtracktor.com` 在 JS 里一次未出现，白名单照 manifest 留着无妨（只放行、不强制用）。
- 爱果 http/media：`aigo.me`、`www.aigo.me`、`bucket.usemarkt.xyz`、`*.usemarkt.xyz`。
- 2048 http/media：`2048ai4.com`（及 `*.`）、`madouai.xyz`（及 `*.`）、`acfan.ymkizv84.work`（及 `*.`）、`gwbe.jw5cqzrc.work`（及 `*.`）。

校验规则（抄 iDuanJu `DomainPolicy` 的语义）：精确域名或 `*.example.com`（只匹配一层子域还是多层，以 `repo` 源码 `DomainPolicy` 为准，实施时读一次，不要猜）；跳转落点每跳都查；本机/内网地址（`localhost`、10/172.16/192.168、`*.local`、IP 字面量）直接拒绝；`host.http.request` 命中白名单外域名时返回 `host.error('E_PERMISSION', …)`（不要静默返回空串——现有 `request()` 出错返回 `""` 的静默风格不能用在 idj 上，否则插件会把空当正常响应解析，报错信息全丢）。**播放器侧不校验白名单**（见 §3.5）。

**CF 处理（v1：只报错，不解盾；接法待定）**：

- 现状核实：4 个 manifest 的 `cloudflare` 全是 `false`，v1 不需要解盾。撞盾判定：`cf-mitigated: challenge` 头，或 403/503 且正文含 Just a moment 等特征（判定逻辑已有现成实现：`native/core/network_browser.go:117-121` `browserChallengeStatus` / `:234` `isCFMitigatedChallenge`，只认 403 + `cf-mitigated: challenge`）；撞盾时 `host.http.request` 返回 `host.error('E_CF_REQUIRED', …)`，Dart 侧原样显示。
- **为什么 v1 不接现有解盾路**：本树 v57（提交 `4649482`）已按用户令删应用盾——票池（tlsGet 票池、播放层补票）与 v56 补丁的盾接线已 revert；全树 grep `cf_clearance` / `ticketPool` / `TicketPool` 只剩一处注释（`native/core/provider_custom_maccms.go:1180`），没有任何可复用的可见 WebView 人工验证入口。iDuanJu Android 的做法是弹可见 WebView 让用户手动过验证、成功后 `importCookies` 并记 `learnedUA` 再重试一次（RE §8.4）——魔蚁树里没有这个入口，要新造。
- 后续接法（二选一，待父级/用户定，见 §9）：
  - （a）指纹升级：`host.http.request` 切到 `Downloader.doPreparedCatalogRequest`（`network_limiter.go:236`）+ `huangguoBrowserTransport`（`network_browser.go`）的浏览器指纹升级——无人工验证，只能过指纹级拦截，撞真人验证仍报 `E_CF_REQUIRED`。
  - （b）可见 WebView 人工验证：新造一个验证页（WebView 打开站方验证页，用户手动通过后把 cookie 导入插件 Cookie 罐 + 记 `learnedUA`，24 小时有效），再重试一次。工作量大（新 UI + Go 侧 `importCookies` 入口 + 罐持久化联动），但与 iDuanJu Android 同款。

---

## 3. 插件变站点桥接（片库）

### 3.1 一句话：装上就能当站用，动态注册，不是内置写死

插件装好后注册进片库的站点列表，当站用：片库里能看到它、能切站、能进分类/详情/播放。注册是动态的——装插件时注册，卸载/停用时注销，启动时从索引恢复。

### 3.2 站 key 与显示名规则

| 项 | 规则 | 依据 |
|---|---|---|
| 站 key | `idj_` + 短名（`idj_chengguo`、`idj_chaoliu`、`idj_aiguo`、`idj_ai2048`） | `idj_` 前缀全树零命中；`chaoliu` 已被 py 潮流站占用（`builtin_py_sites.dart:628`，另有 jar `ZakaChaoliu`），绝不能用裸名。短名取自 manifest.id 的末段（`com.idj.ext.chengguo` → `chengguo`）；末段冲突时加 `_2` / `_3`（与 jar 直导同名排号规则同款思路） |
| 显示名 | manifest.name；潮流AV、2048AI 加 `🔞` 前缀（`🔞潮流AV`、`🔞2048AI`）；橙果、爱果不加 | 用户定的分区（旧 adapt_plan §2.2 的表，方向改后仍有效）；🔞 是成人标记的唯一载体（`midnight_zone.dart` 的 `isAdultSourceName` 只认前缀） |
| 分区 `section` | 橙果/爱果 `sectionDrama`（短剧区）；潮流/2048 `sectionVideo`（视频区） | 用户定的分区；**忽略 manifest 的 `adult` 字段**——4 个 manifest 的 `adult` 全是 `true`，含短剧站（RE §2.3），按该字段分会把短剧站也判成人 |
| `origin` / `importType` | `origin: originImport`，`importType: 'js'` | `isJsSource`（`core_bridge.dart:838`）认的唯一标记；`originImport` 使其进导入分组逻辑（切换弹窗里按内容分组后不再按来源分，见 §5） |
| `importExt` | 存插件 id（`com.idj.ext.chengguo`） | 供 `_idjCall` 与 Go 侧找包文件、找存储目录；不要用它存 token 之类 |

### 3.3 注册 / 注销 / 启用 / 停用 / 启动恢复

- 注册：`SourceSite.importedSites[siteKey] = site`（`models.dart:773`）。**不写 `importedJsFiles`**（`models.dart:782`）——idj 脚本不走 `_jsSpiderScript()`，写了反而会被当成普通 JS 蜘蛛文件误读。`_idjCall` 用 `importExt` 里的插件 id 找包文件。
- 注册后通知：`store.refreshSiteRegistry()`（`local_store.dart:388`，即 `_notify()`），全部站点列表（设置列表、站点切换、跨站探活池）立即刷新（`PluginMarketScreen._afterRegistryChange` 同款手法）。
- 注销（卸载/停用）：从 `importedSites` 移除 + `refreshSiteRegistry()`。Go 侧运行态（`storage.json` / `cookies.json`）按 §1.8 的约定处理（停用保留，卸载默认保留、可选清除）。
- 启动恢复：`lib/main.dart:168` `await PluginManager.ensureBuiltinPlugins(preferences);` 之后加一行 `await IdjPluginRegistry.restoreAll();`。恢复逻辑：读索引 → 逐个校验包文件存在且哈希未变 → 重登记 `enabled == true` 的插件；包文件缺失/损坏的跳过并记日志（索引条目标记损坏，列表里显示“已损坏”，不拦启动）。
- 启用/停用：只改索引 `enabled` + 登记/注销，不动包文件与运行态。停用后该站从片库消失（不在 `visibleSources` 里），重启用立即回来，不用重装。

### 3.4 五处 Dart 分流与形状翻译（`IdjContract`）

新文件 `lib/idj_contract.dart`（`IdjContract.categoriesFromHome / pageFromResult / detailFromResult / planFromResult` 四个纯函数，与 `PyContract` 并列，**不改 `PyContract`**）。`core_bridge.dart` 里 `isJsSource` 的分支内再分流 `isIdjSource(source)`（key 以 `idj_` 开头）→ 走 `_idjCall` + `IdjContract`；非 idj 的 JS 站保持原样。

| 界面动作 | Dart 入口 | idj 落法 |
|---|---|---|
| 取分类 | `categories()` L2298 | `_idjCall(source, 'home')` → `IdjContract.categoriesFromHome`：读 `home['categories']`（`[{id, name}]`），前置「全部」（id `''`）。分类第一次从哪取、缓存在哪、切站后怎么刷新，见 §6 |
| 目录/翻页 | `catalog()` L2388 | 有 query → `_idjCall(source, 'search', query, page)`；否则 `_idjCall(source, 'category', category, page)` → `IdjContract.pageFromResult`：读 `{items, hasMore}`（无 `page`/`pagecount`/`list`，`category` 甚至不回 `page`）；列表项字段是 `{id, title, cover, duration, remarks, url?, tags?}`（映射见下）；`hasMore` 为真时 `pagecount = page+1`。**空分类拦截保留**：`category.isEmpty` 时改调 `home()` 取 `home['items']`（橙果 home 是 hot/featured 合并、潮流是 chinese 1–4 页合并、爱果是首页、2048 是 `/videos` 第 1 页前 30 条），`hasMore` 取 home 的（2048 home 的 `hasMore` 恒 true，只取第一页、不追翻页，RE §9.8-7） |
| 搜索 | 同 `catalog()` 的 query 分支 | `search({keyword, page})` 形状与 `category` 一样是 `{items, hasMore}` |
| 详情 | `detail()` L2811 | `_idjCall(source, 'detail', vodId)` → `IdjContract.detailFromResult`：插件返回 `{id, title, cover, desc, duration, tags, lines: [{name, line, episodes: [{id, name}]}]}`；`lines[i].name` → `flag`（线路名，仅展示）；`episodes[j].id` → `Episode.id`（分集键）；`episodes[j].name` → `Episode.title`。`line` 字段是**显示名、不可当键用**（RE §9.7），只存 `flag` 供展示；真正分集键只放 `id` |
| 取流 | `resolvePlayback()` L2976 与 `resolve()` L3231（**两个调用点都要改**） | `_idjCall(source, 'player', flag: episode.raw['flag'], playId: episode.raw['id'])` → `IdjContract.planFromResult`：取 `streams[0]` 的 `url` + `headers`（`{User-Agent, Referer}` 透传），`expiresAt` → `PlaybackPlan.expiresAt`（`models.dart:1462` 字段已存在）；`format: hls/mp4` → `needsParse: false`。多流（潮流多画质）v1 只取第一条，多线路选择是后续项。空 `streams` 时 url 为空，抛 `AppFailure('插件没有返回可播放地址')` |
| 封面 | `cover()` L2731（不动） | 4 站封面都是绝对 http 地址（橙果经自家 `/_img/` 代理拼出的也是绝对地址）；`proxy://` 前缀才走蜘蛛代理，idj 不用 |
| 聚合搜索 | `searchAcross()` L2477 / `searchAcrossProgressive()` L2572（结构不动） | idj 站加入 js 腿（6 路并发、每站 10 秒超时，失败只记名不抛错）。4 站会与同名/同源站重复出结果（idj 潮流 vs py 潮流，见 §9 R14）；v1 默认并存、如实报重复 |

列表项映射（`pageFromResult` 内）：`id` → `vod_id`、`title` → `vod_name`、`cover` → `vod_pic`、`remarks` → `vod_remarks`、`duration` → 时长（字符串，如 `"N集"` / `"M:SS"`，原样展示）、`url` → 详情页地址（仅展示用，不作取流键）、`tags` → 标签。`PyContract.itemToDrama`（`py_contract.dart:15`）是映射范本，照抄字段对应关系、不改它。

**输出清洗（`PluginOut` 同款，`IdjContract` 里做）**：标题 ≤200 字、简介 ≤4000 字、items 上限 500、chapters 上限 5000、images 上限 2000、streams 上限 12（RE §8.3 的值）。超限的截断并记日志，不抛错（插件返回超大列表不该炸掉界面）。

**短剧区搜索开关**：`models.dart` 的 `duanjuOnlineSearch` / `duanjuPaged` 是写死 id 白名单集合。动态安装的站没有字面量可补，改为**规则式**：两个 getter 各加一条 `(isDramaSection && importType == 'js')`。现有 JS 站全是视频分区（`imported_site_record.dart:68` `asSite` 写死 `sectionVideo`），不受影响；以后新装的短剧插件自动获得在线搜索与分页搜索，不用再改 `models.dart`。

### 3.5 播放链路（结论：不用改播放器，但有两处要注意）

- `PlaybackPlan`（`models.dart:1451`）v1 只填 `url` + `headers` + `expiresAt`。
- 头透传已通：`lib/player_screen.dart:1528/1793/1944`（`headers: plan.headers` / `httpHeaders: plan.headers`，进 ExoPlayer）、`lib/tvbox_video_pane.dart:209/243`。`lib/playback_loader.dart` 的 `_load` 不改头。
- 播放器拿 `plan.url` + `plan.headers` 直接请求 m3u8/mp4 与分片，**不经过 Go 核、不经过蜘蛛 HTTP**。所以蜘蛛层的域名白名单拦不住播放器，播放器侧也没有白名单——唯一的校验是 `native/core/provider_huangguo.go:1376` `isProviderHTTPMediaURL()`（scheme 为 http/https、host 非空、无 userinfo）。`IdjContract.planFromResult` 里再加一道 URL 形态校验（https、443 端口、无 userinfo、非 IP 字面量，不符的流丢弃记日志；media 白名单不符只记日志、不丢弃——播放器侧白名单是后续项，不要在本批悄悄加上）。
- 要注意的两处：
  1. `lib/player_screen.dart:1826` `resolvePlaybackRedirects(plan.url, plan.headers)`：取流后还会跟一次重定向解析，重定向后的头是 `resolved.headers`——若站方 302 到签名地址且签名在头里，要确认头不被丢（现有 py 站同样走这条，行为一致，不新增风险，只列为验播时观察项）。
  2. 2048 的代理地址含 `path=` 查询参数（被 `encodeURIComponent` 编码过一次的路径）；`isProviderHTTPMediaURL` 只看 scheme/host，不解码，不会误拦。
- `expiresAt`：字段存在，但 JS 路径没有“到期前重调 play”的机制（iDuanJu 有，RE §4）。v1 做法：`PlaybackPlan.expiresAt` 照实填，过期后播放失败即由现有播放失败重试/报错路径处理（`playback_recovery.dart` / `playback_error.dart`），重调 play 是后续项。
- `proxy` 字段（v1 不做）：4 个插件的 `play` 返回里**没有 `proxy` 字段**。以后补的位置：`hlsKey` / `segmentDecrypt` → `PlaybackPlan.decryptionKey` + `native/core/app_stream.go` / `app_download_hls.go` 的取分片处；`stripFakeHeader` 同处（分片读取时跳过前 N 字节）；`drm cenc-ctr` → `native/core/app_cenc_stream.go` 的 CENC 链路。

### 3.6 play 传参修复（§9.7 的坑，兼容层内解决，main.js 一字不改）

- Dart 侧已经传对了两个值：`resolvePlayback` / `resolve` 里 `_jsCall(source, 'player', flag: episode.raw['flag'], playId: episode.raw['id'])`。`flag` 是详情里 `lines[i].name`（显示名，如 `"线路1 · 1080P"`），`playId` 是 `episodes[j].id`（分集键）。
- Go 的 idj play 路径必须调：**`play({id: episodeId, episodeId, line})`**，即把 `playID` 同时填进 `id` 与 `episodeId`，`line` 填 `flag`。逐站验证（RE §9.7 的推演）：
  - 橙果：`id = packId`（如 `"123005"`）→ 查 `cg_ep_map_v1` 命中，或拆“剧 id + 末 3 位集号”正确。**不这样传会恒播第 1 集**。
  - 爱果：`id = 集号字符串` → 查 `ag_eps_v1` 找 eid。**不这样传会恒播第 1 集**。
  - 潮流：`id = "{mvarr键}|{视频id}"` → 取指定线路画质；`line` 是显示名，插件不读它。**不这样传会丢线路选择**（只播最高画质）。
  - 2048：单集，`id = 视频 id`，传不传都对。
- **实施时不要改 Dart 的 `flag`/`playId` 传参**（已经是对的），只改 Go 侧 idj play 的参数组装。并在 `app_js_idj_test.go` 里给 4 站各写一个 fixture：构造假 `detail` 结果 → 取某集的 `episodeId` → 调 `play` → 断言插件收到的 `id` 就是该集的键（橙果断言不是第 1 集）。

### 3.7 成人门禁与分区（“成人走午夜门禁”在本树的可执行口径）

先写清树里的实情（已核实，实施工人不要按想象写）：

- 本树**没有独立的“午夜区”tab**：底部导航是片库、直播、听读、网盘、小程序、演员库、游戏区、我的。`lib/models.dart:848` 有明确注释：“统一视频区谓词：全部视频分区站源都在点播区浏览，不再按来源或 🔞 名拆成点播/午夜两个区。午夜区已并入统一站点区”。分区判定函数就是 `isVodZoneSource(site) => site.isVideoSection`（`models.dart:850`）。
- 成人标记的实际载体是**显示名前缀 `🔞`**：`lib/midnight_zone.dart` 只有两个辅助函数——`isAdultSourceName(name) => name.startsWith('🔞')` 与 `filterSourcesByAdult(...)`；消费处：`lib/hero_mix.dart:46–58`（首页轮播成人站抽样只认 `🔞`）、`lib/hongguo_drama_home.dart:304/322`（成人站筛选）、`lib/adult_scrape_service.dart`（女优库刮削只认已注册且可见的 🔞 站）。
- 成人门禁的实际载体是**用户档案**：`lib/local_store.dart:182` `allowsSource()`——`locked` 时全禁；`importedSites` 与 `custom`/`cloudDrive` 的站**直接放行**（设备级功能，不走档案）；其余走 `LocalProfile.allows()`（`lib/local_profiles.dart:27`：`admin || sources.contains(source)`）。**按此逻辑，动态注册进 `importedSites` 的 🔞 站会被直接放行，不经过档案的成人开关。**
- **修仙境界门禁在本树不存在**：全树 grep `cultivation` / `unlockedVideo` 零命中（境界门禁只在修仙版树里）。

所以“成人插件仍走午夜门禁”在本树 v1 的可执行口径是以下三件（都是现有机制，不新造门禁）：

1. **显示名 `🔞` 前缀**（潮流AV、2048AI）：首页轮播抽样、成人站筛选、女优库刮削三处自动认到。
2. **切换弹窗里的「午夜类」分组**（见 §5.3）：视频分区且带 `🔞` 前缀的站集中进午夜组展示，找得到、分得开；短剧分区站不论带不带 `🔞` 都留在短剧类——`🔞` 不决定分组。
3. **`defaultHiddenSiteIds`（`models.dart:825`）加两个成人站 key**（`idj_chaoliu`、`idj_ai2048`）：从未在「源显示列表」里配置过的新用户默认看不到这两个站，要在源显示列表里手动打开才可见。**局限要如实写**：已配置过隐藏列表的用户不受影响（以存档值为准）；且这只是“默认不显示”，不是访问控制——`allowsSource()` 对导入站直接放行，深链/直达仍能打开。

档案级真门禁（导入站也走档案开关）是待定项（见 §9），不要在本批擅自加——加了会改变全部导入站的放行逻辑，波及面超出 idj。

---

## 4. 市场 UI（小程序内）

### 4.1 位置：小程序内的市场，不要另起独立市场页

市场 UI 落在 **`lib/miniapp/mini_app_home_page.dart` 的 `MiniAppHomePage`**（底部导航「小程序」tab；入口三处：`lib/home_screen.dart:3500` 通用壳、`lib/home_screen.dart:2818` Win7 壳、`lib/hongguo_drama_home.dart:1108` 第 5 个 tab）。不要用 `lib/plugin_market_screen.dart`（那是设置里的 jar/zip/py 插件市场，`PluginMarketScreen`，入口在 `settings_screen.dart:421`），不要另起一个独立市场页。

现有结构（已核实）：`MiniAppHomePage` 是 `DefaultTabController(length: 3)`，顶栏 `toolbarHeight: 42`，三个 tab「已安装 / 市场 / 海阔」；右上角三个按钮：`+`（`_showCreateMenu`：从 zip 包安装 / 从文件夹安装 / 从链接安装 / 海阔小程序 / 刷新市场）、视图切换（网格/列表）、设置（`MiniAppSettingsScreen`，改市场地址）；「市场」tab（`_marketTab`）用 `_loadMarket()` 拉 `settings.marketUrl`（`MiniAppSettings.defaultMarketUrl`，`lib/miniapp/mini_app_settings.dart:13`，默认是 ghfast.top 代理的 ant-video market.json），`parseMiniAppMarketJson`（`lib/miniapp/mini_app_manifest.dart:129`，读 `{"apps": [...]}`），`_installMarketItem` 调 `MiniAppStore.installFromUrl(expectedMd5, expectedSize)`，`_showMarketInfo` 弹详情对话框；已安装 tab 长按出底部动作单（打开/卸载/详情）。

**改动：TabBar 加第 4 个 tab「插件」**（`length: 3 → 4`，tabs 顺序：已安装 / 市场 / 海阔 / 插件）。tab 内容是插件市场（不是小程序市场），但**不另起一页**——tab 内容写成同一文件里的一个 Widget（或新文件 `lib/miniapp/idj_plugin_tab.dart`，只作 tab 内容、不独立导航、不注册路由；实施工人二选一，推荐后者以免 `mini_app_home_page.dart` 再长）。

注意格式隔离：小程序市场 JSON 是 `{"apps": [...]}`（`MiniAppMarketItem`），idj 订阅是 `{"name", "plugins": [...], "cms": [...]}`——**不要混用解析器**，各用各的（`parseMiniAppMarketJson` 不动；idj 订阅另写解析）。

### 4.2 「插件」tab 的分区（四区）

| 区 | 内容 | 数据来源 |
|---|---|---|
| 已安装 | 插件列表：每行名、版本、插件 id、🔞 标记（adult）、启用开关（Switch）、按钮「详情」「卸载」「检查更新」；已停用的行置灰并标“已停用”；损坏的条目（包文件缺失/哈希变了）标“已损坏”，只给「卸载」「重新安装」 | `IdjPluginStore.listInstalled()`（读索引 + 包文件校验） |
| 安装入口 | 三个按钮：「从网址安装」「从文件安装（.idjplugin）」「粘贴插件/订阅」 | 走同一安装器（§1.6 的 interpret）；「从文件安装」入口**保留**（用户 2026-11-24 11:55 令确认不丢），完整流程见 §4.2.1；文件用 `FilePicker`（`allowedExtensions: ['idjplugin']`，照 `PluginMarketScreen._pickAndInstallFile` 的写法）；粘贴弹文本框对话框 |
| 订阅 | 订阅列表：每条订阅一行（名 + 地址 + 刷新按钮 + 删除）；点开一条订阅，展开它的插件（每插件一行：名、版本、简介、adult 标记、「安装」/「更新」按钮）与 cms 条目（只展示名 + api，见 §4.4）；「添加订阅地址」按钮（文本框输地址，先拉取一次成功才保存，与 iDuanJu `addSubscription` 同款） | SharedPreferences 字符串列表 `moyi_idj_subscriptions`（只存地址）；订阅内容**不持久化**，每次打开 tab 时重拉，失败留旧列表记 error（与 iDuanJu `refreshSubscriptions` 同款；小程序市场 `_loadMarket` 静默刷新失败留旧列表的手法同款） |
| 更新检查 | 「检查更新」按钮（手动触发，无定时自动刷新） | 见 §4.5 |

安装/卸载/启用/停用后：调 `store.refreshSiteRegistry()`（`local_store.dart:388`）让片库列表立即刷新（`PluginMarketScreen._afterRegistryChange` 同款手法：`refreshSiteRegistry()` + 刷新本页安装状态），再 `_refreshInstalled()` 刷新 tab。

### 4.2.1 本地导入流程（从文件安装）写实

**入口保留（用户 2026-11-24 11:55 亲口令）**：「从文件安装（.idjplugin）」是三个安装按钮之一，本次修订确认不丢；右上角 `+` 号菜单里的「安装插件文件（.idjplugin）」（§4.6）是同一入口的另一条路，两处调同一个安装器入口，不写两套逻辑。

**一步步流程**：

1. 小程序 → 「插件」tab → 点「从文件安装（.idjplugin）」（或右上角 `+` → 「安装插件文件（.idjplugin）」）。
2. 系统文件选择器打开（见下约束），用户挑一个本地 `.idjplugin` 文件；文件类型过滤只认 `.idjplugin`，别的后缀不显示/不可选。
3. 选好后按选择器返回的 URI 读文件字节（**不依赖真实文件路径**，见下约束），得到整包 JSON 文本。
4. 解析：按 §1.3 校验 manifest（格式、id/版本/entry、类型与必需能力、域名白名单形态、update.url 须 https），按 §1.4 核对 integrity（扁平字符串 `"sha256-…"` 与对象形态都接受，去前缀后比对 SHA-256 + base64）。
5. 弹安装确认 sheet（§4.3）：名、版本、插件 id、类型、adult 标记、域名数、简介；成人提示按分区（section）写——短剧分区写“装好后进短剧区”，视频分区 🔞 站写“装好后进午夜组，默认不对新用户显示”。
6. 点「安装」后走安装链其余步骤（§1.5 probe 试加载 → 写盘 + 索引 → 注册）：probe 失败、integrity 不符、校验失败都拒装，不留半成品（§1.9）。
7. 装好后进片库当站用：按 section 分组进站点切换弹窗（橙果/爱果进短剧类，潮流/2048 进午夜类，见 §5.3），tab 自动切到「插件」tab 的已安装区（§4.6 同款手法）。

**关键约束——文件选择走系统文件选择器，不自己造应用内文件浏览**：

- 选文件用 `FilePicker`（`allowedExtensions: ['idjplugin']`），它在安卓侧调的就是系统文件选择器（SAF，`ACTION_OPEN_DOCUMENT`）。**不自己写应用内文件浏览/目录树、不自己拼文件路径。**
- 原因：用户手机是华为鸿蒙 NEXT，应用跑在卓易通容器里，系统选择器才是可靠的路——系统选择器由系统出面给一次性的读权限，应用内自造浏览在容器里容易拿不到真实路径、权限也麻烦。
- 落法：只拿选择器返回的 URI 读字节（`FilePickerResult.files.single.bytes` 或按 URI 读流），不要 `File(path)` 去猜路径；用户在选择器里点取消时什么都不发生（不报错、不留半成品）。

**验收情形**：

- 用户发来的 4 个 `.idjplugin`（橙果短剧、潮流AV、爱果短剧、2048AI）就是走这条本地导入装进来的（§8.4 的逐站自检以这条为安装方式；不走网址安装、不内置）。
- 文件类型过滤只认 `.idjplugin`；选到非插件文件、或文件内容不是合法 `.idjplugin`（缺 manifest / 缺入口脚本 / JSON 解析失败）时，在插件 tab 内给一句看得懂的中文报错（§1.9 解析行文案，如“不是合法的 .idjplugin（缺少 manifest 或入口脚本）”），**不闪退**，不留半成品。

### 4.3 安装确认 sheet（装前先看明白）

点「安装」后不直接装，先弹确认 sheet（底部动作单或对话框，二选一，与 `MiniAppHomePage._showInstalledActions` 的底部动作单风格一致）：

- 内容：名、版本、插件 id、类型（video/shortdrama/comic/live）、adult 标记、域名数（`permissions.http` 数量 + 展开看全部域名）、存储需求、update.url 有无、简介（`description`，有就展示、没有不编）。成人提示文案**按分区（section）写，不按 adult 字段写**：短剧分区写“短剧插件：装好后进短剧区，可在片库短剧区找到”（橙果/爱果 adult=true 但进短剧区，用这句）；视频分区且带 `🔞` 前缀写“成人插件：装好后进午夜组，默认不对新用户显示”——按 §3.7 的口径写，不要写“需 Face ID”之类魔蚁没有的东西；视频分区无 `🔞` 前缀不加成人提示行。
- 更新时：先算 PermissionDiff（§1.8），有扩大项的单独列出差异（“新版本多申请了 N 个域名：…” / “成人标记由否变是”），点“确认更新”才装。
- 按钮：「安装」/「取消」。安装中按钮置灰 + 转圈（`_installing` 集合防重入，照 `_installMarketItem` 的写法）。

### 4.4 订阅列表远程安装（不自动装、逐个点安装）

订阅格式（RE §1、§6.2）：`{"name": "...", "plugins": [{"id","name","manifest","type","adult","version","description"}], "cms": [{"name","api","adult}]}`，其中 `manifest` 可以是**相对订阅地址的路径**（用 `Uri.resolve` 解析；相对地址解析失败的条目跳过并记日志）。

- 订阅里的插件**不会自动安装**，只展示、由用户逐个点安装（iDuanJu 原话，RE §6.2）。每条插件行按 `manifest.version` 与已安装版本比 semver，显示「安装」或「更新」（照 `PluginsScreenKt` 订阅页的“安装/更新”与 APK 实测 §8.6）。
- `refreshSubscriptions()`：逐个重拉，失败只记 error 不丢旧列表（iDuanJu 同款）。刷新时机是 UI 手动（tab 打开时拉一次 + 「刷新」按钮），**未发现定时自动刷新的代码**（RE §8.6），魔蚁侧也不加定时器。
- `cms` 条目：v1 **只展示**（名 + api + adult 标记），不提供“一键添加采集站”。原因：魔蚁侧有无对等的“一键加 CMS 站”入口未核实（`lib/subscription_entries.dart` 未读），不要硬写。实施前核实，有入口就接、没有就保持只展示（见 §9）。
- 订阅地址本身的管理：添加时先拉取一次成功才保存（iDuanJu `addSubscription` 同款）；删除订阅只删地址，不卸载已装的插件（已装插件独立存在）。

### 4.5 更新检查（有 update.url 的才查）

- `checkUpdates()`：只对 manifest 里写了 `update.url` 的插件，拉新 manifest、比 semver，有新版才列出待安装（RE §6.2 同款）。**本案 4 个插件都没有 update.url**——所以它们不会自动检查更新，更新靠订阅里的版本号比对 + 作者发新版（订阅刷新后插件行变“更新”）。
- 手动触发：插件 tab 里的「检查更新」按钮（查 update.url 插件 + 刷新全部订阅并比对版本），结果用列表展示（有更新的逐条列出 + 「更新」按钮；无更新的 Toast “已是最新”）。
- 更新安装走同一安装链（§1.3–§1.5 全过一遍：校验 + integrity + probe + PermissionDiff 确认），同 id 覆盖、保留原启用态（§1.2）。

### 4.6 右上角「+」菜单加两项（安装入口也从这里进）

`MiniAppHomePage._showCreateMenu`（底部动作单）现有 5 项：从 zip 包安装 / 从文件夹安装 / 从链接安装 / 海阔小程序 / 刷新市场。**加两项**：

- 「安装插件文件（.idjplugin）」：走系统文件选择器挑本地 `.idjplugin` 文件 → 走安装器；完整流程与约束见 §4.2.1（只认 `.idjplugin` 后缀、不自造应用内文件浏览）。
- 「粘贴插件/订阅」：文本框对话框 → 走 `interpret`（§1.6）。

这两项与 tab 里的三个安装按钮调**同一个安装器入口**，不写两套逻辑。点完后若装成功，tab 自动切到「插件」tab 的已安装区（照 `PluginMarketScreen` 导入成功后重开弹窗切导入区的手法：`_pickSource(initialZoneIndex: 1)` 同款思路）。

---

## 5. 站点切换弹窗改成分组样式

### 5.1 截图长什么样（已亲眼看过，原图 `~/workspace/idjplugin_adapt_20261124/station_list_grouped_ref.jpg`）

- 一个「全部站源」**底部弹窗**（94 个）：顶部有拖拽条；标题「全部站源」，副标题「94 个」；右上角三个图标：星形（☆ 空心）、网格（田字格）、关闭×。
- 组标题「短剧类 11」，下面**三列网格**放圆角矩形站点卡片（红果、帝果、禁果短剧、饭果、河果、花生、猫果、短剧网站、五五、星果、芽果）；再是「视频类 16」（鬼片、韩小圈、爱看机器人、青空、笔盒、黑桃、360、真果·鉴、168影院、红牛、魔都、牛牛、闪电、无水印、影视工厂……）。
- 卡片是**纯文字**圆角矩形（无图标），当前选中的站高亮（红果是浅蓝底）。

**用户要的就是这种：魔蚁的站点列表按类别分组展示，不是平铺一长串。** 这里的“分类”指站点切换弹窗里的**站分组**，不是站内视频分类——两点都要进设计，别混成一件事（站内分类见 §6）。

### 5.2 现有弹窗长什么样（已核实）

`lib/source_picker_sheet.dart` 的 `showSitePickerDialog`（L53）+ `SitePickerDialog`：

- 今天是**居中 Dialog**（`maxWidth: 560`，`maxHeight: 屏幕高 * 0.7`），标题「切换片库源」，有关闭按钮（底部「关闭」）与搜索框（搜站点名称）。
- 分组：调用方传 `List<SourcePickerGroup>`（`title` + `entries` + `zone`）；列表区 `_listBody` 按组渲染，组标题是 `NeonSectionTitle('标题（N）')`，组内是 `_siteGrid` 图标宫格（`SiteIcon` 30 + 站名，列数随宽响应：≥480→5 列、≥340→4 列、其余 3 列，行高固定 74）。
- 选中态：主色描边 + 辉光 + 右上角 ✓ 角标；打开弹窗自动滚到当前站（`_scrollToCurrent`，`_currentKey` + `ensureVisible`）；搜索时组标题隐藏、只滤名字。
- 双区翻页：`enableZoneFlip`（只有片库传 `true`）时「内置区 / 导入区」两个区签淡入淡出切换、左右滑切区；`zone` 按 `SourcePickerGroup.zoneBuiltin` / `zoneImport` 分。
- 长按可删（导入站删文件、内置站隐藏），编辑模式删图标；右上角 `+` 号导入钮（`onImport`，只有片库传）。
- 调用方三处：片库 `lib/home_screen.dart:657` `_pickSource`（分组数据 `_sourcePickerGroups()`，L626）、内容区 `lib/content_zone_screen.dart:261`（单组、无标题）、直播 `lib/live_screen.dart:839`（「平台源」/「导入源」两组）。

片库的分组数据今天是 `SourceGroup.sectionGroups(_librarySources)`（`lib/models.dart:916`）：按**来源**分——内置短剧 / 内置影视 / 导入 / 导入配置（+ 一个标题为空的「全部站源」特殊条目 `__all__`，id `__all__`，进全部站源合并视图）。**这正是截图不要的样子**：截图按内容类别分（短剧类/视频类），不按内置/导入分。

### 5.3 分组规则：按内容类别（短剧类/视频类/午夜类）

新分组规则（实施点：`lib/models.dart` 新增 `SourceGroup.pickerCategoryGroups(Iterable<SourceSite> sources)`；`lib/home_screen.dart:626` `_sourcePickerGroups()` 改调它，不再调 `sectionGroups`）：

| 组 | 进组条件 | 顺序 |
|---|---|---|
| 短剧类 | `section == sectionDrama`（不论显示名带不带 `🔞`、不论 adult） | 第 1 组 |
| 视频类 | `section == sectionVideo` 且显示名**不**以 `🔞` 开头 | 第 2 组 |
| 午夜类 | `section == sectionVideo` 且显示名以 `🔞` 开头（`midnight_zone.dart` 的 `isAdultSourceName`） | 第 3 组 |

**分组先按 section 分短剧/视频，视频区内再按 `🔞` 分视频类/午夜类。`🔞` 只决定两件事——午夜门禁（进不进午夜门禁）和显示名前缀，不决定分组。**（用户 2026-11-24 11:49 亲口定；此前按 `🔞` 前缀分组的旧口径作废。）

- 空组不出现。组内顺序：沿用现有 `visibleSources` 的顺序（不重排；重排会打乱用户已习惯的站序）。
- **插件站同样进分组**：橙果/爱果（`sectionDrama`）进短剧类——它俩 manifest 的 `adult` 全是 `true` 也不进午夜类；潮流/2048（`sectionVideo` + 🔞）进午夜类。不需要为插件站写特殊分支——分组只看 `section`（视频区内再看 `🔞` 前缀），任何站都一样。
- **直播站不进这个弹窗**：直播是单独 tab，有自己的切换弹窗（`live_screen.dart:839`，分组「平台源」/「导入源」不动）。片库弹窗里没有“直播类”组——用户令里的“直播”是举例现有分区，不是要求把直播站塞进片库弹窗。
- `sectionGroups()`（`models.dart:916`）**本批不删**：实施前 grep 确认调用方；本批只改 `_sourcePickerGroups()` 的调用点。若改后 `sectionGroups` 无人调用，留着（删它是另一次清理，不要顺手删）。
- **与 `models.dart:848` 注释的界限（必须写清，实施工人不要“纠正”它）**：注释说“午夜区已并入统一视频区，不再按来源或 🔞 名拆成点播/午夜两个区”——管的是**浏览分区**（`isVodZoneSource`，进哪个区浏览）。弹窗里的「午夜类」组只是**展示分组**（找站时分得开），不改变任何站的浏览分区：视频分区 🔞 站仍在统一视频区浏览，只是弹窗里集中放在午夜组；短剧分区站（含带 🔞 前缀的短剧站）在短剧区浏览、弹窗里也在短剧类。两者不冲突，不要互相改。

### 5.4 弹窗改哪几个文件、怎么改

| 文件 | 改什么 |
|---|---|
| `lib/source_picker_sheet.dart` | **容器**：居中 Dialog → ModalBottomSheet（顶部拖拽条 + 圆角顶；`showSitePickerDialog` 签名 `Future<String?>` 不变，三处调用方不用改；最大高度约 85% 屏高）。**头部**：标题改「全部站源」，副标题「N 个」（可见站总数 = 各组 entries 之和，打开时算好；隐藏的站不计入——`_librarySources` 已是 `visibleSources`，见 `home_screen.dart:332`）。右上角：`+` 号导入钮（保留，只有片库传 `onImport` 时显示）+ 网格/列表切换钮 + 关闭×。**组标题**：`NeonSectionTitle('标题（N）')` 改成纯文本「短剧类 11」格式（名 + 空格 + 数，不用括号）。**卡片**：图标宫格改纯文字圆角矩形卡片——去掉 `SiteIcon`（截图无图标），三列固定（截图是三列；现有 3/4/5 响应列改固定 3 列），卡片高 44–48、圆角 12、描边；站名最多 2 行省略。**选中态**：主色描边 + 辉光 + ✓ 角标 → 改成主色浅底填充（截图的浅蓝底效果，取当前主题 `colorScheme.primaryContainer` 或主色低透明度）+ 名字加粗，**不加角标**（截图没有）。**保留**：搜索框（搜站点名称，搜时组标题隐藏的现有行为不变）、长按删除与编辑模式、自动滚到当前站（`_scrollToCurrent` 机制不动，`_currentKey` 仍挂在选中卡片上）、「全部站源」特殊条目（见 §5.5） |
| `lib/home_screen.dart:626` | `_sourcePickerGroups()`：改调 `pickerCategoryGroups`；`enableZoneFlip` 不再传（片库弹窗取消内置区/导入区翻页，见 §5.6）；其余（`onDeleteSite`、`onImport`、导入成功重开切导入区）不动。注意：导入成功后重开弹窗的逻辑（`_pickSource(initialZoneIndex: 1)`）要改——没有导入区了，改为重开后自动滚到新装的站（用 `initialZoneIndex` 的位置传新站 id，或重开后直接以新站为当前站；实施工人二选一，写进实现记录） |
| `lib/models.dart` | 新增 `SourceGroup.pickerCategoryGroups()`（§5.3 的规则）；`sectionGroups()` 不动（见 §5.3） |
| `lib/content_zone_screen.dart:261` / `lib/live_screen.dart:839` | **不用改调用代码**：样式（bottom-sheet + 纯文字卡片 + 选中浅底）自动跟随；分组数据仍由调用方给（内容区单组无标题、直播「平台源」/「导入源」两组），保持原样。影响要写进预览验收：直播弹窗至少出一张 PNG 对照 |

### 5.5 「全部站源」特殊条目与选中态、数量的算法

- **「全部站源」条目保留**：今天 `_sourcePickerGroups()` 首组是标题为空、只含 `__all__` 条目（id `__all__`，名「全部站源」）的组，点它进全部站源合并视图（`_applySourcePick('__all__')`）。截图的弹窗标题本身就是「全部站源」，但标题不能当按钮——**保留这个条目**，渲染成置顶单独一行（与分组卡片同样式、单独一行、全宽），点它回合并视图；当前是合并视图时它高亮（`currentId == '__all__'` 的现有判定不动）。
- **选中态保持**：`currentId` 由调用方传入（片库传当前站 id 或 `__all__`）；选中卡片的判定（`entry.id == widget.currentId`）与自动滚动（`_scrollToCurrent`）机制不动，只换视觉（浅底 + 加粗）。切站后关闭弹窗、调用方 `_applySourcePick(picked)` 切站并重拉分类（见 §6.4），弹窗下次打开时滚到新当前站。
- **数量算法**：组标题后的数 = 该组 `entries.length`（搜索时不显示组标题，数也不显示，与现有行为一致）；副标题总数 = 全部组 entries 之和（不含已隐藏的站；`_librarySources` 已过滤隐藏站）。`__all__` 条目不计入任何组的数量（它在组外单独一行），副标题总数也不含它（它是视图切换，不是站）。

### 5.6 内置区/导入区翻页取消（影响要写明）

- 片库弹窗今天有「内置区 / 导入区」翻页（`enableZoneFlip: true`，`home_screen.dart:657`）。分组改按内容后，导入站按分区混进短剧类/视频类/午夜类各组，**翻页失去意义，片库调用里取消**（不传 `enableZoneFlip`）。
- `enableZoneFlip` 参数与区签实现**保留在 `SitePickerDialog` 里**（直播/阅读未用它，但参数与实现是弹窗的通用能力；本批不删，删是另一次清理）。`SourcePickerGroup.zone` 字段同样保留（`_sourcePickerGroups` 不再按它分组，但字段本身是模型的一部分）。
- 用户影响：以前在“导入区”里找导入站的用户，改后在短剧类/视频类/午夜类里找（导入站仍在，且长按删除、+ 号导入都在）。预览图里要有一张含导入站（idj 插件站 + 一个 py 导入站）的分组图，证明导入站没丢。

### 5.7 星形按钮：v1 不做（不要画死按钮）

截图右上角第一个是星形（☆ 空心）。树里**没有站点收藏机制**（全树 grep `收藏站|favoriteSource` 零命中），星形在截图里的用途无法从一张静态图确定（可能是“只看收藏”，也可能是“收藏当前站”）。**v1 不画星形**：右上角只留网格/列表切换 + 关闭×。星形的用途与收藏机制一起列为待定（见 §9），等用户定用途、收藏机制立项后再加。**绝不画一个点了没反应的死按钮。**

网格/列表切换的定义：网格 = 三列纯文字卡片（默认，截图样式）；列表 = 全宽文字行（站名左对齐、选中行右侧 ✓，与 `MiniAppHomePage` 的列表行同款思路）。切换只活一会话（不持久化，与 `MiniAppHomePage` 的 `_viewMode` 同款）。

---

## 6. 站内视频分类

### 6.1 结论先行（钉死的一条）

**装上的插件站在片库里，它的站内分类必须按插件自己的来**：分类走插件 `home()` 返回的 `categories`（不是魔蚁写死），`category({id, page})` 翻页；分类名以插件返回为准，魔蚁侧不写死、不改名。

展示位置是**站内分类**（进站后的分类侧边栏 / 分类行），**不是**站点切换弹窗里的站分组（那是 §5 的事，两点别混）。

### 6.2 魔蚁现有分类 UI 是怎么做的（已核实）

| 环节 | 现状（文件 + 函数） |
|---|---|
| 分类数据从哪来 | 按站拉：`AppRepository.categories(source)`（`core_bridge.dart:2278`）。JS 站：`_jsCall(source, 'home')` → `PyContract.categoriesFromHome(home)`（`py_contract.dart:37`），读 `home['class']`（`[{type_id, type_name}]`），前置 `CatalogCategory.all`（id `''`，名「全部」）。Go 站走 `_read('categories-$source')`；jar 站走 `JarBridge.categories` |
| 分类缓存在哪 | 只缓在内存：`CatalogBrowser._menus[source.id]`（`catalog_browser.dart`，`loadCategories` 写入）。没有分类磁盘缓存（py/js/Go 站都一样） |
| 分类在哪显示 | 片库主界面：分类行（`home_screen.dart:407` `_categories` getter = `[全部, ..._categories]`）；频道页：左侧分类侧边栏 `CategorySidebar`（`lib/neon/neon_channel_view.dart:77`，首项写死 `('','热门')` + 其余分类）；内容区：`content_zone_screen.dart:172` `_loadCategories`（按站拉、首分类自动选中） |
| 切站后分类怎么刷新 | `home_screen.dart:432` `_loadCategories`（generation guard）：切组即重拉新组各站的分类；当前选中分类在新站不存在时 `_changeCategory('')` 回「全部」（`:460-464`）。内容区同款：切源清空分类并重拉（`content_zone_screen.dart:126` `_selectSource` 里 `_categories = []` 后 `_loadCategoriesWithAutoRetry()`，失败自动补拉最多 2 次） |
| 分组内分类怎么合并 | `CatalogBrowser._choices`（`catalog_browser.dart:125`）：同组多站的分类**按名字合并**，id 改写成 `category:<名字>`，再经 `choice.requests[source.id]` 还原回各站自己的分类 id 去取目录（`load()` L188-192、L258、L325）。另有本地分类：缓存过的剧按 `categoryName(item.category)` 生成 `local:<名字>` 分类（L138-148）。`categories(group)`（L152）= `[全部, ...合并后的分类]` |
| 分类名归一化 | `categoryName()`（`catalog_browser.dart:6`）：`AI成人短剧`/`AI短剧` → `AI 短剧`、`AI成人漫剧`/`AI漫剧` → `AI 漫剧`、`AI换脸` → `AI 换脸`、`AI魔改` → `AI 魔改`、`AI剧` → `AI 剧`、空 → `未分类`；其余原样。**这个函数会改写显示名**，见 §6.3 的冲突 |

### 6.3 冲突：`categoryName()` 会改写插件分类名（必须绕过）

`_choices` 合并时（`catalog_browser.dart:130`）用 `categoryName(category.name)` 作合并键与显示名。插件分类名若撞上归一化表（如橙果的 tag 里有 `AI短剧`），界面上会显示成 `AI 短剧`——与用户“分类名不改名”令直接冲突。

**定法**：`_choices` 里 idj 站的分类**绕过 `categoryName()` 归一化**——合并键与显示名都用插件返回的原名。实现方式（二选一，由实现工人定，写进实现记录）：（a）在 `_choices` 循环里，若 `source.id` 是 idj 站（`isIdjSource` 前缀判断），`name` 取原值、不调 `categoryName()`；（b）给 `categoryName()` 加可选参数 `normalize`，idj 调用处传 `false`。推荐（a），改动面最小（只动 `_choices` 一处）。

注意：本地分类（`local:<名字>`，由缓存剧的 `item.category` 生成）仍走 `categoryName()`，不动——那是魔蚁本地数据的归一化，不是插件分类名。

### 6.4 动态安装的插件站，分类落法（逐项确认）

| 问题 | 答案 |
|---|---|
| 分类来源 | 插件 `home()` 返回的 `categories`（`[{id, name}]`），经 `IdjContract.categoriesFromHome` 转成 `[全部, ...categories]`。不是魔蚁写死。`home()` 里没有 `categories` 时返回只有「全部」的列表（不要编默认分类） |
| 分类第一次从哪取 | 没有内置登记、没有写死表。进站 / 切站时 `_loadCategories` 现场调一次插件 `home()`，活取。2048 的 `home()` 会顺带拉一页视频（48 条），有浪费但可接受，v1 不做分类缓存 |
| 缓存在哪 | 只缓在内存 `CatalogBrowser._menus[source.id]`（一会话）；不另建分类磁盘缓存。插件自有的分类回退（橙果 `cg_cats_v1`）存在 Go 侧 `storage.json` 里，由插件自己读，不经过魔蚁分类缓存 |
| 切站后分类怎么刷新 | `_loadCategories` generation guard：切组重拉新组各站的 `home()`；当前选中分类在新站不存在时回「全部」（`home_screen.dart:460-464` 的现有行为，idj 站跟随）。切回某站会再跑一次它的 `home()`（内存缓存只活一会话） |
| 空分类拦截还在不在 | **在**。`catalog(category: '')` 时不调 `category({id: ''})`（潮流会抛 `E_ARGS`，橙果解析不到 `line:`/`tag:` 前缀），改调 `home()` 取 `home['items']`。拦截点在 `core_bridge.dart` `catalog()` 的 idj 分支里（见 §3.4 的表）。频道页 `CategorySidebar` 首项 `('','热门')` 点的就是这个拦截路径 |
| 翻页 | `category({id, page})`，`page` 从 1 开始；`hasMore` 为真时 `pagecount = page+1`（`IdjContract.pageFromResult`）。插件不回 `page` 字段时不补编页码 |
| 分类名 | 以插件返回为准，不写死、不改名（§6.3 的绕过是实施要点）。4 个插件的分类事实见 §6.5 |
| 「全部站源」合并视图 | `_group.id == 'all'` 时同组多站分类按名合并是现有行为，所有站都一样，idj 站跟随。插件分类与别站同名分类合并后，点该分类会同时向各站发各自的 `requests[source.id]` 取目录（`load()` L188-192）——这是合并视图的设计，不是 bug |
| 站内筛选（filters） | 插件不返回筛选数据时不画筛选区（`category_sidebar.dart` 的注释原话：“filters 只有站方真实返回筛选数据时才有，没有就不画筛选区，绝不编假筛选”）。idj 插件目前都不返回 filters，v1 不画 |

### 6.5 4 个插件的分类事实（RE §9，实施与自检以此为准，不要抄描述文字）

| 插件 | 分类来源 | 详情 |
|---|---|---|
| 橙果短剧 | **动态取** | 每次 `home()` 先调 `linesList()` 从接口 `filter_options` 里取：`line:{code}`（`lines[]` 的 name）+ `tag:{slug}`（`tags[]` 的 name，**只取前 10 个**）。manifest 描述称“5 条线路 + 15 个题材标签”，以代码为准（标签只取前 10 个）。分类拉取失败时用 `cg_cats_v1` 缓存，缓存也没有则返回空分类 |
| 潮流AV | **写死 10 个** | chinese 中文字幕、censored 有碼AV、uncensored 無碼AV、reducing-mosaic 無碼破解、amateurjav 素人AV、dt 國產自拍、animation H動畫、CensoredAnimation H有碼動畫、UncensoredAnimation H無碼動畫、tdAnimation H_3D動畫。对应接口 `/zh/{分类}_list/all/{page}.html`。`category` 校验 id 必须在表内，否则抛 `E_ARGS`“未知分类”。manifest 描述只列 7 个，以代码为准 |
| 爱果短剧 | **写死 4 个** | all 最新更新、huangguo 黄果短剧、aiguo 爱果原创、mogai 魔改短剧。未知 id 回退到 all |
| 2048AI | **全动态** | 分类来自 `/api/v1/categories?type=video` 的实时返回（`{id, name}`，过滤掉 `enabled === false` 与 `type === "post"` 的项）；失败时唯一回退分类 `{id: "27", name: "每日更新"}`。manifest 描述里的分区名（AV中文字幕、国产自拍等）是描述文字，代码里没有这些名字；**分类名无法离线列出**，自检时把当时拉到的分类名逐条记进报告 |

---

## 7. GPL-3.0 干净复写规则

iDuanJu 仓库（`my-name-is-alan/iDuanJu`）是 GPL-3.0。魔蚁只按**接口规范**自己写代码，**不直接抄 iDuanJu 源码**。

### 7.1 规范来源（可以读、可以照着写）

| 来源 | 是什么 | 用来定什么 |
|---|---|---|
| `repo/docs/plugins/SPEC_ZH.md`（idj1 草案） | 插件格式与函数契约的文字规范 | `.idjplugin` 结构、manifest 字段、export default 五函数签名、错误码表、播放 `proxy` / 图片 `transform` 声明 |
| `repo/STVTests/PluginTests.swift` 的契约 | 宿主测试里的契约断言 | 安装校验、host 行为、错误映射的期望（读断言，不抄实现） |
| `repo/scripts/pack-plugins.py`（29 行打包算法） | 打包算法 | integrity 哈希算法：entry 脚本 SHA-256 + base64 → `manifest.integrity.files[entry]`（算法本身，不是代码复制） |
| RE 报告 §2–§9 观测到的行为 | 逆向观测 | 4 个插件实际用的入口、真实返回形状、真实传参差异（§9.7）、限额数值 |
| `repo/STV/Plugins/PluginNet.swift:207-208` 的禁发头表 | 11 项禁发头清单（原 12 项减 `authorization`，用户 2026-11-24 18:40 令放行） | `host.http.request` 发请求前删哪些头（抄**清单**，不抄 `perform()` 实现） |
| `repo` 的 `DomainPolicy` 源码 | 白名单匹配语义 | `*.example.com` 匹配几层子域（实施时读一次，不要猜） |

### 7.2 必须自己重写的实现（不得粘贴 iDuanJu 的 Kotlin/Swift 代码）

- 全部 Go 代码（`app_js_idj.go`）：prelude 拼装、host 回调、HTTP、存储、Cookie 罐、白名单、限额。iDuanJu 的 `PluginGlue.PRELUDE` 字符串、`PluginHost.handle` 分发、`PluginRuntime`、`PluginStore`、`PluginVideo` / `PluginProviders` 桥接、`PluginOut` 清洗、`M3UImport` 生成逻辑，一律不得粘贴——只按 §2.4–§2.6 的接口表自己写。
- 全部 Dart 代码（`idj_plugin_store.dart`、`idj_contract.dart`、市场 tab、弹窗改动）：安装链、解释器、订阅、注册、形状翻译。iDuanJu 的 `PluginManifest.kt` / `PluginBundle.parse` / `PluginStore.kt` / `PluginsScreen.kt`，一律不得粘贴——只按 §1.3–§1.8 的规则自己写。
- 测试夹具：Go/Dart 测试里用的迷你合成插件脚本，**新写**（几十行，只够覆盖 `home/category/search/detail/play` 各一次），不得把 4 个真实 `main.js` 的片段粘进测试。

### 7.3 插件文件本身的边界

- 4 个 `.idjplugin` 是用户发来的第三方插件内容（作者 @yydsys），魔蚁**运行时原样加载**（不改 `main.js` 一字，包括 play 传参修复都做在加载器/桥接层，见 §3.6），**不提交进魔蚁树**（不进 `assets/`、不进测试固件）。Go 加载测试要覆盖真插件时，读工作目录外的 `~/workspace/idjplugin_adapt_20261124/plugins/*.idjplugin`（测试里文件不存在时跳过，不硬编码进树）。
- 4 个 `main.js` 里的手写 AES 密钥/IV 是写死在插件里的站方密钥（RE §9.3：`KEY = "2acf7e91e9864673"`，`IV = "1c29882d3ddfcfd6"`）——那是插件内容的一部分，运行时在 goja 里原样跑；**不要把密钥抄进魔蚁代码、文档或记忆**（本文不复述除这一处说明外的任何密钥；实现工人也不得把插件内密钥提取出来另作他用）。

---

## 8. 实施顺序、测试计划与预览图计划

### 8.1 实施顺序（共 7 步，每步都有可验的出口）

| 步 | 做什么 | 出口（验收） |
|---|---|---|
| 0. **预览图先行** | 分组弹窗 PNG + 插件 tab PNG + 安装确认 sheet PNG（§8.3） | 用户看图点头，再写实现代码（用户 2026-10-27 令：每个界面都要出预览图片和图纸，用户满意之后才动手实现） |
| 1. Go 兼容层最小集 | `native/core/app_js_idj.go`：先落加载器行级兜底（探针方案 A），再写 `idjCall` + prelude（三入口）+ `"idjCall"` action + 持久化目录 | §8.2 的 Go 测试全过（含 Cookie 跨调用、存储跨调用、禁发头剥离、小写响应头、play 传参 4 站 fixture、60 次上限） |
| 2. Dart 安装器 | `lib/idj_plugin_store.dart`：解析/校验/integrity/probe/写盘/索引/注册/启动恢复 | `test/idj_plugin_store_test.dart` 全过；`flutter analyze` 0 错 0 警告 |
| 3. Dart 桥接 | `lib/idj_contract.dart` + `core_bridge.dart` 五处分流 + 空分类拦截 + `duanjuOnlineSearch`/`duanjuPaged` 规则式改动 + `_choices` 里 idj 分类绕过 `categoryName()` | `test/idj_contract_test.dart` 全过；现有 `PyContract` 测试零回归 |
| 4. 市场 UI | `MiniAppHomePage` 加「插件」tab + `+` 号菜单两项 + 安装确认 sheet + 订阅管理 + 更新检查 | widget 测试全过；实现后重渲预览图与步骤 0 的图对照，用户终认 |
| 5. 分组弹窗 | `source_picker_sheet.dart` 改 bottom-sheet 分组样式 + `home_screen.dart` `_sourcePickerGroups` 改按内容分组 + `models.dart` 新增 `pickerCategoryGroups` | `test/site_picker_grouped_preview_test.dart` 的 PNG 与截图一致（组标题 + 数量 + 三列网格 + 选中高亮）；直播/阅读弹窗样式跟随、分组数据不动 |
| 6. 逐站交付门自检 | 4 个插件走安装流程装进再验（§8.4 的表，联网实测） | 每站分类/翻页/详情/搜索/真播五项结果 + 未验项清单。爱果 ep≥2 登录墙、2048 动态分类名、潮流换站耗时如实写进报告 |
| 7. 回报定夺 | §9 的待定项随自检报告一起报，等一句话再合树 | 合树与构建另等用户令（构建令在用户手里，用户 2026-10-31 令） |

步骤 1 与步骤 5 无依赖，可并行；步骤 0 的预览图是两路共用的前置门。

### 8.2 测试计划

**命令（以树内既定口径为准，不新发明）**：

- Dart 静态检查：`~/workspace/tools/flutter/bin/flutter analyze`（好 SDK 在 `~/workspace/tools/flutter`，`~/flutter/bin` 那个是坏的；见 `~/TOOLS.md`）。**要求 0 错 0 警告**。
- Dart 测试：`TMPDIR` 指到 workspace 大盘（`/tmp` 只有 512M），加 `--no-pub`（见 `~/AGENTS.md` 2026-11-24 两条）。形如：`TMPDIR=~/workspace/tmp/flutter_test ~/workspace/tools/flutter/bin/flutter test --no-pub test/idj_contract_test.dart test/idj_plugin_store_test.dart`。
- Go 测试：`cd ~/workspace/moyi_idjplugin_20261124/native && ~/workspace/tools/go1.26.0/bin/go test ./core/ -run 'TestJsSpider|TestIdj' -v`（Go 用 `~/workspace/tools/go1.26.0/bin/go`，`go.mod` 要求 1.26.0）。`go test ./...` 全量只在改动波及面大时跑，平时跑 `./core/`。
- **不构建、不提交、不推仓**：本批只做到“树内改完 + analyze + 测试过”，手机验播等用户令。

**新增测试文件**：

| 文件 | 覆盖内容 |
|---|---|
| `native/core/app_js_idj_test.go`（新；探针文件 `app_js_idj_probe_test.go` 保留作 P0 证据） | ① 加载器行级兜底：4 个真插件原文件加载 + 5 个入口全找到（探针已过，落正式代码后改回严格断言）。② `host.http.request`：对本地 `httptest` 发 GET/POST，断言禁发头被剥、响应头键全小写、method 省略为 GET、timeout 毫秒生效、超 20MB 报错、白名单外域名报 `E_PERMISSION`。③ `host.storage`：`set` 后新 runtime `get` 能读到（持久化）、1MB 上限拒绝、不同插件互不可见。④ `host.error`：`throw host.error('E_PARSE','…')` 回到 Go 侧带 `.code`。⑤ play 传参：4 站各一个 fixture，断言插件收到的 `id` 是分集键（橙果断言不是第 1 集）。⑥ Cookie 罐：两次调用间 Set-Cookie 能带到下次请求。⑦ 限额：60 次/调用、120 次/分钟、20MB 体。⑧ 完整性：改过一个字节的脚本拒绝加载 |
| `test/idj_plugin_store_test.dart`（新） | manifest 校验 problems()（合法通过；id/版本/entry/域名/能力缺失各拒一个）；integrity 扁平串与对象形态都接受、值不对拒装（4 个的真值见 RE §9.2，实施时以原文件重算为准）；订阅解析（manifest 相对地址解析、不自动装）；索引读写（启用/停用/卸载/重装保留启用态）；站 key 生成（`idj_` 前缀，`chaoliu` 不被抢） |
| `test/idj_contract_test.dart`（新） | `IdjContract` 四函数：`categoriesFromHome`（读 `categories`、前置“全部”）；`pageFromResult`（`{items, hasMore}` → `CatalogPage`，`hasMore` 为真时 `pagecount = page+1`）；`detailFromResult`（`lines` → 多线路 `Episode`，`flag` 是线路名、`id` 是分集键）；`planFromResult`（`streams[0]` → `PlaybackPlan`，`expiresAt` 透传、空 `streams` 时 url 为空）。fixture 用 RE §9.3–§9.6 里的真实返回形状（不要编字段） |
| `test/site_picker_grouped_preview_test.dart`（新，预览图） | 分组弹窗渲染 PNG（§8.3） |
| `test/idj_plugin_tab_preview_test.dart`（新，预览图） | 插件 tab + 安装确认 sheet 渲染 PNG（§8.3） |
| 现有测试（回归，必须过） | `native/core/app_js_spider_test.go`、`app_js_spider_compat_test.go`（现有 JS 蜘蛛零回归）；`test/builtin_py_sites_test.dart`、`test/chaoliu_registration_test.dart`（注册表零回归，尤其 `chaoliu` key 未被抢）；`test/content_py_test.dart`、`test/py_contract_full_protocol_test.dart`（`PyContract` 未动）；`test/sources_test.dart`、`test/playback_loader_test.dart`、`test/playback_policy_test.dart`（调用链零回归）；`test/midnight_zone_test.dart`（`🔞` 谓词未动）。`test/actress_test.dart` 有 9 个基线旧败（6 个 pumpAndSettle 超时 + 3 个文案不一致），**只要求与基线一致、不新增失败**，不要顺手修它 |

### 8.3 预览图计划（UI 先出图，再动手实现）

范式照 `test/actress_group_preview_test.dart`（只做测试内截图，不改业务代码；`pumpWidget` + `toImage`，PNG 落 `~/workspace/moyi_previews`；调过 `toImage` 的测试在收尾时会挂起——跑单测、超时杀掉只取 PNG；**绝不把预览文件与普通测试批量跑在一个调用里**，见 `~/AGENTS.md` 2026-11-16 教训）。

| 图 | 测什么 | 假数据（测试内合成，不用真站数据） |
|---|---|---|
| 分组弹窗-默认 | 底部弹窗：标题「全部站源」+ 副标题「N 个」；短剧类/视频类/午夜类三组（组标题 + 数量）；三列纯文字卡片；选中站浅蓝底 + 加粗；置顶「全部站源」行 | 假站 12 个：短剧 5（含 1 个 idj 假站，其中 1 个短剧站带 🔞 前缀，验收它仍在短剧类、不进午夜类）、视频 4、午夜 3（含 `🔞潮流AV`、`🔞2048AI` 假站）；当前选中一个短剧站；另含 1 个 py 导入站，证明导入站没丢 |
| 分组弹窗-午夜组 | 午夜组单独成组、视频分区 🔞 站集中（短剧 🔞 站不在此组）；选中一个午夜站时高亮正确 | 同上，当前选中 `🔞潮流AV` 假站 |
| 分组弹窗-直播对照 | 直播弹窗样式跟随（bottom-sheet + 纯文字卡片），分组仍是「平台源」/「导入源」 | 假直播站 4 个（平台 2、导入 2） |
| 插件 tab | 「插件」tab：已安装区（2 个已装 + 1 个已停用置灰 + 1 个已损坏）、安装入口三按钮、订阅区（1 条订阅展开 2 个插件 + 1 个 cms 行）、「检查更新」按钮 | 全假数据；插件名用 4 个真插件的名字（名是事实，不涉代码复制） |
| 安装确认 sheet | 确认 sheet：名/版本/id/类型/adult 标记/域名数/简介 + PermissionDiff 差异行（更新场景）；成人提示文案按分区写（见 §4.3） | 假 manifest（橙果形态：短剧站、adult true、域名 7 个）——该 sheet 上显示短剧区文案“装好后进短剧区”，不要写成午夜组文案 |

预览图出完先给用户看，**用户点头再写实现代码**；实现后再重渲一遍对照（实现后的图与预览图不一致时以用户终认为准）。

### 8.4 逐站交付门自检（4 个站，走安装流程装进再验）

通用门（用户 2026-10-23 定）：分类首页非空有真封面、主页与内容分类翻页、详情完整、搜索出真结果、`playerContent` 现取真实地址并以其自带 header 验真播（HLS 拉首分片、直链 Range 206 + 魔数）。**本机出口验不了的先换路子，全路子仍验不了不许以“待用户终验”口径推送——先停下报清未验项与卡点**（同条令）。

安装方式：4 个插件一律走本地导入（§4.2.1，从文件安装）装进——用户发来的 `.idjplugin` 文件就是验收的输入；不走网址安装、不内置。

| 站 | 验什么 | 关键断言 / 卡点 |
|---|---|---|
| 橙果短剧 | 安装：走安装流程装进（扁平 integrity 兼容 + probe 通过）；分类首页：`home()` 返回的动态分类（`line:` + 前 10 个 `tag:`）每类第 1 页非空有真封面；翻页 `page=2` 与第 1 页零重叠；详情：数字 id → 标题/简介/tags/总集数齐，分集数与 `total_episode_count` 对得上；搜索关键词出真结果；取流：点第 N 集（N>1）播的确实是第 N 集（**§3.6 的回归点**，用 `play` 返回的 `media.source_url` 里的集号或分片地址核对，绝不能只验第 1 集）；手写 AES-CBC 解密在 goja 里跑通 | 封面走 `/_img/` 代理（base64 无 `=` 填充），验封面 URL 能下载；分类拉取失败时 `cg_cats_v1` 缓存回退要能工作（断网一次看分类是否还在） |
| 潮流AV | 安装同上；10 个写死分类逐个首页非空；翻页；详情 `ld+json` 标题/封面/简介/番号/时长齐，`lines` 为 mvarr 多画质线；搜索出真结果；取流：点某线路某集，`play.php` 回真 m3u8（拉首分片验），且**线路选择生效**（点 720P 不出 1080P 的流）；年龄验证：首次调用过验证页后，后续 `home/category/detail/play` 不再撞验证页（Cookie 罐持久化的验收标准） | 域名轮换（15 个 mjv 域名）与重试预算：单次调用请求数记数，撞 60 上限时报错信息要带插件名；`media` 域名含 `streamfastpro.com`，手机上播不播得通是**未验项**（本机出口可能 403） |
| 爱果短剧 | 安装同上；4 个写死分类首页 + 翻页；详情 `admin-drama-<slug>`，分集按集号升序、`episodeId`（UUID）齐；搜索出真结果；取流：**第 1 集真播**（`POST /api/ui/episodes/{eid}/playback` 回 `playUrl`，HLS 首分片验）；**第 2 集预期失败**：返回插件原话“这一集要登录爱果账号才能看，目前每部第 1 集可直接播”，不要把它修成静默空列表，也不要冒充能播 | 登录墙是站方行为，不是 bug；自检报告里写明“除第 1 集外需登录，魔蚁侧无登录能力” |
| 2048AI | 安装同上；分类动态取：`home()` 返回的分类与 `/api/v1/categories?type=video` 实时返回一致（失败时唯一回退 `{27 每日更新}`）；分类翻页 `hasMore = page*30 < total`；详情单线路单集；搜索出真结果；取流：`verifyStream` 两次验 `#EXTM3U` 通过，返回代理地址 `…/api/v1/m3u8/proxy?path=…`，HLS 首分片验；代理验不过且原地址是 `.m3u8` 时回退直连流 | 分类名**无法离线列出**（接口实时返回），自检时把当时拉到的分类名逐条记进报告；`acfan.ymkizv84.work` / `gwbe.jw5cqzrc.work` 两个域名在 JS 里未出现（RE §9.8-6），只在 media 白名单里，验播时看分片是否真走它们 |

**本机出口验不了的未验项（实施后填实测结果）**：4 站的真播都可能受本机出口限制（数据中心出口对部分成人站 403、MissAV 播放地址本机拉不到是前科）。若本机 `host.http.request` 能通站方 API 但播放器直链被拦，分开写：**“站方接口通、取流地址已拿到、首分片本机拉不到”**，不要写成“站死了”或“已验真播”。潮流的 `streamfastpro.com` 系分片域名与 2048 的 `*.ymkizv84.work` / `*.jw5cqzrc.work` 代理分片：本机直连结果与手机结果可能不一致，**手机实测是唯一终验**。2048 的实时分类名、橙果的动态 `line:`/`tag:` 列表：只有联网拉到才算数，实施前不要把 RE 报告里的描述文字当分类表写进代码或测试。

---

## 9. 待父级/用户定的事项清单

以下事项**不定也能跑通 v1**，但不要擅自替用户定，随自检报告一起报，等一句话再合树：

**已定（2026-11-24 用户亲口，不再待定）**：

| # | 事项 | 定下的口径 |
|---|---|---|
| D1 | 切换弹窗分组规则 | 分组按站的分区（section）走：短剧站不论名字带不带 🔞 都留短剧类；🔞 只决定午夜门禁与显示名前缀，不决定分组。午夜类 = 视频分区 + 🔞 前缀。见 §5.3 |
| D2 | 安装确认 sheet 成人提示文案 | 文案按分区写，不按 adult 字段写：短剧分区写“装好后进短剧区”，进午夜区的站才写“装好后进午夜组，默认不对新用户显示”。橙果/爱果（adult=true 但进短剧区）用短剧区文案。见 §4.3 |

以下 14 项仍待定，一条都不许擅自定掉：

| # | 事项 | 现状与建议 | 不定会怎样 |
|---|---|---|---|
| 1 | `host.version.app` 取值 | 建议 `"1.5.2"`（所实现的 idj1 宿主规格水平；4 个插件 `minAppVersion` 都是 1.5，用 Go 核版本 `0.2.19` 会拒装全部 4 个）。见 §2.4 | 实现工人按建议值写；改只是一行常量 |
| 2 | CF 后续接法 | v1 只报 `E_CF_REQUIRED`（4 个插件 `cloudflare: false`，用不上）。后续二选一：（a）指纹升级（`Downloader.doPreparedCatalogRequest` + `huangguoBrowserTransport`）；（b）新造可见 WebView 人工验证页（`importCookies` + `learnedUA`，与 iDuanJu Android 同款）。见 §2.6 | v1 不影响；有盾插件出现时再定 |
| 3 | 内容过滤是否补 | iDuanJu 有 `ContentFilter`（标题/标签含 `萝莉`、`正太`、`高中生`、`JK`、`teen`、`schoolgirl` 等词的结果宿主侧丢弃，插件无法关闭）；魔蚁没有。补过滤与用户 2026-11-05“写源照站原样写，不按标签删”铁律冲突，**需用户亲口定**，本设计不擅自加 | v1 不补；这些标题原样出现 |
| 4 | 成人门禁深度 | v1 是 🔞 前缀 + 午夜组（仅视频分区 🔞 站；短剧 🔞 站留短剧类，见 §5.3）+ `defaultHiddenSiteIds` 加两个成人站 key（只影响新用户；只是默认不显示，不是访问控制）。档案级真门禁（导入站也走档案开关）要不要做，需定——做了会改变全部导入站的放行逻辑 | v1 按 §3.7 三件套；深链仍能打开导入 🔞 站 |
| 5 | 新站默认可见 | 建议 `defaultHiddenSiteIds` 加 `idj_chaoliu`、`idj_ai2048`（只影响从未配过隐藏列表的新用户）；短剧两站默认可见 | 不定就先不加（4 站默认全可见） |
| 6 | idj 潮流与现有 py 潮流 / jar `ZakaChaoliu` 并存 | 站 key 不同但内容同源：聚合搜索会出重复结果，女优库刮削会多一个同源站。是否把 `idj_chaoliu` 排除在聚合搜索/刮削之外，或下线 py 潮流 | v1 默认并存、如实报重复 |
| 7 | 订阅里的 cms 条目接线 | v1 只展示、不接线（魔蚁侧有无“一键加 CMS 站”入口未核实，`lib/subscription_entries.dart` 未读） | 实施前核实，有入口就接、没有就保持只展示 |
| 8 | 插件存储根目录与索引选型 | 建议：包文件 `documents/idj_plugins/<id>/bundle.idjplugin`，Go 运行态 `engine.directory/idj/<id>/`，索引 SharedPreferences `moyi_idj_plugins` | 实现工人按建议写；改只是路径与键名 |
| 9 | 切换弹窗星形按钮 | v1 不做（树里无站点收藏机制）。星形的用途与收藏机制是否立项，需用户定 | v1 右上角只留网格/列表切换 + 关闭 |
| 10 | `host.storage` 同步还是异步 | RE §9.1 的用法像同步；实现工人写 `app_js_idj.go` 之前，必须以 `plugin_js_analysis.md` 里的解码源码为准再确认一次 | 确认前不动手写 host 桥 |
| 11 | iOS 侧核查 | `ios/QuickJSBridge/` 是否另有 JS 引擎、会不会与 goja 冲突，未核实；实施前读一次再定 | 若无关则无影响 |
| 12 | 60 次/调用上限与潮流重试量 | v1 照抄 60 上限（撞线报 `E_RATE_LIMIT`，信息带插件名与已用次数），不改插件重试逻辑；撞线频率由实测定 | 频繁撞线再议（收紧重试是改 `main.js`，本批不动） |
| 13 | 插件设置 UI | 4 个插件 `settings` 全空；有设置的插件出现时，设置 UI 与 `host.settings` 真值再立项 | v1 `host.settings` 返回 `{}` |
| 14 | 导入成功后弹窗重开逻辑 | 没有导入区了，`_pickSource(initialZoneIndex: 1)` 的重开逻辑要改（§5.4）：重开后自动滚到新装的站，或重开后直接以新站为当前站；实现工人二选一，写进实现记录 | 小体验点，不拦 v1 |

---

## 附录：接线点速查

（完整接线点全表见 `adapt_plan.md` 附录；这里只列本设计正文引用过的关键点，实施时以 adapt_plan 附录为准。）

**Go 核**：`native/go.mod:24`（goja 版本）；`native/core/app_js_spider.go:21/28/77/240/272/377/533/551/569/597/763/779/852/961`；`native/core/app_js_spider_compat.go`（`jsStripModuleSyntax`）；`native/core/app_runtime.go:105/232/330/435/449`；`native/core/network_limiter.go:236`；`native/core/network_browser.go`；`native/core/provider_huangguo.go:1376`；`native/core/app_cenc_stream.go:513`；`native/core/media_playlist.go:11`；`native/core/network_media.go:176`。

**Dart**：`lib/models.dart:48/62-63/773/782/784/789/825/848/850/852/916/971/1451`（`duanjuOnlineSearch` / `duanjuPaged` 在 `models.dart` 内，行号以实施时 grep 为准）；`lib/core_bridge.dart:838/841/874/2155/2215/2278/2314/2388/2477/2572/2731/2811/2976/3231`；`lib/py_contract.dart:15/37/103/114/177`；`lib/idj_contract.dart`（新建）；`lib/idj_plugin_store.dart`（新建）；`lib/main.dart:168`；`lib/plugin_manager.dart:138`；`lib/import_file_store.dart:16/28`；`lib/imported_site_record.dart:25/68`；`lib/midnight_zone.dart`；`lib/local_store.dart:182/234/388`；`lib/local_profiles.dart:27`；`lib/hero_mix.dart:46`；`lib/player_screen.dart:1528/1793/1944/1826`；`lib/tvbox_video_pane.dart:209/243`；`lib/catalog_browser.dart:6/125/152/161`；`lib/category_sidebar.dart`；`lib/home_screen.dart:332/334/407/432/460-464/626/657/2818/3500`；`lib/source_picker_sheet.dart:53`；`lib/content_zone_screen.dart:172/261`；`lib/live_screen.dart:839`；`lib/neon/neon_channel_view.dart:77`；`lib/miniapp/mini_app_home_page.dart`；`lib/miniapp/mini_app_store.dart`；`lib/miniapp/mini_app_manifest.dart:89/129`；`lib/miniapp/mini_app_settings.dart:13/22`；`lib/plugin_market_screen.dart`（idj 不用，勿往里加入口）；`lib/hongguo_drama_home.dart:1108`。

**测试**：`native/core/app_js_idj_test.go`（新建）、`native/core/app_js_idj_probe_test.go`（已有，未提交，保留）、`test/idj_plugin_store_test.dart`（新建）、`test/idj_contract_test.dart`（新建）、`test/site_picker_grouped_preview_test.dart`（新建）、`test/idj_plugin_tab_preview_test.dart`（新建）。

**插件侧事实来源**：`~/workspace/idjplugin_adapt_20261124/RE_REPORT.md`（§8 APK 逆向、§9 四个 `main.js` 分析、§10 适配判断）、`~/workspace/idjplugin_adapt_20261124/plugin_js_analysis.md`（解码后源码精读）、`~/workspace/idjplugin_adapt_20261124/probe_report.md`（P0 探针）、`~/workspace/idjplugin_adapt_20261124/plugins/*.idjplugin`（4 个整包原文件；实施时以此为准重算哈希，**绝不提交进魔蚁树**）、`~/workspace/idjplugin_adapt_20261124/station_list_grouped_ref.jpg`（分组弹窗截图）。

---

*设计员注：本文只产出设计，不动任何实现代码、不跑测试、不构建、不提交。实施工人按本文 + adapt_plan 附录施工；凡本文写“待定”的，施工前先报父级确认，不要擅自定。*
