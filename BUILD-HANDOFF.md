# 构建交接说明（给接手的 AI / 开发者）

这份文档的目的是：任何人或任何 AI 拿到这个仓库，不改一句话就能把 APK 编出来；要改功能，也知道改哪里、怎么验。

---

## 1. 工程是什么

Flutter 安卓壳 + Go 原生核心 + Chaquopy 内嵌 Python。

| 部分 | 位置 | 说明 |
|---|---|---|
| Flutter UI | `lib/` | 主界面、播放器、抽屉菜单、阅读区、小程序容器 |
| Go 原生核心 | `native/` | 编译成 `libmoyi_core.so`，走 FFI |
| Python 蜘蛛 | `recovered/python/`、`assets/py_spiders/` | Chaquopy 打包进 APK，运行时跑爬虫 |
| 内置 jar | `assets/jars/zakatv.jar`、`assets/jars/youtube.jar` | Java 爬虫插件 |
| 安卓工程 | `android/` | Gradle + Chaquopy + NDK |
| 云构建 | `.github/workflows/build-android.yml` | 唯一可靠的出包方式 |

版本号在 `pubspec.yaml` 的 `version:`；应用名 / 构建号在 `lib/app_build.dart`（`appName`、`appBuild`）。

---

## 2. 构建（推荐：直接走云端）

本机（不含 Android SDK + NDK + Flutter 的机器）编不出包，不要在本地硬编。

### 2.1 触发方式

两种，二选一：

1. **推代码触发**：往 `main` 分支 push，自动跑一次（`**.md` 和 `docs/**` 的改动不触发）
2. **手动触发**：仓库页面 → Actions → `build-android` → Run workflow

手动触发时可填两个参数：

- `variant`：`moyi`（魔蚁box，全站源）或 `duanjushijie`（短剧视界，仅红果）
- `abi`：`arm64-v8a`（默认，真机用这个）/ `armeabi-v7a` / `x86_64`（模拟器）

### 2.2 环境要求（workflow 里已全部自动装好）

- JDK 21
- Android SDK：platform 36、build-tools 36.0.0
- NDK `28.2.13676358`、CMake `3.22.1`
- Go（按 `native/go.mod`）
- **Python 3.11**：Chaquopy 编译期内嵌依赖必须有本机 3.11 解释器
- Flutter `3.47.0` stable

### 2.3 出包关键点（踩过的坑，别删）

1. **Python 3.11 必须装**：不装会报 `Couldn't find Python 3.11`，在 Chaquopy 编内嵌 Python 包那步直接挂。workflow 里 `actions/setup-python@v5` 装 3.11，并写入 `CHAQUOPY_BUILD_PYTHON`。
2. **`buildPython` 要注入**：`scripts/build_android.py` 读取 `CHAQUOPY_BUILD_PYTHON` 传给 Gradle，否则 Chaquopy 仍找不到解释器。
3. **`android/local.properties` 由 CI 现写**：里面只有 `flutter.sdk` 和 `sdk.dir`，不要提交进仓库。
4. **产物在 `dist/android/`**：文件名形如 `moyi-1.0.0-arm64-v8a.apk`，同时生成 `SHA256SUMS.txt`。CI 用 artifacts 上传，保留 30 天。

### 2.4 签名

默认用 debug 证书，能装能跑，不能上架。

要固定签名，配 4 个仓库 Secrets：

```
ANDROID_KEYSTORE_BASE64     # keystore 文件 base64
ANDROID_KEYSTORE_PASSWORD
ANDROID_KEY_ALIAS
ANDROID_KEY_PASSWORD
```

配了之后 `scripts/configure_signing.py` 自动接管，下一次构建生效，不用改代码。

---

## 3. 改完代码怎么验

### 3.1 最低验证（1 分钟，任何机器）

```bash
dart format lib/app_drawer.dart      # 格式
flutter analyze                      # 类型 + 语法（需要 Flutter SDK）
```

`flutter analyze` 报 error 就别推，推了 CI 也编不过。

### 3.2 单测（改 UI 必做）

```bash
flutter test test/app_drawer_test.dart test/midnight_zone_test.dart
```

改抽屉 / 菜单 / 设置入口后，至少跑这两个。

### 3.3 真机验收

编出来的臂包装上后重点看：

- 左滑能否弹出抽屉，主页是否被遮罩变暗（Modal，不是分栏）
- 抽屉里横向 Tab 能否滑动，切换后分组卡片内容是否跟着换
- 各入口点进去有没有反应（不能是死按钮）
- 午夜区在「未成年保护」未开启时是否隐藏

---

## 4. 抽屉（侧边菜单）改在哪

文件：`lib/app_drawer.dart`

结构（从上到下）：

1. `_header()`：头像（`assets/ant_logo.png`）+ 应用名 + 版本号 `v1.0.1 (5)` + 关闭按钮
2. `_shelfTabs()`：横向 Tab，`SingleChildScrollView(scrollDirection: Axis.horizontal)` + `Row`，值来自 `enum DrawerShelf { video, music, reading, comic, miniApp }`
3. `_shelfSections()`：按当前 Tab 返回分组卡片。每个分组 = `_DrawerSection`（分组标题 + 圆角 `DecoratedBox` 卡片）+ 若干 `_DrawerRow`
4. `_appToolSection()`：通用工具（所有 Tab 都在）
5. `_guardianSection()`：未成年保护开关（仅午夜区解锁后出现）
6. `_footer()`：版权信息

### 关键约束

- **Tab 只决定卡片内容，不负责跳页**。跳页仍走 `onZoneSelected(HomeZone.xxx)`，与改造前一致，`home_screen.dart` 不用改。
- **`HomeZone` 只有 6 个值**：`drama / vod / midnight / live / audio / novel`。没有 `comic`、没有 `music`：
  - 漫画源是阅读区里的 `sourceType == 2`，所以「漫画」Tab 落到 `HomeZone.novel`
  - 音乐没有独立板块，音频能力在 `HomeZone.audio`（听书），所以「音乐」Tab 里放的是听书 + 音乐源导入入口
- 新增入口必须**有真实落点**，不要放假按钮。加功能就先在 `AppDrawerTool` 里加枚举值，再在 `home_screen.dart` 的 `_onTool()` 里接上页面。
- 文案不要和 Tab 名重复（`find.text` 会命中两个，测试会挂）。板块卡片标题用「XX模块」。

### 加一个菜单项要改的地方

1. `enum AppDrawerTool` 加值
2. `_shelfSections()` 或 `_appToolSection()` 里加一行 `_row(...)` / `_toolRow(...)`
3. `lib/home_screen.dart` 的 `_onTool()` 里 `case` 接页面
4. `test/app_drawer_test.dart` 的 `expected` 表加一条

---

## 5. 直接丢给 AI 的接管提示词

> 这是一个 Flutter 安卓应用（魔蚁box，包名 com.moyi.box）。工程结构：`lib/` 是 Dart UI，`native/` 是 Go 核心（编成 libmoyi_core.so），Python 蜘蛛走 Chaquopy 打包。构建只能走 GitHub Actions 的 `build-android` workflow：推 main 自动跑，或手动 Run workflow 选 `variant` 和 `abi`。出包在 `dist/android/`。
>
> 已知坑：CI 必须装 Python 3.11 并把路径注入 `CHAQUOPY_BUILD_PYTHON`，否则 Chaquopy 会报 `Couldn't find Python 3.11`。NDK 28.2.13676358、CMake 3.22.1、Flutter 3.47.0。默认 debug 签名，配了 4 个 ANDROID_* Secrets 才用正式签名。
>
> 侧边菜单在 `lib/app_drawer.dart`：头像头部 + 横向 Tab（`DrawerShelf`）+ 圆角分组卡片 + 版权 footer。`HomeZone` 只有 drama/vod/midnight/live/audio/novel 六个值，没有 comic 和 music——漫画源是阅读区里 `sourceType==2` 的源，音频在 audio 板块。
>
> 改完请跑 `flutter analyze` 和 `flutter test test/app_drawer_test.dart test/midnight_zone_test.dart`，再推 main 触发构建。不要新增没有落点的假按钮。

---

## 6. 这份文档不含的东西

- 服务器地址、部署机凭据：不在这里，也不需要
- 签名文件本体：不进仓库，只放 Secrets
- 任何第三方服务的 key：工程里的 key 都在 `assets/jar_site_configs.json` 和 Python 蜘蛛里，属于运行配置，不是构建依赖

---

## 7. 海阔小程序模块（2026-11-11）

目录 `lib/miniapp/haikuo/`：

| 文件 | 作用 |
| --- | --- |
| `haikuo_program.dart` | 数据模型（`HaikuoKind.script/rule/link`）+ 稳定 id（sha1 名称+主体） |
| `haikuo_codec.dart` | JSON 结构归一（单条/数组/`{data:[...]}` 包裹）、zip/gzip/base64、口令解码 |
| `haikuo_store.dart` | 落盘 `Documents/haikuo/programs.json`，增删改、去重、导出 |
| `haikuo_runtime_html.dart` | 运行时页面：hiker 兼容层（fetch/pdfa/pdfh/setResult/`$`/`hiker://page` 虚拟页） |
| `haikuo_runner_page.dart` | 本地 HTTP 服务 + WebView 跑脚本，`/__fetch` 同源代理解决跨域，点播走 media_kit |
| `haikuo_home_page.dart` | 面板：文件导入 / 口令导入 / 链接导入 / 示例导入 / 详情 / 删除 |

口令格式对照海阔官方源码（`qiusunshine/hikerView` 的 `AutoImportHelper` / `ShareRuleUtil`）：

1. `海阔视界规则分享，当前分享的是：小程序￥home_rule￥<载荷>￥`
2. `rule://<整段口令的 base64>`
3. 载荷是 `base64://@<标题>@<规则 JSON 的 base64>`

规则字段：`title / author / version / type / url / col_type / find_rule / searchFind / detail_find_rule / pages / icon`。`url` 常见 `hiker://empty##<真实地址>`，子页在 `pages`（JSON 字符串）里，运行时按 `hiker://page/<path>` 解析。

入口：小程序首页「已安装」顶部固定一块「海阔小程序」，以及右上角「+」菜单里的「海阔小程序」。

## 8. 主题覆盖（2026-11-11）

- `applyThemePreferences` 的 `neon` 分支现在换整套 ColorScheme（`Neon.bg` 底、`Neon.purple` 主色、`Neon.cyan` 次色），顶栏透明、卡片霓虹描边 —— 点播区/设置页等所有页面跟着变。
- `lib/ui_style.dart` 新增 `themeStyleNotifier` / `neonStyleActive`，`main.dart` 每次重建时同步当前风格。
- 抽屉在霓虹风格下用 `NeonBackdrop` 铺氛围光、底色透明、激活胶囊走 `Neon.hotGradient`（`ValueKey('drawer-neon')`）。
- 内容区（点播/午夜/短剧目录）在霓虹风格下包一层 `NeonBackdrop`。

## 9. 首屏不自动出列表的修复（2026-11-11）

`lib/home_screen.dart` 新增 `_loadWithAutoRetry()` 与 `_scheduleAutoLoad()`：

- 首屏 / 切板块：`_load(useCache: true)` 之后如果列表还是空、且没有报错，立刻补一次线上请求；仍为空则 1.5 秒后再补一次（覆盖内核刚启动第一次请求落空）。
- 站源晚于页面就绪的情况：页面重建时检查一次，站源就绪后自动补拉，不需要用户手动下拉。
- 切换板块 / 换站源时重置 `_autoLoadedOnce`。
