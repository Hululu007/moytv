class PySpiderContract {
  static const coreMethods = [
    'getName',
    'init',
    'homeContent',
    'homeVideoContent',
    'categoryContent',
    'detailContent',
    'searchContent',
    'playerContent',
  ];

  static const defaultedMethods = [
    'getDependence',
    'destroy',
    'localProxy',
    'isVideoFormat',
    'manualVideoCheck',
    'action',
  ];

  static const requiredMethods = [...coreMethods, ...defaultedMethods];
}

class PySourceValidation {
  const PySourceValidation({
    required this.ok,
    required this.hasSpider,
    required this.missing,
    this.filled = const [],
    this.mode = 'full',
  });

  final bool ok;
  final bool hasSpider;
  final List<String> missing;
  final List<String> filled;
  final String mode;

  bool get playOnly => mode == 'playOnly';

  String get message {
    if (ok) return '';
    if (!hasSpider) return '未找到 class Spider，不是 TVBox py 蜘蛛文件';
    return '缺少核心方法：${missing.join('、')}';
  }

  String get filledNote {
    if (filled.isEmpty) return '';
    if (playOnly) {
      return '仅播放模式，已补齐 ${filled.length} 个方法：${filled.join('、')}';
    }
    return '已自动补齐缺省方法 ${filled.length}/${PySpiderContract.defaultedMethods.length}：${filled.join('、')}';
  }
}

PySourceValidation validatePySource(String source) {
  final hasSpider = RegExp(r'class\s+Spider\s*[:(]').hasMatch(source);
  if (!hasSpider) {
    return const PySourceValidation(
      ok: false,
      hasSpider: false,
      missing: PySpiderContract.coreMethods,
    );
  }
  bool defines(String method) =>
      RegExp('def\\s+$method\\s*\\(').hasMatch(source) ||
      RegExp('^\\s*$method\\s*=', multiLine: true).hasMatch(source);
  final missing = [
    for (final method in PySpiderContract.coreMethods)
      if (!defines(method)) method,
  ];
  final filled = [
    for (final method in PySpiderContract.defaultedMethods)
      if (!defines(method)) method,
  ];
  if (missing.isNotEmpty && defines('playerContent')) {
    return PySourceValidation(
      ok: true,
      hasSpider: true,
      missing: const [],
      filled: [...missing, ...filled],
      mode: 'playOnly',
    );
  }
  return PySourceValidation(
    ok: missing.isEmpty,
    hasSpider: true,
    missing: missing,
    filled: filled,
  );
}

String? identifyJsSource(String source) {
  final text = source.trim();
  if (text.isEmpty) return '文件为空';
  final markers = [
    'homeContent',
    'categoryContent',
    'detailContent',
    'searchContent',
    'playerContent',
    'spider',
    'rule',
  ];
  if (!markers.any(text.contains)) {
    return '未识别到 JS 蜘蛛特征（缺少 homeContent/spider/rule 等标记）';
  }
  return null;
}
