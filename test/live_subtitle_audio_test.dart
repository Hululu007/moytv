import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/live_subtitle_audio.dart';

void main() {
  test('一片只有在更高序号的片出现后才算写完', () {
    const scanner = LiveSubtitleChunkScanner();
    expect(
      scanner.readyChunks({'chunk_000.raw'}, processExited: false),
      isEmpty,
    );
    expect(
      scanner.readyChunks(
        {'chunk_000.raw', 'chunk_001.raw'},
        processExited: false,
      ),
      ['chunk_000.raw'],
    );
    expect(
      scanner.readyChunks(
        {'chunk_001.raw', 'chunk_003.raw'},
        processExited: false,
      ),
      ['chunk_001.raw'],
    );
    expect(
      scanner.readyChunks({'chunk_000.raw', 'other.txt'}, processExited: false),
      isEmpty,
    );
  });

  test('进程退出后剩余的片全部可取', () {
    const scanner = LiveSubtitleChunkScanner();
    expect(
      scanner.readyChunks({'chunk_002.raw'}, processExited: true),
      ['chunk_002.raw'],
    );
    expect(
      scanner.readyChunks(
        {'chunk_000.raw', 'chunk_001.raw', 'chunk_002.raw'},
        processExited: true,
      ),
      ['chunk_000.raw', 'chunk_001.raw', 'chunk_002.raw'],
    );
  });

  test('空目录与乱序文件名', () {
    const scanner = LiveSubtitleChunkScanner();
    expect(scanner.readyChunks({}, processExited: true), isEmpty);
    expect(
      scanner.readyChunks(
        {'chunk_010.raw', 'chunk_002.raw', 'chunk_003.raw'},
        processExited: false,
      ),
      ['chunk_002.raw', 'chunk_003.raw'],
    );
  });
}
