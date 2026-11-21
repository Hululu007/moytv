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
