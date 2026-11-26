# JavDB 演员列表报错修复报告（2026-11-26 晚）

基线：发布组装树顶端 `0b8c105`（20261126 发版状态）
工作树：`~/workspace/moyi_javdb_actors_fix_20261126`，分支 `javdb-actors-fix`
状态：本地提交，未推仓、未构建。**真拉未验、待手机验**（本机出口到 jdforrepam.com 不通，与此前各批同）。

## 一、用户实报与根因

用户装 20261126 版后，演员库切 JavDB 源、点「演员」页签，整页报错「参数不能为空: type」，演员列表出不来。

根因：我们 `JavdbApiClient.actors()` 调的是拼接推定的 `api/v1/actors?page=N`，**漏传服务端必传参数 `type`**。服务端校验不过、回 `success=false + message「参数不能为空: type」`，我们的 `_getJson` 把 message 原样抛成 AppFailure 显示在页面上——报错文案本身就是服务端回的，不是我们编的。

## 二、实证来源（一个字没猜）

AvPlay 本尊反编译（`~/workspace/avplay_source_20261126/sources/`）：

- `service/javdb/api/JavDbApiService.java` 全部公开方法逐个查过：top250 / latestMovies / latestMagnetUpdates / ranking / tagMovies / categoryMovies / categoryTags / searchMovies / detail / detailByNumber / magnets / relatedLists / reviews / hotReviews / userReviews / collectList 等——**没有演员列表、也没有演员详情的 API 方法**。演员只以 `JavDbApiActor`（id/name/avatar_url/gender）形态嵌在作品详情的 `actors` 字段里。
- `service/javdb/JavDbUtils.java:49` 的 `createActorsPath(id)` 返回 `"actors/" + id`——是**网页通道**（javdb.com）拼演员页地址用的，不是 API 列表。

同为这套 JavDB API 的在役客户端、jar 版蜘蛛 ZakaJavdbAmns（`~/workspace/zakatv_work/jadx_live_out/sources/com/github/catvod/spider/ZakaJavdbAmns.java`）原文实证：

- 第 64 行分类表：`{"actors", "女优", "/api/v1/actors?type=0&page={page}", ""}`——演员列表就是 `GET /api/v1/actors?type=0&page={page}`，`type=0` 即其标注的「女优」一类（同表 makers/series/directors 也是 `?type=0&page=` 同式）。
- 第 2774 行 `actorOptions()`：`faceList(api("/api/v1/actors?type=0&page=" + i), "actors")`——第二处同式调用；信封取 `data.actors`（`faceList` 定义在第 683 行：读 `data` 对象下指定键的数组）。
- 同函数内演员字段取值：`id`、`name`（空落 `name_zht`)、`videos_count`。
- 第 695-697 行 `searchMovies`：`api("/api/v2/search?q=" + urlEnc(str) + "&page=" + i)`——搜索参数名是 **`q`**，不是我们推定的 `keyword`（同根因的第二个错，一并修了，见下）。
- 演员作品：第 2621/2853/3240 行，jar 版走**网页通道** `actorWorksHtml`（javdb.com 镜像的 `/actors/{id}` 页 HTML 解析），API 侧没有演员作品调用。

API_MAP.md（`~/workspace/avplay_source_20261126/API_MAP.md` 第 26 行）对演员只有一句「演员 `…/actors/`」，无参数记录——与「AvPlay 本尊不做 API 演员列表」互证。

## 三、我们的错在哪（逐条核对结果）

调用链：演员库原生页 JavDB 段 → `javdb_view.dart` 的 `JavdbSourceView._load()`（演员页签）→ `JavdbApiClient.actors()` → 报错页。

| 调用点 | 旧写法 | 核对结论 |
|---|---|---|
| 演员列表 `actors()` | `api/v1/actors?page=N` | **错**：漏必传 `type`，即本 bug |
| 搜索 `searchMovies()` | `api/v2/search?keyword=…&page=N` | **错**：参数名应为 `q`（jar 版实证）；AvPlay 的搜索请求构造方法 jadx 没还原出来，无法从它那侧再证，但 jar 是在役可用客户端，以它为准 |
| 演员解析 `JavdbActor.fromJson` | 只读 `name` | 不全：jar 版是 name 空落 `name_zht`，已补 |
| 最新作品 `latestMovies()` | `api/v1/movies/latest?page=N` | 对：路径 AvPlay 逐字实证（JavDbApiService.java:955），jar 版同路径；jar 版演员调用同式只带 page、无 limit 亦可用，不动 |
| 演员作品 `actorMovies()` | `api/v1/actors/{id}?page=N` | **仍未证实**：两个参照客户端都走网页通道、API 侧无此调用。本批不动路径（改网页解析是另一条链、且 javdb.com 网页有盾，未经令不擅自扩围），注释已如实标注，列入未验项 |
| 作品详情 `movieExtra()` / 磁力 / 评论 | `api/v1/movies/{id}` 等 | 详情与磁力此前已有实证（磁力信封由 jar 版实证），评论路径仍属推定但不在本批范围、未动 |

## 四、改了什么（只动 2 个文件）

`lib/actress/javdb_api.dart`：

1. `actors()`：URL 改为 `api/v1/actors?type=0&page=$page`，注释写明实证出处与用户实报的对应关系。
2. `searchMovies()`：参数名 `keyword=` 改 `q=`，注释写明出处。
3. `JavdbActor.fromJson`：名字 name 为空时落 `name_zht`（jar 版取值顺序）。
4. 文件头「实证程度」段与 `actorMovies()` 注释同步改实：演员列表已由 jar 版补实证、演员作品仍未证实且两参照客户端都走网页通道。

`test/javdb_api_test.dart`：

- 既有解析测试加请求形状断言：演员列表请求必须含 `api/v1/actors?type=0&page=1`（假取数记录 URL，不编响应形状——响应信封 `data.actors` 与字段 id/name/name_zht/avatar_url/gender 都照 jar 版实证形状）。
- 新增「名字空时落 name_zht」与「搜索参数名是 q 不是 keyword」两条测试。

## 五、测试结果

- `test/javdb_api_test.dart`：8/8 全过（原 6 + 新 2）。
- 相邻簇：`actress_javdb_stills_test` 13/13、`actress_javdb_extra_test` 10/10、`actress_pan115_offline_test` 19/19，全过（计数与各批基线记录一致）。
- analyze（改动两文件）：0 错 0 警；2 条 info（`prefer_initializing_formals`、测试文件 material 弃用提示）与基线组装树同文件对照**逐条相同**，均为存量、非本批引入。
- 结论：与基线对照 **0 新增失败**。

## 六、未验项（如实）

- **真拉未验、待手机验**：本机出口连不上 jdforrepam.com，`type=0` 修法只有 jar 版在役代码实证、没有本机真响应背书。手机上重点看：JavDB 源「演员」页签应出演员网格（不再报 type 错）；JavDB 搜索应出结果（q 参数修后）。
- 演员作品页（点演员进作品列表）走的 `api/v1/actors/{id}` 仍是拼接推定、无任何参照客户端实证，可能仍报错/回空；若手机实测不行，下一批应按 jar 版路线改走网页通道解析，或干脆改用「按演员名走搜索」的口径，请主聊定夺。

## 七、顺带查：截图「当前用户无权访问，请返回剧库后重新选择。」（只查不修）

**是 App 自有文案，不是站点返回的。** 出处：`lib/detail_screen.dart:1528-1531` 的 StatusPanel（标题「当前用户无权访问」+ 副文「请返回剧库后重新选择。」与截图逐字一致；截图右上角的刷新圆箭头也是该页顶栏的 RefreshAction）。

触发条件（`detail_screen.dart:1474-1476`）：

```dart
final allowed =
    widget.store.profileEpoch == _profileEpoch &&
    widget.store.allowsSource(drama.source);
```

`allowed` 为假时整个详情页被这块面板替换。`allowsSource`（`lib/local_store.dart:196-205`）先过 `SourceSite.isAvailable(source)`（`lib/models.dart:797-801`：只认内置站 id / 自定义 / 已导入 / 网盘站四类登记）。

**最可能的落点就是 JavDB 本源**：`javdb_view.dart:50` 的 `openJavdbWork` 打开作品时造的 Drama 写死 `source: 'javdb'`——这个 id 不在上述任何一类登记里，`isAvailable('javdb')` 恒为假 → `allowsSource` 恒为假 → 只要从 JavDB「最新作品」/搜索结果点开任何一部作品，必落这块面板（与用户两张截图相隔 1 分钟、同为日文片名标题的情形吻合；具体点的是哪一部无法从截图定死，但代码链是恒定触发的）。

对照：演员库其他入口不踩这个坑——本地库作品走演员库自有详情页（ActressDetailPage，不经这道门）；`actress_detail_page.dart:1247` 用的 `source: 'missav'` 是已登记的内置站 id。

修法候选（供主聊定夺，本批未动播放/详情链）：① 给 DetailScreen 的门禁加「演员库信息源」豁免口径（如 javdb 这类只提供信息、播放走番号竞速的源）；② `openJavdbWork` 改用一个已登记的承载源 id（需评估对跨站探活/线路归属的影响）；③ 把 'javdb' 登记为正式 SourceSite（牵动站点列表与门禁面，最大）。三者都牵动面不小，建议单独立批。
