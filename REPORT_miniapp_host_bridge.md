# 空壳版小程序宿主数据桥 — 交卷报告

- 批次：空壳版小程序宿主数据桥（用户 2026-11-26 17:31 令「全部修复更新补上」，此前挂起的裁量项按「接」执行；17:38 用户在主聊亲口「同意」放行工作树后全量开工）
- 基线：`ed69442`（v68 组装树顶端），分支 `miniapp-host-bridge`，工作树 `~/workspace/moyi_miniapp_host_bridge_20261126`
- 状态：**本地提交，未推仓、未构建**
- 改动文件：`lib/miniapp/mini_app_sources.dart`、`test/mini_app_sources_test.dart`（仅此两处实现/测试文件，其余契约面未动）

## 一、问题

空壳剥离批（afbdf9f）剥空内置登记后，`HostMiniAppSourceProvider` 只读内置登记：jar 侧只认 zakatv/missav30 两张静态表，py 侧只认 `SourceSite.importedSites` 里 origin=builtin 的条目。空壳版里内置 py 注册已停、jar 静态表为空，「用宿主站取数」类小程序拿到空清单；带站点版同样受限——用户自己导入的站、配置带来的站、插件市场装回的站，小程序一律取不到。

## 二、汇合口径（本批实现）

数据源改为汇合现有全部可用注册表，落点只在 `HostMiniAppSourceProvider` 三处，小程序侧接口签名（`MiniAppSourceProvider` 契约、`source.*` 信封、60 秒超时、并发 3 上限、错误码）一字未动：

1. **listSites()**：清单分两段，顺序固定。
   - **内置段**：构成与顺序与汇合前一字不变——jar 静态表（zakatv + missav30，跳 audioOnly）＋注册表里 origin=builtin 的 py 条目；`available` 口径不变（jar 看 `JarBridge.isJarSource`，py 看 `importedPyFiles` 是否有文件）。
   - **汇合段**：遍历注册表其余条目追加——importType 为 `py`/`jsonlist` 的站（type 记 `py`，available 同 py 口径），以及 id 在 jar 桥已注册 spec 的站（type 记 `jar`，available=true）。jsonlist 登记执行时走生成的 py 蜘蛛，与宿主 `NativeRepository.isPySource` 同口径。
   - **去重规则**：全表按站 id（`key`）去重，先到先留。真实重复来自 ZakaTV jar：内置 jar 站经 `JarImport._registerBuiltin` 还会在注册表留一条同 id 的 import/jar 登记——去重后只保留内置段那条，位置与字段都不变。
2. **_resolveSite()**：先走原内置 jar 静态表路径（完整 id 与短 key、未注册报 SITE_UNAVAILABLE 的口径不变）；未命中再认 jar 桥已注册的任意 spec（按完整 siteId）；再认注册表里 importType 为 `py`/`jsonlist` 的任意来源条目（内置/导入/配置/插件装回）；都不中报 SITE_NOT_FOUND（文案由「未找到内置站点」改为「未找到站点」）。
3. **proxyFetch()**：与 _resolveSite 同步放开——注册表里 importType 为 `py`/`jsonlist` 的任意来源条目都可走蜘蛛 localProxy 取图；非 py 站与未知站仍报 SITE_NOT_FOUND。

取数链不新造：jar 经 `JarBridge.callJson`、py 经 `PyBridge.call`（含 `_resolvePyPath` 的已保存文件→懒加载缓存两级，与原提供者一致）。

## 三、两版清单构成对照

| | 带站点版 | 空壳版 |
|---|---|---|
| 汇合前 | 内置 jar 静态表 + 内置 py；导入/配置/市场装回的站小程序不可见 | 清单为空（jar 表空、builtin py 注册已停） |
| 汇合后 | 内置段**不缩水、不变序**（单测逐项断言）；其后追加用户导入 py/jar/jsonlist 站、配置 py/jar 站、市场装回的 py/jar 包站 | 内置段为空；用户从插件市场装回的 jar/py 包站、自行导入的 py/jar/jsonlist 站进入清单，小程序可正常取数 |

## 四、明确不在汇合集内的站（残留边界，如实标注）

- **JS 蜘蛛站与 idj 插件站**（importType=`js`，含 `idj_` 站）：其取数链是 `NativeRepository` 的 Go 核调用（`jsSpider`/`idjCall`），绑在带用户权限校验与插件失败看门狗的实例上，本提供者现有的 jar/py 两条静态链都够不着。要接就得给提供者新接一条 Go 核调用通道（或把仓库实例注入构造点），超出本批三处改点范围——本批不列入清单、解析报 SITE_NOT_FOUND，**不冒充可达**。小程序里这类站仍不可用，待主聊裁量是否单独立项接线。
- **HTML 导入站**：不是蜘蛛形态（点选进宿主页面），无目录/取流链，不在列。
- **Go 核站与配置里的非蜘蛛条目**（红果等）：与汇合前一致，不在此列。
- **远程 py 站的冷启动**：配置带来的远程 py 站若从未在主界面打开过、文件未落盘，提供者沿用原 `_resolvePyPath` 口径报 SITE_UNAVAILABLE（清单里 available=false）；在主界面打开过一次后文件就位即恢复。此为提供者既有边界，本批未扩围处理。

## 五、验证

- `test/mini_app_sources_test.dart`：基线 27 条全过 → 改后 **28 条全过**（新增「汇合站经现有链解析取数」1 条；清单测试改汇合口径断言：内置段条数/顺序/available 不变、去重、汇合段构成与顺序、JS/idj 不进清单；未知键测试改断言 JS/idj 仍 SITE_NOT_FOUND；proxyFetch 测试改任意来源 py 放行）。
- 相邻文件：`test/mini_app_server_test.dart`、`test/mini_app_test.dart` 改后全过。
- `test/mini_app_builtin_test.dart`「内置包资产完整性（磁盘实测）」1 条失败——**干净基线（stash 后）在本工作树同挂**，是工作树资产实测环境问题，非本批引入。**0 新增失败**成立。
- analyze（改动两文件）：0 错 0 警；仅 3 条 info 级 `prefer_initializing_formals`，都在未改动的构造函数初始化列表上（基线原样）。
- 测试按仓库惯例：`flutter test --no-pub`、TMPDIR 指 workspace 大盘、同树单 flutter 串行。

## 六、手机终验项

1. **空壳版**：装一个插件市场 jar 包站（或 py 包站）后，打开一个靠宿主站取数的小程序（source.* 清单类），清单里应出现该站且能打开分类/详情/取流出画。
2. **空壳版**：导入一个 py 站后，同上验清单出现该站、封面（proxy:// 改写）能显示。
3. **带站点版回归**：小程序宿主站清单里内置站顺序与构成与 v68 一致（内置在前），导入站跟在后面；内置站取数照常。
4. 已知边界（预期行为、非故障）：小程序清单里不会出现 idj 插件站与导入的 JS 蜘蛛站（见第四节，待裁量立项）。
