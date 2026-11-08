import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:moyi/miniapp/mini_app_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recovered demo and emby zips install', () async {
    final temp = await Directory.systemTemp.createTemp('miniapp_realzip_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final store = MiniAppStore(rootOverride: temp);
    const base =
        '/home/hatch/workspace/moyi/restored/recovered/flutter_assets/miniapp';
    final demo = await store.installFromZipFile(File('$base/demo.zip'));
    expect(demo.appId, 'com.ant.demo');
    expect(demo.entry, 'index.html');
    expect(demo.hasPermission('network'), isTrue);
    final emby = await store.installFromZipFile(File('$base/emby.zip'));
    expect(emby.appId, 'com.ant.emby');
    expect(emby.entry, 'index.html');
    final installed = await store.listInstalled();
    expect(installed.length, 2);
    final demoDir = await store.installedDir('com.ant.demo');
    expect(await File('${demoDir!.path}/app.js').exists(), isTrue);
    expect(await File('${demoDir.path}/page2.html').exists(), isTrue);
    final embyDir = await store.installedDir('com.ant.emby');
    expect(await File('${embyDir!.path}/lib.js').exists(), isTrue);
  });
}
