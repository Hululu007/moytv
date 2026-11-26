# 巨型 py 蜘蛛导入不识别修复报告

分支：`import-giant-py`（基线 main `efd0049`），工作树 `~/workspace/moyi_import_giant_py_20261126`。只本地提交，未推仓、未构建。
（报告文件名说明：工作树根的 `REPORT.md` 是主树带进来的旧批次报告，按 115 修复批先例另名存档，不覆盖。）

## 问题

用户 2026-11-26 11:08 发来 `______1__35_otmb.py` 并报「这个导入不识别」。
样本本体：2,028,777 字节、41,879 行、1,819,013 字符，UTF-8 解码正常；老壳方言巨型聚合蜘蛛（站名「本地资源管理」），文件头几百行中文更新日志注释，第 10082 行 `class Spider(Spider):`，类体内直接定义 854 个方法，核心方法只缺 `homeVideoContent`，其余 7 个齐全。

## 逐段定位（本机实测，桌面 CPU）

| 阶段 | 结果 | 耗时 |
|---|---|---|
| 文件解码（UTF-8） | 正常，无需 GBK 回退 | — |
| Dart 静态校验（同口径正则复算） | 通过：有 Spider 类、只缺 homeVideoContent → playOnly 放行 | 0.03 秒 |
| 宿主 `validate_source`（ast.parse 全量） | ok=True、mode=playOnly、类体方法 854 个 | 0.93～1.59 秒 |
| 宿主 `_load_spider`（加载+实例化） | 成功，`getName()` 直调 = 「本地资源管理」 | 0.98 秒 |
| 宿主 `handle` ping（修复前） | **失败**：`ping/getName: AttributeError: 'super' object has no attribute 'init'` | — |
| 导入链其余环节（sha256、存盘、文件选择） | 逐段查过，无大小上限、无卡点 | — |

## 真凶一（实证，本机可复现）：宿主桩基类缺合同方法，super() 调用必炸

- 样本 `Spider.init`（第 10126 行）第一行就是 `super().init(extend)`，不在 try 里。
- 宿主注入的 `base.spider` 桩类 `BaseSpider`（`py_spider_host.py` 的 `_ensure_base_spider_stub`）只有缓存与 HTTP 帮手方法，**没有任何合同方法**（init/getName/homeContent/…）。
- `_DEFAULT_IMPLS` 里虽有 init 等默认实现，但 `_fill_defaults` 只往**实例**上填、且类已定义的方法不填；`super().init()` 查的是**基类**，实例填充救不了。
- `handle()` 每次调用先执行 `spider.init(extend)` 再分发，于是这个站**每次打开必炸**，Dart 侧抛「py 蜘蛛执行失败（步骤=…/init…）」。导入时的 ping 失败被导入链吞掉（导入本身可能显示成功），但站点打不开，用户观感就是「导入不识别」。
- 这不是单个文件的毛病：凡是 init 或其它方法里调 `super().<合同方法>()` 的老壳方言蜘蛛都中招，本样本只是第一个撞上的 2MB 级代表。

## 真凶二（手机侧高概率，按机理定位，未真机实测）：校验 30 秒固定预算会被巨型文件吃爆

- `PyBridge.validate` 把整份源码（本样本 181 万字符）经平台通道送进 Chaquopy 做 ast.parse，Dart 侧固定 30 秒超时，超时直接抛 AppFailure「蜘蛛校验超时，请重试」→ 整单判死。
- 本机桌面 CPU 做这件事要 0.93～1.59 秒；鸿蒙卓易通容器里 CPU 慢一个数量级并不罕见，再叠加首次调用拉起 Python 运行时（status 探测另有 10 秒封顶），30 秒很容易被吃光。即导入在手机上可能根本走不到存盘那一步。

## 修复（四件）

1. **宿主桩基类补齐合同方法**（`android/app/src/main/python/py_spider_host.py` 与 iOS 副本 `ios/PythonBridge/Resources/py_spider_host.py` 同改）：给桩 `BaseSpider` 加 14 个合同方法默认实现（init/getName/homeContent/homeVideoContent/categoryContent/detailContent/searchContent/playerContent/getDependence/destroy/localProxy/isVideoFormat/manualVideoCheck/action），口径与 `_DEFAULT_IMPLS` 一致、只回空结果不造假数据，子类覆写与 super() 加工都不受影响。两份文件的桩函数区域原本逐字一致，本批同改后仍逐字一致；iOS 副本其余区域与安卓真源有 182 行既有漂移，本批未动，留待备料脚本统一同步时处理。
2. **校验超时按规模放宽**（`lib/py_bridge.dart`）：`validateTimeoutFor(源码长度)` = 30 秒 + 每多 512K 字符加 15 秒、120 秒封顶；本样本约 182 万字符 → 75 秒。不只是改大：与第 3 件组合，最坏情况也不判死。
3. **校验超时降级放行**（`lib/py_bridge.dart`、`lib/import_center.dart`）：`PyBridge.validate` 超时不再抛 AppFailure，改回 `PyValidation.degraded()`（ok 视为真、degraded 置真，与「运行时不可用回 null 放行」同口径）；导入成功备注追加「文件较大，运行时校验超时，已按静态校验结果放行」。静态校验已先行把关，降级不放进坏文件。另一处调用方 `py_lazy_fetch` 只认 ok，自动同口径受益，未改。
4. **仅播放备注写明缺什么**（`lib/py_spider_validator.dart`、`lib/import_center.dart`）：`PySourceValidation` 新增 `missingCore` 留存被缺的核心方法；`filledNote` 改为「缺少核心方法 homeVideoContent（首页没有视频列表），未缺的分类、搜索、详情、播放功能照常可用；已自动补齐缺省方法 N 个：…」。import_center 旧文案「首页只有一集正片」对这类（分类/搜索/详情/播放都齐、只缺首页推荐）文件是错述，一并撤掉。

## 修复后实测（本机、原文件、冷进程、修复后宿主）

- `validate_source`：0.93 秒，ok=True，playOnly。
- `handle` ping（含加载+init）：**OK**，name=「本地资源管理」。
- `handle` categories / catalog / search / detail：全部 OK。

## 回归

- 方言样本新增 `test/py_dialect_samples/super_base.py`（`from base.spider import Spider` + `super().init` 起手 + super 合并 homeContent + 缺 homeVideoContent 的 playOnly 形态，即本样本的缩小版），已登记进 `run.py` 的 EXPECTED，实测 PASS（校验 + 8 动作全通）。
- 方言样本全套与基线对照：基线为「1 项不符合预期」（arity_dialect 在无 --vendor 环境记 STUBBED，环境产物、与本批无关），本批同样 1 项、另加新样本 1 个 PASS，**零新增不符合**。
- Dart 测试：目标 3 文件（py_bridge_stability / import_center / external_py_import）36 个全过；相关 9 文件（py_lazy_fetch、import_center_compact、site_import_flow、content_py ×2、py_spider_generator、json_list_import、tvbox_compat_import、builtin_py_sites）158 个全过。合计 194 个全过。
- 行为变更点（有意为之，已同步改测试）：`py_bridge_stability_test` 原「校验超时报 AppFailure」改为「校验超时降级放行」断言，并新增超时缩放断言；`import_center_test` 新增「只缺 homeVideoContent 时备注写明缺什么与影响」。
- analyze：562 条 info、**0 错 0 警**，与基线持平。

## 未动与残余

- 导入后 ping 的 10 秒预算未动：巨型蜘蛛在手机上首次加载可能超过 10 秒，ping 超时只是蜘蛛名同步不上（登记名退回文件名），不影响导入成功与站点打开；打开时走 call 的 70 秒预算，加载+init 在其内。
- Kotlin 桥未动（通道传 2MB 字符串本身不是瓶颈，瓶颈在解析与冷启动，已由放宽+降级覆盖）。

## 手机终验法（装含本批的新版后）

1. 导入 `______1__35_otmb.py`：应导入成功，不再报「蜘蛛校验超时」；结果备注应出现「缺少核心方法 homeVideoContent（首页没有视频列表），未缺的分类、搜索、详情、播放功能照常可用」。
2. 站点名：ping 通时显示「本地资源管理」，ping 超时则为文件名（属预期，不算失败）。
3. 点开该站：应能出分类/列表（该站是本地资源管理站，列表内容取决于手机本地存储里的文件），不再报「py 蜘蛛执行失败」。
