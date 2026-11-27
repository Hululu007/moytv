// JavDB 对齐 jar 版路线回归测试（2026-11-27 用户实报三件）：
// ①女优作品没有 API——旧实现打 api/v1/actors/{id} 解析作品
// 必然回空，改走网页通道（镜像轮换 + 判定 + 正则解卡，jar
// 版 ZakaJavdbAmns 逐字移植；夹具卡片结构照 2026-11-27 本
// 机从 javdb.pw 实拉的演员页真卡）；
// ②详情走 api/v4/movies/{id} 取 data.movie（旧 v1 本机实测
// 404）；取数主通道是签名头、不预先登录——只有 v4 这类接
// 口明确回 JWT 错误时才机会性登录一次重试（2026-11-27
// 用户纠正后回读 jar 源码实证：login() 不看返回值、没令
// 牌只带签名照样取数、只有个别分类要 JWT）；
// ③duration 单位是分钟、spfcas 图床同样是 XOR 图、列表信
// 封自带 preview_images 要解出来给详情页剧照区。
// 真接口在本机出口时通时断：登录/v4 只验请求形状与解析，
// 网页通道已实拉实测（见 REPORT），手机终验为准。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/javdb_api.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

String _envelope(Object? data) => jsonEncode({'success': 1, 'data': data});

/// 照 javdb.pw 实拉演员页真卡结构裁出的夹具（两卡 + 填充注
/// 释过 2000 字判定线）。
const _actorPageHtml = '''
<html><head><title>演员作品</title></head><body>
<div class="movie-list h cols-4 vcols-8">
<div class="item">
<a href="/v/mOzQ7R" class="box" title="オナ禁した仆のマシマシザーメンを’あの’アイポケ美女たち29名がニッコリ受け入れてくれる神・対・応 大量颜射ベスト8时间">
<div class="cover ">
<img loading="lazy" src="https://c0.jdbstatic.com/covers/mo/mOzQ7R.jpg">
</div>
<div class="video-title"><strong>IPOK-044</strong> オナ禁した仆のマシマシザーメン</div>
<div class="meta">
12/08/2026
</div>
</a>
</div>
<div class="item">
<a href="/v/Aq2w6O" class="box" title="M调教×相部屋NTR 家族旅行中に夫は急务でトンボ帰りし二人きりマゾ性癖を见抜かれた美人妻は义父に性的支配され…。 枫カレン 生写真3枚セット">
<div class="cover ">
<img loading="lazy" src="https://c0.jdbstatic.com/covers/aq/Aq2w6O.jpg">
</div>
<div class="video-title"><strong>IDPC-013</strong> M调教×相部屋NTR</div>
<div class="meta">
11/08/2026
</div>
</a>
</div>
</div>
<!-- padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding
padding padding padding padding padding padding padding padding padding -->
</body></html>
''';

void main() {
group('base85 解码（jar 版 b85decode 向量）', () {
test('整组与尾组都对得上独立实现', () {
// 向量由 python base64.b85encode 对同明文算出（同字母表）。
expect(javdbB85Decode('Xk~0{Zv'), 'hello');
expect(javdbB85Decode('VPX'), 'ab');
expect(javdbB85Decode(''), '');
});
});

group('女优作品网页通道', () {
test('判定函数照 jar 版：长度 + movie-list + /v/', () {
expect(javdbLooksLikeActorPage(_actorPageHtml), isTrue);
expect(javdbLooksLikeActorPage('<html>movie-list /v/</html>'), isFalse);
expect(
javdbLooksLikeActorPage('x' * 3000),
isFalse,
);
});

test('真卡结构解出 id/番号/标题/封面', () {
final movies = javdbParseActorWorksHtml(_actorPageHtml);
expect(movies, hasLength(2));
expect(movies[0].id, 'mOzQ7R');
expect(movies[0].number, 'IPOK-044');
expect(movies[0].title, contains('オナ禁した仆の'));
expect(
movies[0].poster,
'https://c0.jdbstatic.com/covers/mo/mOzQ7R.jpg',
);
expect(movies[1].id, 'Aq2w6O');
expect(movies[1].number, 'IDPC-013');
});

test('镜像轮换：第一家回假页跳过、第二家真页解卡', () async {
final seen = <String>[];
final client = JavdbApiClient(
fetch: (url) async {
seen.add(url);
if (url.startsWith('https://javdb580.com')) {
return '<html>blocked</html>';
}
return _actorPageHtml;
},
);
final movies = await client.actorMovies('kzx6');
expect(movies, hasLength(2));
expect(seen[0], 'https://javdb580.com/actors/kzx6');
expect(seen[1], 'https://javdb.com/actors/kzx6');
});

test('翻页带?page=N、全镜像失败回空不抛', () async {
final seen = <String>[];
final client = JavdbApiClient(
fetch: (url) async {
seen.add(url);
throw Exception('timeout');
},
);
final movies = await client.actorMovies('kzx6', page: 3);
expect(movies, isEmpty);
expect(seen, hasLength(3));
expect(seen.first, contains('/actors/kzx6?page=3'));
});
});

group('登录 + v4 详情', () {
test('先凭签名直取、回 JWT 错误才登录拿令牌重试一次', () async {
final calls = <String>[];
var detailAttempts = 0;
final client = JavdbApiClient(
fetch: (url) async {
calls.add('GET $url');
detailAttempts++;
if (detailAttempts == 1) {
return jsonEncode({
'success': 0,
'action': 'JWTVerificationError',
'message': '請登錄帳號',
});
}
return _envelope({
'movie': {
'id': 'm1',
'number': 'SAME-711',
'score': 4.2,
'cover_url': 'https://tp.spfcas.com/covers/m1.jpg',
'actors': [
{
'name': '演员甲',
'avatar_url': 'https://c0.jdbstatic.com/avatars/a.jpg',
},
{'name': '演员乙', 'cover_url': 'https://c0.jdbstatic.com/avatars/b.jpg'},
],
'preview_images': [
{'large_url': 'https://tp.spfcas.com/samples/s1.jpg'},
{'thumb_url': 'https://tp.spfcas.com/samples/s2.jpg'},
],
},
});
},
post: (url, body, contentType) async {
calls.add('POST $url');
expect(contentType, startsWith('multipart/form-data; boundary='));
expect(body, contains('name="username"'));
expect(body, contains('name="app_version_number"'));
expect(body, contains('1.9.35'));
return jsonEncode({
'success': 1,
'data': {'token': 'test-token-123456'},
});
},
);
final extra = await client.movieExtra('m1');
// 顺序：详情(只带签名、被回 JWT 错误) → 登录 → 详情(成功)。
// 不许一上来先登录——签名才是数据主通道。
expect(calls, hasLength(3));
expect(calls[0], contains('api/v4/movies/m1'));
expect(calls[1], startsWith('POST https://apidd.spthgb.com/api/v1/sessions'));
expect(calls[2], contains('api/v4/movies/m1'));
expect(extra.actors, hasLength(2));
expect(extra.actors[0].name, '演员甲');
expect(extra.actors[0].avatarUrl, contains('avatars/a.jpg'));
// 头像 avatar_url 空时落 cover_url（jar 版取值顺序）。
expect(extra.actors[1].avatarUrl, contains('avatars/b.jpg'));
expect(extra.stills, [
'https://tp.spfcas.com/samples/s1.jpg',
'https://tp.spfcas.com/samples/s2.jpg',
]);
expect(extra.poster, 'https://tp.spfcas.com/covers/m1.jpg');
expect(extra.score, '4.2');
});

test('登录失败不挡免登录接口（latest 照常解析）', () async {
final client = JavdbApiClient(
fetch: (url) async => _envelope({
'movies': [
{'id': 'm1', 'number': 'ADN-821', 'title': '标题', 'duration': 150},
],
}),
post: (url, body, contentType) async =>
jsonEncode({'success': 0, 'message': 'bad credentials'}),
);
final movies = await client.latestMovies();
expect(movies.single.number, 'ADN-821');
// duration 单位是分钟：150 就是 150 分钟，不许再除 60。
expect(movies.single.durationMinutes, 150);
});

test('登录接口抛错/超时也不挡数据：演员与最新凭签名直取、且不触发登录', () async {
var postCalls = 0;
final client = JavdbApiClient(
fetch: (url) async {
if (url.contains('api/v1/actors')) {
return _envelope({
'actors': [
{'id': 'a1', 'name': '演员甲', 'avatar_url': ''},
],
});
}
return _envelope({
'movies': [
{'id': 'm1', 'number': 'ADN-821', 'title': '标题', 'duration': 150},
],
});
},
post: (url, body, contentType) async {
postCalls++;
// 登录端点抛错等价于超时/连不上（_login 内部同一条
// catch 路径）：绝不能因此挡住签名直取的数据。
throw Exception('login endpoint timeout');
},
);
final actors = await client.actors();
expect(actors.single.name, '演员甲');
final movies = await client.latestMovies();
expect(movies.single.number, 'ADN-821');
// 信封成功就根本不该碰登录接口。
expect(postCalls, 0);
});

test('非 JWT 的拒绝不触发登录（签名错误照原样报错）', () async {
var postCalls = 0;
final client = JavdbApiClient(
fetch: (url) async =>
jsonEncode({'success': 0, 'message': 'invalid signature'}),
post: (url, body, contentType) async {
postCalls++;
return jsonEncode({
'success': 1,
'data': {'token': 'test-token-123456'},
});
},
);
await expectLater(client.latestMovies(), throwsA(anything));
expect(postCalls, 0);
});

test('JWT 错误但登录失败：只登录一次、只挡该分类，其它接口随后照常', () async {
var postCalls = 0;
final client = JavdbApiClient(
fetch: (url) async {
if (url.contains('api/v4/movies/')) {
return jsonEncode({
'success': 0,
'action': 'JWTVerificationError',
'message': '請登錄帳號',
});
}
return _envelope({
'movies': [
{'id': 'm1', 'number': 'ADN-821', 'title': '标题', 'duration': 150},
],
});
},
post: (url, body, contentType) async {
postCalls++;
return jsonEncode({'success': 0, 'message': 'bad credentials'});
},
);
// v4 详情要令牌、登录又失败：该分类报错收尾……
await expectLater(client.movieExtra('m1'), throwsA(anything));
// ……但登录只许尝试一次（旧实现一次失败请求能连登三次）。
expect(postCalls, 1);
// 其它分类不许被连累：随后 latest 凭签名照常取数、不再登。
final movies = await client.latestMovies();
expect(movies.single.number, 'ADN-821');
expect(postCalls, 1);
});
});

group('列表信封与图床', () {
test('preview_images 解出（large 优先、thumb 兜底）', () {
final movie = JavdbMovie.fromJson({
'id': 'm1',
'number': 'SAME-711',
'title': '标题',
'preview_images': [
{'large_url': 'https://tp.spfcas.com/samples/l1.jpg', 'thumb_url': 'https://tp.spfcas.com/samples/t1.jpg'},
{'thumb_url': 'https://tp.spfcas.com/samples/t2.jpg'},
'https://tp.spfcas.com/samples/plain.jpg',
],
});
expect(movie.previewImages, [
'https://tp.spfcas.com/samples/l1.jpg',
'https://tp.spfcas.com/samples/t2.jpg',
'https://tp.spfcas.com/samples/plain.jpg',
]);
});

test('spfcas 图床认作 JavDB 图（走 XOR 解密路径）', () {
expect(javdbIsImageUrl('https://tp.spfcas.com/covers/m1.jpg'), isTrue);
expect(javdbIsImageUrl('https://c0.jdbstatic.com/covers/m1.jpg'), isTrue);
expect(javdbIsImageUrl('https://img.example.com/m1.jpg'), isFalse);
});
});

group('详情页接线（JavDB 源）', () {
testWidgets('v4 详情演员补上头区演员行、预览图补上剧照区', (tester) async {
tester.view.physicalSize = const Size(390, 844);
tester.view.devicePixelRatio = 1;
addTearDown(tester.view.reset);
SharedPreferences.setMockInitialValues({});
final store = LocalStore(await SharedPreferences.getInstance());
addTearDown(store.dispose);
final client = JavdbApiClient(
fetch: (url) async {
if (url.contains('/magnets')) return _envelope({'magnets': []});
if (url.contains('/reviews')) return _envelope({'reviews': []});
if (url.contains('api/v4/movies/')) {
return _envelope({
'movie': {
'id': 'm1',
'number': 'SAME-711',
'actors': [
{
'name': '羽田结衣',
'avatar_url': 'https://c0.jdbstatic.com/avatars/yui.jpg',
},
],
'preview_images': [
{'large_url': 'https://tp.spfcas.com/samples/s1.jpg'},
{'large_url': 'https://tp.spfcas.com/samples/s2.jpg'},
],
},
});
}
return _envelope({'movies': []});
},
);
const drama = Drama(
id: 'SAME-711',
source: 'javdb',
sourceId: 'm1',
title: 'SAME-711 样本影片',
tags: ['SAME-711'],
episodes: 0,
);
await tester.pumpWidget(
MaterialApp(
home: DetailScreen(
drama: drama,
repository: FixtureRepository(),
store: store,
initialDetail: DramaDetail(drama, const []),
javdbStillsClient: client,
),
),
);
var castFound = false;
var stillsFound = false;
for (var i = 0; i < 30; i++) {
await tester.runAsync(
() => Future<void>.delayed(const Duration(milliseconds: 150)),
);
await tester.pump(const Duration(milliseconds: 80));
castFound = find
.byKey(const ValueKey('cast-羽田结衣'))
.evaluate()
.isNotEmpty;
stillsFound = find
.byKey(const ValueKey('detail-stills-section'))
.evaluate()
.isNotEmpty;
if (castFound && stillsFound) break;
if (find.byType(Scrollable).evaluate().isNotEmpty) {
await tester.drag(
find.byType(Scrollable).first,
const Offset(0, -300),
);
await tester.pump(const Duration(milliseconds: 80));
}
}
expect(castFound, isTrue, reason: '演员行应由 v4 详情演员补上');
expect(stillsFound, isTrue, reason: '剧照区应由 v4 详情预览图补上');
expect(find.text('当前用户无权访问'), findsNothing);
expect(tester.takeException(), isNull);
await tester.pumpWidget(const SizedBox.shrink());
});
});
}
