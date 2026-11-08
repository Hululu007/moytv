import 'package:moyi/media_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeExecutor implements MediaExecutor {
  List<String>? runArgs;
  MediaProbe probeResult = MediaProbe({
    'format': {'duration': '60.0'},
    'streams': [
      {'codec_type': 'video', 'codec_name': 'h264'},
    ],
  });

  @override
  Future<MediaProbe> probe(String file) async => probeResult;

  @override
  Future<void> run(
    List<String> arguments, {
    double duration = 0,
    void Function(double)? progress,
  }) async {
    runArgs = arguments;
  }

  @override
  Future<void> cancel() async {}
}

void main() {
  test('remux arguments copy and regenerate timestamps', () {
    final args = remuxHlsArguments('/data/job1');
    expect(args.first, '-i');
    expect(args[1], '/data/job1/index.m3u8');
    expect(args, contains('-c'));
    expect(args[args.indexOf('-c') + 1], 'copy');
    expect(args, contains('+genpts'));
    expect(args, contains('make_zero'));
    expect(args.last, '/data/job1/remuxed.mp4');
  });

  test('remux returns the output after probe validation', () async {
    final executor = _FakeExecutor();
    final output = await remuxHlsDirectory('/data/job1', executor: executor);
    expect(output, '/data/job1/remuxed.mp4');
    expect(executor.runArgs, remuxHlsArguments('/data/job1'));
  });

  test('remux fails when the probe has no video track', () async {
    final executor = _FakeExecutor()
      ..probeResult = MediaProbe({
        'format': {'duration': '60.0'},
        'streams': [
          {'codec_type': 'audio', 'codec_name': 'aac'},
        ],
      });
    await expectLater(
      remuxHlsDirectory('/data/job1', executor: executor),
      throwsA(isA<Exception>()),
    );
  });
}
