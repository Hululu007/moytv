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
import 'theme_settings.dart';
import 'external_py_import.dart';
import 'playback_foreground.dart';
import 'tv_theme.dart';
import 'zoo_builtin_seed.dart';
import 'home_screen.dart';
import 'hongguo_account.dart';
import 'jar_bridge.dart';
import 'builtin_py_sites.dart';
import 'jar_import.dart';
import 'local_store.dart';
import 'profiles_screen.dart';
import 'package_smoke.dart';
import 'lan_controller.dart';
import 'player_picker.dart';
import 'proxy_kernel_service.dart';
import 'signature_check.dart';
import 'video_enhancement_assets.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
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
    LanController.current?.dispose();
    LanController.current = null;
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
      unawaited(AppUpdateChecker.maybeCheckSilently());
      unawaited(ProxyKernelService.maybeAutostart());
      await JarImport.registerBuiltinZakatv();
      await BuiltinPySites.register();
      if (mounted) {
        setState(() {
          store = LocalStore(preferences);
          unawaited(JarBridge.setJarFingerprint(store!.jarFingerprintEnabled));
          unawaited(store!.syncLibraryFromDb());
          repository.access = store;
          LanController.current?.dispose();
          final link = LanController(
            repository,
            store!,
            kind: device.television
                ? 'tv'
                : Platform.isWindows
                ? 'computer'
                : 'phone',
          );
          LanController.current = link;
          link.openPlayback = (request) async {
            final epoch = request.profileEpoch;
            if (request.cancelled ||
                !mounted ||
                store!.locked ||
                !link.receiving ||
                store!.profileEpoch != epoch ||
                !store!.allowsSource(request.detail.drama.source)) {
              throw StateError('当前用户不能接收播放');
            }
            await link.playbackHost?.stop();
            if (request.cancelled ||
                !mounted ||
                store!.locked ||
                store!.profileEpoch != epoch ||
                !link.receiving) {
              throw StateError('播放接收已取消');
            }
            final navigation = navigator.currentState;
            if (navigation == null) throw StateError('接收设备界面尚未就绪');
            unawaited(
              navigation.pushAndRemoveUntil<void>(
                buildPlayerRoute<void>(
                  navigation.context,
                  detail: request.detail,
                  initialIndex: request.index,
                  initialPosition: request.position,
                  repository: repository,
                  store: store!,
                  handoff: request,
                ),
                (route) => route.isFirst,
              ),
            );
          };
        });
      }
      await ZooBuiltinSeeder.seed(repository);
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

class MoyiApp extends StatelessWidget {
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
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([store]),
    builder: (_, _) => _application(),
  );

  Widget _application() => MaterialApp(
    navigatorKey: navigatorKey,
    title: appName,
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: applyThemePreferences(
      AppTheme.platformLight,
      modeStyle: store?.themeModeStyle ?? '',
      style: store?.themeStyle ?? '',
      accent: store?.themeAccent ?? '',
    ),
    darkTheme: applyThemePreferences(
      AppTheme.platformDark,
      modeStyle: store?.themeModeStyle ?? '',
      style: store?.themeStyle ?? '',
      accent: store?.themeAccent ?? '',
    ),
    themeMode: themeModeFor(
      store?.themeModeStyle ?? '',
      store?.themeMode ?? 'system',
    ),
    builder: (context, child) {
      final mode = store?.displayMode ?? 'auto';
      final tv = mode == 'television' || mode == 'auto' && television;
      final theme = Theme.of(context);
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.systemBars(theme.brightness),
        child: ThemeBackgroundWrapper(
          store: store,
          child: AppOrientationScope(
            television: tv,
            child: AppLayout(
              television: tv,
              version: version,
              child: Theme(
                data: tv
                    ? televisionTheme(
                        theme.brightness == Brightness.dark
                            ? AppTheme.dark
                            : AppTheme.light,
                      )
                    : theme,
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
                    SingleActivator(LogicalKeyboardKey.goBack): DismissIntent(),
                  },
                  child: FocusTraversalGroup(child: child!),
                ),
              ),
            ),
          ),
        ),
      );
    },
    home: store != null
        ? store!.locked
              ? ProfilesScreen(store: store!, locked: true)
              : ExternalPyImportListener(
                  store: store!,
                  repository: repository,
                  child: HomeScreen(
                    key: ValueKey(
                      'profile-${store!.profile.id}-${store!.profileEpoch}',
                    ),
                    repository: repository,
                    store: store!,
                  ),
                )
        : Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.play_circle_fill_rounded,
                      color: Color(0xFFFF765F),
                      size: 72,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      bootstrapError ?? '正在打开$appName',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 24),
                    if (bootstrapError == null)
                      const CircularProgressIndicator.adaptive()
                    else
                      FilledButton(
                        onPressed: onRetry,
                        child: const Text('重新打开'),
                      ),
                  ],
                ),
              ),
            ),
          ),
  );
}
