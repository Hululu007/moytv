// 女优库 whos 手机现爬（2026-11-21）：validator.nu 列表通道，
// 封面密文 XOR 解码，hash 直拼 m3u8，不取详情、不走补流。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_site_crawl.dart';
import 'package:moyi/models.dart';

import 'fixtures.dart';

/// 外面已实测的真实例（whos 列表页第 1 页前两张卡）。
const _cipher1 =
'39252521226b7e7e277f3934232230277f3c347e383c303634227e30277e32356932683568676364603333353469606533333362653530306166676661677f3b213651';
const _cipher2 =
'2f333337347d686831692f2235342631692a22682e2a262022346826316874257026707072257076727277757e757f752373252273702221717073747026692d372047';

String _cardHtml(String code, String cipher, String title) =>
'<a href="/videos/$code" class="group block">'
'<div data-cover-src="$cipher" class="lazy-cover-skeleton" '
'alt="$title"></div></a>';

const _page1Html = '''
<section aria-label="影片库">
<div id="video-list" class="video-directory__grid">
''';

void main() {
group('whos 封面密文解码', () {
test('真实例 1：解出封面地址与 hash', () {
final decoded = decodeWhosCover(_cipher1);
expect(decoded, isNotNull);
expect(
decoded!.pic,
'https://v.hersav.me/images/av/cd8c9d96251bbde814bbb34daa076706.jpg',
);
expect(decoded.hash, 'cd8c9d96251bbde814bbb34daa076706');
expect(
whosM3u8Url(decoded.hash),
'https://v.hersav.me/cd8c9d96251bbde814bbb34daa076706/cd8c9d96251bbde814bbb34daa076706.m3u8',
);
});

test('真实例 2：另一张卡，密钥不同', () {
final decoded = decodeWhosCover(_cipher2);
expect(decoded, isNotNull);
expect(
decoded!.pic,
'https://v.hersav.me/images/av/3b7a775b7155029282d4be47ef67437a.jpg',
);
expect(decoded.hash, '3b7a775b7155029282d4be47ef67437a');
});

test('坏密文返回 null，不编假地址', () {
expect(decodeWhosCover(''), isNull);
expect(decodeWhosCover('00'), isNull);
expect(decodeWhosCover('zz'), isNull);
expect(decodeWhosCover('abc'), isNull);
expect(decodeWhosCover('00112233445566778899aabbccddeeff'), isNull);
});
});

group('whos vod_id 与卡片解析', () {
test('vod_id 与外面 Python 爬虫一致（md5 前 8 位）', () {
expect(whosVodId('fc2ppv-4913308'), '62af401e');
expect(whosVodId('fc2ppv-4927098'), 'cbc091a4');
expect(whosVodId('ankk-680'), 'f158f2ac');
});

test('解析两张真卡，坏卡跳过', () {
final html =
'$_page1Html'
'${_cardHtml('fc2ppv-4913308', _cipher1, '测试标题一')}'
'${_cardHtml('fc2ppv-4927098', _cipher2, '测试标题二')}'
'${_cardHtml('bad-001', '00112233445566778899aabbccddeeff', '坏卡')}'
'</div></section>';
final cards = parseWhosListCards(html);
expect(cards.length, 2);
expect(cards[0].code, 'fc2ppv-4913308');
expect(cards[0].title, '测试标题一');
expect(
cards[0].pic,
'https://v.hersav.me/images/av/cd8c9d96251bbde814bbb34daa076706.jpg',
);
expect(cards[0].hash, 'cd8c9d96251bbde814bbb34daa076706');
expect(
cards[0].m3u8,
'https://v.hersav.me/cd8c9d96251bbde814bbb34daa076706/cd8c9d96251bbde814bbb34daa076706.m3u8',
);
expect(cards[1].code, 'fc2ppv-4927098');
expect(cards[1].hash, '3b7a775b7155029282d4be47ef67437a');
});

test('空页无卡', () {
expect(parseWhosListCards(''), isEmpty);
expect(parseWhosListCards('<html></html>'), isEmpty);
});
});

group('whos 现爬写盘', () {
late Directory temp;
late MemoryActressDatabase db;

setUp(() {
temp = Directory.systemTemp.createTempSync();
db = MemoryActressDatabase();
});

tearDown(() {
temp.deleteSync(recursive: true);
});

ActressSiteCrawlService makeService(
Future<String> Function(int page) fetcher,
) => ActressSiteCrawlService(
repository: _NoopRepository(),
db: db,
documentsDir: temp,
whosListFetcher: fetcher,
);

test('两页真卡写盘合格式，直链已拼好，不走蜘蛛', () async {
final fetched = <int>[];
Future<String> fetcher(int page) async {
fetched.add(page);
if (page == 1) {
return '$_page1Html'
'${_cardHtml('fc2ppv-4913308', _cipher1, '测试标题一')}'
'${_cardHtml('fc2ppv-4927098', _cipher2, '测试标题二')}'
'</div></section>';
}
return '';
}

final service = makeService(fetcher);
addTearDown(service.dispose);
await service.start(site: 'whos', maxPagesPerCategory: 50);

expect(fetched, [1, 2]);
expect(service.current.done, isTrue);
expect(service.current.items, 2);
expect(service.current.enriched, 0);
expect(service.current.error, isEmpty);

final file = File('${temp.path}/actress_json/mjv011.json');
expect(file.existsSync(), isTrue);
final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
expect(
() => validateActressJsonDocument(doc, '现爬 whos.json'),
returnsNormally,
);
final rows = (doc['list'] as List).cast<Map<String, dynamic>>();
expect(rows.length, 2);
final first = rows.firstWhere(
(r) => r['vod_code'] == 'fc2ppv-4913308',
);
expect(first['vod_id'], '62af401e');
expect(first['vod_name'], '测试标题一');
expect(
first['vod_pic'],
'https://v.hersav.me/images/av/cd8c9d96251bbde814bbb34daa076706.jpg',
);
expect(first['vod_actor'], '');
expect(first['vod_remarks'], '高清');
expect(first['vod_area'], '日本');
expect(first['type_name'], '日本AV');
expect(first['vod_play_from'], 'whos');
expect(
first['vod_play_url'],
'正片\$https://v.hersav.me/cd8c9d96251bbde814bbb34daa076706/cd8c9d96251bbde814bbb34daa076706.m3u8',
);
expect(
first['vod_content'],
'<p>这是一部来自 <strong>日本AV</strong> 分类的作品，番号：<strong>fc2ppv-4913308</strong>，标题为：<br><strong>测试标题一</strong></p>',
);

final checkpoint = await db.checkpoint(
ActressRosterSourceId.chaoliu,
'site_crawl_whos',
);
expect(checkpoint, isNotNull);
expect(checkpoint!.finished, isTrue);
expect(checkpoint.total, 2);
});

test('取回为空即停：0 条、完成、不写文件', () async {
final service = makeService((_) async => '');
addTearDown(service.dispose);
await service.start(site: 'whos');
expect(service.current.done, isTrue);
expect(service.current.items, 0);
expect(
File('${temp.path}/actress_json/mjv011.json').existsSync(),
isFalse,
);
});

test('取数抛错报“现爬失败”，断点停在上一个好页', () async {
Future<String> fetcher(int page) async {
if (page == 1) {
return '$_page1Html'
'${_cardHtml('fc2ppv-4913308', _cipher1, '测试标题一')}'
'</div></section>';
}
throw Exception('validator 502');
}

final service = makeService(fetcher);
addTearDown(service.dispose);
await service.start(site: 'whos', maxPagesPerCategory: 50);
expect(service.current.error, contains('现爬失败'));
expect(service.current.items, 0);
final checkpoint = await db.checkpoint(
ActressRosterSourceId.chaoliu,
'site_crawl_whos',
);
expect(checkpoint, isNotNull);
expect(checkpoint!.finished, isFalse);
expect(checkpoint.cursor, '0/1');
expect(checkpoint.total, 1);
});

test('第二轮重跑不重复：同番号同直链跳过', () async {
Future<String> fetcher(int page) async {
if (page == 1) {
return '$_page1Html'
'${_cardHtml('fc2ppv-4913308', _cipher1, '测试标题一')}'
'</div></section>';
}
return '';
}

final service = makeService(fetcher);
addTearDown(service.dispose);
await service.start(site: 'whos', maxPagesPerCategory: 1);
await service.start(site: 'whos', maxPagesPerCategory: 1);
final file = File('${temp.path}/actress_json/mjv011.json');
final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
expect((doc['list'] as List).length, 1);
});
});
}

/// 不走蜘蛛的假仓：whos 现爬只用取数器，不应调 repository。
class _NoopRepository extends FixtureRepository {
@override
Future<CatalogPage> catalog(
String source, {
int page = 1,
String query = '',
String category = '',
bool force = false,
Map<String, String> filters = const {},
}) async {
throw StateError('whos 现爬不应调 repository.catalog');
}
}
