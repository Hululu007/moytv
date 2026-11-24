import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../core_bridge.dart';
import '../crosssite_probe.dart';
import '../models.dart';
import 'actress_database.dart';
import 'actress_generic_crawl.dart';
import 'actress_film_library.dart';
import 'actress_json_fallback.dart';
import 'actress_models.dart';
import 'actress_mytv_bind.dart';

/// MJV 视频分类（与潮流蜘蛛 chaoliu.py 的 MJV_CATS 同表，只取视频类；
/// 18H 漫画/同人/写真/小说四类不是视频，不爬）。
const actressMjvVideoCategories = <({String id, String name})>[
  (id: 'chinese', name: '中文字幕'),
  (id: 'censored', name: '有码'),
  (id: 'uncensored', name: '无码'),
  (id: 'amateurjav', name: '素人'),
  (id: 'reducing-mosaic', name: '无码破解'),
  (id: 'animation', name: 'H动画'),
  (id: 'CensoredAnimation', name: 'H有码动画'),
  (id: 'UncensoredAnimation', name: 'H无码动画'),
  (id: 'tdAnimation', name: 'H_3D动画'),
  (id: 'dt', name: '国产自拍'),
];

/// whos 列表页一张卡：番号代码、标题、解出的封面与 hash、拼出的直链。
typedef WhosListCard = ({
  String code,
  String title,
  String pic,
  String hash,
  String m3u8,
});

/// whos 列表页取数：输入页码，返回 validator.nu 吐回的列表页原始 HTML，
/// 取不到返回 ''。默认走 validator.nu 通道；测试注入假取数，不走网。
typedef WhosListFetcher = Future<String> Function(int page);

/// whos 条目 vod_id：与外面 Python 爬虫同一口径——md5 前 8 位十六进制，
/// md5 输入是 'https://whos.tv/videos/' + 番号代码。
String whosVodId(String code) =>
    md5
        .convert(utf8.encode('https://whos.tv/videos/$code'))
        .toString()
        .substring(0, 8);

/// whos 封面密文解码（纯函数）：16 进制解码成字节，末字节就是 XOR
/// 密钥，其余字节逐字节 XOR 该密钥，得到封面地址
/// https://v.hersav.me/images/av/ 下的 32 位 hash 封面图（.jpg）。
/// 解不出合法封面地址返回 null（该卡跳过，不编假地址）。
({String pic, String hash})? decodeWhosCover(String cipherHex) {
  if (cipherHex.length < 4 || cipherHex.length.isOdd) return null;
  if (!RegExp(r'^[0-9a-f]+$').hasMatch(cipherHex)) return null;
  final bytes = <int>[];
  for (var i = 0; i < cipherHex.length; i += 2) {
    bytes.add(int.parse(cipherHex.substring(i, i + 2), radix: 16));
  }
  final key = bytes.last;
  final plain = String.fromCharCodes(
    bytes.sublist(0, bytes.length - 1).map((b) => b ^ key),
  );
  final match = RegExp(r'/images/av/([0-9a-f]{32})\.jpg').firstMatch(plain);
  if (match == null) return null;
  return (pic: plain, hash: match.group(1)!);
}

/// whos 播放地址：hash 直接拼，不用取详情。
String whosM3u8Url(String hash) =>
    'https://v.hersav.me/$hash/$hash.m3u8';

/// whos 列表页卡片解析（纯函数，与 whos2.py 的 CARD_RE 同义）：
/// href="/videos/番号代码" 后跟 data-cover-src 密文与 alt 标题；
/// 密文解不出合法 hash 的卡跳过。
List<WhosListCard> parseWhosListCards(String html) {
  final pattern = RegExp(
    r'href="/videos/([a-z0-9-]+)"[^>]*>.*?data-cover-src="([0-9a-f]+)"[^>]*alt="([^"]*)"',
    dotAll: true,
  );
  final cards = <WhosListCard>[];
  for (final match in pattern.allMatches(html)) {
    final code = match.group(1)!;
    final decoded = decodeWhosCover(match.group(2)!);
    if (decoded == null) continue;
    cards.add((
      code: code,
      title: (match.group(3) ?? '').trim(),
      pic: decoded.pic,
      hash: decoded.hash,
      m3u8: whosM3u8Url(decoded.hash),
    ));
  }
  return cards;
}

/// whos 列表页实取：validator.nu 通道（W3C 校验服务代取，CF 挡不住它）。
/// GET https://validator.nu/?doc=目标页地址（已 URL 编码）&showsource=yes&out=json，
/// 取回 JSON 里 source.code 就是列表页原始 HTML。90 秒超时，失败
/// 重试 3 次（退避 2/5 秒），502 也重试；3 次都失败返回 ''。
Future<String> fetchWhosListPageViaValidator(int page) async {
  final target = page <= 1
      ? 'https://whos.tv/videos'
      : 'https://whos.tv/videos/page-$page';
  return fetchWhosPage(target);
}

/// whos 单页取数（2026-11-21 用户令“现爬也要过盾”）：whos.tv 直连被
/// Cloudflare 挑战挡住，这里按多通道依次试，任一取回带卡片的真页面即
/// 返回：
/// 1. validator.nu（W3C 校验器代取，第一页稳）；
/// 2. validator.w3.org（同服务另一入口，nu 504 时兜一把）；
/// 3. 直连 whos.tv（手机 UA；CF 偶尔放行，能过就直接用）。
/// 每通道两次（退避 2/5 秒），全部失败返回 ''（现爬停在上一个好页，
/// 下轮续跑，不死循环翻页）。
Future<String> fetchWhosPage(String target) async {
  const userAgents = [
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 '
        'Mobile/15E148 Safari/604.1',
    'Mozilla/5.0 (Linux; Android 14; PGT-AN10) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
  ];
  final encoded = Uri.encodeComponent(target);
  final channels = <({String url, bool json})>[
    (
      url: 'https://validator.nu/?doc=$encoded&showsource=yes&out=json',
      json: true,
    ),
    (
      url:
          'https://validator.w3.org/nu/?doc=$encoded&showsource=yes&out=json',
      json: true,
    ),
    (url: target, json: false),
  ];
  const timeout = Duration(seconds: 45);
  const backoffs = [Duration(seconds: 2), Duration(seconds: 5)];
  for (final channel in channels) {
    for (var attempt = 0; attempt < 2; attempt++) {
      final client = HttpClient()..connectionTimeout = timeout;
      try {
        final request = await client
            .getUrl(Uri.parse(channel.url))
            .timeout(timeout);
        request.headers.set(
          HttpHeaders.userAgentHeader,
          userAgents[attempt % userAgents.length],
        );
        request.headers.set(
          HttpHeaders.acceptHeader,
          channel.json ? 'application/json' : 'text/html',
        );
        final response = await request.close().timeout(
          const Duration(seconds: 60),
        );
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 60));
        if (response.statusCode == 200) {
          var html = body;
          if (channel.json) {
            final doc = jsonDecode(body);
            if (doc is Map<String, dynamic>) {
              final source = doc['source'];
              html = source is Map<String, dynamic>
                  ? (source['code'] as String? ?? '')
                  : '';
            } else {
              html = '';
            }
          }
          // 认真页面：至少带卡片标记，且不是 CF 挑战页。
          if (html.length > 10000 &&
              html.contains('data-cover-src') &&
              !html.contains('Just a moment')) {
            return html;
          }
        }
      } catch (_) {
        // 这条通道这次没成：重试或换下一条通道。
      } finally {
        client.close(force: true);
      }
      if (attempt < backoffs.length - 1) {
        await Future.delayed(backoffs[attempt]);
      }
    }
  }
  return '';
}

/// 手机现爬进度（列表页横幅显示、可取消）。
class ActressSiteCrawlProgress {
  const ActressSiteCrawlProgress({
    this.running = false,
    this.site = 'mjv',
    this.categoryIndex = 0,
    this.categoryCount = 0,
    this.categoryName = '',
    this.page = 0,
    this.items = 0,
    this.enriched = 0,
    this.enrichTried = 0,
    this.done = false,
    this.error = '',
  });

  final bool running;
  final String site;
  final int categoryIndex;
  final int categoryCount;
  final String categoryName;
  final int page;
  final int items;

  /// 已补上直链/女优名的条数。
  final int enriched;

  /// 已尝试补流的条数（含失败的尝试）：补流期间每起一条就加一，
  /// 面板在“详情 + 取流各 ≤70 秒”的慢单元里也能看到数字在走，
  /// 不只在补成功时才跳（2026-11-24 同步卡顿修复）。
  final int enrichTried;
  final bool done;
  final String error;

  String get label {
    if (error.isNotEmpty) return error;
    if (done) return '现爬完成：$items 条，已补流 $enriched 条';
    if (!running) return '未开始';
    final enrich = enrichTried > 0 || enriched > 0
        ? ' · 补流中 $enrichTried 条 · 已补上 $enriched 条'
        : '';
    return '现爬 $categoryName（$categoryIndex/$categoryCount）第 $page 页 · $items 条$enrich';
  }
}

/// 取消中断：在途取数不等它超时、立刻停等（见 [_raceCancel]，
/// 与 ActressSyncService 的 _SyncCancelled 同一口径）。
class _CrawlCancelled implements Exception {
  const _CrawlCancelled();

  @override
  String toString() => '现爬已取消';
}

/// 女优库手机现爬：选站后按分类逐页爬，存 hsck 同格式 JSON 到本地。
///
/// - mjv：走潮流蜘蛛（chaoliu.py，MJV 全站蜘蛛）分类目录，
///   repository.catalog('chaoliu', category, page) 现取；
/// - whos：没有分类蜘蛛，影片库是一条平铺列表（341,844 部、28,487 页、
///   每页 12 条），当成一个分类“全部”来爬。列表页是服务端渲染 HTML，
///   直连被 CF 挡，走 validator.nu 通道代取（GET validator.nu/?doc=目标页
///   地址（已 URL 编码）&showsource=yes&out=json，取 JSON 里 source.code）；
///   卡片 data-cover-src 是 16 进制密文，末字节即 XOR 密钥，解出封面
///   https://v.hersav.me/images/av/ 下的 32 位 hash 封面图，直链直接拼
///   https://v.hersav.me/ 下 hash 直拼的 m3u8，不取详情、不走补流；
///   一页取不到卡或取回为空即停；
/// - 片库站：走本站蜘蛛自己的分类（repository.categories(站 id)
///   现取，空 id 的“全部”伪分类跳过；取回为空回落到单个“全部”）
///   与本站蜘蛛的 catalog 现取；条目 site 记本站 id，取流走本站
///   蜘蛛；文件夹分类直接按 drillId 取目录，空页即停，不另下钻；
/// - 有界：每分类默认取前 50 页（每页 24 条），补流每分类做前 50
///   条（详情 + 取流各一次）；全站条目不设死上限（2026-11-20
///   用户令：内置 json 的本地存储随爬取增长，库的容量与文件体积
///   不设条数与体积死上限）；MJV 全站约 51 万条目，手机上全量现爬
///   不现实，不承诺全量；
/// - 存储（2026-11-20 用户令：所有数据全部进内置的 mjv011.json
///   这一个文件，json 是唯一落地口径）：App 资源包里的 assets 文件
///   只读，手机侧写入口是同名同格式的本地影子文件
///   documents/actress_json/mjv011.json（普通文件，不是
///   SharedPreferences 单键，不重蹈 m3u 单键超 16MB 的覆辙）；
///   任何站爬到的视频行都只追加进这一个文件，不分站另存；
///   单文件里的行按 vod_play_from 认站（mjv011 → mjv，其余来源名
///   即站 id）；新行先合并进内存表，攒够阈值、分类结束或整轮结束
///   时才批量落盘（2026-11-24 同步卡顿修复：旧写法每页全量重写
///   几十 MB 的单文件，O(n²) 越跑越慢）；一轮内合并表常驻内存
///   （只读一次文件）；写盘后同一批条目同步进库（人表
///   + 作品表，json-first，库是 json 的派生索引），列表进行中就
///   能陆续出人；读时兜底加载器把本地新增合并着算；
///   合并后的全文可导出（列表页的导出合并 JSON，走 MYTV/mjv011.json
///   或系统保存对话框），用户拷走即用；
/// - 断点续跑：检查点存在 sync_state（source=site_crawl，phase=站，
///   cursor=分类下标/页码），落盘后才往前存点，失败停在当前页；
/// - 批量落盘（同格式，indent=2、顶层四键、13 字段 +
///   vod_code/vod_actress_pic），不用等全站爬完；写完即进兜底。
class ActressSiteCrawlService {
  ActressSiteCrawlService({
    required this.repository,
    required this.db,
    this._documentsDir,
    Directory? localJsonDir,
    WhosListFetcher? whosListFetcher,
  }) : _localJsonDir = localJsonDir,
       _whosListFetcher =
           whosListFetcher ?? fetchWhosListPageViaValidator;

  /// 2026-11-20 MYTV 绑定：绑定解析出来后调，本地 json 影子
  /// 目录改走 MYTV/db。只在列表页自己建的实例上调，测试注入
  /// 的实例不动。目录换了就清掉内存里的合并表，下次按新目录
  /// 重读（别把旧目录的表写进新目录）。
  void bindLocalDir(Directory dir) {
    if (dir.path == _localJsonDir?.path) return;
    _localJsonDir = dir;
    _localByKey = null;
    _localSite = null;
  }

  /// 每分类默认页数（2026-11-20 用户令：最少 50 页）。
  static const defaultMaxPagesPerCategory = 50;

  /// 每分类补流条数（详情 + 取流，补上女优名/番号/直链；与页数
  /// 同比例放宽：旧 5 条/3 页约 1.7 条/页，取 1 条/页即 50 条/
  /// 分类、全站 500 次详情+取流；严格按比例是 83 条/分类太重）。
  static const defaultEnrichPerCategory = 50;

  /// 分类工人数（2026-11-20 用户令：爬取必须多进程/多并发）：
  /// 10 个 mjv 分类由 3 个工人并行爬，分类之间不互相等；
  /// 每分类内的页仍顺序取（空页即停，靠短页启发）；补流在各
  /// 分类内顺序做。进库镜像串在一条队列上（多工人并发写库时
  /// 不抢），取页与写盘不串。
  static const defaultCategoryConcurrency = 3;

  /// 断点存在 sync_state：source 借潮流名册源（现爬走潮流蜘蛛），
  /// phase 用 site_crawl_站名，与名册 roster/films/ranking 各记各的。
  static const _checkpointSource = ActressRosterSourceId.chaoliu;
  static String _checkpointPhase(String site) => 'site_crawl_$site';

  /// 一轮默认总预算（2026-11-24 同步卡顿修复）：现爬一轮最多
  /// 60 分钟，到时停下、断点记未完成，下次继续跑；start() 可传
  /// timeBudget 覆盖（同步服务传作品阶段同一预算）。
  static const defaultTimeBudget = Duration(minutes: 60);

  /// 全量重写一次单文件的条数阈值（2026-11-24 同步卡顿修复）：
  /// 一页只有 12–24 条时每页都重写几十 MB 的单文件是 O(n²) 越跑
  /// 越慢；改成攒够阈值、分类结束或整轮结束时才落盘一批。
  static const flushThresholdEntries = 500;

  /// 测试用计数：实际写盘次数（_appendEntries/_flushEntries 落盘
  /// 才加一）。验收“别每页全量重写”就看它：页数远大于写盘次数。
  static var flushWriteCount = 0;

  /// 每分类的断点（分类工人并行时，单游标记不住各分类进度，
  /// 每分类各记各的页码；整轮完成只看总检查点）。
  static String _categoryCheckpointPhase(String site, int categoryIndex) =>
      'site_crawl_${site}_cat$categoryIndex';

  final AppRepository repository;
  final ActressDatabase db;
  final Directory? _documentsDir;

  /// 2026-11-20 MYTV 绑定：绑定后的本地 json 目录覆盖
  /// （MYTV/db）；不设时走原来的 documents/actress_json。
  Directory? _localJsonDir;

  /// whos 列表页取数（默认 validator.nu 通道；测试注入假取数）。
  final WhosListFetcher _whosListFetcher;

  final _progressController =
      StreamController<ActressSiteCrawlProgress>.broadcast();

  Stream<ActressSiteCrawlProgress> get progress =>
      _progressController.stream;

  var _running = false;
  var _cancelled = false;
  var _current = const ActressSiteCrawlProgress();

  /// 本轮是否因总预算到时停下（不是用户取消）。
  var _budgetExpired = false;

  bool get budgetExpired => _budgetExpired;

  /// 本轮总预算的截止点（start/startGenericSite 开始时定）。
  DateTime? _deadline;

  bool get _overBudget =>
      _deadline != null && DateTime.now().isAfter(_deadline!);

  /// 一次 start() 内有效的取消信号：cancel() 完成它，[_raceCancel]
  /// 听到就立刻停等。每次开始时重建，跑完不复用。
  Completer<void>? _cancelSignal;

  bool get running => _running;

  ActressSiteCrawlProgress get current => _current;

  void _emit(ActressSiteCrawlProgress progress) {
    _current = progress;
    if (!_progressController.isClosed) _progressController.add(progress);
  }

  void cancel() {
    _cancelled = true;
    final signal = _cancelSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  /// 等一个取数 future，但取消时不等它超时、立刻抛 [_CrawlCancelled]。
  /// 底层的取数本身停不下来（Dart future 不可撤）：竞跑输了的那
  /// 一方结果被丢弃——取数晚回来时它的完成/错误回调都已挂上，
  /// 不会变成未处理异常；写盘/写库在 await 之后，抛错即跳过。
  Future<T> _raceCancel<T>(Future<T> future) {
    if (_cancelled) throw const _CrawlCancelled();
    final signal = _cancelSignal;
    if (signal == null) return future;
    final completer = Completer<T>();
    var settled = false;
    future.then(
      (value) {
        if (!settled) {
          settled = true;
          completer.complete(value);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!settled) {
          settled = true;
          completer.completeError(error, stack);
        }
      },
    );
    unawaited(
      signal.future.then((_) {
        if (!settled) {
          settled = true;
          completer.completeError(const _CrawlCancelled());
        }
      }),
    );
    return completer.future;
  }

  /// 开始一轮现爬：重置取消信号、预算截止点与预算到时标志。
  void _beginRun(Duration timeBudget) {
    _cancelSignal = Completer<void>();
    _deadline = DateTime.now().add(timeBudget);
    _budgetExpired = false;
  }

  void dispose() {
    _progressController.close();
  }

  /// 开始现爬：whos 走 validator.nu 列表通道（见类注释），其余站走蜘蛛。
  /// 分类由 [categoryConcurrency] 个工人并行爬（默认 3 个）。
  Future<void> start({
    String site = 'mjv',
    int maxPagesPerCategory = defaultMaxPagesPerCategory,
    int enrichPerCategory = defaultEnrichPerCategory,
    int categoryConcurrency = defaultCategoryConcurrency,
    Duration timeBudget = defaultTimeBudget,
  }) async {
    if (_running) return;
    if (site == 'whos') {
      _running = true;
      _cancelled = false;
      _beginRun(timeBudget);
      try {
        await _runWhos(maxPagesPerCategory);
      } on _CrawlCancelled {
        _emit(
          ActressSiteCrawlProgress(
            site: site,
            error: '已取消',
          ),
        );
      } catch (error) {
        _emit(
          ActressSiteCrawlProgress(
            site: site,
            error: '现爬失败：$error',
          ),
        );
      } finally {
        // 收尾落盘：本轮攒着没写盘的条目一次写进去，别丢；
        // 写盘失败也不掀翻收尾（下次断点续跑重爬，合并键去重）。
        try {
          await _flushEntries(site);
        } catch (_) {
          // 落盘失败：json 里缺这批，断点仍按未完成记，下次续跑。
        }
        _localByKey = null;
        _localSite = null;
        _running = false;
      }
      return;
    }
    _running = true;
    _cancelled = false;
    _beginRun(timeBudget);
    // 蜘蛛 id：mjv 走潮流蜘蛛，其余站走本站蜘蛛。
    final spiderId = site == 'mjv' ? 'chaoliu' : site;
    final playFrom = site == 'mjv' ? 'mjv011' : spiderId;
    // 分类：mjv 用硬编码表；其余站取本站自己的分类（空 id 的“全部”
    // 伪分类跳过；取回为空或取分类失败，回落到单个“全部”）。
    final List<({String id, String name})> categories;
    if (site == 'mjv') {
      categories = actressMjvVideoCategories;
    } else {
      final usable = <({String id, String name})>[];
      try {
        for (final c in await repository.categories(site)) {
          if (c.drillId.isNotEmpty) {
            usable.add((id: c.drillId, name: c.name));
          }
        }
      } catch (_) {
        // 取分类失败：回落到“全部”单分类，不让一次取分类失败
        // 卡住整轮现爬。
      }
      categories = usable.isEmpty
          ? const [(id: '', name: '全部')]
          : usable;
    }
    // 一轮内合并表常驻内存：只读一次本地单文件，写盘按批量落盘；
    // 取消/跑完后丢弃，下轮重读（文件是唯一真相）。
    _localByKey = await _loadLocalEntries(site);
    _localSite = site;
    var items = 0;
    var enriched = 0;
    var enrichTried = 0;
    try {
      // 断点：总检查点已完成（或没有）时整轮从头爬（多轮追加靠
      // 这个语义：第二轮重爬全部分类，新番号追加、旧行按更新规则
      // 合并）；总检查点未完成时，每分类各按自己的分类检查点续跑
      // （已完成的分类跳过，未完成的从断页续爬）。
      final saved = await db.checkpoint(
        _checkpointSource,
        _checkpointPhase(site),
      );
      final resume = saved != null && !saved.finished;
      final startPages = <int>[];
      for (var ci = 0; ci < categories.length; ci++) {
        var fromPage = 1;
        if (resume) {
          final cat = await db.checkpoint(
            _checkpointSource,
            _categoryCheckpointPhase(site, ci),
          );
          if (cat != null && cat.finished) {
            fromPage = -1;
          } else if (cat != null && cat.cursor.isNotEmpty) {
            fromPage = int.tryParse(cat.cursor) ?? 1;
            if (fromPage < 1) fromPage = 1;
          }
          if (cat != null) items += cat.total;
        }
        startPages.add(fromPage);
      }
      var nextCat = 0;
      var doneCats = 0;

      Future<void> categoryWorker() async {
        while (!_cancelled && !_budgetExpired) {
          final ci = nextCat;
          if (ci >= categories.length) return;
          nextCat++;
          final fromPage = startPages[ci];
          if (fromPage < 0) {
            doneCats++;
            continue;
          }
          final category = categories[ci];
          var enrichLeft = enrichPerCategory;
          var categoryDone = false;
          var catItems = 0;
          var pagesDone = fromPage - 1;
          // 本分类中途抛错（目录/补流取数失败）：先记下，走完分类收尾
          // （落盘+断点）再往上抛（start() 转“现爬失败”）；批量落盘后
          // 抛错直接跳过收尾会丢已取数据与断点。
          Object? categoryError;
          for (var page = fromPage; page <= maxPagesPerCategory; page++) {
            if (_cancelled || _budgetExpired) break;
            // 总预算到时：本页不取了，分类收尾落盘后停，断点记未完成。
            if (_overBudget) {
              _budgetExpired = true;
              break;
            }
            _emit(
              ActressSiteCrawlProgress(
                running: true,
                site: site,
                categoryIndex: ci + 1,
                categoryCount: categories.length,
                categoryName: category.name,
                page: page,
                items: items,
                enriched: enriched,
                enrichTried: enrichTried,
              ),
            );
            CatalogPage pageResult;
            try {
              // 取消时不等这页目录取完（py 腿最长 70 秒）立刻停等。
              pageResult = await _raceCancel(
                repository.catalog(
                  spiderId,
                  category: category.id,
                  page: page,
                ),
              );
            } on _CrawlCancelled {
              break;
            } catch (error) {
              categoryError = error;
              break;
            }
            final rows = pageResult.items;
            if (rows.isEmpty) {
              categoryDone = true;
              break;
            }
            final entries = <ActressJsonEntry>[
              for (final drama in rows)
                _entryFromCatalog(drama, category, site, playFrom),
            ];
            items += entries.length;
            catItems += entries.length;
            pagesDone = page;
            // 批量落盘：没攒够阈值时只进内存合并表、不写盘，返回
            // false；只有落盘后才往前写断点——没落盘的页崩了重爬
            // （合并键去重，不重复入库），不把没落盘的数据记成
            // 已完成。
            final durable = await _appendEntries(site, entries);
            // 补流：本分类前 K 条没直链的，详情 + 取流补齐（K 按分类计，
            // 跨页累计，不按页重置）；补好的攒一页一次写盘。
            // 每起一条就报一次进度：详情 + 取流各 ≤70 秒，旧写法
            // 只在页循环顶部报数，补流期间面板长时间停在一个数上。
            final filledEntries = <ActressJsonEntry>[];
            var filledDurable = durable;
            for (final entry in entries) {
              if (enrichLeft <= 0 || _cancelled || _budgetExpired) break;
              if (_overBudget) {
                _budgetExpired = true;
                break;
              }
              if (entry.playable) continue;
              enrichTried++;
              _emit(
                ActressSiteCrawlProgress(
                  running: true,
                  site: site,
                  categoryIndex: ci + 1,
                  categoryCount: categories.length,
                  categoryName: category.name,
                  page: page,
                  items: items,
                  enriched: enriched,
                  enrichTried: enrichTried,
                ),
              );
              ActressJsonEntry? filled;
              try {
                // 取消时不等这条的详情 + 取流（最长 140 秒）立刻停等。
                filled = await _raceCancel(_enrichEntry(entry, spiderId));
              } on _CrawlCancelled {
                break;
              } catch (error) {
                // 补流取数抛错：记下，跳出补流与本页循环，分类收尾
                // 落盘、记断点后再往上抛，不断点、不丢已取数据。
                categoryError = error;
                break;
              }
              if (filled != null) {
                filledEntries.add(filled);
                enriched++;
                enrichLeft--;
              }
            }
            if (categoryError != null) {
              // 补流中途抛错：本页已到手的补流结果先落盘（别丢），
              // 但断点不往前写——下次从本页续爬，重新补流。
              if (filledEntries.isNotEmpty) {
                await _appendEntries(
                  site,
                  filledEntries,
                  mirrorRequired: false,
                );
              }
              pagesDone = page - 1;
              break;
            }
            if (filledEntries.isNotEmpty) {
              filledDurable = await _appendEntries(
                site,
                filledEntries,
                mirrorRequired: false,
              );
            }
            if (durable || filledDurable) {
              await db.saveCheckpoint(
                ActressSyncCheckpoint(
                  source: _checkpointSource.name,
                  phase: _categoryCheckpointPhase(site, ci),
                  cursor: '${page + 1}',
                  total: catItems,
                  updatedAt: DateTime.now().millisecondsSinceEpoch,
                ),
              );
            }
            if (rows.length < 24) {
              categoryDone = true;
              break;
            }
          }
          // 分类收尾先落盘：本分类攒着没写盘的条目一次写进去，
          // 再写分类检查点——断点只认已落盘的页。落盘失败时检查点
          // 一个字都不往前写，下次从上一个已落盘的断页续爬。
          var flushed = false;
          try {
            flushed = await _flushEntries(site);
          } catch (_) {
            flushed = false;
          }
          // 分类完成：短页/空页到头，或跑满每分类页数上限；
          // 取消/预算到时/落盘失败不记完成，下次从断页续爬。
          final catFinished =
              flushed &&
              !_cancelled &&
              !_budgetExpired &&
              (categoryDone || pagesDone >= maxPagesPerCategory);
          if (catFinished) {
            await db.saveCheckpoint(
              ActressSyncCheckpoint(
                source: _checkpointSource.name,
                phase: _categoryCheckpointPhase(site, ci),
                cursor: '',
                total: catItems,
                finished: true,
                updatedAt: DateTime.now().millisecondsSinceEpoch,
              ),
            );
          } else if (flushed && pagesDone >= fromPage) {
            await db.saveCheckpoint(
              ActressSyncCheckpoint(
                source: _checkpointSource.name,
                phase: _categoryCheckpointPhase(site, ci),
                cursor: '${pagesDone + 1}',
                total: catItems,
                finished: false,
                updatedAt: DateTime.now().millisecondsSinceEpoch,
              ),
            );
          }
          // 本分类中途抛错：收尾已落盘、断点已记，现在往上抛，
          // start() 转“现爬失败”，不断点、不丢已取数据。
          if (categoryError != null) throw categoryError;
          doneCats++;
        }
      }

      final workers = List.generate(
        categoryConcurrency < 1 ? 1 : categoryConcurrency,
        (_) => categoryWorker(),
      );
      await Future.wait(workers);
      await db.saveCheckpoint(
        ActressSyncCheckpoint(
          source: _checkpointSource.name,
          phase: _checkpointPhase(site),
          cursor: '$doneCats/${categories.length}',
          total: items,
          finished:
              !_cancelled &&
              !_budgetExpired &&
              doneCats >= categories.length,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      _emit(
        ActressSiteCrawlProgress(
          site: site,
          categoryIndex: categories.length,
          categoryCount: categories.length,
          items: items,
          enriched: enriched,
          enrichTried: enrichTried,
          done: !_cancelled && !_budgetExpired,
          error: _cancelled
              ? '已取消'
              : (_budgetExpired ? '本轮时间到，已记断点，下次继续' : ''),
        ),
      );
    } on _CrawlCancelled {
      // 取消：各分类收尾已落盘、断点已记，直接按取消收口，
      // 不报“现爬失败”。
      _emit(
        ActressSiteCrawlProgress(
          site: site,
          items: items,
          enriched: enriched,
          enrichTried: enrichTried,
          error: '已取消',
        ),
      );
    } catch (error) {
      _emit(
        ActressSiteCrawlProgress(
          site: site,
          items: items,
          enriched: enriched,
          enrichTried: enrichTried,
          error: '现爬失败：$error',
        ),
      );
    } finally {
      // 收尾落盘：异常中途退出时攒着的条目一次写进去，别丢。
      try {
        await _flushEntries(site);
      } catch (_) {
        // 落盘失败：断点仍按未完成记，下次续跑。
      }
      _localByKey = null;
      _localSite = null;
      _running = false;
    }
  }

  /// 任意站点现爬（2026-11-21 用户令「不管什么站点都可以爬取」）：
  /// 只认页面结构，不认站点名。侦察（MacCMS 接口 / 页面卡片簇 + 翻页
  /// 规律）→ 逐页取列表 → 按需补详情（女优名/番号/直链）→ 与内置站
  /// 同一条落地管线（json 单文件 + 库镜像 + 影视库）。
  ///
  /// 站点身份 `custom_<host>`：同一网址反复爬落同一身份，行按站隔离。
  /// 认不出的站（盾/纯脚本渲染/没有列表）直接报原因，不静默空跑；
  /// 抓到一半网络抖了也只停当前页，断点存页码，下次接着爬。
  Future<void> startGenericSite(
    String url, {
    int maxPages = defaultMaxPagesPerCategory,
    int enrichPerPage = 12,
    GenericSiteCrawler? crawler,
    Duration timeBudget = defaultTimeBudget,
  }) async {
    if (_running) return;
    _running = true;
    _cancelled = false;
    _beginRun(timeBudget);
    final engine = crawler ?? GenericSiteCrawler();
    var items = 0;
    var enriched = 0;
    var enrichTried = 0;
    var siteId = 'custom';
    try {
      final plan = await _raceCancel(engine.probe(url));
      siteId = plan.siteId;
      _localByKey = await _loadLocalEntries(siteId);
      _localSite = siteId;
      final phase = _checkpointPhase('generic_$siteId');
      final saved = await db.checkpoint(_checkpointSource, phase);
      var startPage = 1;
      if (saved != null && !saved.finished && saved.cursor.isNotEmpty) {
        startPage = int.tryParse(saved.cursor) ?? 1;
        if (startPage < 1) startPage = 1;
        items = saved.total;
      }
      var lastPage = startPage - 1;
      Object? runError;
      for (var page = startPage; page <= maxPages; page++) {
        if (_cancelled || _budgetExpired) break;
        if (_overBudget) {
          _budgetExpired = true;
          break;
        }
        _emit(
          ActressSiteCrawlProgress(
            running: true,
            site: siteId,
            categoryIndex: 1,
            categoryCount: 1,
            categoryName: plan.note,
            page: page,
            items: items,
            enriched: enriched,
            enrichTried: enrichTried,
          ),
        );
        ({List<GenericCrawlCard> cards, bool hasNext}) result;
        try {
          // 取消时不等这页取完立刻停等。
          result = await _raceCancel(engine.fetchPage(plan, page));
        } on _CrawlCancelled {
          break;
        } catch (error) {
          // 取页抛错：先记下，收尾落盘、补写上一个好页的断点后再往上抛
          // （外层 catch 转“现爬失败”）；批量落盘后抛错直接跳过收尾
          // 会丢已取数据与断点。
          runError = error;
          break;
        }
        if (result.cards.isEmpty) break;
        final entries = <ActressJsonEntry>[];
        var enrichLeft = enrichPerPage;
        for (final card in result.cards) {
          if (_cancelled || _budgetExpired) break;
          var title = card.title;
          var actor = card.actor;
          var cover = card.cover;
          var code = card.code;
          var playUrl = card.playUrl;
          var description = card.description;
          var pubdate = card.pubdate;
          // 采集接口的行已经带女优名和播放地址；页面卡片缺的才去抓详情。
          if ((actor.isEmpty || playUrl.isEmpty) && enrichLeft > 0) {
            enrichLeft--;
            // 每起一条详情就报一次：详情取数慢时面板能看到补流在走。
            enrichTried++;
            _emit(
              ActressSiteCrawlProgress(
                running: true,
                site: siteId,
                categoryIndex: 1,
                categoryCount: 1,
                categoryName: plan.note,
                page: page,
                items: items,
                enriched: enriched,
                enrichTried: enrichTried,
              ),
            );
            GenericCrawlDetail? detail;
            try {
              // 取消时不等这条详情取完立刻停等。
              detail = await _raceCancel(engine.fetchDetail(card.url));
            } on _CrawlCancelled {
              detail = null;
            }
            if (detail != null) {
              if (detail.title.isNotEmpty) title = detail.title;
              if (actor.isEmpty) actor = detail.actor;
              if (code.isEmpty) code = detail.code;
              if (cover.isEmpty) cover = detail.cover;
              if (description.isEmpty) description = detail.description;
              if (playUrl.isEmpty && detail.mediaUrl.isNotEmpty) {
                playUrl = detail.mediaUrl;
              } else if (playUrl.isEmpty && detail.playPageUrl.isNotEmpty) {
                // 只有播放页时不当直链存（存了会变成「能点但播不了」），
                // 地址记进简介，播放仍走本站点自己的详情。
                description =
                    '${description.isEmpty ? '' : '$description\n'}'
                    '播放页：${detail.playPageUrl}';
              }
              if (actor.isNotEmpty || playUrl.isNotEmpty) enriched++;
            }
          }
          if (code.isEmpty) {
            code = extractAvId(title: title, id: card.url) ?? '';
          }
          entries.add(
            ActressJsonEntry(
              site: siteId,
              vodId: card.url,
              vodName: title,
              vodPic: cover,
              vodActor: actor,
              vodDirector: '',
              vodRemarks: '高清',
              vodPubdate: pubdate,
              vodArea: '',
              vodYear: '',
              vodContent:
                  description.isNotEmpty
                  ? '<p>${_escapeHtml(description)}</p>'
                  : '<p>${_escapeHtml(title)}</p>',
              vodPlayFrom: siteId,
              vodPlayUrl: playUrl.isEmpty ? '' : '正片\$$playUrl',
              typeName: '自定义站',
              vodCode: code,
              vodActressPic: '',
            ),
          );
        }
        items += entries.length;
        lastPage = page;
        // 批量落盘：只有落盘后才往前写断点（与分类现爬同一口径）。
        final durable = await _appendEntries(siteId, entries);
        if (durable) {
          await db.saveCheckpoint(
            ActressSyncCheckpoint(
              source: _checkpointSource.name,
              phase: phase,
              cursor: '${page + 1}',
              total: items,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        }
        if (!result.hasNext) break;
      }
      // 收尾先落盘，再写总检查点：落盘失败不记完成，下次续爬。
      var flushed = false;
      try {
        flushed = await _flushEntries(siteId);
      } catch (_) {
        flushed = false;
      }
      if (runError != null) {
        // 取数中途抛错：断点停在上一个好页（不写总检查点，下次从好页的
        // 下一页续爬），再往上抛（外层 catch 转“现爬失败”）。
        if (flushed && lastPage >= startPage) {
          await db.saveCheckpoint(
            ActressSyncCheckpoint(
              source: _checkpointSource.name,
              phase: phase,
              cursor: '${lastPage + 1}',
              total: items,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        }
        throw runError;
      }
      await db.saveCheckpoint(
        ActressSyncCheckpoint(
          source: _checkpointSource.name,
          phase: phase,
          cursor: '',
          total: items,
          finished: flushed && !_cancelled && !_budgetExpired,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      _emit(
        ActressSiteCrawlProgress(
          site: siteId,
          categoryIndex: 1,
          categoryCount: 1,
          categoryName: plan.note,
          page: lastPage < 1 ? 1 : lastPage,
          items: items,
          enriched: enriched,
          enrichTried: enrichTried,
          done: !_cancelled && !_budgetExpired,
          error: _cancelled
              ? '已取消'
              : (_budgetExpired ? '本轮时间到，已记断点，下次继续' : ''),
        ),
      );
    } on _CrawlCancelled {
      _emit(
        ActressSiteCrawlProgress(
          site: siteId,
          items: items,
          enriched: enriched,
          enrichTried: enrichTried,
          error: '已取消',
        ),
      );
    } on GenericCrawlFailure catch (error) {
      _emit(
        ActressSiteCrawlProgress(
          site: 'custom',
          items: items,
          enriched: enriched,
          enrichTried: enrichTried,
          error: error.message,
        ),
      );
    } catch (error) {
      _emit(
        ActressSiteCrawlProgress(
          site: 'custom',
          items: items,
          enriched: enriched,
          enrichTried: enrichTried,
          error: '现爬失败：$error',
        ),
      );
    } finally {
      // 收尾落盘：异常中途退出时攒着的条目一次写进去，别丢。
      try {
        await _flushEntries(siteId);
      } catch (_) {
        // 落盘失败：断点仍按未完成记，下次续跑。
      }
      _localByKey = null;
      _localSite = null;
      _running = false;
    }
  }

  String _escapeHtml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// whos 现爬：影片库当成一个分类“全部”，按页码逐页取 validator.nu
  /// 列表页源码、解析卡片、直链条目每页即写盘。条目已有直链，不补流。
  /// 一页取回为空或无卡即停（不死循环翻页）；取数失败（3 次重试都
  /// 不过）抛给 start() 报“现爬失败”，断点停在上一个好页，下轮续跑。
  /// 断点与蜘蛛站同一机制：phase site_crawl_whos，cursor '0/页码'。
  /// 写盘走主树单文件口径（mjv011.json，行按 vod_play_from 认站）；
  /// 条目没女优名，镜像只留 json、不进库（人/作品行等同步补）。
  Future<void> _runWhos(int maxPagesPerCategory) async {
    const category = (id: '', name: '全部');
    _localByKey = await _loadLocalEntries('whos');
    _localSite = 'whos';
    var items = 0;
    var lastGoodPage = 0;
    var lastGoodItems = 0;
    Object? runError;
    final saved = await db.checkpoint(
      _checkpointSource,
      _checkpointPhase('whos'),
    );
    var startPage = 1;
    if (saved != null && !saved.finished && saved.cursor.isNotEmpty) {
      final parts = saved.cursor.split('/');
      startPage = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 1;
      items = saved.total;
    }
    for (var page = startPage; page <= maxPagesPerCategory; page++) {
      if (_cancelled || _budgetExpired) break;
      if (_overBudget) {
        _budgetExpired = true;
        break;
      }
      _emit(
        ActressSiteCrawlProgress(
          running: true,
          site: 'whos',
          categoryIndex: 1,
          categoryCount: 1,
          categoryName: category.name,
          page: page,
          items: items,
          enriched: 0,
        ),
      );
      String html;
      try {
        // 取消时不等这页取完（validator.nu 通道最长 90 秒）立刻停等。
        html = await _raceCancel(_whosListFetcher(page));
      } on _CrawlCancelled {
        break;
      } catch (error) {
        // 取数抛错：先记下，收尾落盘、补写上一个好页的断点后再往上抛
        // （start() 转“现爬失败”）。批量落盘后好页的断点只在落盘时
        // 写，抛错直接跳过收尾会丢断点——断点停在上一个好页。
        runError = error;
        break;
      }
      if (html.isEmpty) break;
      final cards = parseWhosListCards(html);
      if (cards.isEmpty) break;
      final entries = [for (final card in cards) _whosEntryFromCard(card)];
      items += entries.length;
      lastGoodPage = page;
      lastGoodItems = items;
      // 批量落盘：只有落盘后才往前写断点（与分类现爬同一口径）。
      final durable = await _appendEntries('whos', entries);
      if (durable) {
        await db.saveCheckpoint(
          ActressSyncCheckpoint(
            source: _checkpointSource.name,
            phase: _checkpointPhase('whos'),
            cursor: '0/$page',
            total: items,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
    }
    // 收尾先落盘，再写检查点：落盘失败不记完成，下次续爬。
    var flushed = false;
    try {
      flushed = await _flushEntries('whos');
    } catch (_) {
      flushed = false;
    }
    if (runError != null) {
      // 中途抛错：断点停在上一个好页（基线行为：抛错跳过收尾总检查点，
      // 页检查点留着）；总检查点不写，下次从好页的下一页续爬。
      if (flushed && lastGoodPage > 0) {
        await db.saveCheckpoint(
          ActressSyncCheckpoint(
            source: _checkpointSource.name,
            phase: _checkpointPhase('whos'),
            cursor: '0/$lastGoodPage',
            total: lastGoodItems,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      throw runError;
    }
    await db.saveCheckpoint(
      ActressSyncCheckpoint(
        source: _checkpointSource.name,
        phase: _checkpointPhase('whos'),
        cursor: '',
        total: items,
        finished: flushed && !_cancelled && !_budgetExpired,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _emit(
      ActressSiteCrawlProgress(
        site: 'whos',
        categoryIndex: 1,
        categoryCount: 1,
        categoryName: category.name,
        items: items,
        enriched: 0,
        done: !_cancelled && !_budgetExpired,
        error: _cancelled
            ? '已取消'
            : (_budgetExpired ? '本轮时间到，已记断点，下次继续' : ''),
      ),
    );
  }

  /// whos 卡片转 JSON 条目：直链已拼好（vodPlayUrl 带正片$直链），
  /// 女优/日期/年份列表页没有，留空不编假值，等以后映射或详情补。
  ActressJsonEntry _whosEntryFromCard(WhosListCard card) {
    return ActressJsonEntry(
      site: 'whos',
      vodId: whosVodId(card.code),
      vodName: card.title,
      vodPic: card.pic,
      vodActor: '',
      vodDirector: '',
      vodRemarks: '高清',
      vodPubdate: '',
      vodArea: '日本',
      vodYear: '',
      vodContent:
          '<p>这是一部来自 <strong>日本AV</strong> 分类的作品，番号：<strong>${card.code}</strong>，标题为：<br><strong>${card.title}</strong></p>',
      vodPlayFrom: 'whos',
      vodPlayUrl: '正片\$${card.m3u8}',
      typeName: '日本AV',
      vodCode: card.code,
      vodActressPic: '',
    );
  }

  /// 一轮内常驻内存的本地合并表（站 + 按 mergeKey 索引的条目）：
  /// 只读一次单文件 mjv011.json，写盘只写不重读；取消/跑完后丢弃，
  /// 下轮重读（文件是唯一真相）。键带站前缀：单文件里多站同
  /// （分类，番号）各留各的，不跨站撞键。
  Map<String, ActressJsonEntry>? _localByKey;
  String? _localSite;

  /// 读本地单文件 mjv011.json 进合并表：文件不存在或坏了即空表
  /// （坏文件不卡整轮，下次写盘重建）。行按 vod_play_from 认站，
  /// 来源名空着才回落到本次现爬的站。
  Future<Map<String, ActressJsonEntry>> _loadLocalEntries(
    String site,
  ) async {
    final byKey = <String, ActressJsonEntry>{};
    try {
      final dir = await _localDir();
      final file = File(
        path.join(dir.path, ActressJsonFallback.localFileName),
      );
      if (!file.existsSync()) return byKey;
      final doc = jsonDecode(file.readAsStringSync());
      if (doc is! Map<String, dynamic>) return byKey;
      validateActressJsonDocument(doc, file.path);
      for (final row in (doc['list'] as List)) {
        if (row is Map<String, dynamic>) {
          final rowSite = siteForPlayFrom(
            row['vod_play_from']?.toString() ?? '',
          );
          final entry = ActressJsonEntry.fromRow(
            row,
            rowSite.isEmpty ? site : rowSite,
          );
          byKey['${entry.site}|${entry.mergeKey}'] = entry;
        }
      }
    } catch (_) {
      // 本地文件坏了就按空表重建，不让一次坏文件卡住整轮现爬。
    }
    return byKey;
  }

  ActressJsonEntry _entryFromCatalog(
    Drama drama,
    ({String id, String name}) category,
    String site,
    String playFrom,
  ) {
    // 潮流分类行只有 id/标题/封面/日期：番号从 id 的 slug 段或标题里
    // 抠（抠不到就空着，等详情补）；女优名与直链一律空着，等补流。
    final code = _extractCode(drama.id) ?? _extractCode(drama.title) ?? '';
    return ActressJsonEntry(
      site: site,
      vodId: drama.id,
      vodName: drama.title,
      vodPic: drama.cover,
      vodActor: '',
      vodDirector: '',
      vodRemarks: '高清',
      vodPubdate: drama.onlineDate,
      vodArea: '',
      vodYear: '',
      vodContent: '<p>${drama.title}</p>',
      vodPlayFrom: playFrom,
      vodPlayUrl: '',
      typeName: category.name,
      vodCode: code,
      vodActressPic: '',
    );
  }

  String? _extractCode(String text) {
    if (text.isEmpty) return null;
    final slug = text.split('#').last;
    final fromSlug = extractAvId(title: slug);
    if (fromSlug != null && fromSlug.isNotEmpty) return fromSlug;
    return extractAvId(title: text);
  }

  /// 详情 + 取流补一条：女优名从详情描述的“演员：”行取，
  /// 番号从标题/集 id 抠，直链取 resolve 回的地址；详情与取流都走
  /// 本站蜘蛛（mjv 走潮流蜘蛛）。
  Future<ActressJsonEntry?> _enrichEntry(
    ActressJsonEntry entry,
    String spiderId,
  ) async {
    try {
      final detail = await repository.detail(
        Drama(
          id: entry.vodId,
          source: spiderId,
          title: entry.vodName,
          cover: entry.vodPic,
        ),
      );
      if (detail.episodes.isEmpty) return null;
      final actor = _actorFromDescription(detail.drama.description);
      final first = detail.episodes.first;
      final plan = await repository.resolve(detail.drama, first);
      if (plan.url.isEmpty) return null;
      final code = entry.vodCode.isNotEmpty
          ? entry.vodCode
          : (_extractCode(first.id) ??
              _extractCode(detail.drama.title) ??
              '');
      return ActressJsonEntry(
        site: entry.site,
        vodId: entry.vodId,
        vodName: detail.drama.title.isNotEmpty
            ? detail.drama.title
            : entry.vodName,
        vodPic: detail.drama.cover.isNotEmpty
            ? detail.drama.cover
            : entry.vodPic,
        vodActor: actor,
        vodDirector: entry.vodDirector,
        vodRemarks: '高清',
        vodPubdate: detail.drama.onlineDate.isNotEmpty
            ? detail.drama.onlineDate
            : entry.vodPubdate,
        vodArea: entry.vodArea,
        vodYear: entry.vodYear,
        vodContent: entry.vodContent,
        vodPlayFrom: entry.vodPlayFrom,
        vodPlayUrl: '正片\$${plan.url}',
        typeName: entry.typeName,
        vodCode: code,
        vodActressPic: entry.vodActressPic,
      );
    } catch (_) {
      return null;
    }
  }

  /// 详情映射把 vod_actor 拼进描述末尾“演员：XXX”行（见 PyContract）。
  String _actorFromDescription(String description) {
    final match = RegExp(r'演员：([^\n]+)').firstMatch(description);
    return match?.group(1)?.trim() ?? '';
  }

  /// 按更新规则合并写盘：同（站，分类，番号）且播放链接相同跳过，
  /// 任一字段不同就替换；全新即追加。顶层四键、indent=2。
  /// 不设条数上限：本地单文件随爬取增长（2026-11-20 用户令）。
  /// 合并表是一轮内常驻内存的那份（_localByKey），写盘只写不重读。
  /// 写盘后同一批条目同步进库（json-first：先落 json、再进库镜像，
  /// 库是 json 的派生索引），列表进行中就能陆续出人。
  /// 批量落盘（2026-11-24 同步卡顿修复）：旧写法每页都把内存里
  /// 全部条目全量重写一遍（几万条、几十 MB），O(n²) 越跑越慢；
  /// 新写法新合并的条目先只进内存表，攒够 [flushThresholdEntries]
  /// 条、或分类/整轮结束调 [_flushEntries] 时才写盘。返回 true
  /// 表示“磁盘上已包含全部已合并条目”（写过盘、或本批全是重复行
  /// 磁盘上本来就有）：调用方只有这时才往前写断点，没落盘的页
  /// 崩了重爬（合并键去重），不把没落盘的数据记成已完成。
  /// [_dirtyEntries] 是自上次落盘以来新合并/替换的条目数。
  var _dirtyEntries = 0;

  Future<bool> _appendEntries(
    String site,
    List<ActressJsonEntry> fresh, {
    bool mirrorRequired = true,
  }) async {
    if (fresh.isEmpty) return true;
    final dir = await _localDir();
    await dir.create(recursive: true);
    final file = File(
      path.join(dir.path, ActressJsonFallback.localFileName),
    );
    var byKey = _localByKey;
    if (_localSite != site || byKey == null) {
      byKey = await _loadLocalEntries(site);
      _localByKey = byKey;
      _localSite = site;
    }
    var changed = 0;
    for (final entry in fresh) {
      final key = '${entry.site}|${entry.mergeKey}';
      final old = byKey[key];
      if (old != null && old.vodPlayUrl == entry.vodPlayUrl) continue;
      byKey[key] = entry;
      changed++;
    }
    // 全是重复行：磁盘上已有这批数据，不用重写，直接算落盘。
    if (changed == 0) return true;
    _dirtyEntries += changed;
    var durable = false;
    if (_dirtyEntries >= flushThresholdEntries) {
      await _writeLocalFile(file, byKey);
      _dirtyEntries = 0;
      durable = true;
    }
    // 同一批条目进库镜像：有女优名的行建/合人物并写作品行，
    // 没女优名的行只留 json、不进库。json-first：文件先落盘，
    // 镜像后做；多分类工人并行时，镜像串在一条队列上依次跑
    // （写库不并行抢），取页与写盘不串。镜像重试一次仍失败时：
    // 页行抛错（调用方不记本页检查点，下轮断点续跑重爬本页重做
    // 镜像，json 里同键同链接直接跳过）；补流行吞掉不卡整轮。
    var mirrored = false;
    for (var attempt = 0; attempt < 2 && !mirrored; attempt++) {
      try {
        await _mirrorEntries(fresh);
        mirrored = true;
      } catch (_) {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    }
    if (!mirrored && mirrorRequired) {
      throw StateError('进库镜像失败：本页 ${fresh.length} 条未进库，库未同步');
    }
    // 影视库追加（2026-11-20）：同一批条目进 MYTV/db/女优库.db
    // （videos 结构），与 json 影子文件、app 库镜像同批；失败不卡
    // 现爬（下次打开影视库时 domain 比对与修复流程会补记）。
    await _appendToFilmLibrary(fresh);
    return durable;
  }

  /// 把内存合并表全量写进单文件（批量落盘的唯一写盘点）：
  /// 格式与旧写法完全一致（顶层四键、indent=2），只是写盘的
  /// 时机从“每页”改成“攒够阈值/分类结束/整轮结束”。
  Future<void> _writeLocalFile(
    File file,
    Map<String, ActressJsonEntry> byKey,
  ) async {
    final doc = <String, dynamic>{
      'list': [for (final e in byKey.values) e.toRow()],
      'parse': 0,
      'jx': 0,
      'last_update': DateTime.now().toIso8601String(),
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(doc),
    );
    flushWriteCount++;
  }

  /// 强制落盘：分类结束/整轮结束/异常收尾时调，把内存合并表里
  /// 攒着的条目一次写进单文件。没攒条目时不写盘。
  /// 返回 true 表示磁盘上已包含全部已合并条目。
  Future<bool> _flushEntries(String site) async {
    final byKey = _localByKey;
    if (byKey == null || _localSite != site) return _dirtyEntries == 0;
    if (_dirtyEntries == 0) return true;
    final dir = await _localDir();
    await dir.create(recursive: true);
    final file = File(
      path.join(dir.path, ActressJsonFallback.localFileName),
    );
    await _writeLocalFile(file, byKey);
    _dirtyEntries = 0;
    return true;
  }

  /// 现爬条目追加进影视库文件（绑定的 女优库.db）：失败只吞掉，
  /// 不抛、不卡现爬；写库口径与修复共用 [FilmLibraryWriter]。
  Future<void> _appendToFilmLibrary(List<ActressJsonEntry> fresh) async {
    try {
      final bind = await ActressMytvBind.instance.ensureBound();
      final writer = FilmLibraryWriter(dbPath: bind.dbPath);
      await writer.appendCrawledFilms(fresh);
    } catch (_) {
      // 影视库追加失败不卡现爬：json 已落盘、app 库镜像已成。
    }
  }

  /// 进库镜像串行队列：多工人并发调镜像时依次执行，不并行写库。
  Future<void> _mirrorQueue = Future.value();

  Future<void> _mirrorEntries(List<ActressJsonEntry> fresh) {
    final run = _mirrorQueue.then((_) => mirrorActressJsonEntriesToDb(db, fresh));
    // 队列本身永不带错：一次镜像失败不能毒掉整条链（旧写法
    // run.then((_) {}) 会把错传进链里，此后所有镜像直接跳过、
    // 静默丢数据，与名册写锁中毒同一毛病，见重载批 REPORT 第三节）。
    _mirrorQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<Directory> _localDir() async {
    if (_localJsonDir != null) return _localJsonDir!;
    if (_documentsDir != null) {
      return Directory(
        path.join(_documentsDir.path, ActressJsonFallback.localDirName),
      );
    }
    final docs = await getApplicationDocumentsDirectory();
    return Directory(path.join(docs.path, ActressJsonFallback.localDirName));
  }
}
