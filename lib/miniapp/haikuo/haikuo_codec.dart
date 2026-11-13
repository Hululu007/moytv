import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:enough_convert/enough_convert.dart';

import 'haikuo_program.dart';

/// 海阔小程序文本解析：JSON 结构归一 + 口令解码。
///
/// 海阔生态里同一个小程序的落盘形态差别很大——有的是脚本包，有的是
/// 规则清单，外面还可能套一层 `{data: [...]}` / `{sites: [...]}`；
/// 口令又可能是纯 JSON、URL、base64、gzip+base64 或 zip。
/// 这里统一做「尽量认出来」，认不出就抛一句人话，不让调用方崩。
abstract final class HaikuoCodec {
  static const _wrapperKeys = <String>[
    'data',
    'list',
    'items',
    'apps',
    'programs',
    'programmes',
    'miniapps',
    'miniApps',
    'miniprograms',
    'sites',
    'rules',
    'result',
    'results',
    'payload',
    'body',
    '小程序',
    '海阔小程序',
    '海阔',
    'appsList',
    'appList',
    'sourceList',
    'sources',
  ];

  static final _urlPattern = RegExp(
    r'''https?://[^\s，。、"',<>（）()【】\[\]]+''',
    caseSensitive: false,
  );

  /// 把一段文本（JSON / base64 / gzip / zip 的文本形态）解析成小程序列表。
  static List<HaikuoProgram> parseText(String text, {String origin = ''}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const HaikuoFormatException('内容为空，没有可导入的小程序');
    }
    final bytes = Uint8List.fromList(utf8.encode(trimmed));
    return parseBytes(bytes, origin: origin);
  }

  /// 二进制解析：自动识别 zip / gzip / 纯文本 / base64。
  static List<HaikuoProgram> parseBytes(
    List<int> bytes, {
    String origin = '',
    int depth = 0,
  }) {
    if (bytes.isEmpty) {
      throw const HaikuoFormatException('内容为空，没有可导入的小程序');
    }
    if (depth > 4) {
      throw const HaikuoFormatException('小程序包嵌套层级过深，已停止解析');
    }
    // zip：把里面的 json / txt 全试一遍
    if (bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
      final archive = ZipDecoder().decodeBytes(bytes);
      final programs = <HaikuoProgram>[];
      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        final name = entry.name.toLowerCase();
        if (!(name.endsWith('.json') ||
            name.endsWith('.txt') ||
            name.endsWith('.js'))) {
          continue;
        }
        final content = entry.content as List<int>?;
        if (content == null || content.isEmpty) continue;
        try {
          programs.addAll(
            parseBytes(
              content,
              origin: origin,
              depth: depth + 1,
            ).map((item) => item.copyWith(origin: origin)),
          );
        } on HaikuoFormatException {
          continue;
        }
      }
      if (programs.isEmpty) {
        throw const HaikuoFormatException('压缩包里没有找到小程序 JSON');
      }
      return programs;
    }
    // gzip
    if (bytes.length > 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
      final raw = GZipDecoder().decodeBytes(bytes);
      return parseBytes(raw, origin: origin, depth: depth + 1);
    }
    final text = decodeText(bytes).trim();
    final head = text.isEmpty ? '' : text.codeUnitAt(0);
    if (head == 0x7B || head == 0x5B) {
      return parseJsonText(text, origin: origin);
    }
    // 文本形态的 base64 / 口令
    final decoded = tryBase64(text);
    if (decoded != null && decoded.isNotEmpty) {
      try {
        return parseBytes(decoded, origin: origin, depth: depth + 1);
      } on HaikuoFormatException {
        // 落到下面按口令再试一次
      }
    }
    throw const HaikuoFormatException(
      '没认出这个格式，海阔小程序需要 JSON、压缩包或有效口令',
    );
  }

  /// 解码字节为文本：优先 UTF-8，不行退回 GBK。
  static String decodeText(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      try {
        return const GbkCodec(allowInvalid: true).decode(bytes);
      } catch (_) {
        return latin1.decode(bytes, allowInvalid: true);
      }
    }
  }

  static Uint8List? tryBase64(String text) {
    var value = text.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('data:') && value.contains(',')) {
      value = value.substring(value.indexOf(',') + 1);
    }
    value = value.replaceAll(RegExp(r'\s'), '');
    if (value.length < 8) return null;
    if (!RegExp(r'^[A-Za-z0-9+/\-_]+=*$').hasMatch(value)) return null;
    var normalized = value.replaceAll('-', '+').replaceAll('_', '/');
    final remainder = normalized.length % 4;
    if (remainder == 2) {
      normalized += '==';
    } else if (remainder == 3) {
      normalized += '=';
    } else if (remainder != 0) {
      return null;
    }
    try {
      return base64.decode(normalized);
    } catch (_) {
      return null;
    }
  }

  static List<HaikuoProgram> parseJsonText(String text, {String origin = ''}) {
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const HaikuoFormatException('JSON 格式有误，检查一下括号和引号');
    }
    final programs = parseDecoded(decoded, origin: origin, rawText: text);
    if (programs.isEmpty) {
      throw const HaikuoFormatException('JSON 里没有识别到海阔小程序条目');
    }
    return programs;
  }

  /// 结构归一：单对象、数组、包一层的 `{data: [...]}` 都能吃。
  static List<HaikuoProgram> parseDecoded(
    dynamic decoded, {
    String origin = '',
    String rawText = '',
    int depth = 0,
  }) {
    final out = <HaikuoProgram>[];
    _collect(
      decoded,
      out,
      origin: origin,
      rawText: rawText,
      depth: depth,
    );
    return out;
  }

  static void _collect(
    dynamic node,
    List<HaikuoProgram> out, {
    required String origin,
    required String rawText,
    required int depth,
  }) {
    if (depth > 6) return;
    if (node is List) {
      for (final item in node) {
        _collect(
          item,
          out,
          origin: origin,
          rawText: rawText,
          depth: depth + 1,
        );
      }
      return;
    }
    if (node is! Map) return;
    final map = <String, dynamic>{
      for (final entry in node.entries) '${entry.key}': entry.value,
    };
    final name = _firstText(map, const [
      'name',
      'title',
      '名称',
      'appName',
      'nickName',
      'nickname',
      'appname',
    ]);
    // 海阔原生规则用的是 find_rule / rule / searchFind 这几个字段，
    // 导出的「小程序包」里有的写成 script / code / js，两种都要认。
    final script = _firstText(map, const [
      'script',
      'find_rule',
      'findRule',
      'rule',
      'code',
      'js',
      'javascript',
      'sourceCode',
      'scriptCode',
      'searchFind',
      'main',
      'content',
      'body',
      'src',
    ], minLength: 6);
    final url = _firstText(map, const [
      'url',
      'link',
      'address',
      'entry',
      'entryUrl',
      'homepage',
      '网址',
      'api',
    ]);
    final entries = _countEntries(map);

    if (name != null && script != null) {
      final icon = _firstText(map, const ['icon', 'img', 'logo', 'cover', 'pic']);
      final author = _firstText(map, const ['author', 'user', '作者', 'nick']) ?? '';
      final version = _firstText(map, const ['version', 'ver', '版本']) ?? '';
      final description =
          _firstText(map, const ['desc', 'description', 'intro', '简介', 'remark']) ??
          '';
      final isRule =
          map.containsKey('find_rule') ||
          map.containsKey('findRule') ||
          map.containsKey('col_type') ||
          map.containsKey('pages') ||
          map.containsKey('searchFind');
      final raw = jsonEncode(map);
      out.add(
        HaikuoProgram(
          id: HaikuoProgram.makeId(name, raw),
          name: name,
          author: author,
          version: version,
          icon: icon ?? '',
          description: description,
          script: script,
          url: url ?? '',
          kind: isRule ? HaikuoKind.rule : HaikuoKind.script,
          origin: origin,
          rawJson: raw,
          entries: entries,
          importedAt: DateTime.now(),
        ),
      );
      return;
    }

    // 纯包裹（只有 name + data/sites 之类）要继续往里钻，别把它当成一个小程序。
    final looksLikeRule =
        url != null ||
        map.containsKey('find_rule') ||
        map.containsKey('findRule') ||
        map.containsKey('col_type') ||
        map.containsKey('pages') ||
        map.containsKey('searchFind');
    // 规则 / 清单形态：有名字、有链接或有一批子条目，但没有脚本主体。
    if (name != null && looksLikeRule) {
      final icon = _firstText(map, const ['icon', 'img', 'logo', 'cover', 'pic']);
      final author = _firstText(map, const ['author', 'user', '作者', 'nick']) ?? '';
      final description =
          _firstText(map, const ['desc', 'description', 'intro', '简介', 'remark']) ??
          '';
      final body = url ?? jsonEncode(map);
      out.add(
        HaikuoProgram(
          id: HaikuoProgram.makeId(name, body),
          name: name,
          author: author,
          icon: icon ?? '',
          description: description,
          url: url ?? '',
          kind: url != null && entries == 0 ? HaikuoKind.link : HaikuoKind.rule,
          origin: origin,
          rawJson: rawText.isEmpty ? jsonEncode(map) : rawText,
          entries: entries,
          importedAt: DateTime.now(),
        ),
      );
      return;
    }

    for (final key in _wrapperKeys) {
      final child = map[key];
      if (child == null) continue;
      _collect(
        child,
        out,
        origin: origin,
        rawText: rawText,
        depth: depth + 1,
      );
    }
  }

  static int _countEntries(Map<String, dynamic> map) {
    for (final key in const ['data', 'list', 'items', 'sites', 'rules', 'sources']) {
      final value = map[key];
      if (value is List && value.isNotEmpty) return value.length;
    }
    // 海阔规则的子页写在 pages 里，可能是 JSON 字符串
    final pages = map['pages'];
    if (pages is List && pages.isNotEmpty) return pages.length;
    if (pages is String && pages.trim().startsWith('[')) {
      try {
        final decoded = jsonDecode(pages);
        if (decoded is List) return decoded.length;
      } catch (_) {}
    }
    return 0;
  }

  static String? _firstText(
    Map<String, dynamic> map,
    List<String> keys, {
    int minLength = 1,
  }) {
    for (final key in keys) {
      final value = map[key];
      if (value is String) {
        final trimmed = value.trim();
        if (trimmed.length >= minLength) return trimmed;
      } else if (value is num) {
        // 用户规则的 version 是数字（如 16、3），不认数字会丢版本号。
        final text = value.toString();
        if (text.length >= minLength) return text;
      }
    }
    return null;
  }

  /// 从口令文本里抽出所有值得尝试的载荷（URL / 深链 / 原始文本）。
  ///
  /// 海阔官方的分享口令有三种形态（对照 hikerView 的 AutoImportHelper）：
  /// 1. `海阔视界规则分享，当前分享的是：小程序￥home_rule￥<载荷>￥…`
  /// 2. `rule://<整段口令的 base64>`
  /// 3. 载荷本身是 `base64://@标题@<规则 JSON 的 base64>`
  static List<String> extractCandidates(String raw) {
    final text = raw.trim();
    final candidates = <String>[];
    void add(String value) {
      var v = value.trim();
      // 官方口令结尾常带分隔符（`…￥`），尾巴剪干净再当载荷试
      while (v.endsWith('￥') || v.endsWith('|')) {
        v = v.substring(0, v.length - 1).trim();
      }
      if (v.isEmpty) return;
      if (!candidates.contains(v)) candidates.add(v);
    }

    add(text);
    // rule://<base64>：解出来就是一段完整口令，递归再抽一次
    if (text.toLowerCase().startsWith('rule://')) {
      final decoded = tryBase64(text.substring('rule://'.length));
      if (decoded != null && decoded.isNotEmpty) {
        for (final nested in extractCandidates(decodeText(decoded))) {
          add(nested);
        }
      }
    }
    // base64://@标题@<载荷>
    if (text.contains('base64://@')) {
      final parts = text.split('@');
      for (final part in parts) {
        final trimmedPart = part.trim().replaceAll('base64://', '');
        if (trimmedPart.length > 24) {
          final decoded = tryBase64(trimmedPart);
          if (decoded != null && decoded.isNotEmpty) {
            final inner = decodeText(decoded).trim();
            if (looksLikeJson(inner)) add(inner);
          }
        }
      }
    }
    // 官方口令的 ￥ 分段：第 0 段是提示语，第 1 段是类型，第 2 段起是载荷
    if (text.contains('￥')) {
      final segments = text.split('￥');
      if (segments.length >= 3) {
        add(segments.sublist(2).join('￥'));
        for (final segment in segments.sublist(2)) {
          add(segment);
        }
      }
      for (final segment in segments) {
        add(segment);
      }
    }
    for (final match in _urlPattern.allMatches(text)) {
      add(match.group(0) ?? '');
    }
    // 海阔 / hiker 深链：把里面的 url / code / data 参数挖出来
    final deepLink = RegExp(
      r'''(?:hiker|haikuo|haik|海阔)://[^\s，。、"',<>（）]+''',
      caseSensitive: false,
    );
    for (final match in deepLink.allMatches(text)) {
      final link = match.group(0) ?? '';
      add(link);
      try {
        final uri = Uri.parse(link);
        for (final key in const ['url', 'u', 'code', 'data', 'json', 'src']) {
          final value = uri.queryParameters[key];
          if (value != null && value.isNotEmpty) add(value);
        }
        final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
        for (final segment in segments) {
          if (segment.length > 12) add(segment);
        }
      } catch (_) {
        // 深链解析失败就当普通文本处理
      }
    }
    // 「口令：xxxx」这种带前缀的写法，把前半段去掉再试一次
    for (final separator in const ['：', ':', '】', ']', '>']) {
      final index = text.indexOf(separator);
      if (index > 0 && index < text.length - 8) {
        add(text.substring(index + 1));
      }
    }
    return candidates;
  }

  /// 云口令短码：`云<N>oooole/<短码>`（海阔官方云剪贴板分享的简写）。
  ///
  /// 已验证的映射（2026-11-11 实测）：
  /// 云 6 = 摆烂剪贴板 pasteme.tyrantg.com，取法
  /// `GET https://pasteme.tyrantg.com/api/getContent/<短码>`，
  /// 短码取 `云6oooole/xxxxxx/<短码>` 里最后一个 `/` 后面的那段
  /// （`xxxxxx/` 前缀不能带进接口地址，会 500）；
  /// 接口回 `{"return_code":0,"data":"<标准口令文本>"}`，
  /// 再按普通口令解析。其他云编号的服务端地址未公开
  /// （官方导入器 RuleImporterManager 闭源），不硬猜，报明原因。
  static final _cloudCodePattern = RegExp(
    r'云\s*(\d+)\s*oooole\s*/\s*([A-Za-z0-9_.\-/]+)',
    caseSensitive: false,
  );

  /// 从文本里找云口令短码，返回取回用的接口地址；没有短码返回 null。
  ///
  /// 未知云编号直接抛错（不在这里返回 null，免得调用方把它当普通口令
  /// 再试一圈，最后只剩一句没头没尾的“没认出这个格式”）。
  static String? cloudApiUrl(String text) {
    final match = _cloudCodePattern.firstMatch(text);
    if (match == null) return null;
    final cloud = int.tryParse(match.group(1) ?? '') ?? 0;
    final tail = match.group(2) ?? '';
    final code = tail.split('/').lastWhere(
      (segment) => segment.isNotEmpty,
      orElse: () => '',
    );
    if (code.isEmpty) return null;
    if (cloud == 6) {
      return 'https://pasteme.tyrantg.com/api/getContent/$code';
    }
    throw HaikuoFormatException(
      '云剪贴板$cloud 的取回地址未公开（官方导入器闭源），暂不能直接解析；'
      '请用 JSON 文件、明文口令或云剪贴板 6 的链接导入',
    );
  }

  /// 解析云剪贴板接口的返回体，取出里面的口令文本。
  static String parseCloudApiResponse(String body) {
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const HaikuoFormatException('云剪贴板返回的内容无法解析');
    }
    if (decoded is! Map) {
      throw const HaikuoFormatException('云剪贴板返回的内容无法解析');
    }
    if (decoded['return_code'] != 0) {
      throw const HaikuoFormatException(
        '云剪贴板没找到这条内容，可能已过期或被删除',
      );
    }
    final data = decoded['data'];
    if (data is! String || data.trim().isEmpty) {
      throw const HaikuoFormatException(
        '云剪贴板没找到这条内容，可能已过期或被删除',
      );
    }
    return data;
  }

  /// 生成口令分享：把一条规则编成官方 ￥ 口令形态
  /// `海阔视界规则分享，当前分享的是：小程序￥home_rule￥<载荷>￥`，
  /// 载荷是规则 JSON 的 base64。现有导入（extractCandidates →
  /// parseBytes → tryBase64）能原样认回，往返不丢字段。
  ///
  /// 载荷优先用规则的原始 JSON（rawJson，含 class/sort 等声明）；
  /// 没有原始 JSON 时按导入器认的字段重建一份最小规则对象。
  /// 云剪贴板 6 的上传接口未公开（官网无文档），这里不编假短码，
  /// 只出本地口令：对方在口令导入里粘贴即可。
  static String buildShareCode(HaikuoProgram program) {
    final payload = base64Encode(utf8.encode(shareJson(program)));
    return '海阔视界规则分享，当前分享的是：小程序￥home_rule￥$payload￥';
  }

  /// 口令载荷用的规则 JSON 文本（buildShareCode 与“复制 JSON”共用）。
  static String shareJson(HaikuoProgram program) {
    final raw = program.rawJson.trim();
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return raw;
      } on FormatException {
        // 原始文本不是合法 JSON，往下重建。
      }
    }
    final map = <String, dynamic>{
      'title': program.name,
      if (program.author.isNotEmpty) 'author': program.author,
      if (program.version.isNotEmpty) 'version': program.version,
      if (program.url.isNotEmpty) 'url': program.url,
      if (program.script.isNotEmpty) 'script': program.script,
    };
    return jsonEncode(map);
  }

  static bool looksLikeJson(String text) {
    final trimmed = text.trim();
    return trimmed.startsWith('{') || trimmed.startsWith('[');
  }
}
