# 魔蚁TV v30（1.0.0+8）修复说明

本轮改动全部围绕三件事：删掉腐老二、把 MissAV 播放真正修活、让 Go 核站点吃上清关票据。

## 1. 删除「🔞腐老二」站点

按用户指示直接下架，不是隐藏而是连根删掉：

- 站点列表里的条目（`lib/models.dart`）
- 站点图标映射和图标文件（`lib/site_builtin_icons.dart`、`assets/site_icons/ic_app_fl2.png`）
- Go 核整份实现（`native/core/seku/sites_yh_fulao2.go`）
- 注册表 slotOrder 与 provider 映射（`registry.go`、`provider_seku.go`）

删完 `grep fulao2` 全库只剩三行无关注释（娜娜站里提到同族实现）。Go 核重新编译通过。

## 2. MissAV 播放修活（核心）

### 问题不是域名，是站点换了两样东西

诊断结论（实测，不是推测）：

- 站点把媒体 CDN 从 `surrit.mrstcdn.store` 换成了 `*.b-cdn.net`（Bunny CDN）
- 播放地址不再明文写在页面里，改成塞进 JS 压缩器（Dean-Edwards packer）里

所以镜像域名再多也没用——老代码找的是老域名，新地址根本不出现。

### 怎么修的

Go 核里加了通用解包器（`sites_g2.go`）：识别 packer 的六参数形式，按 base-N 键表还原 payload，再从还原后的 JS 里取播放地址。字典顺序、进制、主机名每页都不一样，所以只能真解，不能正则硬套。

播放地址优先级不变：先解包，解不出来再走老的「反转片段」和「surrit 明文」两条兜底。

### 实测结果

- 详情页 m3u8：`200`
- 分片：`200`，1,003,732 字节，`h264 1280x720 + aac`
- 播放头：无 Referer、错 Referer、空 UA 全部 200 —— Bunny CDN 不校验，比原来的盾好搞
- 列表页：真页面解析出 12 张卡片（番号/标题/封面都对），封面源 `200`

## 3. 清关票据接进 Go 核站点（鉴黄师等）

### 原来的缺口

App 里本来就有一套人工清关（WebView 过一次 Cloudflare，回填 `cf_clearance`），但这套只服务 Dart 侧发出的请求。Go 核站点撞盾后拿不到票据，也报不出挑战——所以页面是白的，用户还不知道能去解一次。

### 怎么修的

在过盾层加了双向桥（`native/core/seku/shield.go`）：

- **查票**：Go 核站点发请求前，本地票池没票就问 App 的清关库，拿到就带上 Cookie 和签发时的 UA（UA 必须对齐，否则票据作废）
- **报挑战**：真撞上 Cloudflare 挑战页（不是空响应、不是普通 403），回报给 App 的待清关列表，节流 5 分钟一站一次

`app_runtime.go` 启动时把这两头接上。不绑定任何站点，所有 Go 核站点共用。

这样鉴黄师（javrate）被挡时不再是白页：App 会显示该站待清关，用户解一次，票据回填后重试即可出内容。

## 4. 顺手补的

- `whos`、`nvku`、`qilinyingshi` 三个内置 py 源缺主页映射，补齐（站点图标/主页判定会用到）
- 图标与映射表的计数断言跟着实现更新

## 验证情况（照实说）

- Go 核：`go build` 通过，新增 6 个单测全过（packer 解包 3 个 + 清关桥接 3 个）
- Dart：`flutter analyze lib/` 0 error，站点相关测试 31 项全过
- MissAV：真页面、真 m3u8、真分片验过（见上）
- 鉴黄师：**没能在我这边出内容**。javrate 对机房 IP 一律回 Cloudflare 挑战页，现成中转（r.jina.ai 要授权、relay 被限流）都不通。清关通路是代码层做好并测过的，但「用户手机上解一次能不能过」需要真机点一遍才算数
- 5 个历史遗留单测（hjw fixture、jrMkURL、expires、av321 两条）在改动前后都失败，属早先就与实现不一致，本轮未动
