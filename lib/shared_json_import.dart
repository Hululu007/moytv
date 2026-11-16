import 'dart:convert';

import 'content_legado.dart';
import 'core_bridge.dart';
import 'miniapp/haikuo/haikuo_codec.dart';
import 'miniapp/haikuo/haikuo_program.dart';
import 'miniapp/haikuo/haikuo_store.dart';
import 'novel_source_store.dart';
import 'tvbox_config.dart';

/// 系统里分享/打开一个 JSON 文件时的内容分流：
///
/// 只复用各导入器现有的识别与导入能力，不自创新规则：
/// - TVBox 配置：TvBoxConfigParser 能解出的对象且含 sites/spider 键
///   （与导入中心文件导入的判定一致；base64 包裹与尾随逗号由解析器
///   自己处理，与导入器实际接受能力一致）；
/// - 阅读书源：validateLegadoJson（单对象）；数组时逐条用同一判定，
///   与阅读区批量导入同一条规则；
/// - 海阔小程序：HaikuoCodec.parseText 能解析出条目（与小程序页
///   文件导入同一套解析，含宽容 JSON、zip、gzip、base64 形态）。
///
/// 判定顺序是 TVBox → 书源 → 海阔：海阔解析器会把 TVBox 配置里
/// 的每个站点（有 name 又有 api）认成一条小程序，所以配置必须先判；
/// 书源签名（bookSourceUrl + 四组规则）足够独特，放中间可避免
/// 被海阔解析器误认。三种都不是时返回 unsupported，调用方诚实
/// 提示，不崩。
///
/// 已知边界：带 `//` 注释的 TVBox 配置到不了 TVBox 判定（应用内
/// 文件导入的严格判定同样拒绝它），会落到海阔解析——与现有各路
/// 的行为一致，这里不另行处理。
enum SharedJsonKind { haikuo, legado, tvboxConfig, unsupported }

SharedJsonKind classifySharedJson(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return SharedJsonKind.unsupported;
  // TVBox 配置：对象形态 + sites/spider 键。
  try {
    final parsed = TvBoxConfigParser.parse(trimmed);
    if (parsed.containsKey('sites') || parsed.containsKey('spider')) {
      return SharedJsonKind.tvboxConfig;
    }
  } catch (_) {
    // 不是配置对象，往下试。
  }
  // 阅读书源：单对象走 validateLegadoJson；数组逐条用同一判定，
  // 有一条能过即算书源（与阅读区批量导入的规则一致）。
  dynamic decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    decoded = null;
  }
  if (decoded is Map) {
    try {
      validateLegadoJson(trimmed);
      return SharedJsonKind.legado;
    } catch (_) {
      // 不是合法书源，往下试海阔。
    }
  } else if (decoded is List) {
    for (final item in decoded) {
      if (item is! Map) continue;
      try {
        validateLegadoJson(jsonEncode(item));
        return SharedJsonKind.legado;
      } catch (_) {
        continue;
      }
    }
  }
  // 海阔小程序：解析器自己说了算，抛错即不是规则。
  try {
    final programs = HaikuoCodec.parseText(trimmed);
    if (programs.isNotEmpty) return SharedJsonKind.haikuo;
  } on HaikuoFormatException {
    // 不是海阔形态。
  }
  return SharedJsonKind.unsupported;
}

/// 海阔导入：默认走 HaikuoStore.importBytes（与小程序页文件导入
/// 同一入口）。不传 onDuplicates 时仓库默认同名两边都留
/// （HaikuoDuplicateDecision.keepBoth），分享场景下不弹窗问。
typedef HaikuoSharedJsonImportFn =
    Future<HaikuoImportResult> Function(List<int> bytes, String origin);

/// 书源导入：默认走 NovelSourceStore.importJsonText（与阅读区
/// 文件导入同一套 JSON 分支：单条与批量同一规则）。
typedef LegadoSharedJsonImportFn =
    Future<({List<NovelImportRecord> records, int skipped})>
    Function(String text);

/// 配置导入：默认走 TvBoxImporter.importFromText（与导入中心
/// 文件导入同一入口）。
typedef TvBoxSharedJsonImportFn =
    Future<TvBoxImportReport> Function(
      String text,
      String sourceIdentity,
      String displayName,
    );

/// 分享 JSON 的分流执行器：两个原生队列的消费处（插件分享通道
/// 与外部导入监听）共用。返回给用户看的提示文案，各路文案与
/// 应用内导入一致；认不出时返回诚实提示，不抛错。
class SharedJsonImportHandler {
  SharedJsonImportHandler({
    AppRepository? repository,
    HaikuoSharedJsonImportFn? haikuoImport,
    LegadoSharedJsonImportFn? legadoImport,
    TvBoxSharedJsonImportFn? configImport,
    Future<void> Function()? onLegadoImported,
  }) : _haikuoImport =
           haikuoImport ??
           ((bytes, origin) => HaikuoStore().importBytes(bytes, origin: origin)),
       _legadoImport =
           legadoImport ?? ((text) => NovelSourceStore.importJsonText(text)),
       _configImport =
           configImport ??
           ((text, identity, displayName) {
             final repo = repository;
             if (repo == null) {
               throw StateError('配置导入需要 AppRepository');
             }
             return TvBoxImporter(repo).importFromText(
               text,
               sourceIdentity: identity,
               displayName: displayName,
             );
           }),
       _onLegadoImported =
           onLegadoImported ?? NovelSourceStore.applyToRegistry;

  final HaikuoSharedJsonImportFn _haikuoImport;
  final LegadoSharedJsonImportFn _legadoImport;
  final TvBoxSharedJsonImportFn _configImport;
  final Future<void> Function() _onLegadoImported;

  /// 分流并导入，返回提示文案。调用方保证 [bytes] 非空；
  /// 大小上限沿用各路现有的：配置走导入中心文件导入的
  /// TvBoxImporter.maxConfigFileBytes；海阔与书源本身没有
  /// 文件上限，原生通道的 32MB 上限（插件分享读流 /
  /// 外部导入 maxExternalPyBytes）在读字节时已经拦过。
  Future<String> handle(List<int> bytes, {required String fileName}) async {
    final text = HaikuoCodec.decodeText(bytes);
    switch (classifySharedJson(text)) {
      case SharedJsonKind.tvboxConfig:
        if (bytes.length > TvBoxImporter.maxConfigFileBytes) {
          return '文件过大，无法导入';
        }
        try {
          final report = await _configImport(
            text,
            'file:$fileName:${text.length}',
            '',
          );
          final empty =
              report.apiSites +
                  report.jarSites +
                  report.lives +
                  report.parses ==
              0;
          if (empty) return '未导入任何内容「${report.name}」';
          return '已导入「${report.name}」：${report.summary}';
        } catch (error) {
          return error.toString();
        }
      case SharedJsonKind.legado:
        try {
          final result = await _legadoImport(text);
          await _onLegadoImported();
          if (result.records.length == 1 && result.skipped == 0) {
            return '已导入 ${result.records.first.name}';
          }
          return '已导入 ${result.records.length} 条，跳过 ${result.skipped} 条';
        } on FormatException catch (error) {
          return '导入失败：${error.message}';
        } catch (_) {
          return '导入失败：文件读取或保存失败';
        }
      case SharedJsonKind.haikuo:
        try {
          final result = await _haikuoImport(bytes, '分享：$fileName');
          final notes = result.notes
              .where((note) => note.isNotEmpty)
              .toList();
          if (notes.isEmpty) return result.summary;
          final shown = notes.take(3).join('；');
          final rest = notes.length > 3 ? '，还有 ${notes.length - 3} 条' : '';
          return '${result.summary}；$shown$rest';
        } on HaikuoFormatException catch (error) {
          return error.message;
        } catch (error) {
          return '导入失败：$error';
        }
      case SharedJsonKind.unsupported:
        return '文件「$fileName」不是可识别的 JSON：不是小程序规则、书源或 TVBox 配置';
    }
  }
}
