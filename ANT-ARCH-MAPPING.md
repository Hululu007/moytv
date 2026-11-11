# 蚂蚁影视架构逆向 + 本工程改造对照

> 对象：`app-arm64-v8a-release-1.apk`（包名 `com.leospring.flutter_ant_video`，versionName 2.0.6 / versionCode 2020，minSdk 24，targetSdk 28，597 个文件）
> 本工程：`moytv`（魔蚁box，`com.moyi.box`，Flutter 3.47 / minSdk 24 / target & compileSdk 36）

---

## 一、对方的运行时架构（拆包实测，不是猜的）

| 层 | 实现 | 包内证据 |
| --- | --- | --- |
| 界面 | Flutter Release AOT | `lib/arm64-v8a/libapp.so` 27.0 MB、`libflutter.so` 11.6 MB |
| 播放 | mpv + FFmpeg 全家桶，另有 mdk / fvp 软解 | `libmpv.so` 21.7 MB、`libavcodec.so` 14.1 MB、`libavformat/libavfilter/libavutil/libass.so`、`libmdk.so`、`libfvp.so` |
| 脚本运行时 | 三套并存：QuickJS、Node、Python 3.12 | `libqjs.so`、`libnode.so` 49.5 MB、`libpython3.12.so` + `libpythonbundle.so` + `libpythonsitepackages.so` |
| 蜘蛛/源引擎 | drpy2 + drpy-core-lite + XBPQ 模板 | `assets/flutter_assets/assets/js/lib/`：`drpy2.js`、`drpy2.min.js`、`drpy-core-lite.min.js`、`模板.js`、`cat.js`(参数函数库)、`cheerio.min.js`、`htmlParser.js`、`crypto-js.js`、`node-rsa.js`、`jsencrypt.js`、`pako.min.js`、`gbk.js`、`dayjs.min.js`、`he.js`、`qs.js`、`jsonpathplus.min.js` |
| 小程序容器 | InAppWebView + 注入式 JS SDK | `assets/miniapp/ant-sdk.js`（24 KB）、`demo/`、`emby/`、`ant.png` |
| 规则编辑 | 内嵌 Monaco 编辑器 | `assets/flutter_assets/assets/monaco/` |
| 音乐源 | 洛雪(lx)风格音乐源 | `assets/flutter_assets/assets/music_lx/`、`js/lib/lx_music_example.js` |

### 小程序容器的关键设计（1:1 抄的这部分）

- `ant-sdk.js` 在 `document-start` 注入页面，页面不用手动引；首次调用前用
  `flutter_inappwebview.callHandler` 等桥接就绪，20 ms 轮询。
- JSAPI 命名空间实测为三个：**`ant.player`、`ant.request`、`ant.source`**，
  统一走一个 `antInvoke` handler，带 `callId` 做请求/回包配对。
- 权限是**声明式**的：能力必须写进小程序包内 `manifest.json` 的 `permissions`，
  未声明就调 → 直接 `PERMISSION_DENIED` 失败，不是静默降级。
- 小程序有独立安装目录 + 市场（zip 安装、在线站点型两种形态），
  还有**局域网服务**（只接受私有网段来源，端口可用性自检，失败有独立错误码）。
- 容器对路径做了越界校验（"小程序请求越界路径已拒绝""只能是目标小程序内的相对路径"），
  并且同一时刻只有前台小程序能拉起另一个小程序。

### 其它实测结论

- 采集/源访问是宿主统一代发的（"采集源访问""小程序接口"），页面/脚本不直接持有网络栈。
- 缓存清理是**分域**的：只清可重新加载的缓存，保留配置、收藏、观看记录、离线下载、
  小说与漫画章节、小程序数据和源运行环境。
- 目标机 targetSdk 只有 28，且申请了 `MANAGE_EXTERNAL_STORAGE`（全盘文件权限）——
  这是它能在任意目录读源/写缓存的原因，我们按现代 Android 规范没跟这条。

---

## 二、我们这边对应的架构（已经有，保持不动）

| 能力 | 本工程实现 |
| --- | --- |
| 界面 | Flutter 3.47（AOT） |
| 网络内核 | Go 原生库 `libmoyi_core.so`（32 MB），TLS 指纹 / HTTP 全部走这层 |
| 脚本源 | Chaquopy Python 3.11（`libpython3.11.so`）+ py 站点、XBPQ 规则编辑器 |
| 播放 | mpv（`libmpv.so`）+ FFmpeg（`libffmpegkit.so`） |
| 小程序 | 自建容器 + 安装目录 + 市场 + 局域网共享（与对方同构） |
| 书/漫/音 | 听书、漫画、小说共用 `content_zone_screen.dart`（sourceType 区分） |

差别只在：我们用 **Go 内核 + Python 一套主运行时**，对方是 **QuickJS / Node / Python 三套并存**。
对方三套的代价是包体 267 MB（Node 一个就 49.5 MB）；我们已经够用，没有把 Node 搬进来。

---

## 三、本次对源码做了什么（删 / 并 / 换）

### 1. 设置页：从「一长条平铺」改为「分组式」（对齐对方的设置体系）

改前是 25 个 `ListTile` 一条道排到底（看起来像调试菜单），改后按 9 个分组归类：

| 分组 | 条目 |
| --- | --- |
| 播放与画面 | 播放器选择 / 观看体验 / 解析接口 |
| 外观与界面 | 外观主题 / 界面模式 |
| 网络与连接 | 网络与资源 / 代理内核 / 站点验证 / 过盾、指纹与请求头 |
| 源与规则 | 站源管理 / 内容源管理 / 站点检查 / 蜘蛛规则编辑器 |
| 存储与缓存 | 存储空间 / 导入中心 / 种子 |
| 小程序 | 小程序 |
| 媒体库 | 追剧 / 最近观看 |
| 设备 | 设备互联 / 设备注册档案 |
| 账号 | 用户管理 / 软件更新 / 关于 |

### 2. 删掉的重复入口

- 抽屉里原来把「软件更新 / 导入中心 / 解析接口 / 站点验证 / 代理内核 / 设备互联 /
  播放器选择 / 蜘蛛规则编辑器 / 观看体验 / 种子」十个工具再摆一遍，和设置页完全重复。
  抽屉只留三个高频入口（站源管理、内容源管理、播放器选择、导入中心、软件更新、设置），
  其余统一从「设置」进。
- 设置页里「Python 指纹过盾 / Jar 指纹过盾 / 自定义请求头」三个开关原来插在平铺列表中间，
  现在归到「过盾、指纹与请求头」一个页面（开关和存储字段一个都没动，旧配置照旧生效）。

### 3. 换掉的文案与入口命名

- 页面标题由「设置与备份」改为「设置」；条目文案统一成「能力 + 一句话说明」
  （例如「站源管理 — 独立更新、连接与播放检测」）。
- 「主题设置」→「外观主题」，「设置」下的备份类入口并进「存储与缓存」。

### 4. 小程序页：按你发的截图重做

- 顶栏：标题 + 新建（zip / 文件夹 / 链接三种安装方式）+ 网格/列表切换 + 设置。
- 双 Tab：**已安装 / 市场**。
- 网格图标：名称首字 + 按 appId 取色的圆角方块（不依赖小程序包自带图标，
  截图里那种彩色方块效果就是这么来的）。
- 长按 / 点击已安装项：打开、卸载、详情（详情里给 appId、版本、渲染方式）。

---

## 四、验证结论

| 项 | 结果 |
| --- | --- |
| `flutter analyze` | 0 error / 0 warning（其余 127 条是仓库原有的 lint 提示） |
| widget 测试 | `app_drawer_test` + `mini_app_test` + `ui_style_test` 共 38 条全过 |
| 构建 | Go 原生库 + Gradle `assembleRelease` 通过，APK 90.7 MB |
| 包信息 | `com.moyi.box`，versionName 1.0.0 / versionCode 1，minSdk 24，target & compileSdk 36 |
| ABI | 只有 `arm64-v8a`（30 个原生库，与云构建产物一致） |
| 签名 | v2/v3，`CN=Android Debug`（未配签名 Secrets 时的预览签，能装能跑，不能上架） |
| 新 UI 是否进包 | 已核 `libapp.so` 内的 UTF-16 字符串：9 个分组名、全部设置条目标题、小程序「已安装 / 市场」全在 |

---

## 五、以后要改的地方

- 出包：`python3 scripts/build_android.py --abi arm64-v8a --all-sources`（需 Android SDK + NDK 28.2 + Python 3.11）
- 云构建：推 `main` 或 Actions → `build-android` → Run workflow，可选 variant / abi
- 签名：配 `ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD` 四个 Secrets
