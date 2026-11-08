import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/site_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _plain = SourceSite('plain', '普通站', '');
const _jar = SourceSite(
  'jar:cfg:key',
  'Jar 站',
  '',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
  importType: 'jar',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('non-empty first page is ok', () {
    final result = classifySiteCheck(
      site: _plain,
      itemCount: 3,
      wasHidden: false,
      jarSupported: true,
    );
    expect(result.isOk, isTrue);
    expect(result.itemCount, 3);
  });

  test('empty first page is failed with a plain reason', () {
    final result = classifySiteCheck(
      site: _plain,
      itemCount: 0,
      wasHidden: false,
      jarSupported: true,
    );
    expect(result.isFailed, isTrue);
    expect(result.reason, '首分类无内容');
  });

  test('error reason is truncated to one line without a stack', () {
    final result = classifySiteCheck(
      site: _plain,
      itemCount: 0,
      error: Exception('first line\nsecond line\n${'x' * 200}'),
      wasHidden: false,
      jarSupported: true,
    );
    expect(result.isFailed, isTrue);
    expect(result.reason, isNot(contains('\n')));
    expect(result.reason.length, lessThanOrEqualTo(101));
  });

  test('jar site is skipped only when jar is unsupported', () {
    final skipped = classifySiteCheck(
      site: _jar,
      itemCount: 0,
      wasHidden: false,
      jarSupported: false,
    );
    expect(skipped.isSkipped, isTrue);
    expect(skipped.reason, '本平台不支持 jar 站');
    final probed = classifySiteCheck(
      site: _jar,
      itemCount: 2,
      wasHidden: false,
      jarSupported: true,
    );
    expect(probed.isOk, isTrue);
  });

  test('auto-hide marks only newly failed visible sites', () {
    final results = applySiteCheckAutoHide([
      classifySiteCheck(
        site: _plain,
        itemCount: 0,
        wasHidden: false,
        jarSupported: true,
      ),
      classifySiteCheck(
        site: const SourceSite('hidden', '已隐藏站', ''),
        itemCount: 0,
        wasHidden: true,
        jarSupported: true,
      ),
      classifySiteCheck(
        site: _jar,
        itemCount: 0,
        wasHidden: false,
        jarSupported: false,
      ),
      classifySiteCheck(
        site: const SourceSite('ok', '正常站', ''),
        itemCount: 1,
        wasHidden: false,
        jarSupported: true,
      ),
    ]);
    expect(results.map((result) => result.autoHidden), [
      true,
      false,
      false,
      false,
    ]);
    final groups = groupSiteCheckResults(results);
    expect(groups.ok.length, 1);
    expect(groups.failed.length, 2);
    expect(groups.skipped.length, 1);
  });

  test('last-run formatting handles never-checked', () {
    expect(formatSiteCheckLastRun(null), '尚未检查');
    expect(
      formatSiteCheckLastRun(DateTime(2026, 11, 1, 9, 5)),
      contains('11/1 09:05'),
    );
  });

  test('runner times out a hanging site and keeps the rest', () async {
    final results = await runSiteChecks(
      sites: [_plain, const SourceSite('slow', '慢站', '')],
      hiddenIds: {},
      jarSupported: true,
      probe: (siteId) async {
        if (siteId == 'slow') {
          await Future<void>.delayed(const Duration(seconds: 5));
          return 9;
        }
        return 4;
      },
      perSiteTimeout: const Duration(milliseconds: 50),
    );
    expect(results[0].isOk, isTrue);
    expect(results[1].isFailed, isTrue);
    expect(results[1].reason, '检查超时（15 秒）');
  });

  test('runner stops before new probes once cancelled', () async {
    var calls = 0;
    final results = await runSiteChecks(
      sites: [_plain, const SourceSite('other', '另一站', '')],
      hiddenIds: {},
      jarSupported: true,
      probe: (siteId) async {
        calls++;
        return 1;
      },
      isCancelled: () => true,
    );
    expect(calls, 0);
    expect(results, isEmpty);
  });

  test('runner skips jar probes on unsupported platforms', () async {
    var calls = 0;
    final results = await runSiteChecks(
      sites: [_jar],
      hiddenIds: {},
      jarSupported: false,
      probe: (siteId) async {
        calls++;
        return 1;
      },
    );
    expect(calls, 0);
    expect(results.single.isSkipped, isTrue);
  });

  test('last run round-trips through the store snapshot', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    expect(store.siteCheckLastRun, isNull);
    final stamp = DateTime(2026, 11, 1, 23, 0);
    await store.setSiteCheckLastRun(stamp);
    expect(store.siteCheckLastRun, stamp);
    store.dispose();
  });
}
