# 番茄取流三步修复（魔蚁主树 Go 核）

- 工作树：`~/workspace/moyi_fanqie_v5_20261124`，分支 `fanqie-v5`，基线 main `8a501e4`（v64）
- 状态：**树内完成，未合树、未构建、未推仓**（只按用户 18:51 令做树内）
- 上游依据：ch6vip/fqapp `2f31ba83`（2026-11-23，28 字段信封 + 备用门）与 `bef83c90`（2026-11-24，AnonymousV5）
- 诊断依据：`~/workspace/fanqie_stream_check_20261124/REPORT.md`
- **取流真播未验，待手机终验**（本机出口验不了真播，见“未验项”）

## 一、改了哪些文件

| 文件 | 改动 |
|---|---|
| `native/core/provider_hongguo_v5.go` | 28 字段信封 + extra 参数 + `hongguoV5PlaybackEnvelopeIsFull` + GET 签名共用段 + 匿名段（AnonymousV5Identity、anonymous_medusa、anonymous_playback_query、sign_anonymous_playback_v5）+ Float 原语 |
| `native/core/provider_hongguo_v5_gorgon.go` | 新建：`hongguoV5GenerateGorgon`（8404 变体，KSA 只赋值不交换的 quirk 原样保留） |
| `native/core/provider_hongguo_playback_routes.go` | 新建：梯子状态（Door/Route/routes()/PlaybackRouteState：plan/parked/exhausted/success/failed/note_round/rotate_due/rotation_paced/note_rotate），冷却 30 秒/5 秒、轮换节奏与上游一致 |
| `native/core/provider_hongguo_anon_identity.go` | 新建：TTEncrypt（ttEncrypt/ttDecryptResponse/normalize gzip 头）+ 匿名设备注册（4 秒超时、2 小时缓存、30 秒退避、10 分钟空包刷新、1 秒激活忽略结果）+ `current`/`refreshAfterEmpty` |
| `native/core/provider_hongguo_v5_media.go` | `hongguoV5FetchModel` 重写为梯子：三份体（anon/v5/model）+ 每门一次调用 + 空包同门重探 + 冷却记账 + 至多一次身份轮换后重跑；另加 tab 门整形、video_model 体、每门尝试函数 |
| `native/core/provider_hongguo_app.go` | `hongguoAppClient` 加 `playbackRoutes` 与 `anonIdentity` 字段（零值可用） |
| `native/core/provider_hongguo_v5_test.go` | 夹具按门打 tag；5 个旧策略测试按梯子行为重写；Branch12 测试扩到 28 字段全序 + 信封校验 |
| `native/core/provider_hongguo_v5_ladder_test.go` | 新建：4 个上游参考向量、路由状态、TTEncrypt、夹具梯子行为（见“测试”） |
| `native/core/provider_hongguo_multi_spade_test.go` | `TestHongguoV5ModelSingleRequest`：梯子先注册匿名身份再发一次 v5 请求 |
| `native/core/provider_fanqie_slot.go`、`provider_fanqie_media.go`、`provider_hongguo_native_media.go`、`provider_hongguo_new_media.go` | 只改过期注释（“V5 单腿”“空回包直接报错”等），逻辑一字未动 |

未动：Dart 界面、版本号、其他站。

## 二、上游原版 vs 修仙移植对照

逐项 diff 的结果（修仙树 `~/workspace/huoyi_juhe/rust/` 对上游两提交）：

**与上游一字相同**：`sign/v5.rs`、`sign/gorgon.rs`、`upstream/playback_routes.rs`、`device/crypto.rs` 的 TTEncrypt 两原语（只多 2 个单测）。

**只有局部附加的差异**：
- `upstream/playback_identity.rs`：上游 408 行 + 本地 16 行（`OnceLock` 进程级共享单例 `shared()`；构造失败会被缓存为错误直至进程重启）。
- `upstream/mod.rs`：`playback_identity` 由上游私有改成 `pub(crate)`（否则 endpoints::video 够不到）；另 `pub mod shuqi` 位置不同（与本次无关的既有差异）。

**以下 5 处偏离上游，Go 移植以上游为准（修仙版只当第二参考）**：

1. **model 门体错误**：修仙版没有独立的 video_model_body，model 门沿用 v5 体（其报告自认“假设，不是上游实证”）；上游 model 体是独立形状（biz_param：device_level 3、from_video_id ""、source 9、video_platform 3，另加 content_type 1004 + video_id）。Go 移植用上游的 model 体。
2. **tab 门字段缺失**：修仙版 tab GET 只带 video_id 一个字段（其单测也只验这一个）；上游带 9 个字段（video_id、video_id_type 0、device_level 1、need_all_video_definition 1、need_mp4_align 0、use_os_player 0、video_platform 1024、source 0、from_video_id ""）。Go 移植用 9 个。
3. **重探缺少守卫**：修仙版空包后无条件 sleep 250ms 再试一次；上游要求未重探过、门未 park、非 prefetch、尝试数 < 8、剩余预算 > 1 秒。Go 移植按上游守卫。
4. **轮换不完整**：修仙版全空后只在 rotate_due 时刷新匿名身份；上游还会轮换池设备、清 skip_routes、按全 routes 重跑一轮（每请求最多一次），且非空回包但无可用档位时也跳过该门并轮换。Go 移植按上游外层循环。
5. **plan 缺少已轮换分支**：修仙版只走 plan(now, false)；上游 rotated 且非 prefetch 时直接用全 routes()。Go 移植照此。

修仙版其余梯子语义与上游一致：梯子顺序 anon→v5→model-a→model-c→tab-b、空包冷却 30 秒/非空失败 5 秒、同门重探、note_round(all_empty)、anon 门内部空包刷新一次。

**两个上游细节是读 diff 才抠出来的，修仙版报告没写**：
- 前台全冷却时 plan 返回**全部**冷却门按恢复时间排序，循环里照常尝试（不是只探最早恢复的一门）；这是 2f31ba83 相对更早版本的改动。Go 的 Plan 照此实现；但注意同一请求内第二次取门时 skip_routes 已含全部门，所以不会立刻重探——冷却门重探发生在轮换清掉 skip_routes 之后，或下一个新请求里。
- 业务码失败的门只记 failed（5 秒冷却），不记 rejected；只有解析出模型但选不出可播档位时才记 rejected 并触发轮换分支。

**一个上游原文不在手头 diff 里的判断**：客户端 `rotate_playback_identity` 的函数体不在已取到的 diff 里（只有 video.rs 的调用方：超时、取新池设备 id 当 pin）。Go 的轮换同时刷池设备与匿名身份、任一成功即算轮换成功（梯子首门就是 anon， fresh 的匿名身份本身就值得再跑一轮）。若合树后有人拿到上游客户端原文，请核对这一处。

## 三、Go 落法

### 第 1 步：28 字段信封（`provider_hongguo_v5.go`）

- `hongguoV5PlaybackQuery(identity, ticket, appID, extra)`：原 12 字段后追加 16 个，顺序固定（ac=wifi、os=android、ssmix=a、device_brand=HONOR、language=zh、os_api=31、manifest_version_code=74332、resolution=1312*2848、dpi=480、host_abi=arm64-v8a、dragon_device_type=phone、pv_player=74332、compliance_status=0、need_personal_recommend=1、player_so_load=1、is_android_pad_screen=0）；门字段（extra）插在信封与 `_rticket` 之间；`_rticket` 仍在最后；query hash 与 `_rticket` 分支按 28 字段算。
- 新增 `hongguoV5PlaybackEnvelopeIsFull` 校验（16 字段齐全且非空）。版本号不变（7.4.3.32 / 74332）。
- GET 签名（`hongguoV5SignPlaybackGet`）与 POST 共用 `hongguoV5SignRequestAt`：零字节体摘要选分支，不带 Content-Type / Content-Encoding / X-Ss-Stub。
- Float 原语：proto 新增 `hongguoV5Float`（wire type 5，LE f32），只匿名 Medusa 用。

### 第 2 步：备用门（`provider_hongguo_v5_media.go`）

- 梯子顺序 anon→v5→model-a→model-c→tab-b。
- 单集门 `POST /novel/player/video_model/v1/`（两 host：api5-normal-sinfonlinea 与 api5-normal-sinfonlinec），体是独立的 video_model_body（见对照第 1 条），不是 v5 体。
- video_tab 门 `GET /reading/bookapi/video_tab/multi_video_model/v1/`（host api5-normal-sinfonlineb），extra 共 9 字段（见对照第 2 条）；回包先过 `video_tab_player_shape`（code==0 才取 data，重包成 `{"data": data}` 再解析）。
- 空包同门 250ms 重探一次，带上游全部守卫（见对照第 3 条）。

### 第 3 步：AnonymousV5（首选门）

- 端点同一 player/v1 但**带尾斜杠** `…/player/v1/`；体 = v5 体 + video_id + content_type: 1（只带当前一集，不带 upcoming）。
- 30 字段有序信封（`hongguoAnonymousPlaybackQuery`）：`_rticket` 位置靠前（第 4 位），egdi 非空时末尾追加 klink_egdi。
- 头：X-Khronos、X-Gorgon（8404 变体）、X-Argus、X-Ladon、X-Helios、X-Medusa（匿名版）、X-Xs-From-Web: 0、X-Ss-Stub（大写 hex body MD5）、Content-Type、Content-Encoding、User-Agent、Accept。
- Gorgon（`provider_hongguo_v5_gorgon.go`）：data = MD5(query)[..4] + MD5(body)[..4] + 4 零字节 + LE32(67503104) + BE32(ts)；KSA 只赋值不交换（quirk 原样保留）；末轮 rotate_left(4) + reverse_bits ^ 20，就地改写。
- 匿名 Medusa（`hongguoAnonymousMedusa`）：FLAGS、device proto 38 字段、env_13/environment/nested、message 字段 21 为 Sint(312)（旧版 377）、字段 16 为 sec_token 字符串；其余（seed、xmxor、check、packed、AES、prefix）与旧 Medusa 同构。
- 匿名身份（`provider_hongguo_anon_identity.go`）：注册 host `log5-applog-lq.fqnovel.com`，激活 host `log5-applog-lf.fqnovel.com`；app 7.3.9.32、Xiaomi 23127PN0CC、Android 14、os_api 34；TTL 2 小时、注册超时 4 秒、失败退避 30 秒、空包刷新间隔 10 分钟、激活 1 秒超时结果忽略；header JSON 全字段与上游一致；payload 经 gzip（头 10 字节归一化）+ TTEncrypt 发送；回包若以 TT_MAGIC 开头则 tt_decrypt_response，否则当原始 JSON 解析；device_id/install_id/egdi 取值与 valid_id 校验与上游一致。

### 梯子编排（`hongguoV5FetchModel`，对照上游 `fetch_playback_model` + `fetch_resolved_playback_model`）

- 每请求最多 8 次门尝试（含一次同门重探）；skip_routes 记已试过的门；Body 即返回；Empty 记 failed（30 秒冷却）；Failed/Deadline 记 failed（5 秒冷却），Deadline 跳出整轮。
- 解析步（`hongguoV5FetchParsed`）：JSON 解析失败或业务码失败 → 该门记 failed（非空），梯子继续下一门；解析出模型但选不出可播档位 → 记 rejected，继续循环。
- 外层：全门试完且尝试数没再涨时，若 rejected 存在、或（轮换节奏允许且（全空或轮换到期）），则轮换一次（池设备重注册 + 匿名刷新，任一成功即算成功）、清 skip_routes、按全 routes 重跑；每请求最多轮换一次。
- 成功时记 success + note_round(false)；全败时 note_round(all_empty)，全空才开播放器暂停窗口（见“行为变化”）。

### 有意偏离（已在代码注释里标明）

1. **状态放每 Downloader 一份**，不是上游的进程级 OnceLock 单例：Go 核已有 per-Downloader 状态模式，且便于测试隔离。语义（冷却、plan 顺序、轮换节奏）与上游一致。
2. **池设备换设备预算每请求共享 3 次**，不是上游的每门 3 次：Go 核无有界设备池可轮换，沿用旧单腿“每请求 3 次”的不变量。匿名门不走池设备，不占预算。
3. **v5 门体保留魔蚁本地的 upcoming 预取形状**（"1004": [当前, 后续…]，最多 3 个 id）：上游 v5 体只带当前一集；旧单腿就这么取后续集进预取缓存，改掉会丢预取。anon 体与 model 体严格按上游只带当前一集。
4. **轮换同时刷池设备与匿名身份**（见对照节末尾的判断说明）。
5. 匿名注册的 JSON 序列化：Go `encoding/json` 与上游 serde_json 一样按键排序，字段与值逐项对过（40+ 字段）。

### 行为变化（相对旧单腿，测试已钉住）

- 空包不再直接报错：先同门重探一次，再降级下一门；全门空包且轮换到期时轮换一次再跑；最后才报空包错误（仍带“限流”字样，三个媒体槽靠它拼提示）。
- 业务码失败不再直接报错：该门失败，梯子继续下一门；全门业务失败才报最后一个业务错。
- 空模型（有 body 但无本集模型）不再开播放器暂停窗口：暂停窗口只在**全轮空包**时开；空模型走 rejected + 轮换。
- 全 401/403 耗尽时仍报“换设备 3 次后仍失败”（旧文案保留）；暂态耗尽仍报最后的 HTTP 状态。

## 四、测试

- `go vet ./...`：干净，0 输出。
- `go test ./core/ -run 'TestHongguoV5' -count=1`：**37/37 通过**（约 4 秒），含：
  - 4 个上游参考向量全对上：匿名 query SHA-256（`8aa5299b…`）、匿名 Gorgon（`840434124001…`）、helios SHA-256（`ec80528b…`）、匿名 Medusa SHA-256（`1dcbde6e…`）。
  - 28 字段信封：全序 + 各字段值 + `envelope_is_full`（12 字段旧信封判不满）。
  - 梯子顺序 anon→v5→model-a→model-c→tab-b；冷却语义（空包 30 秒/非空 5 秒、成功清冷却并置顶、speculative 只取 1 门、全冷却时前台取全部按恢复时间排、speculative 全冷却取空）；轮换节奏（2 轮全空才到期、speculative 永不轮换、成功轮换后 30 秒内不再轮）。
  - TTEncrypt round-trip + gzip 头归一化；model 体（10 字段 biz_param、content_type 1004、无 mixed map）；anon 体（只带当前集、content_type 1）；tab 查询 9 字段 + 整形（业务码/无 data/非法 JSON 均判失败）。
  - 夹具梯子行为（请求序列逐字钉住）：anon 首门命中；anon+v5 空包降级到 model-a；全空降级到 tab-b；v5 业务码失败降级到 model-a；401/403 换设备（3 次耗尽仍报“换设备 3 次”）；暂态 500/429 同设备重试；全空包触发一次轮换后重跑；400 直接失败。
- `go test ./core/ -count=1` 全量：本分支跑到约 6 分钟时被我 SIGQUIT 中断核查，日志里 9 个失败；**基线对照（`8a501e4` 干净树，同一命令，跑满 600 秒超时）失败清单一字相同**：TestNativeCoverDecryptsAndPersistsAcrossRestart、TestNativeCoverFormatsFailuresAndOfflineFallback、TestNativeCoverRedirectAndBoundedDiskCache、TestNativeCatalogCacheFreshnessPagingAndRefresh、TestNativeCategoryDiscoveryUsesSourceLinks、TestNativeHLSExtensionlessPlaylistsAndRedirectBase、TestSourceHealthRejectsHTML200AndPreservesFailureStage、TestSourceHealthChecksHLSKeyAndBoundedMedia、TestDanmakuTruncationKeepsEmojiIntact——**全部是基线旧败，0 新增失败**。core 套件在基线也跑不满默认 10 分钟超时（大量用例走真实网络/长超时，CPU 几乎空闲），是既有状况，与梯子无关。
- `go test ./...` 全量：`core/seku` 包 600 秒超时；**基线对照同样 600 秒超时**，另有 5 个 0.00 秒瞬时失败（TestHjwParseFixtures、TestJrMkURL、TestJrParseExpires、TestAv321B64AndSlug、TestAv321OrderCandidates）——同样是基线旧问题，与本次改动无关（本次没碰 seku 任何文件）。

> 注意：本次全量 core 测试耗时很长（大量用例走真实网络/长超时，CPU 几乎空闲），不是梯子变慢——V5 子集只要 4 秒。测试中途的 SIGQUIT 是我为定位卡住位置主动发的，不是测试自己超时。

## 五、未验项

- **取流真播未验，待手机终验**：本机出口到字节系边缘普遍 17–27 秒回包且多为空包，验不了真播。手机上需验：番茄站播一集（首选 anon 门）、红果站播一集（同链）、多集连续播（预取缓存）、限流时降级是否生效。
- 匿名身份注册整条链未发过真实请求：注册 host（log5-applog-lq）与激活 host（log5-applog-lf）本机没通过；若手机上该域名不通，anon 门会直接失败并降级到 v5 门，不会卡住播放（夹具已覆盖该路径：注册失败 → anon Failed → v5 接管）。
- model 门请求体是上游原文（非假设），但同样没发过真实请求；tab 门 9 字段亦然。
- 轮换分支（池设备 + 匿名身份同刷）的真实效果未验：夹具只验了逻辑。

## 六、合树注意点

- 主树 main 正被 tag-filter 合并推进（合树工人在 `~/workspace/moyi_main_checkout` 里），合树时需 rebase 到新 main；本分支只碰 Go 核取流文件，与 tag-filter 的 Dart 改动无交集，冲突面小。
- 本分支基线 `8a501e4`；合树前重跑 `go test ./core/`（或全量）确认。
- `provider_hongguo_v5_test.go` 的夹具已改签名（answer 按门打 tag），若合树时别的分支也在改同一夹具，以本版为准。
- 不要把本分支的改动与修仙树 `~/workspace/huoyi_juhe` 的 Rust 版混淆：两者是同一修复的两种语言实现，Go 版以上游为准，修仙版 5 处偏离已在对照节列明。
