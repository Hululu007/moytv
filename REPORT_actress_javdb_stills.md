# 演员库 JavDB 补剧照（2026-11-26）

基线 9dab199（分支 actress-whos-ui），本地提交、不推仓、不构建。

## 需求

从本地库 / who's 入口打开的作品详情，剧照（stills）为空时按番号去
JavDB 接口补预览图；已有剧照不覆盖；拉不到保持空、不挡开页、不弹窗、
不拿封面冒充。

## 改动文件与落点

- `lib/actress/actress_online_detail.dart`：新增
  `actressJavdbStillsSupplement({current, code, client, timeout})`——
  current 非空原样返回且不发请求；按番号搜索后经 actressCodeKey
  归一化精确相等才认那部作品，再 movieExtra 取 stills；任何失败/
  超时（默认约 6 秒）返回 current。与详情页既有「详情补充」同一
  条链（和 _refreshCodeMeta、在线线路区同属详情加载后的后台补充），
  没有另造平行链。
- `lib/detail_screen.dart`：新增可选构造参数 `javdbStillsClient`
  （测试注入口，照 playerFactory/videoBuilder 既有风格）；新方法
  `_loadJavdbStills(drama, generation)` 紧挨 `_refreshCodeMeta`，
  在 `_load` 成功路与 initialDetail 回退路各一处 unawaited 调用；
  source=='javdb' 跳过（入口已按 id 拉过）、stills 非空跳过、
  代次守卫、写回前再查仍为空才 setState。剧照渲染改走顶层函数
  `_detailStillImage(url)`，`_stillsSection` 与 `_StillsAllPage` 共用。
- `lib/models.dart`：DramaDetail 新增 `withStills`（照 withEpisodes 样式）。
- `lib/actress/javdb_api.dart`：新增 `javdbIsImageUrl()`（host 为
  jdbstatic.com 或其子域）。
- `lib/actress/javdb_image.dart`（新增）：JavdbImage 组件从
  javdb_view.dart 逐字搬家（行为未改）；javdb_view.dart 改为
  import+export 它。
- `test/actress_javdb_stills_test.dart`（新增）：13 例。

## 显示路径查实（任务第 3 点）

- JavDB 图床 c0.jdbstatic.com，预览图在 /samples/ 路径，显示前须过
  XOR 解密（依据 avplay_source_20261126/API_MAP.md）。JavDB 入口的
  封面/头像此前已走 JavdbImage 解密路径。
- **查实一个存量问题**：详情页剧照区原先用普通 Image.network 显示，
  没有 XOR 解密——即此前 JavDB 入口（openJavdbWork）带进的剧照也走
  这条未解密路径（图床图未解密会显示为乱码/坏图）。本批已让图床
  地址在剧照区与全部剧照页统一走 JavdbImage 解密路径，非图床地址
  维持 Image.network + 深色占位。这是让新补剧照能正确显示所必需的
  最小范围改动，顺带修正了 JavDB 入口自带剧照的同一问题。
- 观察项（本批未动）：头区背景条也把 stills 当背景候选、仍走通用
  路径，未接解密路径；如需处理另行立项。

## 验证

- 新测试 test/actress_javdb_stills_test.dart：13/13 全过（补图逻辑
  10 例：精确匹配/近似不认/搜不到/出错/超时/已有不覆盖且零请求/
  空番号零请求；图床判定 1 例；详情页接线组件 2 例）。
- 回归（与基线 9dab199 对照）：javdb_api_test、
  actress_detail_sections_test、actress_online_lines_test、
  actress_online_parse_test、actress_javdb_extra_test（第二批）合并
  跑全过、0 失败、0 新增失败。
- actress_online_preview_test.dart（预览渲染）：本机当前负载下
  每张预览渲染要 1–4 分钟，整文件（10 例）在给定时限内跑不完，
  两次尝试均以超时杀进程收尾（退出码 124，收尾报 stream 关节
  伪影，与 AGENTS.md 既有教训一致）。期间 home / search /
  javdb actors 三张 PNG 均重新落地，且 git 比对与基线提交字节
  一致（渲染结果无变化）——JavdbImage 搬家为逐字移动、行为未
  变，与此互证。此项记为本机未验完（无整文件通过结论），不判
  代码问题；javdb_api_test 内的视图状态测试全过。
- analyze 改动文件：0 错 0 警（仅存量 info 级：material.dart 弃用
  提示全仓都有；javdb_api 构造器 prefer_initializing_formals 为
  原有写法）。

## 未验项（手机终验）

- JavDB 接口真拉未验：本机出口全天波浪式断连，search /
  api/v1/movies/{id} 真响应没拉到；解析与匹配层已用夹具验真。
  手机终验：本地库打开一部库里无剧照的作品，详情页应自动补出
  JavDB 预览图（番号对得上时）；对不上/断网时剧照区保持不显示、
  页面照常打开。
- 补图只走搜索→精确匹配→详情一条链，搜索路径 api/v2/search 与
  详情路径 api/v1/movies/{id} 均为拼接推定（沿用上一批口径，
  API_MAP 仅 3 条路径逐字命中），真响应形状待手机侧证实。
