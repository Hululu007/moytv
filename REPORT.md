# v66 .sql 导入失败修复报告

分支：`actress-import-fix`（基线 246378a / v66），worktree `~/workspace/moyi_import_fix_20261125`。
改动文件：`lib/actress/actress_sql_import.dart`、`test/actress_sql_import_test.dart`。未构建、未推仓。
（注：此路径原有一份番茄修复报告，是主树提交 4ea589f 带进来的；其正本在 `~/workspace/moyi_fanqie_v5_20261124/REPORT.md`，字节一致，未丢失。）

## 一、根因

切分器 `SqlStatementSplitter.addLine` 的旧逻辑：**一行开头不在字符串里时，就拿整行找第一个 `--` 直接截断**，不管这个 `--` 是不是在同一行后面的字符串值里。

真文件第 429 行的标题是 `'K1037 餌食牝 -- 北上尚子'`，`--` 被当成行注释，语句从字符串中间被砍断：字符串未闭合、切分状态错位，下一行 pfes-065 的 INSERT 被吞进上一条的字符串里，拼成一条合并垃圾语句。SQLite 编译这条语句时，第二个字符串提前闭合、`pfes` 成了裸词——报 `near "pfes": syntax error`，与手机截图一字不差。失败发生在换库之前，原库没被动过（与既有失败语义一致）。

复现证据：`harness/repro_before.dart`（从修复前原文件逐字抽出切分器类 + 驱动，纯 Dart 跑真文件）——只喂前 3000 行就切出合并坏语句 #416（k1037+pfes-065）、#798、#2098、#2323、#2473、#2624、#3143 等，连环传染。

同类写法在真文件（4,807,243 行）里的数量：

- 含 `--` 的行 **934 行，全部在字符串值里**（标题、简介等）；
- 以 `--` 开头的真注释行 **0 行**；
- 含 `/*` 的行 **12 行，也全在字符串值里**（如标题 `[真实故事/**◯女人]`）；
- 含 `\r` 的行 0 行。

即：成批问题，不是个例；而且这个文件根本没有真注释，旧写法的注释处理纯属有害。

## 二、修法（切分器）

注释改为**扫描中判定**：逐字扫描时，只有「不在字符串内、不在块注释内」遇到的 `--` 才丢弃本行剩余；新增 `/* */` 块注释状态（可跨行），字符串内的 `--`、`/*` 一律按数据保留。`flush()` 复位块注释状态。修后同工具复跑前 3000 行：k1037 语句完整切出（467 字符，标题内 `--` 保留），合并语句 0 条。

## 三、跳过韧性（用户口径落地）

- 每批 1000 条 INSERT 整批执行失败时，整批逐条重跑：坏的**跳过并计数**（按表归类、留第一条出错样本），好的照常进库，导入继续。
- 单条非 INSERT 语句出错同样跳过计数（建表失败会在后面校验缺表时按结构性失败拦下）。
- **整批一条都跑不成 = 系统性失败**（库锁死、磁盘满之类），抛错整单失败，报错带首条出错原因；结构性失败（缺表、没作品、没播放地址）仍整单失败。失败都在换库之前，原库不动——不把整批静默吞掉。
- 结果新增三字段：`skippedStatements`、`skippedStatementTables`（表名→条数）、`skippedStatementSample`；导入汇总在有跳过时多一行「跳过 N 条出错语句（videos X 条、…）」，不静默。

## 四、双重前缀

导入器失败结果原本自己带「导入失败：」前缀，两个展示处（设置区、列表页 SnackBar）又各带一层，叠成「导入失败：导入失败：」。已改：导入器只放错误原文（首行），展示处保留自己的一层。

## 五、回归

- `actress_sql_import_test.dart`：全过。含新增切分器用例 5 个（字符串内 `--` 根因回归、字符串内 `/*`、块注释跨行、跨行字符串中间行以 `--` 开头、语句后行注释）与新增韧性用例 2 个（单条坏语句跳过计数不炸整单；整批全灭整单失败且原库不动、报错无双层前缀）。
  - 测试替身同步修正：假执行器原先只在批量执行时按表抛错、单条不抛，与真 sqflite 不符（一条 INSERT 走批走单条都会失败），且批不原子。已改为：批先全检再计数（原子）、单条 INSERT 同样按注入失败抛错、单条也计数。两个旧「中途出错」用例在新语义下仍真实成立（纯 video_tag 批逐条全灭 → 整单失败）。
- `actress_sql_import_normalize_test.dart`：6/6 全过。
- `actress_sql_import_preview_test.dart`：预览图在本轮运行中重新落地（settings_import_entry.png），日志无失败标记；进程死在收尾阶段（该文件 toImage 收尾挂起是已知老毛病，文件头注释有写明）。
- analyze 改动文件：0 错 0 警告。

## 六、全量验收

（2026-11-25 晚接手收尾补跑，日志 `harness/full_takeover3.log`）优化后导入器全量跑**一次通过**：`import done in 0:03:50.087921: ok=true`，六表行数与源库逐项一致（videos 448,277、actresses 32,276、video_actress 609,537、video_play_urls 514,572、video_category 448,277、video_tag 2,726,964），跳过语句 0 条。导入产物另行复核：`PRAGMA integrity_check` = ok；三张表全表指纹（行数 + 字段长度总和）与源库逐项相等（videos 448277|17402219|30528631|36105026、video_play_urls 514572|40194837、actresses 32276|200305|1043800）；分散抽样（videos 4 个偏移 ×5 行、video_play_urls 3 个偏移 ×5 行、actresses 头像 20 行）与源库逐行一致。验收进程在断言后段被外部环境杀掉（本机多会话挤压，日志停在 video_tag 行数 PASS 处），未打印的 integrity/指纹/抽样三项由接手人用 sqlite3 对同一产物补验，即上述结果。

**video_tag 小差（2,727,008 vs 2,726,964）已对清**：现行源库（`~/workspace/roster_remrge_20261124/女优库.db`）现读 video_tag 就是 **2,726,964**，转储文件里 INSERT INTO video_tag 也是这个数，导入产物同数——三方一致、导入零丢失。2,727,008 是标签归一化合并前的旧统计（tag_stats 口径，3 组重复标签未并时），差的 44 行在制库阶段就已合并掉，不在导入环节。如 §六开头所记，验收程序从源库现读的基准数同样是 2,726,964。

源库基准数（验收程序从源库现读）：videos 448,277、actresses 32,276、video_actress 609,537、video_play_urls 514,572、video_category 448,277、video_tag 2,726,964。

验收方式：修好的 Dart 导入链（`ActressSqlImporter` + 新切分器）+ FFI 直连系统 libsqlite3 的执行器（替 sqflite，批语义与 sqflite 一致：一事务全成全败），把真 `.sql.gz`（101,407,408 字节）从头导进临时库，断言六表行数与源库逐项一致、`PRAGMA integrity_check` 为 ok、三张表全表指纹（行数 + 标题/封面/播放地址/头像字段长度总和）一致、分散抽 20 条作品与播放地址逐字段一致。

环境干扰（如实记录）：全量跑先后被环境打断多次——①磁盘子卷配额被并行写打满（EDQUOT），一跑在写盘中途报 `database disk image is malformed`，当场验证连新建文件都 EDQUOT，属配额挤压写坏页、非代码问题；②剥离准备侧的工作区反复按进程名批量杀带 `3.50.0` 字样的进程，我方用同版 SDK 的测试/验证进程被误杀多次（进程无日志直接消失、临时库停在半路；其中一跑已推进到 2,997,286 条语句/581MB）。最终改用不带该字样的 Dart 路径、在对方那轮跑完机器空下来后完成全量跑。

## 七、手机终验点

1. 装下一版后导同一份删后库 `.sql.gz`：应一次导完，汇总显示作品 448,277、播放地址 514,572，无报错。
2. 搜 `K1037`（标题带 `--` 的那部）：详情能开、能播；再随手点几部标题带符号的作品。
3. 拿一份截断/损坏的 .sql 副本试导：要么导成且汇总写明「跳过 N 条出错语句」，要么整单失败且原库照常能用——两种都不许把库弄坏。

## 八、导入加速（用户问「能不能加快」）

分段剖析（真文件，harness 实测）：纯切分（读+解码+切分 643MB .sql）约 62 秒 ≈ 3%；逐条/逐批执行 INSERT 占约 97%——瓶颈在执行不在切分。

优化（已落码，口径不退：切分正确性、跳过计数、六表行数、integrity 全保留）：

1. 临时导入连接专用 PRAGMA：journal_mode=MEMORY、synchronous=OFF、cache_size=-262144（256MB）、temp_store=MEMORY、mmap_size=256MB。只限临时库连接（失败整单丢弃不怕），主库打开仍走默认档，红线注释写明。
2. 索引后建：转储里 6 条 CREATE INDEX 在文件最末尾，本就靠后；导入器把建索引攒到数据灌完、归一化之前统一执行（坏的同样跳过计数），避免灌数据时逐行维护索引。

优化前后总时长对比：优化前 **33 分 57 秒**（同 harness、同真文件、未加 PRAGMA 与索引后建的版本，`harness/full_retry.log` 12:03 那跑 ok=true）→ 优化后 **3 分 50 秒**（`harness/full_takeover3.log`），约 **8.9 倍**提速；两次导入结果六表行数均与源库一致。

## 九、后台导入（应用内）

落法：导入任务收进应用级常驻控制器 `ActressDbTaskController`（ChangeNotifier 单例），不再绑导入页生命周期：

- 选完文件点导入后可离开演员库页去用 App 别的功能，导入继续；演员库页顶栏下方有后台导入细横幅（进度 % + 已执行语句数 + 取消钮），设置区与数据库管理页同样能看进度、能取消。
- 导的过程中灌的是临时库，成功才顶替——旧库照常能看能播，界面文案明说。
- 导完：控制器留一次性完成通知，演员库页活着立刻弹汇总 SnackBar；导入期间页面不在的，下次进演员库补弹一次（只弹一次）。失败同样弹，且旧库不受影响。
- 取消：横幅/设置区/管理页都有取消入口，取消后临时库丢弃、旧库不动。
- 诚实边界：这是「应用内后台」——App 还活着时切页面没问题；系统把 App 整个杀掉（鸿蒙 NEXT+卓易通杀后台严）导入会中断，但中断安全（旧库完好、临时库可弃），重新导即可。不宣称被杀还能导。

测试：控制器用例覆盖「挂起时进度可查、忙碌互斥、取消后旧库不动（代次不涨）、导完顶替生效（代次涨+通知只消费一次）」，见 `test/actress_db_manage_test.dart`。

## 十、播放链适配验证（用户问「sql 读取数据能播放有没有做适配」）

字段映射口径（外部 .sql → 工作库 → App 数据层）：

| 外部列 | 工作库落点 | 数据层读法 |
|---|---|---|
| 番号 vod_id | videos.vod_id（主键） | 列表/详情按 vod_id 取行 |
| 标题 | videos.title | FilmLibraryEntry.title |
| 封面 pic_url | videos.pic_url | resolveCoverUrl(pic_url) |
| 播放地址 | videos.m3u8_url / vod_play_url + video_play_urls 地址池 | 播放链取 videos 两列：extractPlayUrl(m3u8_url 非空 ? m3u8_url : vod_play_url) |
| 女优 | actresses（cate_id=全名形、name=短名）+ video_actress 关联 | GROUP_CONCAT(DISTINCT cate_id) 批量取 |
| 分类 | video_category.main_category + videos.type_name（两个维度，归一化时同写） | 列表 LEFT JOIN video_category |

注意：video_play_urls 是地址池（同步/合并用），不在影视库这条播放链上——表格更新写地址时因此两处都写（地址池整表替换 + videos 两列同步第一条）。

验证方式与结果：（2026-11-25 晚接手补跑，日志 `harness/playback_takeover.log`）`harness_pkg/bin/playback_check.dart` 对导入产物（verify_out 导入库）跑 App 数据层原文 SQL（列表分页查询 + GROUP_CONCAT 取女优 + 按 id 严格取行）与真实 `extractPlayUrl`/`resolveCoverUrl`（与 lib 逐字一致，接手时比对过）：样本 9 部（K1037、pfes-065 + 随机 7 部）**67 项断言全过**——每部都能按 id 取到行、播放地址非空 http(s)、与源库同法推导的地址逐字一致、封面与标题逐字一致。结论：导进来的数据经 App 本体数据层能取出真地址、能播（真播仍等手机终验，见 §七）。

边界：VM 只验到「数据层取出真地址」；真播等 v67 装机导入成功后用户手机验（数据中心出口拉流验不了的老规矩）。

## 十一、数据库管理页

入口：演员库设置区「数据库管理」行 + 无库空态/顶上提示条的「数据库管理」钮。只管演员库工作库。

- 当前库信息：作品数/女优数/播放地址数（只读连接现查）、库文件大小、最近一次导入时间与来源文件名（导入成功时记 SharedPreferences，记不下不拦功能；没记录显示「未知」不编造）；没导过库显示明确空态。
- 删除数据库：二次确认（文案讲清后果与备份不跟删），删工作库与 -wal/-shm/-journal 边文件、不删 .bak；删完演员库回空态。
- 备份管理：.bak 存在时单列一块（大小/时间），给「恢复备份」（二次确认，恢复后数据层能正常读）与「删除备份」；不存在显示暂无备份。
- 互斥口径（选「拦下提示」）：有任务（导入/表格更新/导出）在跑时，删除/恢复/开新任务一律先拦下提示「正在…，先取消或等完成」，不自动取消、不打架。
- 导入元信息与管理页实现：`actress_db_meta.dart`、`actress_db_info.dart`、`actress_db_manage_page.dart`。

## 十二、表格导入更新（CSV / Excel）

- 格式：CSV 与 .xlsx。选型如实记：excel/csv 包在本机 pub 缓存里没有、pub.dev 拉不到，故 CSV 用自写 RFC4180 编解码、XLSX 用既有直接依赖 archive+xml 自写编解码（写内联字符串、读共享/内联/数值），已在 pubspec 加 `xml: ^6.5.0`（缓存有 6.6.1，离线可装）。
- 语义是「更新」不是「替换」：以番号为对齐键，已有更新、没有新增、没出现的作品一律不动；整段在一个事务里，失败/取消整体回滚。
- 列映射（与导出同一套八列）：番号/标题/封面/播放地址/女优/女优头像/分类/标签，认常见中英文列名（code/title/cover/play_url|m3u8_url/actress/avatar/category/tags 等，复用 roleForColumn + 头像/标签专用名表）。
- 规则：空单元格不覆盖原值；播放地址非空时整表替换该作品地址（多地址以 ` | ` 拼、拆认 `|｜`、换行、英文/中文分号）；女优只加关联、人名自动建人（cate_id=人名）、带头像列一并更新头像；标签只加。
- 番号大小写（实测抓到的真 bug，已修）：库里 vod_id 是小写形，表格常写大写——存储层 findWork 改 `COLLATE NOCASE` 匹配，更新器以查到的实际 vod_id 为对齐键、新行统一小写落库，否则大写番号会查不到旧行、插成重复行。
- 汇总：新增/更新/跳过行数 + 跳过原因计数（缺番号/没有可更新的内容），管理页可见。
- 实现：`actress_spreadsheet.dart`、`actress_table_update.dart`；走控制器后台任务口径（进度/取消/互斥同导入）。

## 十三、导出选格式

五种：.sql、.sql.gz、CSV、.xlsx、.db 原文件。

- .sql/.sql.gz：全量转储（表结构+数据、索引在数据后、COMMIT 收尾，布局与源转储一致），流式写不整表驻内存；必须能被自家导入原样导回——往返验证：（2026-11-25 晚接手补跑）`harness_pkg/bin/export_import_check.dart` 把真实导出器产出的样本转储（含标题内 `--`、单/双引号、`/* */`、跨行标题等刁钻值）用真实导入器导回，**11 项断言全过**：行数对、刁钻标题逐字无损、播放地址完好、integrity ok、跳过 0 条。（注：该 harness 文件尾部两处期望字符串在原工人最后一次脚本编辑时被多转义写坏、且 play_url_verbatim.dart 头部多一个残留 `}`，接手时已按样本真值修正后才跑通，属验收工具损伤、非产品代码问题。）
- CSV/.xlsx：作品表八列与表格导入完全同一套（地址 ` | ` 拼、女优/标签 `、` 拼，与导入拆法一致），导出→改→表格更新导回的往返在单元测试里成立（改一行只那行变）。
- .db：先关库→拷文件→重开库。
- 落点：file_picker 13.1.0 的 saveFile 必须整份字节、无流式——44 万部导出不能整份进内存。故定为：先流式生成到应用文档目录并给出完整路径（与 App 内 MYTV 合并 JSON 导出的既有先例一致），文件 ≤32MB 时另给「另存到…」走系统保存选择器。走控制器后台任务（进度/取消/互斥），导完给路径与大小；空库先拦下提示导入，不导空文件。
- 实现：`actress_db_export.dart`。

## 十四、删除写入功能（两令：自动记录 + 同步，整个删掉不留）

删掉的：

- 播片自动记录：`actress_play_record.dart`（ActressPlayRecorder 本体）、detail_screen 三处 onPlaybackStarted 调用与 _handlePlaybackStarted、设置页「自动记录播放到演员库」开关与设置字段 autoRecordPlays（含偏好键定义；用户旧偏好里残留的键值成惰性残留、无害）。
- 同步全套：`actress_sync.dart`（ActressSyncService）、`actress_site_crawl.dart`（现爬补库）、`actress_stacking.dart`（叠加合并）、`actress_generic_crawl.dart`（通用现爬，只被现爬与其测试引用）；列表页的同步接线全拆——三构造参数、进度订阅、设置弹窗「同步爬取」区（同步/叠加/任意站点爬取三节）、顶栏「刷新同步」钮、现爬进度行的「导出合并 JSON」动作（ActressJsonFallback.mergedDocument 本体保留，那是兜底数据层不是同步）。
- 保留没误伤：actress_roster_sources.dart（抓取/解析层，搜索与数据库总览在用）、ActressEnrichment（详情/搜索补全，定义在 actress_search.dart）、列表/分类/文件夹/详情/播放、数据库管理全套。

区分（用户特别问的）：**App 播放历史与演员库是两回事**——播放历史是 LocalStore 的 SharedPreferences JSON（key 'history'），不写工作库，删记录器不碰它，照常记。

删完口径：工作库内容只许经数据库管理变更（.sql 导入、表格导入更新、恢复备份、删库）。

其他自动写库路径盘点（只列不删）：

- FilmLibraryService.appendToLibrary / FilmLibraryWriter.appendCrawledFilms 与 mirrorActressJsonEntriesToDb：同步删完后在 lib 内已无生产调用点，成惰性库 API（测试与影视库页的「打开外部库」只读路径不经它）。
- replaceDomain/updateFilmPlayUrl/updateWorkPlayLink：定义文件外无生产调用点（autoReplaceDomain 默认关）。
- 同步检查点 saveCheckpoint：只有已删的现爬在写；存量检查点数据成惰性残留，下次导入换库即覆盖。
- SqfliteActressDatabase 打开时的结构维护（补索引/补列/建汇总表）会写库文件——是结构维护不是内容行，保留并在此如实列明。
- upsertVideoEntries：删记录器后生产调用点只剩 mirror 路（同上，惰性）。

测试：同步/现爬/叠加/记录器的专属测试文件整删 9 个；其余受影响测试逐个去掉假服务注入后保留（actress_test 等）；新增断言「设置弹窗无同步入口、顶栏无刷新同步钮」（actress_db_manage_test）。回归比对：actress_test 42 过 4 败，4 败逐名与 v66 基线同名同因（pumpAndSettle 平台通道老毛病，基线树同名单跑同败，已实证）；code_search 2 败、play_fallback/play_missav_first 各 1 败均在 .sql-only 批记录的基线 18 败名单内；其余演员库测试全过，0 新增失败。

## 十五、本地 JSON 兜底链核查（用户报「JSON 数据也没显示」）

结论：**链通、未被 .sql-only 批误伤**（回归测试 `test/actress_json_chain_test.dart` 三层全过）：

- git 考古：c11edfc 删的是 .db 文件镜像与多库兜底两条 .db 的路，对 actress_json_fallback.dart 只有注释措辞改动；新版 actress_mytv_bind 的 jsonDir 仍是 MYTV/db，老 json 影子文件迁移逻辑（只补没有的、不覆盖）在。
- 实测：bindLocalDirs(jsonDir) → load() → 按人/按番号都能查出本地 JSON 条目；工作库为空时详情合并路（entriesForActressAsync/entriesForCodeAsync）仍能出本地条目。
- 边界（既定口径，不是缺陷）：只在 JSON 里有、工作库里没有的人**不进人物列表**——人物列表从来只读工作库，JSON 条目进显示的路是详情合并与站点筛选（新旧一致）。
- 用户 v66「JSON 没显示」的实因：.sql 导入失败 → 工作库为空 → 人物列表本就只读工作库，自然空。下一节「顶上」正是补这一块（注意顶上用的是内置 who's 目录/映射，不是 MYTV 本地 mjv011.json，两条链别混）。

## 十六、无库顶上（用户令「顶上」）

- 触发：工作库不存在或为空（没导过 .sql）时顶上；导入成功（自动刷新代次涨）立刻切回数据库，JSON 退回只管详情页查演员，不混出数据；删库后自动切回顶上。
- 内容：作品流 = 内置视频目录 whos_video_catalog（339,526 行，番号/标题/封面/播放地址全）分页出卡，点开走 who's 直链播放（whosLocalDetail 一条直链集 + 播放器）；按女优看 = whos_actress_map 把作品按人归拢（演员按作品数降序），点人出她的作品列表；女优无头像，头像位用 ActressAvatar 姓名占位，不现取不编。
- 顶不了的照旧空：分类/类型文件夹/标签只有数据库有（JSON 只有一个「日本AV」），无库时不出分类，不拿假分类糊弄。搜索带上了：目录内按番号/标题查（提交时逐行扫、命中上限停）。
- 性能：目录全文只留一份字符串 + 行偏移表，翻到哪页才解析那几行成对象；解压建表在 compute 子隔离跑，不卡首帧；人物侧复用 WhosJsonIndex 既有常驻索引不另建。实现：`actress_whos_topup.dart`（WhosCatalogPager + ActressWhosTopupView），WhosJsonIndex 新增 actorsByWorks() 枚举。
- 详情页原有查演员行为未动。

## 十七、导入后自动刷新（用户令「导入数据库自动刷新」）

- 机制：控制器数据代次 dataGeneration——.sql 导入换库、表格导入更新成功时控制器内部涨，管理页恢复/删除成功时调 notifyDbMutated() 涨；演员库列表页监听代次，一涨就清列表/分类/文件夹缓存 + NvkuEntryCache、关旧连接按新库重开（_manualReloadDb），已打开的页面直接看到新数据，不重启、不手动重进。
- 联动顶上：无库时是顶上视图，导入成功代次涨 → 重读成功 → 切回数据库人物列表；删库后重读报无库 → 自动切回顶上/空态。
- 范围：演员库人物列表、首页分类与类型文件夹、详情取数都走同一 Sqflite 单例连接，重开后统一新数据；影视库（WhosLocalLibrary 数据库模式）与直播内置片库共用同一单例连接的读者在列表页重开后同样读到新库；若导入完成时列表页不在，其单例缓存连接要等下次进演员库页重读时才换（诚实边界）。
- 测试：顶上文件里「导入代次涨后切回数据库人物」一条 + 管理页「删库代次涨」一条 + 控制器代次用例。
- 手机终验点：导完 .sql 不重启、直接看演员库应是新数据；删库后演员库应自动回到顶上作品流。

## 十八、最终核验结论（2026-11-25 晚，接手收尾）

原工人（b1adcc92）在交卷前异常结束，成果全部留在工作树未提交。本节为接手人逐项复核、补跑、补修后的最终结论；接手期间只动了三处：①`test/actress_json_chain_test.dart` 删一处未用变量（analyze 警告清零）；②`test/actress_mytv_bind_test.dart` 无库空态用例按 §十六新口径改断言（注入小夹具目录/索引，断言顶上提示条出现、旧纯空态文案不出现）；③两处验收 harness 的文本损伤修复（见 §十三注）。产品代码未改一字。

逐项核对（对应本批 10 个子项）：

1. **.sql 切分 bug 修复**：已落地（§一–§四）。真文件全量导入一次通过（§六）：ok=true、六表行数逐项一致、integrity ok、三表指纹一致、抽样逐行一致；跳过 0 条。video_tag 小差已对清（§六）：源库现读、转储、导入产物三方同为 2,726,964，44 行差是制库时标签归一化合并的旧统计，不在导入环节。
2. **导入加速**：已落地。33 分 57 秒 → 3 分 50 秒（约 8.9 倍），口径不退（行数/integrity/指纹全对）。
3. **应用内后台导入**：已落地（§九，控制器 ActressDbTaskController）；控制器用例在 actress_db_manage_test 内全过（挂起进度可查、互斥、取消旧库不动、导完顶替+通知只消费一次）。
4. **.sql 数据能播**：已验证（§十）：9 部样本 67 项断言全过，地址与源库逐字一致。
5. **数据库管理页**：已落地（§十一）；actress_db_manage_test 全过（含删库代次涨、互斥拦下、恢复/删除备份路径）。
6. **表格导入更新 + 导出五格式**：已落地（§十二、§十三）；actress_db_export_file_test 全过；导出→导入往返 harness 11 项全过；CSV/XLSX 同一套列往返在单元测试内成立。
7. **删自动记录 + 删同步**：已落地并经接手全仓 grep 复核——被删类（ActressPlayRecorder/ActressSyncService/现爬/叠加/通用现爬）在 lib 内零生产引用（仅剩一条测试注释提及文件名）；其余写库入口只剩数据库管理四条路（.sql 导入、表格更新、恢复备份、删库）+ actress_database 打开时的结构维护（汇总表/补索引）；appendToLibrary/mirrorActressJsonEntriesToDb/upsertVideoEntries 等只剩惰性库 API、无生产调用点（§十四盘点属实）。
8. **本地 JSON 兜底链**：链通（§十五）；actress_json_chain_test 三层全过（接手清掉其一处 analyze 警告后重跑仍全过）。
9. **内置 who's JSON 顶首页**：已落地（§十六）；actress_whos_topup_test 全过（分页器坏行跳过、按人归拢、顶上视图出卡/点播回调、导入代次涨后切回数据库人物一条在内）；目录只留一份字符串+行偏移表、按页解析，无全量驻内存。
10. **导入后自动刷新**：已落地（§十七，dataGeneration 代次机制）；顶上文件与管理页各有代次用例、全过。

**测试总账（接手复跑，Flutter 3.50.0、--no-pub、串行）**：

- 本批新/改测试：sql_import + normalize 28/28、db_manage + db_export_file + json_chain + whos_topup 26/26、mytv_bind（改后）13/13、site_filter 单跑 3/3（批量时 1 条抖动败、单跑全过）。
- 演员库其余普通测试全量串行跑完：失败共 8 条，**全部与 v66 基线同名同因、0 新增**——actress_test 4 条（3 条 pumpAndSettle 超时老毛病；「详情页点卡库里无地址」一条接手在 246378a 基线树单跑同名同因复现，坐实老失败）、code_search_group 2 条、play_fallback 1 条、play_missav_first 1 条（后四条均在 .sql-only 批记录的基线 21 败名单内）。
- analyze 改动文件（33 个现存文件）：**0 错 0 警告**（info 级仅全树同款 material 弃用提示与个别 unnecessary_import，与基线同款）。
- 预览测试：actress_sql_import_preview 与 actress_list_preview 单跑，PNG 均重新落地（settings_import_entry.png、actress_list_all.png），随后进程死在收尾阶段（`Cannot add event while adding stream`，本树预览测试已知老毛病，与原工人 §五记录一致）；其余改动的预览文件（group/tag/works/zone 等）本批未逐个重跑，其覆盖的界面本批无功能改动、对应普通测试全过——如实标注，未跑不冒充跑过。

**环境插曲（如实记录）**：全量验收先后被环境打断四次（配额 EDQUOT 挤压、进程被外部杀掉、磁盘 IO 饥饿），最终在机器空闲窗口一次跑通；14:30 那跑的 video_actress 唯一约束失败已查清是验收替身（FFI 执行器）在配额压力下 COMMIT 失败后事务残留、逐条重跑与残留事务相撞所致——源库与转储里该行只有一份（已 grep + sqlite3 双查），真实 sqflite 批本身原子、产品代码的整批回滚假设成立，非产品 bug。

**手机终验点（汇总，装 v67 后）**：

1. 导同一份删后库 .sql.gz：一次导完（约几分钟量级，不再是半小时），汇总作品 448,277、播放地址 514,572、无报错；导完不重启，演员库直接是新数据。
2. 搜 K1037、pfes-065 能开详情、能播；标题带 `--`、引号的作品随手点几部。
3. 导入中途离开演员库页去别处，回来进度还在、能取消；取消后旧库照常用。
4. 数据库管理页：库信息（作品/女优/地址数、大小、导入时间、来源文件名）对得上；删库二次确认后演员库自动回顶上作品流；.bak 恢复后数据回来；有任务在跑时删库/恢复被拦下提示。
5. 表格更新：拿导出 CSV 改一行导回，只有那行变；导出五种格式各导一次，.sql 导出能再导回。
6. 没导库时演员库首页是内置 who's 作品流（可点播、按女优看），分类/标签为空属正常；设置里没有「自动记录播放到演员库」开关、没有任何同步入口。
7. 放一份 mjv011.json 到 MYTV/db 后，详情合并能带出本地条目（人物列表不直接进人，属既定口径）。
8. 拿截断/损坏的 .sql 副本试导：要么导成且汇总写明跳过条数，要么整单失败且原库照常能用。

未决事项：无产品侧未决。verify_out/ 保留了本次全量导入产物（女优库.db 933MB + 同 inode 硬链接 preserved_snapshot.db），配额紧时可整目录删，不影响已提交内容。
