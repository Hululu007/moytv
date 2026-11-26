# 魔蚁TV 115 网盘取链与播放链修复报告（问题 1/2/3/5/6）

- 日期：2026-11-26
- 工作树：~/workspace/moyi_pan115_fix_20261126，分支 pan115-m115-fix，基线 efd0049（魔蚁 main）
- 依据：~/workspace/xingchen115_check_20261126/REPORT.md 的问题清单 1、2、3、5、6
- 纪律：只本地提交，未推仓、未构建。无真账号可测，凡单测验不了的都列在文末手机终验清单，不写「已验通」。
- 注：工作树根的 REPORT.md 是主树带进来的旧批次报告（.sql 导入修复），不是本批的，未动。

## 改了什么

### 问题 1：取直链改现行 m115 加密路（新文件 lib/cloud_drive/cloud_m115_crypto.dart）

自己实现了整套 m115 加密（无新增依赖）：

- RSA 裸运算：Dart BigInt.modPow，115 写死 1024 位公钥（模数取自 p115cipher 公开常量），非标准填充（固定 0x02 而非随机数），每块 117 字节明文 → 128 字节密文。
- XOR 混淆：两轮（4 字节 key + 12 字节 key），头部 len%4 字节与正文分块重启 key 的特殊口径按公开算法实现；解密侧 randkey 现算 XOR 密钥（rsa_gen_key，含 G_KTS 常量表）。
- 外层剥壳：AES-128-CBC（固定 key/iv，复用 cloud_aes.dart 的块解密 aesDecryptBlock，自己做 CBC 串联与标准 PKCS#7 去填充，密文长度先截到 16 的倍数）+ LZ4 块解压（自己实现，含帧格式 [2 字节小端长度][block] 循环与重叠 match 逐字节复制）。
- contentMaybeDecrypt：body 首尾是 {}/[]/"" 时原样返回，否则走 AES+LZ4。

Pan115Provider.directLink 改为：POST webapi.115.com/files/download，请求体只有 {"pickcode": ...}（不传 dl）经 m115 加密作 data 字段，取链 UA 置空；响应三层剥壳后取扁平结构 file_url，{fid:{url:{url}}} 嵌套结构只作兜底。老的 GET 跟 302 路径已删除。

加密正确性验法（重点）：m115 的 RSA 加/解密不是互逆运算（两边都用公钥指数，私钥在服务器侧），自加密自解密往返验不了。改用独立实现交叉向量：另写一份按同一公开算法独立实现的 Python 参考（~/workspace/pan115_m115_vectors_20261126/ref_m115.py，向量 vectors.json 同目录；AES 部分用 openssl 命令行、LZ4 部分用 python-lz4 标准库产生），生成 14 个向量用例放进 test/cloud_m115_crypto_test.dart 逐字节对答案：RSA 加密 5 例（含 117 字节整块边界、跨块、中文 pickcode）、RSA 解密 2 例（任意密文 + 参考实现算出的期望明文）、AES+LZ4 外层 3 例（含多帧）、XOR 2 例、rsa_gen_key 1 例。14/14 全过。
诚实边界：本机出口当时不通（PyPI/GitHub 都拉不到），没能直接跑 p115cipher 本体生成向量；向量来自独立 Python 实现，与 Dart 逐字节一致只能证明两份实现互相吻合，算法与常量本身的权威性仍靠 p115cipher/115driver 公开实现与星辰115 那份跑过 56 个向量的 Java 实现背书。真账号取链是最终裁决（见终验清单）。

### 问题 2：直链请求头契约（f 参数 + 下载会话 Cookie）

- CloudDirectLink 扩展四个字段：downloadCookie（取链响应 Set-Cookie 里那对 32 位 hex=32 位 hex，多个取最后一个）、expiresAtMs（URL 的 t 参数）、linkF（URL 的 f 参数）、fetchUserAgent（取链 UA，115 为空串）。
- directLink 组装 headers 的规矩定死：User-Agent 永远是取链时的空 UA；f=3 或没给 f（保守）时才带 Cookie，且只带那一对下载会话 Cookie；f=0/1 不带 Cookie。账号 Cookie 只发 *.115.com 接口，绝不再塞给播放器/CDN。

### 问题 3：扫码绑定改 qandroid + 三件套校验

- token 通道 alipaymini → web（/api/1.0/web/1.0/token/）；二维码优先用 115 出图地址（字段是 /scan/ 内容时才本地绘制，无字段时用 qrcodeapi 出图地址兜底）。
- 轮询改按 data.status 数值判读：0 等待、1 已扫、2 已确认、-1 过期、-2 取消（回 failed 并提示已取消）；status 缺失时保留旧启发式兜底（有 version 且无 msg 视为已确认）。
- 取凭证改走 qrcodeapi 的 /app/1.0/qandroid/1.0/login/qrcode/，表单只有 account={uid}，UA 固定 Mozilla/5.0；凭证从响应体 data.cookie 提取（字符串或键值对象两种形状都认），响应体没有时才退回 set-cookie 拼装兜底。
- 落盘前三件套校验：UID/CID/SEID 缺一不算成功，报错文案写明缺哪个键（normalizePan115Cookie / missingPan115CookieKeys）；通过后规范化为固定键序（UID/CID/SEID/KID，其余键丢弃）。再经 files/index_info 验活（见问题 5），判过期则不报成功；网络类失败不拦登录。

### 问题 5：Cookie 验活与过期处理（含世代保护）

- 新增 Pan115Provider.validateCookies（公开）→ Pan115CookieVerdict{valid, expired, networkError}：调 files/index_info，按结构分类——传输层失败、HTTP 405（限频）/408/429/5xx 归 networkError；过期三码 40101032/40101035/40101037 与其余服务端明确拒绝归 expired。
- 统一响应判读 _checkState 接进 listFolder / search / directLink：state 为假时先分过期/一般错误再解析 data。一般错误带服务端 error_msg 与错误码，不再笼统报「返回格式不对」。
- 命中过期三码：抛「115 登录已过期，请重新登录」，并清登录态——经新回调 CloudDriveProvider.onSessionExpired（引擎 cloud_drive_engine.dart 接线：只在存着的 cookie 与失效时用的那份一致时才 clear）。
- 世代保护两层：provider 内 _sessionGeneration（登录成功、判定过期各 +1；请求发出时记世代，回来时世代已变就不清）；引擎侧再比对 cookie 值。在途旧请求的过期报错清不掉新登录（有专门单测：在列表请求的处理过程中完成一次新登录、再返回旧凭证过期报错，断言不清）。
- HTTP 405 在 listFolder/search/directLink 统一按限频处理（「请求太频繁，请稍后再试」），不清登录态、不当凭证失效。

### 问题 6：播放器侧请求头适配（本批只做了云盘侧能定的部分）

已做：取链 UA 与播放 UA 的契约在 CloudDirectLink.fetchUserAgent + headers 里定死（空串是有效值，注释写明语义），引擎 resolve() 原样透传 headers 不变。
没做（播放器侧，单列待办）：

1. MPV 核（media_kit 的 Media.httpHeaders）：headers 里 User-Agent 为空串时，mpv 的 user-agent 选项为空会让其 curl 流发 libcurl 默认 UA，f=1 校验不过。对照方做法是发字面量 `User-Agent;`（http-header-fields 的空值头写法）。需要在播放层把「UA 空串」翻译成各核的空 UA 表达，属 player_screen / media_kit 适配层改动，不在云盘文件范围。
2. EXO 核：DefaultHttpDataSource 的 setUserAgent('') 行为需真机确认（是否真发空 UA，还是回落默认 UA）。
3. content_http.dart 在透传 headers 时会跳过空值条目（value.isEmpty 直接 return），若 115 直链的预解析跳转（playback_redirect）或其它取流路径走它，空 UA 会被换成默认 UA——修取链后这是下一个会咬人的点，需播放链批次一并处理。
4. 以上三点都要真机双核（EXO/MPV）各验一次 f=1 文件首请求才算数，列入终验清单。

## 接口连带改动

- CloudDriveProvider 新增抽象回调 onSessionExpired（与 onCredentialsRefreshed 同模式）：五家 provider 类各补字段声明（只有 115 会调用）；test/cloud_drive_engine_test.dart 的 FakeProvider、test/qr_poll_retry_test.dart 的 _ScriptedProvider 各补一行字段声明以满足接口。

## 测试与 analyze

- 新增 test/cloud_m115_crypto_test.dart：14 个用例全过（向量明细见上）。
- test/cloud_providers_test.dart 的 115 组按新协议改写/新增：qandroid 通道与三件套、缺 SEID 报错、二维码过期/取消、POST 取链 f=3/f=1/无 f 三种契约、无 pickcode 兜底、过期三码清登录、405 限频不清、世代保护、validateCookies 三类结论、normalize 键序。旧的 302 取链与 alipaymini 断言已删（那正是被修掉的老行为）。
- 全量（本批相关 7 个测试文件）：本树 168/168 全过；基线 efd0049 同 6 个文件（不含新增 crypto 测试）145/145 全过。对照结论：0 新增失败。
- analyze（lib/cloud_drive/ + 本批 4 个测试文件）：0 错误 0 警告，剩 7 条 info 均为基线既有（material 弃用、prefer_initializing_formals 等）。
- pub get 的副产物（GeneratedPluginRegistrant 两处）已 checkout 还原，不在本提交内。

## 不在本批（立项建议，照对照报告问题 4/8）

- 问题 4 转码 m3u8 兜底：建议先做 web 路（GET 115.com/api/video/m3u8/{pickcode}.m3u8，UA=Mozilla/5.0 取播一致，成本约半天），作原画失败时的自动兜底与可选画质；注意 web 路只认 web 绑定会话，而本批扫码已改绑 qandroid——web 路对扫码会话可能不通，安卓路（proapi POST + 同一套 RSA 加密 + user_id 获取链）与 qandroid 绑定正好配套，建议二期直接做安卓路（约 1 天）。两条路都依赖本批的 m115 底座，已就位。
- 问题 8 上传/容量：容量与用户信息各是一个 GET（files/index_info 已在验活里用上，my.115.com nav 接口取昵称/VIP），可随下一批顺带（约半天）；上传是独立中型工程（秒传签名链 + 假 ECDH token + OSS 分片与 V1 签名，3–5 天含实测），单独立项。

## 手机终验清单（没真账号，以下都没验，不许当已验通）

1. 重新扫码登录 115（旧 alipaymini 会话需重扫一次）：能出二维码、确认后登录成功。
2. 真账号取链：点播任意视频能取到直链并起播（原画），EXO 与 MPV 两核各验一次。
3. f=3 文件（多数文件）首请求不 403；f=1 文件在 MPV 下是否因空 UA 表达问题 403（问题 6 待办的真机裁决点）。
4. 长视频播到直链过期点附近的表现（本批只记录了 expiresAtMs，还没做过期前重取续链）。
5. Cookie 自然过期后打开网盘：应明确提示「登录已过期，请重新登录」并回到未登录态，而不是空列表/格式不对。
6. 鸿蒙卓易通容器内：扫码、取链、双核出画各过一遍（容器 UA/网络行为与普通安卓可能不同）。
