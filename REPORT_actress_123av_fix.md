# 演员库 123AV 取址修复（独立小批）报告

分支 `actress-whos-ui`，基线 421e797（第三批）之上。依据：出口补验批报告 `~/workspace/egress_verify_20261126/REPORT.md` 第三节（全链实拉验通）+ 其存档真页样本。

## 死点与修法（四点全落）

旧实现死点：`av123EmbedOf` 主正则写死了 `javplayer` 域名找 iframe 嵌入地址，而嵌入域名早已轮换，永远找不到。

1. **取址改内联脚本**：集数/取址数据不在 iframe 里，在详情页内联调用 `player(JSON.parse('…转义JSON…'), 标题id, 番号, …)` 第一个参数里。新 `av123EpisodesOf` 先用 `av123JsUnescape` 解转义（反斜杠+任意字符→该字符、`\uXXXX`→码点，此解法已用补验批真页样本在本地验证过），再 `jsonDecode` 取集数数组（`{episodes:[...]}` 形也认），每集带 number/name/url。`av123EmbedOf` 改为取第一集 url；旧正则降为兜底且去掉域名写死（任意域名 /e/{id} 都认）。
2. **嵌入域名不写死**：从内联 JSON 现读（实证时已由 javplayer 轮换成 sadie-shop.site，今后还会轮换）；流媒体域名同理以 /stream 接口返回为准。
3. **取流走 /stream 接口**：`av123StreamRequest` 拼 `嵌入源 + /stream?{原查询参数}&id={集数哈希}`（id 取自 /e/{id} 路径段），不再找播放器 iframe。回包按真形状解析：`extractAv123Stream` 先 JSON 取 `media.stream`（实证回包 `{"status":"ok","media":{"stream":"…m3u8","vtt":"…"}}`），解不出再退原正则链。
4. **Referer 用嵌入页地址**：取流请求与返回播放地址的请求头 Referer 都改成嵌入页完整地址（此前取流用站根、播放用嵌入源根）。

实证锚点（补验批）：详情页 200 → 内联 JSON 解出 `https://sadie-shop.site/e/1RWL3E?poster=…` → /stream 回真 m3u8 → 主列表 200 → 变体 200（4819 分片 ≈ 4.0 小时全长）→ 首分片 Range 206、首字节 0x47。

## 改动文件

- `lib/actress/actress_online_parse.dart`：新增 `av123JsUnescape`、`av123EpisodesOf`；`av123EmbedOf` 换主路；`av123StreamRequest` 注释口径改实（拼法不变、id 字符集放宽含 `-`）；`extractAv123Stream` 加 JSON 主路。
- `lib/actress/actress_online_sources.dart`：123AV 取流/播放 Referer 改嵌入页地址；类注释改实。
- `test/actress_online_parse_test.dart`：集数 JSON 用例换成补验批真页样本逐字摘录（番号 c-2582-uncensored-leaked 的内联段）；取流拼址改 sadie-shop.site 样本；新增真回包形状用例；旧 javplayer 夹具改为任意域名兜底用例。

## 验证

- `actress_online_parse_test.dart` + `actress_online_lines_test.dart` 合跑 21/21 全过（lines 用例经 resolvePlay 全链：详情→内联 JSON→/stream→m3u8）。
- analyze 改动文件 0 错 0 警。

## PH 侧口径更新（解析层不动）

PH 未验原因按补验批结论更新：不是站方拒绝、也不是解析不对——签名 m3u8 绑取页时的出口 IP，本机出口每开新连接就换 IP，取页与取 CDN 必然不同 IP，签名一律判 410。手机是单一固定 IP 环境、取页取流同 IP，此 410 不必然复现。PH 解析层维持现状，继续标「未验（签名绑 IP，待手机单 IP 环境验）」。
