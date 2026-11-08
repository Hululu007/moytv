import 'package:moyi/hongguo_device_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mask keeps only head and tail', () {
    expect(maskHongguoDeviceId('1234567890123456789'), '123456…6789');
    expect(maskHongguoDeviceId('123456…6789'), '123456…6789');
    expect(maskHongguoDeviceId(''), '暂无');
  });

  test('profile status prefers limited over registered', () {
    const profile = HongguoDeviceProfile(
      registered: true,
      limited: true,
      deviceId: '123456…6789',
      installId: '987654…4321',
    );
    expect(profile.statusLabel, '受限');
    expect(
      HongguoDeviceProfile.fromJson({
        'registered': false,
        'limited': false,
        'deviceId': '1234567890123456789',
        'installId': '9876543210987654321',
      }).statusLabel,
      '未注册',
    );
  });
}
