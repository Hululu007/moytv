import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'core_bridge.dart';
import 'app_update.dart';
import 'app_layout.dart';
import 'app_orientation.dart';
import 'app_theme.dart';
import 'app_theme_config.dart';
import 'ui_style.dart';
import 'external_py_import.dart';
import 'playback_foreground.dart';
import 'tv_theme.dart';
import 'zoo_builtin_seed.dart';
import 'home_screen.dart';
import 'hongguo_account.dart';
import 'hongguo_account_store.dart';
import 'jar_bridge.dart';
import 'local_store.dart';
import 'plugin_manager.dart';
import 'plugin_share_intent.dart';
import 'profiles_screen.dart';
import 'cloud_drive/cloud_credential_store.dart';
import 'cloud_drive/cloud_drive_stations.dart';
import 'nexhub_scraper/network/network_config_service.dart';
import 'nexhub_scraper/network/runtime/nexhub_http_overrides.dart';
import 'package_smoke.dart';
import 'signature_check.dart';
import 'video_enhancement_assets.dart';
import 'xp_boot_screen.dart';
import 'boot_video.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  // 全局网络覆盖（DNS 设置的生效点）：Dart 侧所有 HttpClient 派生流量
  // 按 NetworkConfigService 的全局档案解析域名。默认档案（系统 DNS）
  // 直通裸客户端，行为与以前一致；用户配了 DNS/Hosts/SNI 后才走
  // 自定义连接。先装覆盖、再读配置，首批请求就按用户配置走。
  HttpOverrides.global = NexHubHttpOverrides();
  await NetworkConfigService.instance.load();
  // 网络直连：应用内代理机件已删，所有请求走直连（手机系统 VPN 在系统层
  // 生效，不受影响）。海阔规则自带 proxy 字段的仍由规则自己的客户端处理。
  unawaited(PlaybackForeground.clearStaleFlag());
  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(AppTheme.systemBars(Brightness.dark));
  }
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
  }
  MediaKit.ensureInitialized();
  VideoEnhancementAssets.registerLicenses();
  if (Platform.isWindows && arguments.firstOrNull == '--package-smoke') {
    await runPackageSmoke(arguments);
    return;
  }
  final device = await AppDevice.detect();
  runApp(AppBootstrap(device: device));
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key, this.device = const AppDevice()});
  final AppDevice device;
  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap>
    with WidgetsBindingObserver {
  final repository = NativeRepository();
  final navigator = GlobalKey<NavigatorState>();
  LocalStore? store;
  Object? error;
  late AppDevice device = widget.device;
  bool? _signatureOk;
  Timer? _hongguoRenewalTimer;

  @override
  void dispose() {
    _hongguoRenewalTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    store?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hongguoRenewalTimer = Timer.periodic(const Duration(minutes: 60), (_) {
      unawaited(repository.refreshHongguoDevice());
    });
    if (signatureCheckEnforced) {
      unawaited(_checkSignature());
    }
    _initialize();
  }

  Future<void> _checkSignature() async {
    final ok = await checkReleaseSignature();
    if (mounted) setState(() => _signatureOk = ok);
  }

  /// 冷启动恢复红果账号会话（见 _initialize 注释）：建一个
  /// HongguoAccountStore 走 load()，失败自己吞掉，不影响启动。
  Future<void> _restoreHongguoAccount(SharedPreferences preferences) async {
    try {
      final accountStore = HongguoAccountStore(
        repository: repository,
        preferences: preferences,
      );
      await accountStore.load();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(repository.refreshHongguoDevice());
    }
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      unawaited(_refreshDevice());
    }
    if (!Platform.isIOS) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(
        NativeRepository(
          background: true,
        ).controlDownloads('pauseAll').catchError((Object _) {}),
      );
    }
  }

  Future<void> _refreshDevice() async {
    final detected = await AppDevice.detect(fallback: device);
    if (!mounted ||
        (device.television == detected.television &&
            device.version == detected.version)) {
      return;
    }
    setState(() => device = detected);
  }

  Future<void> _initialize() async {
    setState(() {
      error = null;
    });
    try {
      final preferences = await SharedPreferences.getInstance();
      unawaited(ensureHongguoAccountLoaded());
      await _refreshDevice();
      await repository.initialize();
      // 冷启动恢复红果账号会话：把持久化的会话交回 Go 核再确认
      // 状态（HongguoAccountStore.load 内做，空 Cookie 不交回）。
      // 恢复失败不阻塞启动；打开账号页时 load() 会再试一次。
      unawaited(_restoreHongguoAccount(preferences));
      unawaited(AppUpdateChecker.maybeCheckSilently());
      // 插件化首次启动：装好全部未被用户卸载的内置插件
      //（整个内置 jar 一个插件 + 44 个 py 插件），行为与以前一致。
      await PluginManager.ensureBuiltinPlugins(preferences);
      if (mounted) {
        setState(() {
          store = LocalStore(preferences);
          unawaited(JarBridge.setJarFingerprint(store!.jarFingerprintEnabled));
          unawaited(store!.syncLibraryFromDb());
          repository.access = store;
        });
      }
      await ZooBuiltinSeeder.seed(repository);
      // 网盘站源恢复：登录过的网盘重新注册进站点列表。
      final createdStore = store;
      if (createdStore != null) {
        final credentialStore = CloudCredentialStore(preferences);
        CloudDriveStations.refresh(credentialStore);
        PluginShareIntent.start(
          store: createdStore,
          repository: repository,
          navigatorKey: navigator,
        );
      }
      final created = store;
      if (created != null) {
        unawaited(created.migrateLegacyThemeSettings());
        unawaited(created.repairImportedJsonListNames());
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = failure;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (signatureCheckEnforced && _signatureOk == false) {
      return MaterialApp(
        theme: AppTheme.platformLight,
        home: const TamperScreen(),
      );
    }
    return MoyiApp(
      repository: repository,
      store: store,
      bootstrapError: error?.toString(),
      onRetry: _initialize,
      television: device.television,
      version: device.version,
      navigatorKey: navigator,
    );
  }
}

class MoyiApp extends StatefulWidget {
  const MoyiApp({
    super.key,
    required this.repository,
    this.store,
    this.bootstrapError,
    this.onRetry,
    this.television = false,
    this.version = appVersion,
    this.navigatorKey,
  });
  final AppRepository repository;
  final LocalStore? store;
  final String? bootstrapError;
  final VoidCallback? onRetry;
  final bool television;
  final String version;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  State<MoyiApp> createState() => _MoyiAppState();
}

class _MoyiAppState extends State<MoyiApp> {
  /// 启动屏首次出现的时间（只在首建 store 为空的冷启动里记）；
  /// 首建即有 store（测试与热启动路径）时保持 null，启动屏永不出现。
  DateTime? _bootShownAt;
  bool _bootMinElapsed = false;
  Timer? _bootTimer;

  @override
  void dispose() {
    _bootTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.store]),
    builder: (_, _) => _application(),
  );

  /// 启动屏是否可见：store 为空时一直可见；store 就绪后，若冷启动
  /// 里启动屏出现过且最短时长未到，继续显示到最短时长（初始化在
  /// 后台继续，绝不阻塞；取初始化完成与最短时间两者较晚者消失）。
  /// 出错时 store 仍为空，直接显示出错分支，不受门控牵制。
  bool get _bootVisible {
    final store = widget.store;
    if (store != null) {
      return _bootShownAt != null && !_bootMinElapsed;
    }
    _bootShownAt ??= DateTime.now();
    _bootTimer ??= Timer(xpBootMinDisplay, () {
      if (mounted) setState(() => _bootMinElapsed = true);
    });
    return true;
  }

  Widget _application() {
    // 当前全局主题（14 套之一）：配色与亮暗全由主题自身决定；
    // 同步给全局通知器，抽屉、内容区等深层组件据此决定是否走霓虹视觉。
    final store = widget.store;
    final config = AppThemeConfig.forTheme(
      store?.appTheme ?? AppThemeMode.xpWindows,
    );
    appThemeNotifier.value = config.mode;
    final themeData = config.toThemeData();
    return MaterialApp(
      navigatorKey: widget.navigatorKey,
      navigatorObservers: [homeRouteObserver],
      title: appName,
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: themeData,
      darkTheme: themeData,
      themeMode: config.isDark ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) {
        final mode = store?.displayMode ?? 'auto';
        final tv = mode == 'television' || mode == 'auto' && widget.television;
        final theme = Theme.of(context);
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: AppTheme.systemBars(theme.brightness),
          child: AppThemeBackground(
            child: AppOrientationScope(
              television: tv,
              child: AppLayout(
                television: tv,
                version: widget.version,
                child: Theme(
                  data: tv ? televisionTheme(theme) : theme,
                  child: Shortcuts(
                    shortcuts: const {
                      SingleActivator(
                        LogicalKeyboardKey.select,
                        includeRepeats: false,
                      ): ActivateIntent(),
                      SingleActivator(
                        LogicalKeyboardKey.gameButtonA,
                        includeRepeats: false,
                      ): ActivateIntent(),
                      SingleActivator(LogicalKeyboardKey.goBack):
                          DismissIntent(),
                    },
                    child: FocusTraversalGroup(
                      child: child!,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      home: _bootVisible
          ? XpBootScreen(
              appName: appName,
              video: const BootVideo(),
              // store 已就绪时门控只是补足最短时长，初始化已成功，
              // 不显示已过期的错误文案。
              error: store == null ? widget.bootstrapError : null,
              onRetry: widget.onRetry,
            )
          : store!.locked
          ? ProfilesScreen(store: store, locked: true)
          : ExternalPyImportListener(
              store: store,
              repository: widget.repository,
              child: HomeScreen(
                key: ValueKey(
                  'profile-${store.profile.id}-${store.profileEpoch}',
                ),
                repository: widget.repository,
                store: store,
              ),
            ),
    );
  }
}
