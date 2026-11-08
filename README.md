# moytv

moyi / 魔蚁box —— Flutter 多端短剧应用（Android / iOS / Windows），带 Go 原生核心（`native/`）、QuickJS 桥（`android/app/src/main/cpp/`）、内嵌 Python 3.11（Chaquopy）。

仓库用途：**源码托管 + GitHub Actions 云构建 APK**。

## 云构建（GitHub Actions）

工作流：`.github/workflows/build-android.yml`

触发方式：

- 推到 `main` 分支 → 自动构建一次（默认魔蚁box、arm64-v8a）
- 手动：Actions → `build-android` → Run workflow，可选 `variant`（moyi / duanjushijie）和 `abi`

产物：

- Actions 运行页面的 **Artifacts** → `apk-<variant>-<abi>-<run-number>`（保留 30 天）
- 打 tag 推送时，自动附加到对应 **Release**

构建链路（与本地一致）：

```
python3 scripts/build_native.py --platform android --abi arm64-v8a [--all-sources]   # Go → libmoyi_core.so
flutter pub get --enforce-lockfile
flutter build apk --release --no-pub --obfuscate --split-debug-info=build/app/outputs/symbols
python3 scripts/package_release.py --platform android --abi arm64-v8a [--all-sources]
```

产物落在 `dist/android/`，同时生成 `SHA256SUMS.txt`。

### 环境版本要求

| 组件 | 版本 |
| --- | --- |
| Flutter | 3.47.0（`stable`） |
| Dart | >= 3.13.0 |
| Go | 见 `native/go.mod` |
| JDK | 21（AGP 9.1 / Kotlin 2.4 要求 17+） |
| Android NDK | 28.2.13676358 |
| CMake | 3.22.1 |
| Gradle | 9.3.1（wrapper 自带） |

### 发布签名（可选）

不配也能出包（走 debug 签名，能装、不能上架）。要固定签名，在仓库 Settings → Secrets and variables → Actions 里配这四个：

- `ANDROID_KEYSTORE_BASE64`：keystore 文件的 base64（`base64 -w0 release.jks`）
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

工作流会调用 `scripts/configure_signing.py` 写入 `android/key.properties`（该文件不入库）。

## 本地构建

```bash
# 前置：Flutter 3.47+、Go、JDK 17+、Android SDK + NDK 28.2.13676358 + CMake 3.22.1
flutter pub get
python3 scripts/build_android.py --abi arm64-v8a --all-sources
```

其他平台：

```bash
python3 scripts/build_windows.py
python3 scripts/build_ios.py
python3 scripts/build_web.py
```

## 目录

```
lib/                 Dart 业务代码
native/              Go 原生核心（bridge / core / server）
android/app/src/main/cpp/   QuickJS JNI 桥
assets/              站源配置、jar 插件、py 爬虫、直播源、代理内核
scripts/             各平台构建/打包脚本
integrations_test/   集成测试
```

## 说明

- `android/local.properties`、`jniLibs/`、`windows/flutter/ephemeral/`、`build/` 等均不入库，由构建流程生成。
- 原生库只产出 `arm64-v8a` 时体积最小；需要其他 ABI 改工作流里的 `abi` 参数即可（`armeabi-v7a` / `x86_64`）。
