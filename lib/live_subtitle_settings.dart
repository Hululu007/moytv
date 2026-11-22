import 'package:shared_preferences/shared_preferences.dart';

/// 实时翻译字幕设置：播放视频时用端侧 Whisper 识别语音、再翻译成中文，
/// 字幕叠在播放器现有字幕层上。
///
/// 持久化口径与树里其他设置模型一致（见 viewing_experience_settings.dart）：
/// 不可变模型 + `moyi_live_subtitle_*` 键 + load/save。
class LiveSubtitleSettings {
  const LiveSubtitleSettings({
    this.enabled = false,
    this.sourceLanguage = 'auto',
    this.modelId = 'tiny',
    this.showOriginal = true,
    this.wifiOnlyDownload = true,
    this.libreTranslateUrl = '',
    this.modelMirrorUrl = '',
    this.translationProvider = 'builtin',
    this.llmBaseUrl = defaultLlmBaseUrl,
    this.llmApiKey = '',
    this.llmModel = defaultLlmModel,
    this.llmThinking = false,
    this.llmContext = true,
    this.mtranUrl = defaultMtranUrl,
    this.mtranToken = '',
  });

  /// LLM 通道默认地址与模型（对齐魔改影视的字幕翻译默认值）。
  static const String defaultLlmBaseUrl = 'https://api.deepseek.com';
  static const String defaultLlmModel = 'deepseek-chat';
  static const String defaultMtranUrl = 'http://localhost:8989';

  static const String keyEnabled = 'moyi_live_subtitle_enabled';
  static const String keySourceLanguage = 'moyi_live_subtitle_source_lang';
  static const String keyModelId = 'moyi_live_subtitle_model';
  static const String keyShowOriginal = 'moyi_live_subtitle_show_original';
  static const String keyWifiOnlyDownload =
      'moyi_live_subtitle_wifi_only_download';
  static const String keyLibreTranslateUrl =
      'moyi_live_subtitle_libretranslate_url';
  static const String keyModelMirrorUrl = 'moyi_live_subtitle_model_mirror';
  static const String keyTranslationProvider =
      'moyi_live_subtitle_translation_provider';
  static const String keyLlmBaseUrl = 'moyi_live_subtitle_llm_base_url';
  static const String keyLlmApiKey = 'moyi_live_subtitle_llm_api_key';
  static const String keyLlmModel = 'moyi_live_subtitle_llm_model';
  static const String keyLlmThinking = 'moyi_live_subtitle_llm_thinking';
  static const String keyLlmContext = 'moyi_live_subtitle_llm_context';
  static const String keyMtranUrl = 'moyi_live_subtitle_mtran_url';
  static const String keyMtranToken = 'moyi_live_subtitle_mtran_token';

  /// 总开关，默认关。
  final bool enabled;

  /// 源语言：auto=自动检测，ja=日语，en=英语，ko=韩语。
  final String sourceLanguage;

  /// 识别模型：tiny=约 74MB（推荐），base=约 141MB（更准更慢）。
  /// 只列多语言模型（英文专用模型不进列表）。
  final String modelId;

  /// 双语对照：同时显示原文行与译文行；关则只显示译文。
  final bool showOriginal;

  /// 仅在 Wi-Fi 下下载模型。
  final bool wifiOnlyDownload;

  /// LibreTranslate 服务器地址（用户自填，默认空）。
  /// 填了就优先走它，失败回退内置翻译通道；留空直接用内置通道。
  /// 绝不写死任何私人地址。
  final String libreTranslateUrl;

  /// 模型下载镜像地址（用户自填，默认空）。
  /// 留空用 Hugging Face；填了则从该地址拼模型文件名下载。
  final String modelMirrorUrl;

  /// 翻译后端：builtin=内置免费通道；llm=OpenAI 兼容大模型；
  /// mtran=MTranServer；libre=LibreTranslate（填了地址时才可选）。
  final String translationProvider;

  /// 大模型通道：OpenAI 兼容的 base_url（不带 /v1 也行）、Key、模型名。
  final String llmBaseUrl;
  final String llmApiKey;
  final String llmModel;

  /// 大模型通道开关：思考模式（慢但更准）、带上文（前后几条一起翻）。
  final bool llmThinking;
  final bool llmContext;

  /// MTranServer 地址与可选 token。
  final String mtranUrl;
  final String mtranToken;

  /// Whisper 源语言码：auto/ja/en/ko 原样透传。
  String get whisperLanguageCode => sourceLanguage;

  /// LibreTranslate 源语言码：auto 透传（服务端自动检测）。
  String get libreTranslateSourceCode => sourceLanguage;

  /// 是否配了联网翻译：配了 LibreTranslate 地址才算配了。
  bool get hasRemoteTranslator => libreTranslateUrl.trim().isNotEmpty;

  /// 大模型通道是否可用（地址与 Key 都填了）。
  bool get hasLlmTranslator =>
      llmBaseUrl.trim().isNotEmpty && llmApiKey.trim().isNotEmpty;

  /// MTranServer 是否可用。
  bool get hasMtranTranslator => mtranUrl.trim().isNotEmpty;

  /// 实际生效的翻译后端：选了但没配好就回落到内置通道，
  /// 绝不让字幕因为设置缺失而整条不出。
  String get effectiveTranslationProvider {
    switch (translationProvider) {
      case 'llm':
        return hasLlmTranslator ? 'llm' : 'builtin';
      case 'mtran':
        return hasMtranTranslator ? 'mtran' : 'builtin';
      case 'libre':
        return hasRemoteTranslator ? 'libre' : 'builtin';
      default:
        return 'builtin';
    }
  }

  /// 当前翻译路线说明（设置页直接展示，不虚构能力）。
  /// 内置翻译通道（谷歌免费端点）默认可用，不再要求用户自填服务器；
  /// 填了 LibreTranslate 就优先走它，失败自动回退内置通道。
  String get translationRouteLabel {
    switch (effectiveTranslationProvider) {
      case 'llm':
        return '当前翻译路线：语音识别（端侧）→ 大模型 $llmModel（失败回退内置翻译）';
      case 'mtran':
        return '当前翻译路线：语音识别（端侧）→ MTranServer（失败回退内置翻译）';
      case 'libre':
        return '当前翻译路线：语音识别（端侧）→ LibreTranslate（失败回退内置翻译）';
      default:
        return '当前翻译路线：语音识别（端侧）→ 内置翻译（无需配置）';
    }
  }

  LiveSubtitleSettings copyWith({
    bool? enabled,
    String? sourceLanguage,
    String? modelId,
    bool? showOriginal,
    bool? wifiOnlyDownload,
    String? libreTranslateUrl,
    String? modelMirrorUrl,
    String? translationProvider,
    String? llmBaseUrl,
    String? llmApiKey,
    String? llmModel,
    bool? llmThinking,
    bool? llmContext,
    String? mtranUrl,
    String? mtranToken,
  }) => LiveSubtitleSettings(
    enabled: enabled ?? this.enabled,
    sourceLanguage: sourceLanguage ?? this.sourceLanguage,
    modelId: modelId ?? this.modelId,
    showOriginal: showOriginal ?? this.showOriginal,
    wifiOnlyDownload: wifiOnlyDownload ?? this.wifiOnlyDownload,
    libreTranslateUrl: libreTranslateUrl ?? this.libreTranslateUrl,
    modelMirrorUrl: modelMirrorUrl ?? this.modelMirrorUrl,
    translationProvider: translationProvider ?? this.translationProvider,
    llmBaseUrl: llmBaseUrl ?? this.llmBaseUrl,
    llmApiKey: llmApiKey ?? this.llmApiKey,
    llmModel: llmModel ?? this.llmModel,
    llmThinking: llmThinking ?? this.llmThinking,
    llmContext: llmContext ?? this.llmContext,
    mtranUrl: mtranUrl ?? this.mtranUrl,
    mtranToken: mtranToken ?? this.mtranToken,
  );

  static Future<LiveSubtitleSettings> load([
    SharedPreferences? prefs,
  ]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    return LiveSubtitleSettings(
      enabled: store.getBool(keyEnabled) ?? false,
      sourceLanguage: store.getString(keySourceLanguage) ?? 'auto',
      modelId: store.getString(keyModelId) ?? 'tiny',
      showOriginal: store.getBool(keyShowOriginal) ?? true,
      wifiOnlyDownload: store.getBool(keyWifiOnlyDownload) ?? true,
      libreTranslateUrl: store.getString(keyLibreTranslateUrl) ?? '',
      modelMirrorUrl: store.getString(keyModelMirrorUrl) ?? '',
      translationProvider:
          store.getString(keyTranslationProvider) ?? 'builtin',
      llmBaseUrl: store.getString(keyLlmBaseUrl) ?? defaultLlmBaseUrl,
      llmApiKey: store.getString(keyLlmApiKey) ?? '',
      llmModel: store.getString(keyLlmModel) ?? defaultLlmModel,
      llmThinking: store.getBool(keyLlmThinking) ?? false,
      llmContext: store.getBool(keyLlmContext) ?? true,
      mtranUrl: store.getString(keyMtranUrl) ?? defaultMtranUrl,
      mtranToken: store.getString(keyMtranToken) ?? '',
    );
  }

  Future<void> save([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    await store.setBool(keyEnabled, enabled);
    await store.setString(keySourceLanguage, sourceLanguage);
    await store.setString(keyModelId, modelId);
    await store.setBool(keyShowOriginal, showOriginal);
    await store.setBool(keyWifiOnlyDownload, wifiOnlyDownload);
    await store.setString(keyLibreTranslateUrl, libreTranslateUrl);
    await store.setString(keyModelMirrorUrl, modelMirrorUrl);
    await store.setString(keyTranslationProvider, translationProvider);
    await store.setString(keyLlmBaseUrl, llmBaseUrl);
    await store.setString(keyLlmApiKey, llmApiKey);
    await store.setString(keyLlmModel, llmModel);
    await store.setBool(keyLlmThinking, llmThinking);
    await store.setBool(keyLlmContext, llmContext);
    await store.setString(keyMtranUrl, mtranUrl);
    await store.setString(keyMtranToken, mtranToken);
  }
}

/// 设置页列出的识别模型（与 whisper 插件内置目录同款：
/// 多语言 tiny/base，校验码见插件 WhisperModelCatalog）。
class LiveSubtitleModelOption {
  const LiveSubtitleModelOption({
    required this.id,
    required this.fileName,
    required this.approximateBytes,
    required this.label,
    required this.detail,
  });

  final String id;
  final String fileName;
  final int approximateBytes;
  final String label;
  final String detail;

  String get sizeLabel {
    final mb = approximateBytes / (1024 * 1024);
    return '约 ${mb.toStringAsFixed(0)} MB';
  }

  static const List<LiveSubtitleModelOption> values = [
    LiveSubtitleModelOption(
      id: 'tiny',
      fileName: 'ggml-tiny.bin',
      approximateBytes: 77691713,
      label: 'tiny（推荐）',
      detail: '约 74 MB · 速度快 · 日语口语够用',
    ),
    LiveSubtitleModelOption(
      id: 'base',
      fileName: 'ggml-base.bin',
      approximateBytes: 147951465,
      label: 'base',
      detail: '约 141 MB · 更准 · 更慢更耗电',
    ),
  ];

  static LiveSubtitleModelOption byId(String id) {
    for (final option in values) {
      if (option.id == id) return option;
    }
    return values.first;
  }
}

/// 源语言选项。
class LiveSubtitleLanguageOption {
  const LiveSubtitleLanguageOption({
    required this.code,
    required this.label,
  });

  final String code;
  final String label;

  static const List<LiveSubtitleLanguageOption> values = [
    LiveSubtitleLanguageOption(code: 'auto', label: '自动检测'),
    LiveSubtitleLanguageOption(code: 'ja', label: '日语'),
    LiveSubtitleLanguageOption(code: 'en', label: '英语'),
    LiveSubtitleLanguageOption(code: 'ko', label: '韩语'),
  ];

  static String labelOf(String code) {
    for (final option in values) {
      if (option.code == code) return option.label;
    }
    return '自动检测';
  }
}
