import 'package:moyi/hongguo_account.dart';
import 'package:moyi/ui_style.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('drama style only keeps ant and falls back to it', () {
    expect(DramaUiStyle.values, [DramaUiStyle.ant]);
    expect(DramaUiStyle.ant.storageValue, 'ant');
    expect(DramaUiStyle.fromStorageValue('ant'), DramaUiStyle.ant);
    expect(DramaUiStyle.fromStorageValue('fullscreen'), DramaUiStyle.ant);
    expect(DramaUiStyle.fromStorageValue('drama'), DramaUiStyle.ant);
    expect(DramaUiStyle.fromStorageValue('unknown'), DramaUiStyle.ant);
    expect(DramaUiStyle.fromStorageValue(null), DramaUiStyle.ant);
    expect(DramaUiStyle.fromStorageValue(''), DramaUiStyle.ant);
  });

  test('drama style labels use own descriptive copy', () {
    expect(DramaUiStyle.ant.label, '蚂蚁');
    for (final style in DramaUiStyle.values) {
      expect(style.label.contains('MiniReel'), isFalse);
      expect(style.label.contains('短剧之家'), isFalse);
      expect(style.label.contains('蚂蚁影视'), isFalse);
      expect(style.label.contains('蚂蚁TV'), isFalse);
    }
  });

  test('drama style value lives under the drama-zone key', () {
    expect(dramaUiStyleStorageKey, 'dramaUiStyle');
    expect(dramaUiStyleStorageKey.contains('drama'), isTrue);
  });

  test('stored fullscreen value falls back to ant on load', () async {
    SharedPreferences.setMockInitialValues({
      dramaUiStyleStorageKey: 'fullscreen',
    });
    await ensureDramaUiStyleLoaded();
    expect(dramaUiStyleNotifier.value, DramaUiStyle.ant);
  });

  test('hongguo account masks phones and round-trips json', () {
    expect(HongguoAccount.maskPhone('13812345678'), '138****5678');
    expect(HongguoAccount.maskPhone(''), '');
    const account = HongguoAccount(
      userId: '123',
      displayName: '测试账号',
      maskedPhone: '138****5678',
      method: 'sms',
    );
    final restored = HongguoAccount.fromJson(account.toJson());
    expect(restored.userId, '123');
    expect(restored.displayName, '测试账号');
    expect(restored.maskedPhone, '138****5678');
    expect(restored.methodLabel, '短信登录');
    expect(account.loggedIn, isTrue);
    expect(
      const HongguoAccount(userId: '', displayName: '', method: 'sms').loggedIn,
      isFalse,
    );
  });

  test('hongguo account persists under an app-level key', () async {
    SharedPreferences.setMockInitialValues({});
    const account = HongguoAccount(
      userId: '123',
      displayName: '测试账号',
      method: 'qr',
    );
    await saveHongguoAccount(account);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(hongguoAccountStorageKey), contains('123'));
    expect(hongguoAccountNotifier.value?.methodLabel, '扫码登录');
    await clearHongguoAccount();
    expect(preferences.getString(hongguoAccountStorageKey), isNull);
    expect(hongguoAccountNotifier.value, isNull);
  });
}
