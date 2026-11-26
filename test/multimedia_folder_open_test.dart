// 网盘文件夹打开响应回归（用户实报：点文件夹像打不开、反应慢）：
// 1. 点文件夹立刻出加载态，不再对着上一层内容干等；
// 2. 进过的文件夹返回再进走内存缓存，不重拉网络；
// 3. 手动刷新绕过缓存现拉；
// 4. 请求失败出明确错误态（带重试），不假死。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/multimedia_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _pan115 = SourceSite('cloud:pan115', '115网盘', '');

Drama _video(String id, String title) =>
    Drama(id: id, source: 'cloud:pan115', title: title, kind: 'video');

Drama _folder(String id, String title, String folderId) => Drama(
  id: id,
  source: 'cloud:pan115',
  title: title,
  kind: 'folder',
  folderId: folderId,
);

class _GateFakeRepository extends FixtureRepository {
  /// category → 已请求次数。
  final calls = <String, int>{};

  /// category → 闸门：设了就等闸门放行才回数据（模拟慢网络）。
  final gates = <String, Completer<void>>{};

  /// 要抛错的 category 集合。
  final failing = <String>{};

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    calls[category] = (calls[category] ?? 0) + 1;
    final gate = gates[category];
    if (gate != null) await gate.future;
    if (failing.contains(category)) {
      throw StateError('115 文件列表获取失败（模拟）');
    }
    if (category == 'fd1') {
      return CatalogPage([_video('pan115:v9', '夹内视频.mkv')]);
    }
    return CatalogPage([
      _folder('pan115:fd1', '目标文件夹', 'fd1'),
      _video('pan115:v1', '根目录视频.mkv'),
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_GateFakeRepository> pumpScreen(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final repository = _GateFakeRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MultimediaScreen(
            repository: repository,
            store: store,
            driveSites: const [_pan115],
            onOpenDrama: (_) {},
            metadataFetcher:
                ({
                  required String title,
                  String? year,
                  String? typeHint,
                }) async => null,
            coverFetcher: (_) async => '',
          ),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return repository;
  }

  testWidgets('点文件夹立刻出加载态，数据回来再填', (tester) async {
    final repository = await pumpScreen(tester);
    expect(find.text('根目录视频.mkv'), findsOneWidget);

    final gate = Completer<void>();
    repository.gates['fd1'] = gate;
    await tester.tap(find.text('目标文件夹'));
    await tester.pump();

    // 请求还没回来：旧内容已撤、加载圈已出，不再假死无反应。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('根目录视频.mkv'), findsNothing);
    expect(find.text('夹内视频.mkv'), findsNothing);

    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('夹内视频.mkv'), findsOneWidget);
  });

  testWidgets('返回再进同一文件夹走缓存，不重拉', (tester) async {
    final repository = await pumpScreen(tester);

    await tester.tap(find.text('目标文件夹'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('夹内视频.mkv'), findsOneWidget);
    expect(repository.calls['fd1'], 1);

    await tester.tap(find.byKey(const ValueKey('multimedia-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('根目录视频.mkv'), findsOneWidget);

    await tester.tap(find.text('目标文件夹'));
    await tester.pump();
    // 命中缓存：内容直接在，没有加载圈，也没有第二次请求。
    expect(find.text('夹内视频.mkv'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(repository.calls['fd1'], 1);
  });

  testWidgets('手动刷新绕过缓存现拉', (tester) async {
    final repository = await pumpScreen(tester);

    await tester.tap(find.text('目标文件夹'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(repository.calls['fd1'], 1);

    await tester.tap(find.byKey(const ValueKey('multimedia-refresh')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(repository.calls['fd1'], 2);
    expect(find.text('夹内视频.mkv'), findsOneWidget);
  });

  testWidgets('文件夹请求失败出错误态带重试，不假死', (tester) async {
    final repository = await pumpScreen(tester);
    repository.failing.add('fd1');

    await tester.tap(find.text('目标文件夹'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('multimedia-error')), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
