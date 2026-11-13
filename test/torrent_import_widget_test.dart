import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/torrent/magnet_file_import.dart';
import 'package:moyi/torrent/torrent_home_screen.dart';
import 'package:moyi/torrent/torrent_magnet.dart';
import 'package:moyi/torrent/torrent_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> freshPrefs() async {
    SharedPreferences.setMockInitialValues({});
    return SharedPreferences.getInstance();
  }

  const magnet1 =
      'magnet:?xt=urn:btih:FC5353DC585D96AB95E99FD5CCAD7DC690A033EF&dn=First';
  const magnet2 =
      'magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&dn=Second';

  test('addAll 按文件顺序插前面、去重、只存一次', () async {
    final prefs = await freshPrefs();
    final store = TorrentSessionStore(prefs);
    final first = parseMagnetUri(magnet1)!;
    final second = parseMagnetUri(magnet2)!;
    await store.add(first);
    final outcome = await store.addAll([second, first, second]);
    expect(outcome.added, 1);
    expect(outcome.duplicates, 2);
    expect(outcome.sessions.length, 2);
    expect(outcome.sessions.first.id, second.infoHash);
    final reloaded = await TorrentSessionStore(prefs).load(prefs);
    expect(reloaded.length, 2);
    expect(reloaded.first.id, second.infoHash);
  });

  testWidgets('导入的列表按编号卡片显示：磁力 001/002 + 哈希', (tester) async {
    final prefs = await freshPrefs();
    final store = TorrentSessionStore(prefs);
    await store.addAll([parseMagnetUri(magnet1)!, parseMagnetUri(magnet2)!]);
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: TorrentHomePage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('种子引擎未接入'), findsOneWidget);
    expect(find.textContaining('磁力 001'), findsWidgets);
    expect(find.text('First'), findsOneWidget);
    expect(find.textContaining('磁力 002'), findsWidgets);
    expect(find.text('Second'), findsOneWidget);
    expect(find.textContaining('fc5353dc'), findsWidgets);
    expect(find.text('导入文件'), findsOneWidget);
    expect(magnetDisplayNumber(0), '磁力 001');
  });
}
