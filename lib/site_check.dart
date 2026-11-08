import 'dart:async';

import 'models.dart';

enum SiteCheckStatus { ok, failed, skipped }

class SiteCheckResult {
  const SiteCheckResult({
    required this.siteId,
    required this.siteName,
    required this.status,
    this.reason = '',
    this.itemCount = 0,
    this.wasHidden = false,
    this.autoHidden = false,
  });

  final String siteId;
  final String siteName;
  final SiteCheckStatus status;
  final String reason;
  final int itemCount;
  final bool wasHidden;
  final bool autoHidden;

  bool get isOk => status == SiteCheckStatus.ok;
  bool get isFailed => status == SiteCheckStatus.failed;
  bool get isSkipped => status == SiteCheckStatus.skipped;

  SiteCheckResult copyWith({bool? autoHidden, String? reason}) =>
      SiteCheckResult(
        siteId: siteId,
        siteName: siteName,
        status: status,
        reason: reason ?? this.reason,
        itemCount: itemCount,
        wasHidden: wasHidden,
        autoHidden: autoHidden ?? this.autoHidden,
      );
}

class SiteCheckGroups {
  const SiteCheckGroups({
    required this.ok,
    required this.failed,
    required this.skipped,
  });

  final List<SiteCheckResult> ok;
  final List<SiteCheckResult> failed;
  final List<SiteCheckResult> skipped;

  int get total => ok.length + failed.length + skipped.length;
}

bool isJarSite(SourceSite site) => site.importType == 'jar';

bool isUnsupportedJarSite({
  required SourceSite site,
  required bool jarSupported,
}) => isJarSite(site) && !jarSupported;

String sanitizeCheckReason(Object? error) {
  if (error == null) return '';
  final firstLine = error.toString().split('\n').first.trim();
  final collapsed = firstLine.replaceAll(RegExp(r'\s+'), ' ');
  if (collapsed.length <= 100) return collapsed;
  return '${collapsed.substring(0, 100)}…';
}

SiteCheckResult classifySiteCheck({
  required SourceSite site,
  required int itemCount,
  Object? error,
  required bool wasHidden,
  required bool jarSupported,
}) {
  if (isUnsupportedJarSite(site: site, jarSupported: jarSupported)) {
    return SiteCheckResult(
      siteId: site.id,
      siteName: site.name,
      status: SiteCheckStatus.skipped,
      reason: '本平台不支持 jar 站',
      wasHidden: wasHidden,
    );
  }
  if (error is TimeoutException) {
    return SiteCheckResult(
      siteId: site.id,
      siteName: site.name,
      status: SiteCheckStatus.failed,
      reason: '检查超时（15 秒）',
      wasHidden: wasHidden,
    );
  }
  if (error != null) {
    return SiteCheckResult(
      siteId: site.id,
      siteName: site.name,
      status: SiteCheckStatus.failed,
      reason: sanitizeCheckReason(error),
      wasHidden: wasHidden,
    );
  }
  if (itemCount <= 0) {
    return SiteCheckResult(
      siteId: site.id,
      siteName: site.name,
      status: SiteCheckStatus.failed,
      reason: '首分类无内容',
      wasHidden: wasHidden,
    );
  }
  return SiteCheckResult(
    siteId: site.id,
    siteName: site.name,
    status: SiteCheckStatus.ok,
    itemCount: itemCount,
    wasHidden: wasHidden,
  );
}

SiteCheckGroups groupSiteCheckResults(List<SiteCheckResult> results) {
  final ok = <SiteCheckResult>[];
  final failed = <SiteCheckResult>[];
  final skipped = <SiteCheckResult>[];
  for (final result in results) {
    switch (result.status) {
      case SiteCheckStatus.ok:
        ok.add(result);
      case SiteCheckStatus.failed:
        failed.add(result);
      case SiteCheckStatus.skipped:
        skipped.add(result);
    }
  }
  return SiteCheckGroups(ok: ok, failed: failed, skipped: skipped);
}

List<SiteCheckResult> applySiteCheckAutoHide(List<SiteCheckResult> results) => [
  for (final result in results)
    result.copyWith(autoHidden: result.isFailed && !result.wasHidden),
];

String formatSiteCheckLastRun(DateTime? value) {
  if (value == null) return '尚未检查';
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '上次检查：${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
}

Future<List<SiteCheckResult>> runSiteChecks({
  required List<SourceSite> sites,
  required Set<String> hiddenIds,
  required bool jarSupported,
  required Future<int> Function(String siteId) probe,
  Duration perSiteTimeout = const Duration(seconds: 15),
  int batchSize = 4,
  bool Function()? isCancelled,
  void Function(int done, int total)? onProgress,
}) async {
  final results = <SiteCheckResult>[];
  final total = sites.length;
  for (var start = 0; start < sites.length; start += batchSize) {
    if (isCancelled?.call() ?? false) break;
    final batch = sites.skip(start).take(batchSize).toList();
    final probed = await Future.wait(
      batch.map((site) async {
        if (isUnsupportedJarSite(site: site, jarSupported: jarSupported)) {
          return classifySiteCheck(
            site: site,
            itemCount: 0,
            wasHidden: hiddenIds.contains(site.id),
            jarSupported: jarSupported,
          );
        }
        try {
          final count = await probe(site.id).timeout(perSiteTimeout);
          return classifySiteCheck(
            site: site,
            itemCount: count,
            wasHidden: hiddenIds.contains(site.id),
            jarSupported: jarSupported,
          );
        } catch (error) {
          return classifySiteCheck(
            site: site,
            itemCount: 0,
            error: error,
            wasHidden: hiddenIds.contains(site.id),
            jarSupported: jarSupported,
          );
        }
      }),
    );
    results.addAll(probed);
    onProgress?.call(results.length, total);
  }
  return results;
}
