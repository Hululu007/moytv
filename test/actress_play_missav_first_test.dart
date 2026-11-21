import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_play.dart';
import 'package:moyi/crosssite_probe.dart';
import 'package:moyi/feed_playability.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// MissAV 提前探（2026-11-21，修 UMSO-660 点播不到）：点播链在
/// 兜底波（MJV 系 + 18AV）之后、eager 波之前单独探一波 MissAV
/// 主站（[actressMissavFirstSiteId]）。兜底站没有的番号（如
/// PRESTIGE 的 UMSO-660）只有 MissAV 有；eager 波 24 站会吃光
/// 45 秒总预算，不提前就永远探不到。
///
/// 只测链逻辑（假探活服务 + 合成取流），不测真网络；旧断言在
/// actress_play_fallback_test.dart 里，一字未动。

const _missavSite = SourceSite(
  'jar:missav30:ZakaMissav',
  '🔞MissAV',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _missavOffSite = SourceSite(
  'jar:missav30:ZakaMissavOff',
  '🔞MissAVOff',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _mjvJarSite = SourceSite(
  'jar:zakatv:ZakaMjv011',
  '🔞mjv011',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _chaoliuSite = SourceSite(
  'chaoliu',
  '🔞潮流',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _mjvGoSite = SourceSite(
  'v_mjv011',
  '🔞mjv011',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _av18mcgSite = SourceSite(
  'jar:zakatv:av18avmcg',
  '🔞18AV',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _av18Site = SourceSite(
  'jar:zakatv:av18av',
  '🔞18AV',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _other1Site = SourceSite(
  'test-site-other-1',
  '🔞其他站1',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _other2Site = SourceSite(
  'test-site-other-2',
  '🔞其他站2',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);

const _allMissavFirstTestSites = [
  _missavSite,
  _missavOffSite,
  _mjvJarSite,
  _chaoliuSite,
  _mjvGoSite,
  _av18mcgSite,
  _av18Site,
  _other1Site,
  _other2Site,
];

void _registerMissavFirstTestSites() {
  for (final site in _allMissavFirstTestSites) {
    SourceSite.importedSites[site.id] = site;
  }
}

void _unregisterMissavFirstTestSites() {
  for (final site in _allMissavFirstTestSites) {
    SourceSite.importedSites.remove(site.id);
  }
}

/// 验活假探针：永远可播（合成地址在测试里没有真服务，默认探针会
/// 判死；链测试只测链逻辑，不测真网络）。
Future<FeedProbeResponse> _alwaysPlayable(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async => const FeedProbeResponse(
  statusCode: 200,
  headers: {'content-type': 'video/mp4'},
  headBytes: [1],
);

DramaDetail _missavDetailFor(String dramaId, String source, String title) =>
    DramaDetail(Drama(id: dramaId, source: source, title: title), [
      Episode({'id': '1', 'title': 'Full', 'flag': '线路1'}, 1),
    ]);

CrossSiteProbeResult _missavFoundResult(
  CrossSiteProvider provider,
  String siteId,
  String dramaId,
  String title,
) => CrossSiteProbeResult(
  provider: provider,
  siteId: siteId,
  status: CrossSiteProbeStatus.found,
  versions: [
    CrossSiteVersion(
      label: dramaId,
      detail: _missavDetailFor(dramaId, siteId, title),
      lines: const [CrossSiteLine(label: '线路1', episodeIndex: 0)],
    ),
  ],
);

class _RecordingProbeService extends CrossSiteProbeService {
  _RecordingProbeService({required super.repository, required this.results});

  final Map<String, CrossSiteProbeResult> results;
  final probed = <String>[];

  @override
  Future<CrossSiteProbeResult> probeProvider(
    CrossSiteProvider provider,
    String siteId,
    String avId,
  ) async {
    probed.add(siteId);
    return results[siteId] ??
        CrossSiteProbeResult(
          provider: provider,
          siteId: siteId,
          status: CrossSiteProbeStatus.empty,
        );
  }
}

void main() {
  group('MissAV 提前探', () {
    late FixtureRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerMissavFirstTestSites();
      addTearDown(_unregisterMissavFirstTestSites);
      repository = FixtureRepository();
      SharedPreferences.setMockInitialValues({});
      store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
    });

    ActressPlayChain chainWith(
      _RecordingProbeService probe, {
      List<SourceSite>? sites,
    }) => ActressPlayChain(
      repository: repository,
      store: store,
      avId: 'UMSO-660',
      candidateSites:
          sites ??
          const [
            // 故意打乱输入顺序：探查顺序由链定，不由输入顺序定。
            _other2Site,
            _missavOffSite,
            _av18Site,
            _missavSite,
            _mjvGoSite,
            _other1Site,
            _chaoliuSite,
            _av18mcgSite,
            _mjvJarSite,
          ],
      probeService: probe,
      probeConcurrency: 1,
      verifyFetch: _alwaysPlayable,
    );

    test('MissAV 在兜底波之后、eager 波之前，不在懒查波', () async {
      final probe = _RecordingProbeService(
        repository: repository,
        results: const {},
      );
      final chain = chainWith(probe);
      expect(
        await chain.nextPlayable(profileEpoch: store.profileEpoch),
        isNull,
      );
      // 兜底 5 站 → MissAV 主站 → eager 两站 → 懒查 MissAVOff。
      // 若 MissAV 还在懒查波，它会排在两 eager 站之后、MissAVOff 之前。
      // eager 两站之间按输入顺序（other-2 在 other-1 之前传入）。
      expect(probe.probed, [
        'jar:zakatv:ZakaMjv011',
        'chaoliu',
        'v_mjv011',
        'jar:zakatv:av18avmcg',
        'jar:zakatv:av18av',
        'jar:missav30:ZakaMissav',
        'test-site-other-2',
        'test-site-other-1',
        'jar:missav30:ZakaMissavOff',
      ]);
      expect(chain.hasMore, isFalse);
    });

    test('兜底波无果时 MissAV 命中成链，不再探 eager 波', () async {
      final probe = _RecordingProbeService(
        repository: repository,
        results: {
          'jar:missav30:ZakaMissav': _missavFoundResult(
            const CrossSiteProvider(
              id: 'jar:missav30:ZakaMissav',
              name: '🔞MissAV',
              siteIds: ['jar:missav30:ZakaMissav'],
              lazy: true,
            ),
            'jar:missav30:ZakaMissav',
            'missav-umso-660',
            'UMSO-660 MissAV 标题',
          ),
        },
      );
      final chain = chainWith(probe);
      final candidate = await chain.nextPlayable(
        profileEpoch: store.profileEpoch,
      );
      expect(candidate, isNotNull);
      expect(candidate!.detail.drama.source, 'jar:missav30:ZakaMissav');
      expect(candidate.detail.drama.id, 'missav-umso-660');
      expect(probe.probed, [
        'jar:zakatv:ZakaMjv011',
        'chaoliu',
        'v_mjv011',
        'jar:zakatv:av18avmcg',
        'jar:zakatv:av18av',
        'jar:missav30:ZakaMissav',
      ]);
    });

    test('兜底波命中时不探 MissAV，常见情况不被拖慢', () async {
      final probe = _RecordingProbeService(
        repository: repository,
        results: {
          'jar:zakatv:ZakaMjv011': _missavFoundResult(
            const CrossSiteProvider(
              id: 'jar:zakatv:ZakaMjv011',
              name: '🔞mjv011',
              siteIds: ['jar:zakatv:ZakaMjv011'],
              lazy: false,
            ),
            'jar:zakatv:ZakaMjv011',
            'mjv-drama',
            'UMSO-660 MJV 标题',
          ),
        },
      );
      final chain = chainWith(probe);
      final candidate = await chain.nextPlayable(
        profileEpoch: store.profileEpoch,
      );
      expect(candidate, isNotNull);
      expect(candidate!.detail.drama.source, 'jar:zakatv:ZakaMjv011');
      expect(probe.probed, ['jar:zakatv:ZakaMjv011']);
    });

    test('resetForRetry 后重探 MissAV 波，不丢这一波', () async {
      final probe = _RecordingProbeService(
        repository: repository,
        results: {
          'jar:missav30:ZakaMissav': _missavFoundResult(
            const CrossSiteProvider(
              id: 'jar:missav30:ZakaMissav',
              name: '🔞MissAV',
              siteIds: ['jar:missav30:ZakaMissav'],
              lazy: true,
            ),
            'jar:missav30:ZakaMissav',
            'missav-umso-660',
            'UMSO-660 MissAV 标题',
          ),
        },
      );
      final chain = chainWith(probe);
      final first = await chain.nextPlayable(profileEpoch: store.profileEpoch);
      expect(first, isNotNull);
      expect(first!.detail.drama.id, 'missav-umso-660');
      chain.resetForRetry();
      expect(chain.triedSources, isEmpty);
      final second = await chain.nextPlayable(
        profileEpoch: store.profileEpoch,
      );
      expect(second, isNotNull);
      expect(second!.detail.drama.id, 'missav-umso-660');
      expect(probe.probed, [
        'jar:zakatv:ZakaMjv011',
        'chaoliu',
        'v_mjv011',
        'jar:zakatv:av18avmcg',
        'jar:zakatv:av18av',
        'jar:missav30:ZakaMissav',
        'jar:zakatv:ZakaMjv011',
        'chaoliu',
        'v_mjv011',
        'jar:zakatv:av18avmcg',
        'jar:zakatv:av18av',
        'jar:missav30:ZakaMissav',
      ]);
    });
  });
}
