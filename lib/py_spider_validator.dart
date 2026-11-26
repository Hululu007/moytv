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
    this.missingCore = const [],
  });

  final bool ok;
  final bool hasSpider;
  final List<String> missing;
  final List<String> filled;
  final String mode;

  /// 仅播放模式下缺失的核心方法名单。missing 在该模式下按既有
  /// 口径清空，这份单独留给导入备注写明到底缺了什么。
  final List<String> missingCore;

  bool get playOnly => mode == 'playOnly';

  String get message {
    if (ok) return '';
    if (!hasSpider) return '未找到 class Spider，不是 TVBox py 蜘蛛文件';
    return '缺少核心方法：${missing.join('、')}';
  }

  /// 核心方法缺失对用户可见功能的影响（仅播放备注用）。
  static const _coreImpact = {
    'getName': '站点名只能用文件名',
    'init': '初始化按默认处理',
    'homeContent': '首页没有分类',
    'homeVideoContent': '首页没有视频列表',
    'categoryContent': '分类列表不可用',
    'detailContent': '详情不可用',
    'searchContent': '搜索不可用',
  };

  String get filledNote {
    if (filled.isEmpty) return '';
    if (playOnly) {
      final parts = <String>[];
      if (missingCore.isNotEmpty) {
        final impacts = [
          for (final method in missingCore)
            if (_coreImpact[method] != null) _coreImpact[method]!,
        ];
        final impactText = impacts.isEmpty ? '' : '（${impacts.join('；')}）';
        parts.add(
          '缺少核心方法 ${missingCore.join('、')}$impactText，'
          '未缺的分类、搜索、详情、播放功能照常可用',
        );
      }
      final defaulted = filled
          .where(PySpiderContract.defaultedMethods.contains)
          .toList();
      if (defaulted.isNotEmpty) {
        parts.add('已自动补齐缺省方法 ${defaulted.length} 个：${defaulted.join('、')}');
      }
      return parts.join('；');
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
      missingCore: missing,
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
