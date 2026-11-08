import 'package:moyi/playback_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('permission wins over other matches', () {
    expect(
      classifyPlaybackError('需要登录后观看，错误 401'),
      PlaybackErrorKind.permission,
    );
    expect(
      classifyPlaybackError('VIP 会员专享，试看结束'),
      PlaybackErrorKind.permission,
    );
    expect(
      classifyPlaybackError('403 Forbidden'),
      PlaybackErrorKind.permission,
    );
  });

  test('network keywords', () {
    expect(classifyPlaybackError('网络连接超时，请重试'), PlaybackErrorKind.network);
    expect(
      classifyPlaybackError('SocketException: failed host lookup'),
      PlaybackErrorKind.network,
    );
    expect(
      classifyPlaybackError('503 Service Unavailable'),
      PlaybackErrorKind.network,
    );
  });

  test('decode keywords', () {
    expect(classifyPlaybackError('解码器不支持该格式'), PlaybackErrorKind.decode);
    expect(
      classifyPlaybackError('codec not supported'),
      PlaybackErrorKind.decode,
    );
  });

  test('source keywords', () {
    expect(classifyPlaybackError('站源未返回播放地址'), PlaybackErrorKind.source);
    expect(classifyPlaybackError('取流失败 404'), PlaybackErrorKind.source);
  });

  test('unknown errors fall back to other without route suggestion', () {
    const kind = PlaybackErrorKind.other;
    expect(classifyPlaybackError('播放接收已取消'), kind);
    expect(classifyPlaybackError(''), kind);
    expect(kind.suggestRoute, isFalse);
    expect(kind.label, '播放失败');
  });

  test('route suggestion follows kind', () {
    expect(PlaybackErrorKind.source.suggestRoute, isTrue);
    expect(PlaybackErrorKind.decode.suggestRoute, isTrue);
    expect(PlaybackErrorKind.permission.suggestRoute, isTrue);
    expect(PlaybackErrorKind.network.suggestRoute, isFalse);
  });

  test('labels and suggestions are non-empty', () {
    for (final kind in PlaybackErrorKind.values) {
      expect(kind.label, isNotEmpty);
      expect(kind.suggestion, isNotEmpty);
    }
  });
}
