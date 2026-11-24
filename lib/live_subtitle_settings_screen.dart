import 'dart:async';

import 'package:flutter/material.dart';

import 'live_subtitle_engine.dart';
import 'live_subtitle_service.dart';
import 'live_subtitle_settings.dart';

/// 实时字幕设置页：总开关、源语言、识别模型（按需下载）、
/// 模型下载镜像、延迟提示。
///
/// 模型不内置进安装包，在这里按需下载到应用私有目录。
/// 非安卓/iOS 上只展示、不提供下载（插件只支持安卓与 iOS）。
class LiveSubtitleSettingsScreen extends StatefulWidget {
  const LiveSubtitleSettingsScreen({super.key, this.service});

  /// 测试注入用；不传则按当前设置新建一个服务。
  final LiveSubtitleService? service;

  @override
  State<LiveSubtitleSettingsScreen> createState() =>
      _LiveSubtitleSettingsScreenState();
}

class _LiveSubtitleSettingsScreenState
    extends State<LiveSubtitleSettingsScreen> {
  LiveSubtitleSettings? _settings;
  LiveSubtitleService? _service;
  final _modelStates = <String, LiveSubtitleModelState>{};
  final _modelBytes = <String, int?>{};
  String? _downloadingModelId;
  double _downloadProgress = 0;
  late final TextEditingController _mirrorController;
  StreamSubscription<double>? _downloadSubscription;

  @override
  void initState() {
    super.initState();
    _mirrorController = TextEditingController();
    unawaited(_load());
  }

  @override
  void dispose() {
    _mirrorController.dispose();
    unawaited(_downloadSubscription?.cancel());
    // 服务是本页新建的才释放；外部注入的不归本页管。
    if (widget.service == null) unawaited(_service?.dispose());
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await LiveSubtitleSettings.load();
    if (!mounted) return;
    final service =
        widget.service ?? LiveSubtitleService(settings: settings);
    setState(() {
      _settings = settings;
      _service = service;
      _mirrorController.text = settings.modelMirrorUrl;
    });
    _downloadSubscription = service.downloadProgress.listen((progress) {
      if (mounted) setState(() => _downloadProgress = progress);
    });
    await _refreshModelStates();
  }

  Future<void> _refreshModelStates() async {
    final service = _service;
    if (service == null) return;
    for (final option in LiveSubtitleModelOption.values) {
      final state = await service.modelState(option.id);
      final bytes = await service.downloadedModelBytes(option.id);
      if (!mounted) return;
      setState(() {
        _modelStates[option.id] = state;
        _modelBytes[option.id] = bytes;
      });
    }
  }

  Future<void> _update(LiveSubtitleSettings next) async {
    await next.save();
    if (!mounted) return;
    setState(() => _settings = next);
  }

  Future<void> _downloadModel(String modelId) async {
    final service = _service;
    if (service == null) return;
    setState(() {
      _downloadingModelId = modelId;
      _downloadProgress = 0;
    });
    try {
      await service.downloadModel(
        modelId,
        onProgress: (progress) {
          if (mounted) setState(() => _downloadProgress = progress);
        },
      );
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('模型下载完成')),
        );
      }
    } on LiveSubtitleEngineException catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('模型下载失败：${e.message}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('模型下载失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _downloadingModelId = null);
      await _refreshModelStates();
    }
  }

  Future<void> _deleteModel(String modelId) async {
    final service = _service;
    if (service == null) return;
    await service.deleteModel(modelId);
    await _refreshModelStates();
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('实时字幕')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final supported = liveSubtitleEngineSupported;
    return Scaffold(
      appBar: AppBar(title: const Text('实时字幕')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
        children: [
          SwitchListTile(
            key: const ValueKey('live-subtitle-enabled'),
            title: const Text('实时字幕'),
            subtitle: const Text('开启后播放时自动识别语音并显示原文字幕'),
            value: settings.enabled,
            onChanged: supported
                ? (value) => _update(settings.copyWith(enabled: value))
                : null,
          ),
          if (!supported)
            const ListTile(
              title: Text('本机不支持'),
              subtitle: Text('实时字幕仅支持安卓与 iOS'),
            ),
          const Divider(),
          const ListTile(title: Text('源语言')),
          RadioGroup<String>(
            groupValue: settings.sourceLanguage,
            onChanged: (value) {
              if (value != null) {
                _update(settings.copyWith(sourceLanguage: value));
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in LiveSubtitleLanguageOption.values)
                  RadioListTile<String>(
                    title: Text(option.label),
                    value: option.code,
                  ),
              ],
            ),
          ),
          const Divider(),
          const ListTile(title: Text('识别模型')),
          for (final option in LiveSubtitleModelOption.values)
            _modelTile(settings, option),
          const Divider(),
          SwitchListTile(
            title: const Text('仅在 Wi-Fi 下下载模型'),
            subtitle: const Text('模型几十 MB，默认只在 Wi-Fi 下下载'),
            value: settings.wifiOnlyDownload,
            onChanged: (value) =>
                _update(settings.copyWith(wifiOnlyDownload: value)),
          ),
          const Divider(),
          const ListTile(title: Text('模型下载镜像（可选）')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const ValueKey('live-subtitle-model-mirror'),
              controller: _mirrorController,
              decoration: const InputDecoration(
                labelText: '镜像地址（可选）',
                hintText: '留空用 Hugging Face',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              onSubmitted: (value) => _update(
                settings.copyWith(modelMirrorUrl: value.trim()),
              ),
            ),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '字幕比声音慢几秒属正常：临时字幕约 2 秒，确认字幕一般慢 4–7 秒'
              '（Whisper 每 2 秒解一段、4 秒后确认）。'
              '模型不内置进安装包，首次使用请先下载；下载后断网也能用。',
            ),
          ),
        ],
      ),
    );
  }

  Widget _modelTile(
    LiveSubtitleSettings settings,
    LiveSubtitleModelOption option,
  ) {
    final state = _modelStates[option.id];
    final bytes = _modelBytes[option.id];
    final downloading = _downloadingModelId == option.id;
    final downloaded = state == LiveSubtitleModelState.downloaded;
    final sizeText = downloaded && bytes != null
        ? '已下载 ${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB'
        : option.sizeLabel;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RadioGroup<String>(
          groupValue: settings.modelId,
          onChanged: (value) {
            if (value != null) _update(settings.copyWith(modelId: value));
          },
          child: RadioListTile<String>(
            title: Text(option.label),
            subtitle: Text('${option.detail} · $sizeText'),
            value: option.id,
          ),
        ),
        if (downloading)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: _downloadProgress),
                const SizedBox(height: 4),
                Text('下载中 ${(_downloadProgress * 100).toStringAsFixed(0)}%'),
              ],
            ),
          )
        else if (downloaded)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _deleteModel(option.id),
              child: const Text('删除模型'),
            ),
          )
        else if (state == LiveSubtitleModelState.notDownloaded)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: liveSubtitleEngineSupported
                  ? () => _downloadModel(option.id)
                  : null,
              child: const Text('下载模型'),
            ),
          )
        else if (state == LiveSubtitleModelState.unknown)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('本机无法检测模型状态（仅安卓/iOS）'),
            ),
          ),
      ],
    );
  }
}
