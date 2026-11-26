# py 导入注册站点不显示文件名——修复报告

- 用户实报：2026-11-26 13:10 主聊「py 导入注册站点不显示文件名」。
- 工作树：`~/workspace/moyi_py_import_name_20261126`，分支 `py-import-name`，基线主树 main `efd0049`。只本地提交，未推仓、未构建、未发 TG。

## 一、现状根因（文件与行号级证据）

显示名链条：导入登记 `ImportedSiteRecord.name` → `LocalStore._syncImportedRegistry()`（lib/local_store.dart:361）→ `ImportedSiteRecord.asSite`（lib/imported_site_record.dart:64，name 原样进 `SourceSite`）→ 站点列表。登记名写错，后面全错。

写错点只有一处：`ImportEngine._importPy`（lib/import_center.dart，基线行号）：

1. 基线第 221 行：先以 `name: candidate.baseName`（文件名去后缀）登记——这一步是对的；
2. 基线第 232–250 行：随后 ping 蜘蛛（10 秒超时），拿到 `ping['name']`（蜘蛛自报的 getName），非空且与文件名不同就 `records[index].copyWith(name: spiderName)` **把登记名覆盖成蜘蛛自报名**，返回的 `siteName` 也随之变蜘蛛名，导入备注带「蜘蛛名为“X”，已同步」；
3. 只有 ping 超时/失败（外层 `catch (_) {}`）才保留文件名。所以常态下（ping 成功）站点显示蜘蛛自报名、看不到文件名，与用户实报一致。

实证（同一支只用旧 API 的临时测试，mock py 桥让 validate 回 ok、ping 回 `{"name": "样例站"}`，导入 `mysite.py`）：

- 旧代码：登记名 = `样例站`（siteName 同）；
- 新代码：登记名 = `mysite`（siteName 同）。

其余入口不是问题源：导入中心屏（import_center_screen.dart:160）、站点列表加号/站点导入流（site_import_flow.dart:307）、导入区（import_center_section.dart:158）、插件市场（plugin_market_screen.dart:217/319）、分享打开（plugin_share_intent.dart:171/199/228）、外部分享（external_py_import.dart:240）、shared_json_import.dart:158、zip_install.dart:162 全部汇入 `ImportEngine._importPy` 一处，改一处全入口一致。`py_lazy_fetch.dart` 只管远程配置站的蜘蛛文件懒下载，不写登记名；`core_bridge.dart` 的 pyPing 只读 filled 方法集，不改名。

附带查实的两点：

- `ImportCandidate.baseName`（基线第 33–36 行）只去后缀、不去路径：zip 包内条目、带目录的候选名会把路径带进站名。jar 侧有 `JarImport.fileBaseName`（jar_import.dart:153）专门剥路径，py 侧缺这一层。
- 同名序号：py 侧只有 `_uniqueId` 给 id 加 hash 后缀保唯一（基线第 165–178 行），**显示名无序号、无基准名概念、无删后重排**——同名文件（内容不同）重复导入会出现两个一模一样的名字。jar 侧有定版机制：`StandaloneJarSite.baseName` + `_renumberBase`（jar_import.dart:179，注册与删除都重排）。

## 二、改法（与 jar 定版口径对齐）

1. **站名以文件名为准**：`_importPy` 删除 ping 改名整段，登记名与返回 siteName 恒为文件名口径，备注去掉「蜘蛛名为“X”，已同步」。ping 在该函数里的唯一用途就是改名，删后导入也不再被 ping 最长拖 10 秒。playOnly/filledNote 备注逻辑原样未动。
2. **文件名口径补剥路径**：`ImportCandidate.baseName` 改为先剥目录段（`/` 与 `\`）再去后缀，与 jar 的 fileBaseName 对齐；jar/zip/json 分支共用此 getter，剥路径对它们无害或更对。
3. **基准名 + 同名序号（jar 同款）**：
   - `ImportedSiteRecord` 新增 `baseName` 字段（JSON 键 `baseName`，旧登记缺失时回落 name 本身，旧数据零扰动）；py/js 登记时写文件名口径，jsonlist 写其内容推导名，html 写其内容名。
   - 新增纯函数 `renumberImportedSiteRecords`（lib/imported_site_record.dart）：按基准名分组，单条显示名=基准名（不带号），多条按列表顺序编号 1/2/3…。
   - 收口在 `LocalStore.syncImportedSites`：全部增删入口（导入引擎、导入中心删除、站点导入流、插件市场、首页）落盘前统一重排——导入同名自动编号、删除后自动重排、剩一条自动回不带号原名，各入口不用各自挂逻辑。`_loadImportedSites` 启动加载后也重排一遍（只改内存），保证重启前后编号一致。
   - `_importJsonList` 的 ping 确认名同步写进 baseName，保住它原有的确认结果不被统一重排拉回内容推导名；jsonlist 的命名来源（内容推导）本身未动，不在本批口径内。
4. **与 jar 口径的唯一差异**：jar 的 `_renumberBase` 还把 jar 子系统内置同名站计入组大小；本批只在导入登记内部编号。理由：py 文件名与内置站中文展示名同名的概率极低，且内置站名不在导入登记表内、无统一枚举点。为这一项耦合全局站点注册表（时序不可靠）不划算，如实记在此处。

## 三、与巨型 py 导入修复批（b85c85d）的衔接

- b85c85d 只在 `_importPy` 备注里拼了 `hostNote`（校验超时降级放行），**未动 ping 改名段**，与本批接触面仅备注字符串一行。组装时以「保留 hostNote、去掉 nameNote」合并即可，不会丢它任何逻辑（missingCore/filledNote 都在校验器侧，本批未碰）。
- 本批基线备注里 playOnly 文案仍是基线旧句（「首页只有一集正片」），b85c85d 已在它的分支改掉，本批未动该句避免扩大冲突面，组装时以 b85c85d 为准。

## 四、存量数据说明（如实）

已落盘的旧记录 name 已被写成蜘蛛自报名，且登记里没存原始文件名（存盘 fileName 是 `py_<idslug>.py` 形态），**无法可靠反推原文件名，本批不做存量迁移**。用户侧恢复办法：删掉那条旧记录后重新导入同一文件即按文件名登记（直接重导会被内容 hash 判「完全相同」跳过、保留旧名）。

## 五、改动文件

| 文件 | 改动 |
|---|---|
| lib/import_center.dart | baseName 剥路径；_importPy 删 ping 改名、登记写 baseName；_importJs/_importJsonList 登记写 baseName；jsonlist ping 改名同步 baseName |
| lib/imported_site_record.dart | 新增 baseName 字段 + effectiveBaseName + copyWith/toJson/fromJson 往返；新增 renumberImportedSiteRecords |
| lib/local_store.dart | syncImportedSites 入口统一重排；_loadImportedSites 加载后重排 |
| lib/site_import_flow.dart | html 登记写 baseName（其内容名，零行为变化） |
| test/py_import_name_test.dart | 新增 13 个测试（见下） |

## 六、测试数字

环境：Flutter `~/workspace/tools/flutter-3.50.0`、TMPDIR 指 workspace 大盘、`--no-pub`、同树单 flutter。

- 基线（改动前）：import_center / external_py_import / json_list_import / site_import_flow / jar_import_naming 共 60 个全过。
- 新增 test/py_import_name_test.dart 13 个全过，钉死：
  - ping 回蜘蛛自报名（mock 桥可用）时登记名、站点表显示名、outcome.siteName 仍是文件名，备注不含「蜘蛛名为」；
  - 候选名带路径只登记文件名部分；baseName 去路径/去后缀单测；
  - 同名不同内容重复导入编号 dup1/dup2、id 不冲突、站点表同步带号；删一条后 sync 重排、剩一条回原名 dup；
  - 纯函数：单条不带号原样返回、三条编号 1/2/3、删中间重排、旧记录无 baseName 零扰动、baseName JSON 往返不丢。
- 改动后相关全套：上述 7 文件 80 个全过（60 基线 + 13 新增 + import_center_compact 7）；另 tvbox_compat_import / tvbox_t4_import / shared_json_import / py_bridge_stability / content_py / import_center_compact 等 6 文件 61 个全过；actress_count_fix / html_host_site / json_list_name_repair / py_contract_full_protocol 4 文件 26 个全过。合计 167 个全过、0 失败、0 新增失败。
- 预览文件 test/import_plus_preview_test.dart：单跑出图（preview landed: import_plus_popup），进程收尾挂死——该文件既有已知现象（批量跑时基线同样卡在此文件），未计失败。
- analyze（本批 5 个改动文件）：0 错 0 警；仅 1 条既有 info（site_import_flow.dart:6 的 material 导入弃用提示，非本批引入）。

## 七、手机终验方法

装含本批的新版后：

1. 导入一个 getName 与文件名不同的 py（比如文件名 `mysite.py`、蜘蛛自报中文名）：站点列表与导入结果都应显示 `mysite`，不再显示蜘蛛自报名；
2. 再导入同名但内容不同的另一份 `mysite.py`：两个站应显示 `mysite1`、`mysite2`；删掉任意一个，剩下的应自动变回 `mysite`；
3. 从文件管理器「打开方式/分享到」导入、从站点列表右上角加号导入各试一次，站名口径应一致；
4. 旧版已被改名的存量站：删掉重导后应显示文件名（见第四节）。
