# 状态（2026-11-21 v33）

## 当前版本
v33（未发布），基线 v32。

## 这轮改了什么
1. 女优库内嵌顶栏：`ActressListPage` 在 `showTitle:false`（内嵌进女优库区域）时
   不再渲染自己的 AppBar，改为一条置顶工具栏（搜索框 + 站点筛选/排行/刷新/设置
   同一行），解决「搜索框和宿主顶栏叠在一起」。
2. Go 核统一请求口：裸连优先 → 真被挡才带票重试 → 票废即作废 → 上报解盾。
   绝不用兜底内容顶替正常响应（v31 的坑）。
3. 新增 `shield_ticket_order_test.go` 固化票据顺序与判盾规则。

## 已排除的原因（别重复排查）
- missav.fans 核层正常：首页 200 / 336KB，/new 200 / 185KB，无盾。
- 7mmtv.sx 核层正常：首页 52 条卡片，`/en/censored_list/all/1.html` 20 条，
  封面 `n3.1024cdn.sx` 正常。站点无盾，域名 7mmtv.sx 是活的。
- whos.tv / javrate.com：真 Cloudflare 挑战（403 + "Just a moment..."），
  Go 直连的 TLS 指纹被识破，curl 能过不代表 App 能过 → 只能靠 App 内
  隐藏浏览器解盾回填票据，票据必须与签发时 UA 一起用。
- 因此「这几个站打不开」不是被加盾搞坏的：其中两个压根没盾。

## 下一步
- 云构建出包，真机点验自动解盾 / 人工验证弹窗。

## v34（2026-11-21 夜）
### 这轮改了什么
1. 女优库顶栏合成一条：内嵌时名册页不画 AppBar；搜索框只留外壳那一条
   （`externalSearch` 传入同一 controller），人数进工具栏；库路径块只在
   异常时显示；其它库卡片压成一行小标签。
2. 点头像取作品：视频库 `actresses.cate_id` 是**名字**不是 id，
   先 rowid→cate_id 再按 cate_id 取作品，去掉 32 万×47 万的大 JOIN；
   开库时补 `video_actress(cate_id)` / `(vod_id)` 索引（只读库建不了就跳过）。
3. 删内置 `assets/actress_json/whos_m3u/`（24MB）：实测 224,456 条地址
   224,454 条在用户库里，内置独有 2 条；索引读取缺资源时返回空，不抛错。
   保留 whos.json（还有 14,760 部库外作品）与 assets/live/m3u（直播用）。
### 未处理（基线既有，非本轮引入）
- `test/actress_test.dart` 界面组 9 个用例在 v33 基线上就红：
  6 个 pumpAndSettle 超时（顶栏输入框常驻光标动画）、3 个断言文案与
  v33 的「演员库 N 位演员」不一致。内嵌顶栏那个用例已修好并通过。

## v35（2026-11-21 深夜）
### 名册真正合并（用户令「名册要与 who's 女优数据库合并」）
- 根因：同一个女优在 `actresses` 里有两条（`木下ひまり（花沢ひまり）` 与
  `木下ひまり`），作品也劈成两份（217 + 739）。实测 300 组这种重复。
- 改法：按**名字**归并成一人，作品数相加（木下ひまり → 956 部真实可播数
  经 v34 精确统计为 755 部去重后）；建 `actress_rollup` 汇总表，
  源表行数变化才重建（一次约 1 秒），列表查询 5ms；只读库写不进时
  回退现算 SQL（0.8 秒）。
- 人数：29,237 → 28,956 人（合并掉 281 组同名）。
- 多人合并名（`A / B / C`）另 477 行、667 部，占 0.14%，暂不拆。

## v36（2026-11-21 深夜）问题站点批量修复
### 这轮改了什么
1. `sites_z2_maccms.go`：17rip 列表改走 `POST /index.php/ds_api/vod`（JSON），
   新增 `z2RipCatalogJSON`；`htmlprofile.go` 增加 `CatalogJSON` 钩子。
2. `sites_yh_pron91.go`：卡片容器兼容 `<article class="vitem">`，标题加 `<bdi>` 兜底。
3. `maccms_api.go`：MacCMS 引擎加「空分类自动回退」（`fallbackCategory`，带缓存）。
4. `sites_jar_tg.go`：429/5xx 指数退避重试（0.8/1.6/3.2s）。
5. 字幕翻译：新增 `GoogleTranslateTranslator`（gtx 免费端点）+ `ChainTranslator`；
   service 默认用内置通道，填了 LibreTranslate 就优先它、失败回退；设置页文案同步。

### 已排除的原因（别重复排查）
- 17rip 不是站挂：`/vodshow/*` 一律 200，只是列表容器空，数据在 POST 接口里。
- ikun 不是接口坏：`ac=list` 正常 67777 条；`t=1` 是空父类，videolist 才 0 条。
- 91pron 不是接口坏：`/v.php` 200/100KB，只是卡片 class 改版。
- 9sex/javrate/whos/javxu：真实 Chromium（反检测参数）+ 45s 等待仍卡在挑战页，
  Turnstile 级校验；avbobo 所有路径 401（出口 IP 门）；bili 服务端 6004；
  ins 官网域名已停放；gdian 只有下载引导页；heguo 5 域名全 NXDOMAIN；
  tg 镜像 `/json/` 连公开频道都 429。
- 单元测试 5 条红线为改动前基线（已 git stash 对比确认）。

### 下一步
- 云构建出包 v36，真机点验 17rip/91pron/ikun 与字幕翻译。

## v37（2026-11-22）三个 MissAV 站源 + 女优库播放入口
### 这轮改了什么
1. `jar_haijiao_takeover.dart`：MissAV官方|过盾、MissAV官方|原生、MissAVtv|原生
   三个 jar 全部接管到 Go 核 `hongguo`（镜像站），不再走各自旧实现。
2. `seku/sites_g2.go`：镜像站女优一览与下钻——头像/封面补全，作品卡带
   `title / vod_pic / vod_remarks`；`app_build.go` + `models.go` +
   `provider_media.go`：封面取图不再因 `cover_source` 不是注册站名而丢图
   （绝对 URL 直接放行）。实测：女优一览 24 人全部有头像，下钻 12 部全部有封面。
3. `actress_detail_page.dart`：库里这个番号有地址、但本机探活没过（不少流媒体站
   只认播放器请求头，探活 403/405）时，直接带库里地址进播放页，不再卡在列表只弹
   「播不了」；只有连库内地址都没有才去跨站现爬。
4. `actress_nvku_page.dart`：嵌在片库顶栏时（showTitle=false）不再重复输出
   「女优库 + 本地库 + 刷新」那一行，只留搜索框，顶栏合成一条。

### 已排除的原因（别重复排查）
- 镜像站列表/封面都有：`/cn/actresses` 24 人 24 图、`/actresses/<name>` 12 部 12 图，
  探针输出见 `seku` 测试记录；缺图是 App 侧封面源白名单问题，不是站点没图。
- 探针临时测试（zz_*.go、app_direct_media_test.go）已删，勿再加回。

## v37 实测核验（2026-11-22 01:2x，真网络探针）
- 三个 MissAV 入口（官方|过盾、官方|原生、tv|原生）已全量接管 `v_missav`，不再走各自写死 missav.ws 的旧解析。
- 镜像站列表链路实测通过：
  - `/cn/actresses` → 24 人，24 张头像（fourhoi.mrstcdn.store/actress/xxxxx-t.jpg）
  - 下钻 `/cn/actresses/波多野結衣` → 12 部，12 张封面，带时长备注
  - 详情/播放 → 解出 `b.surrit.mrstcdn.store/.../playlist.m3u8`，带 Referer/UA 头
- 官方域状态（别再重复排查）：missav.ws / missav.ai / missav.live 均 403（CF 拦机房）；
  missav.fans 200 正常；missav123.com 302；missav06.net 500。
- v37 包已核验：versionCode 11，证书 MD5 与 v36 同一把（可直接覆盖装），
  SHA256 与 Release 上的 SHA256SUMS 一致。

## v42（2026-11-22）五个 jar 站接管 + 封面直链/证书兜底
### 这轮改了什么
1. `lib/jar_haijiao_takeover.dart`：用户点名的五个 jar 站在 ART 上被 verifier
   直接拒（`ZakaJavmapAmns.resolve` 声明返回 `String[]` 实际返回 `String`），
   整个 spider 类装不上 → 表现就是没分类、没图、点开不能播。五个类全部接管到
   Go 核，走 public id（与 `native/core/provider_seku.go` 的 `sekuSlotPublicIDs` 对齐）：
   - `ZakaJavrateAmns`（鉴黄师）→ `v_javrate`（slot faguo）
   - `ZakaJavmapAmns`（日本大平台/JAVMAP）→ `v_javmap`（slot hanxiaoquan）
   - `ZakaPigavAmns`（朱古力）→ `v_pigav`
   - `ZakaGoodavAmns`（正妹AV）→ `v_goodav`
   - `Zaka9SexAmns`（av大平台）→ `v_avbigplat`
   五个 id 在 `lib/models.dart` 里都已声明，接管链路完整。
2. `seku/sites_javmap.go`：`jmapFixCover` 把 `images.x6av.com/getimages.php?src=`
   这种图片代理换回 CDN 直链——该代理实测 200 但正文 0 字节（就是灰块根因），
   直链实测 201KB/800x538 正常 JPEG。
3. `seku/api.go`：`Cover` 加 `coverLooseClient`，图片域只下发叶子证书时放宽一次
   证书链校验重取（只用于封面图片字节，不碰业务接口）。

### 已排除的原因（别重复排查）
- 五个站的 jar 类不是解析过时，是**字节码本身 verifier 不过**，改 jar 不如接管。
- javrate（鉴黄师）/avbigplat（av大平台/9sex）机房出口被 CF Turnstile 级拦，
  列表空是拦出来的，不是代码坏；真机侧走 `ShieldAutoResolver` 解盾回填票。
- javmap（日本大平台）分类/列表/详情都通，播放卡在它外挂的 7mmtv 播放页 CF JSD；
  `httpShieldMarker` 已含 `challenge-platform`，会进解盾队列。
- 52av：站点活（www.52av.one 200，Discuz 论坛，fid 分类齐全），播放器是第三方
  `video1.yocoolnet.in/api/player2.php`，页内不直接给 m3u8，靠播放器 JS 取。

### 验证
- `go build ./...` 通过；`go test ./seku/` 与改动前基线一致（HjwParseFixtures /
  JrMkURL / JrParseExpires / Av321B64AndSlug / Av321OrderCandidates 五条为历史红线，
  改动前后同样失败；TestZ2Smoke 内 z2_thdh 未注册亦为原有）。
