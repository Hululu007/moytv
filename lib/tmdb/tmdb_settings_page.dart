import 'package:flutter/material.dart';

import 'tmdb_config.dart';
import 'tmdb_service.dart';

class TmdbSettingsPage extends StatefulWidget {
  const TmdbSettingsPage({super.key, this.service});

  final TmdbService? service;

  @override
  State<TmdbSettingsPage> createState() => _TmdbSettingsPageState();
}

class _TmdbSettingsPageState extends State<TmdbSettingsPage> {
  TmdbConfig? _config;
  final _apiKeyController = TextEditingController();
  final _languageController = TextEditingController();
  bool _obscureKey = true;
  bool _saving = false;
  bool _testing = false;
  String? _status;
  bool _statusOk = false;

  TmdbService get _service => widget.service ?? TmdbService.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _languageController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final config = await TmdbConfig.load();
    if (!mounted) return;
    setState(() {
      _config = config;
      _apiKeyController.text = config.apiKey;
      _languageController.text = config.language;
    });
  }

  TmdbConfig _editedConfig() {
    final base = _config ?? const TmdbConfig();
    return base.copyWith(
      apiKey: _apiKeyController.text.trim(),
      language: _languageController.text.trim().isEmpty
          ? 'zh-CN'
          : _languageController.text.trim(),
    );
  }

  Future<void> _save() async {
    final config = _editedConfig();
    if (config.apiKey.isNotEmpty && config.apiKey.length < 10) {
      setState(() {
        _status = 'API Key 看起来不完整，请检查后重试';
        _statusOk = false;
      });
      return;
    }
    if (!TmdbConfig.isValidLanguage(config.language)) {
      setState(() {
        _status = '请输入语言代码，例如 zh-CN';
        _statusOk = false;
      });
      return;
    }
    setState(() => _saving = true);
    try {
      await config.save();
      if (!mounted) return;
      setState(() {
        _config = config;
        _status = '配置已保存，影视资料将自动刷新';
        _statusOk = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = '保存失败，请重试';
          _statusOk = false;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    final config = _editedConfig();
    setState(() {
      _testing = true;
      _status = null;
    });
    try {
      await _service.testConnection(config);
      if (!mounted) return;
      setState(() {
        _status = '连接成功';
        _statusOk = true;
      });
    } on TmdbConnectionException catch (e) {
      if (!mounted) return;
      setState(() {
        _status = e.message;
        _statusOk = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _status = '连接失败，请检查地址、网络和 API Key';
        _statusOk = false;
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('TMDB 资料配置')),
      body: config == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (!config.configured)
                      Card(
                        color: colors.surfaceContainerHighest,
                        child: const Padding(
                          padding: EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '未配置 apikey',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                              SizedBox(height: 6),
                              Text(
                                'TMDB 海报、背景、剧情与剧集预览暂不可用，详情页只显示站源自带内容。请在下面填入自己的 TMDB API Key 后保存。',
                                style: TextStyle(height: 1.5),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const ValueKey('tmdb-api-key-field'),
                      controller: _apiKeyController,
                      obscureText: _obscureKey,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: 'API Key',
                        hintText: '请输入 API Key',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: _obscureKey ? '显示 API Key' : '隐藏 API Key',
                          icon: Icon(
                            _obscureKey
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          onPressed: () =>
                              setState(() => _obscureKey = !_obscureKey),
                        ),
                      ),
                      onChanged: (_) {
                        if (_status != null) setState(() => _status = null);
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('tmdb-language-field'),
                      controller: _languageController,
                      decoration: const InputDecoration(
                        labelText: '语言',
                        hintText: '请输入语言代码，例如 zh-CN',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'API Key 只保存在本机，不会上传。没有 Key 时不联网请求 TMDB。',
                      style: TextStyle(height: 1.5),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            key: const ValueKey('tmdb-save-button'),
                            onPressed: _saving ? null : _save,
                            child: _saving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('保存'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton(
                            key: const ValueKey('tmdb-test-button'),
                            onPressed: _testing ? null : _test,
                            child: _testing
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('测试连接'),
                          ),
                        ),
                      ],
                    ),
                    if (_status != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _status!,
                        key: const ValueKey('tmdb-status'),
                        style: TextStyle(
                          color: _statusOk ? colors.primary : colors.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}
