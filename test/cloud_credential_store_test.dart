import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/cloud_drive/cloud_credential_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late CloudCredentialStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = CloudCredentialStore(prefs);
  });

  CloudCredentials creds({String cookie = 'UID=abc123; BDUSS=xyz'}) =>
      CloudCredentials(
        fields: {'cookie': cookie},
        savedAtMs: 1234567890,
        label: 'test',
      );

  group('CloudCredentialStore', () {
    test('保存/读取往返', () async {
      await store.save('pan115', creds());
      final loaded = store.load('pan115');
      expect(loaded, isNotNull);
      expect(loaded!.fields['cookie'], 'UID=abc123; BDUSS=xyz');
      expect(loaded.savedAtMs, 1234567890);
      expect(loaded.label, 'test');
    });

    test('未保存时 load 返回 null，且不生成密钥', () {
      expect(store.load('quark'), isNull);
      expect(prefs.getString('cloud_drive_obfs_key_v1'), isNull);
    });

    test('存盘值不是明文（凭证内容不直接出现）', () async {
      await store.save('baidu', creds(cookie: 'SECRET_COOKIE_VALUE_98765'));
      final raw = prefs.getString('cloud_cred_baidu') ?? '';
      expect(raw, isNotEmpty);
      expect(raw, isNot(contains('SECRET_COOKIE_VALUE_98765')));
      expect(raw, isNot(contains('BDUSS')));
    });

    test('清除后 load 返回 null', () async {
      await store.save('pan115', creds());
      await store.clear('pan115');
      expect(store.load('pan115'), isNull);
    });

    test('loggedInProviderIds 只列已保存的', () async {
      await store.save('pan115', creds());
      await store.save('aliyun', creds(cookie: 'rt=token'));
      final ids = store.loggedInProviderIds(['pan115', 'quark', 'aliyun', 'baidu']);
      expect(ids, containsAll(['pan115', 'aliyun']));
      expect(ids, isNot(contains('quark')));
      expect(ids, isNot(contains('baidu')));
    });

    test('损坏的存盘值 load 返回 null，不抛错', () async {
      await store.save('pan115', creds());
      await prefs.setString('cloud_cred_pan115', '!!!not-base64!!!');
      expect(store.load('pan115'), isNull);
    });

    test('密钥丢失后旧凭证读不出来（不静默生成密钥骗过）', () async {
      await store.save('pan115', creds());
      await prefs.remove('cloud_drive_obfs_key_v1');
      expect(store.load('pan115'), isNull);
    });

    test('多家凭证互不干扰', () async {
      await store.save('pan115', creds(cookie: 'cookie-115'));
      await store.save('quark', creds(cookie: 'cookie-quark'));
      expect(store.load('pan115')!.fields['cookie'], 'cookie-115');
      expect(store.load('quark')!.fields['cookie'], 'cookie-quark');
      await store.clear('pan115');
      expect(store.load('quark')!.fields['cookie'], 'cookie-quark');
    });
  });

  group('CloudCredentials JSON', () {
    test('toJson/fromJson 往返', () {
      final json = creds().toJson();
      final back = CloudCredentials.fromJson(json);
      expect(back.fields['cookie'], 'UID=abc123; BDUSS=xyz');
      expect(back.savedAtMs, 1234567890);
      expect(back.label, 'test');
    });

    test('fromJson 缺字段时容错', () {
      final back = CloudCredentials.fromJson({'fields': {'a': 'b'}});
      expect(back.fields['a'], 'b');
      expect(back.savedAtMs, 0);
    });
  });
}
