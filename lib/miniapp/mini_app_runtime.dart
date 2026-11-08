import 'dart:async';
import 'dart:io';

import 'mini_app_manifest.dart';
import 'mini_app_sdk.dart';
import 'mini_app_server.dart';
import 'mini_app_settings.dart';
import 'mini_app_store.dart';

class MiniAppInstance {
  MiniAppInstance({
    required this.manifest,
    required this.server,
    required this.dir,
  });

  final MiniAppManifest manifest;
  final MiniAppServer server;
  final Directory dir;
  DateTime lastActive = DateTime.now();
  bool foreground = false;

  String get baseUrl => server.baseUrl;

  String get appId => manifest.appId;
}

class MiniAppRuntime {
  MiniAppRuntime({required this.store, required this.settings});

  final MiniAppStore store;
  MiniAppSettings settings;

  final Map<String, MiniAppInstance> _running = {};

  List<MiniAppInstance> get running => _running.values.toList();

  MiniAppInstance? runningInstance(String appId) => _running[appId];

  Future<MiniAppInstance> ensureRunning(MiniAppManifest manifest) async {
    final existing = _running[manifest.appId];
    if (existing != null) {
      existing.lastActive = DateTime.now();
      existing.foreground = true;
      return existing;
    }
    final dir = await store.installedDir(manifest.appId);
    if (dir == null) {
      throw StateError('小程序未安装：${manifest.appId}');
    }
    final usedPorts = _running.values.map((e) => e.server.port).toSet();
    final server = await MiniAppServer.start(
      root: dir,
      entry: manifest.entry,
      sdkScript: MiniAppSdkScript.script,
      basePort: settings.basePort,
      usedPorts: usedPorts,
      lanShare: settings.lanShare,
    );
    final instance = MiniAppInstance(
      manifest: manifest,
      server: server,
      dir: dir,
    )..foreground = true;
    _running[manifest.appId] = instance;
    _evictBackground();
    return instance;
  }

  void markForeground(String appId) {
    final instance = _running[appId];
    if (instance == null) return;
    instance.foreground = true;
    instance.lastActive = DateTime.now();
    _evictBackground();
  }

  void markBackground(String appId) {
    final instance = _running[appId];
    if (instance == null) return;
    instance.foreground = false;
    instance.lastActive = DateTime.now();
    _evictBackground();
  }

  Future<String?> resolveUrl(String appId) async {
    final running = _running[appId];
    if (running != null) return running.baseUrl;
    final dir = await store.installedDir(appId);
    if (dir == null) return null;
    final manifest = await store.readManifest(dir);
    if (manifest == null || !manifest.isValid) return null;
    final instance = await ensureRunning(manifest);
    return instance.baseUrl;
  }

  Future<void> stop(String appId) async {
    final instance = _running.remove(appId);
    if (instance != null) await instance.server.close();
  }

  Future<void> stopAll() async {
    final instances = _running.values.toList();
    _running.clear();
    for (final instance in instances) {
      await instance.server.close();
    }
  }

  void _evictBackground() {
    final background = _running.values
        .where((instance) => !instance.foreground)
        .toList()
      ..sort((a, b) => a.lastActive.compareTo(b.lastActive));
    while (background.length > settings.maxBackground) {
      final victim = background.removeAt(0);
      unawaited(stop(victim.appId));
    }
  }
}
