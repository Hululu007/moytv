# 演员库 JavDB 补磁力 + 评论 + 信息卡系列/评分（2026-11-26）

基线 9dab199（分支 actress-whos-ui），接在补剧照一批之后、分开
提交。本地提交、不推仓、不构建。

## 需求

用户拿 JavDB 详情页截图对照后查实缺三样，补上：
1. 磁力下载链接区（在线线路区下面）：按番号走 JavDB 接口补；
   名称 + 大小/日期副标，点按=复制磁力链接到剪贴板并给中文提示；
   只给链接，不做站内播放、不做下载器、不接第三方网盘。
2. 评论区（作品详情页最下方）：按番号命中后取评论，只读展示，
   头像走 JavDB 图片 XOR 解密路径；不做发表/点赞交互。
3. 信息卡补「系列」和「评分（共 N 人评分）」：JavDB 真返回时照
   原值补进，拿不到不显示、不编造；本地库自带真值照旧优先。

## 接口证据（AvPlay 反编译源码逐字查实）

- 磁力模型 JavDbApiMagnet 字段：hash / name / size（JsonElement）/
  created_at / hd / cnsub；toMagnetOrNull 拼法逐字实证：链接 =
  `magnet:?xt=urn:btih:{hash}`（hash 空则整条丢弃）、name 空回落
  hash、size 走 asMegabyteSizeText（数字按 MB 读）。
- 磁力列表信封 JavDbApiMagnetsData：`{magnets: [...]}`。
- 评论模型 JavDbApiReview 字段：username / content / created_at /
  likes_count / score（模型里没有头像字段）；评论列表信封
  JavDbApiReviewsData：`{reviews: [...]}`。
- 详情模型 JavDbApiMovieDetail 字段含 score / reviews_count /
  series_name / comments_count（没有 score_count 字段）。
- 路径：API_MAP 只写 …/magnets、…/reviews，本批拼为
  `api/v1/movies/{id}/magnets`、`api/v1/movies/{id}/reviews`，
  **拼接推定、未逐字证实**，真响应未验（见未验项）。

## 改动文件与落点

- `lib/actress/javdb_api.dart`：
  - JavdbMovieExtra 新增 score（原值文本）/ scoreCount（人数：
    score_count → score_users → reviews_count 兜底链；AvPlay 详情
    模型只有 reviews_count 一个计数字段，它与「评分人数」的配对
    关系属推定，已在代码注释与本节标注）。
  - 新增 `movieMagnets(movieId)` → List<MagnetLink>（复用通用
    MagnetLink 模型）：顶层解析函数 `javdbMagnetLinkOf` 照实证
    字段拼链，另宽容 magnet/magnet_url/url/link 现成链接字段；
    `javdbSizeLabelOf`（数字 MB→文本、字符串照原样）、
    `javdbDateDigitsOf`（日期归一 YYYYMMDD 给 metaLabel 拼日期）；
    hd → quality 'HD'、cnsub → 标签「字幕」。
  - 新增 `JavdbReview` 模型与 `movieReviews(movieId)`：字段照
    实证直认，昵称/头像另从 user 子对象与 nickname/avatar 类键名
    宽容兜底，空内容行跳过。
  - 客户端出错口径与既有方法一致：抛错给调用方兜底，不吞。
- `lib/models.dart`：DramaDetail 新增 `withExtraInfo`（照
  withStills 样式）。
- `lib/detail_screen.dart`：
  - 新增 `_loadJavdbExtras(drama, generation)`，与补剧照同一处
    后台补充链（_load 成功路 + initialDetail 回退路各一处
    unawaited 调用，紧挨 _loadJavdbStills）。番号命中方式：JavDB
    入口作品 sourceId 即 JavDB 作品 id、直接用；其余入口先
    searchMovies 按番号归一化精确相等才认。命中后磁力/评论/
    详情三路并行、各约 6 秒超时、各独立失败回空；代次守卫。
  - 系列/评分并入 _detail.extraInfo（仅当自带 extraInfo 没有
    同名行时），信息卡照既有整表渲染自动显示，本地自带真值
    不被覆盖。
  - 新增 `_javdbMagnetSection()`：布局照通用 _magnetSection
    （标题「磁力链接」+ 名称 + metaLabel 副标），副标下注明
    「来源：JavDB · 点按复制磁力链接」，行尾复制图标，点按走
    `_copyMagnet`（Clipboard + 「磁力链接已复制」提示）。三处
    布局（宽屏左栏、窄屏两分支）都插在在线线路区之后。
    **没有并入 _detail.magnets 复用 _magnetSection**：查实其点按
    口径是弹「磁力链接暂不支持播放」、与本任务要求的复制口径
    不合，属任务预留的「结构不合」情形；改它的点按会动通用
    详情页既有行为，故按后备口径在演员库链加等价区，通用区
    一行未动。
  - 新增 `_javdbReviewsSection()`：三处布局都插在相关推荐之后
    （页面最下方）。头像走 _detailStillImage（图床地址过 XOR
    解密、其余直显），无头像用昵称首字占位；昵称 + 日期一行、
    内容、点赞数（>0 才显，只展示不可点）。
  - 注入口 javdbStillsClient 注释放宽为 JavDB 补充链共用
    （名称未改，上一批测试不受影响）。
- `test/actress_javdb_extra_test.dart`（新增）：8 例。

## 验证

- 新测试 8/8 全过：磁力解析 3 例（实证字段拼链/大小日期归一、
  字符串大小与直给链接、无 hash 行跳过、出错抛错口径）、评论
  解析 1 例（实证字段 + user 子对象兜底 + 空内容跳过）、评分
  解析 2 例（原值 + reviews_count 兜底、score_count 优先）、
  详情页接线 2 例（三区出现 + 信息卡系列/评分 + 点按复制并验
  剪贴板内容与提示文案；番号没命中时三区全不出现且不去取别片
  数据）。
- 回归（与基线 9dab199 对照）：javdb_api_test、
  actress_javdb_stills_test、actress_javdb_extra_test、
  actress_detail_sections_test、actress_online_lines_test、
  actress_online_parse_test 六文件合并跑全过、0 失败、0 新增
  失败。
- analyze 改动文件（javdb_api.dart / models.dart /
  detail_screen.dart）：0 错 0 警，仅 2 条存量 info（构造器
  prefer_initializing_formals 为原有写法、material.dart 弃用
  提示全仓都有）。

## 未验项（手机终验）

- JavDB 接口真拉未验：本机出口断，magnets / reviews 两条路径
  本身又是拼接推定——响应信封与字段已按 AvPlay 模型夹具验真，
  但真接口的路径与形状要手机侧（或出口恢复后）证实；若真路径
  不同，两区会保持不显示（不挡页），按真响应再修路径即可。
- 手机终验要点：本地库打开一部番号能命中 JavDB 的作品——
  在线线路区下面出现磁力区、点任意一行提示「磁力链接已复制」
  且粘贴出来是完整 magnet 链接；页面最下方出现评论区、头像
  正常显示（解密路径）；信息卡出现系列与评分行（接口有给时）。
