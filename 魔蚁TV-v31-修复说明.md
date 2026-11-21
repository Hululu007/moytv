# 魔蚁TV v31 · 全站点冒烟 + 通用过盾

## 一、全站点冒烟（真实请求，不挂代理）

三层分开测，因为三类站点形态不同，混在一起测不准。

### 1. 站点直连探测（257 个站点主页 / 225 个独立域名）
- 直连即可用：**189**
- Cloudflare 人机校验：**30**
- 其他 403（多为防盗链/风控）：11
- CF 硬拦（1020 一类）：8
- 服务端 5xx：5
- 域名/端口不通：5

> 首轮有 44 个「连不上」是本机出口被限流造成的假失败，已用低并发逐站复测排除（32 个复测后正常）。

### 2. py 蜘蛛实跑（122 个）
直接调每个蜘蛛的 homeContent，等同于用户在 App 里点进去：
- **122/122 正常出分类/内容**
- 结论：py 站点自带镜像与过盾兜底，机房 IP 也能出数据。

### 3. Go 核站点实跑（73 个）
取每站第一类目第一页：
- **59/73 正常出内容**

失败 14 个，归因：

| slot | 现象 | 归因 |
|---|---|---|
| avbigplat | 9sex: all domains failed for /tw/video/all | 待跟进 |
| faguo | catalog returned 0 items (cat=/movie/new) | 待跟进 |
| heguo | catalog returned 0 items (cat=video) | 待跟进 |
| huangdou | whos fetch /videos -> 403 | 需要过盾 |
| ikun | catalog returned 0 items (cat=1) | 待跟进 |
| wangguo | catalog returned 0 items (cat=home) | 待跟进 |
| yh_avbobo | yh_avbobo login failed on all hosts | 待跟进 |
| yh_bilibili | yh_bili login refused: decrypted data is "null" (outer code  | 待跟进 |
| yh_gdian | yh_gdian: base not calibrated (shell page, target not resolv | 待跟进 |
| yh_haijiao | Post "https://api1.ogokfmrx.com/api.php/api/api/mv/list_cons | 待跟进 |
| yh_ins | yh_ins: no guest Authorization token (App sniffs it from H5  | 待跟进 |
| yh_maomi | Post "http://150.109.116.53:8089/api/v2/original/index": con | 待跟进 |
| yh_pron91 | catalog returned 0 items (cat=rf) | 待跟进 |
| z2_17rip | catalog returned 0 items (cat=1) | 待跟进 |

## 二、通用过盾（这次的核心改动）

### 问题根因
Go 核每个站点都自己写取页函数，盾层工具（票池、多通道）只有少数站用得上，
所以每加一个新站，被盾一挡就是白页——这正是 whos / javrate / javxu / 9sex 现在的状态。

### 改法（不针对任何站点，新站自动继承）
1. **统一请求出口**：所有 Go 核请求合并到一个出口，自动带上票池里该主机的通行证（cf_clearance + 签发时 UA），UA 和票必须配对，否则票判无效。
2. **撞盾自动上报**：只在「确认是人机校验页」时上报（页面小 + 带挑战特征）。这里刻意不看响应长短、也不看裸 403——避免把正常小接口和防盗链当成盾（实测 av123 就是被误判搞空过）。
3. **App 内自动解盾**：命中挑战后，App 用一个 1x1 隐藏浏览器把校验跑完，拿到 cf_clearance 自动回填票据库，之后同主机请求全部带票，用户无感。
4. **人工验证兜底**：少数要真人点复选框的（交互式 Turnstile），自动解盾过不去时弹窗让用户点一下，点完同样自动回填，以后不再问。
5. **有票即重试**：回填后遇到被挡请求会立刻用票重试一次，拿原文，不用中转。

关键：这套只认「某主机被挑战」这件事，**不认识任何具体站点**，所以以后新加的站点自动生效。

## 三、删除的站点

两个站点确认已死，按「修不了就删」处理：
- **🔞猫咪 （yh_maomi）**：所有已知地址（124.156.119.252 / 124.156.98.46 / 150.109.116.53 / mao.1f866.com）全部不通，无可用域名。
- **🔞海角社区 （yh_haijiao）**：API 域名 api1.ogokfmrx.com 已失效，原站域名 p3.soqjpaqj.cc 已跳转域名停放页（urldance.com），站点本身已关停。

## 四、验证记录
- `go build ./...` 通过
- `dart analyze`（新增/改动文件）0 issue
- Go 核冒烟改造前后对比：改动前 59/73，改动后 59/73，无回归（av123 一度误伤，已修正并复测恢复 12 条）
- 单元测试：与基线一致（历史遗留失败项与本次改动无关）

## 五、真机需要验证的
自动解盾依赖 App 内 WebView 执行站点校验脚本，沙箱没有真浏览器，这一步**只能真机验证**。
装好后打开 whos、鉴赏师（javrate）、JavXu 这类站：
- 正常情况：首次加载空白几秒 → 自动出内容（后台已回填票据）
- 少数站点会弹「站点需要验证一下」→ 点「去验证」过一下即可，之后不再问
