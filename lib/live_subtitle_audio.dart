import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:path_provider/path_provider.dart';

/// A 路并行取流：播放器不动，后台另起一路 FFmpeg，把同一个播放地址的
/// 音轨解成 16kHz 单声道 s16le，分片喂给识别引擎。
///
/// 实现：一个 FFmpeg 进程用 segment 复用器每 4 秒切一个原始音频片
/// （chunk_000.raw…），Dart 侧每 500ms 轮询工作目录，片写完即读出、
/// 删文件、往下游送。4 秒一片是延迟与上下文的折中：片太长则首条
/// 字幕等太久，片太短则 Whisper 上下文不够。
/// HLS 直播与点播 mp4/本地文件同一条命令（FFmpeg 自己认格式）。
/// 加密源（播放器侧解密）与需要登录 cookie 的源：cookie/请求头
/// 随 headers 一起带上；播放器侧用内存密钥解密的源取不到音轨，
/// 调用方应先判 decryptionKey，见 live_subtitle_service.dart。

class LiveSubtitleAudioException implements Exception {
  const LiveSubtitleAudioException(this.message);

  final String message;

  @override
  String toString() => 'LiveSubtitleAudioException: $message';
}

abstract class LiveSubtitleAudioExtractor {
  /// 产出 s16le 16kHz 单声道 PCM 块（每块约 4 秒音频）。
  /// 出错时流以 [LiveSubtitleAudioException] 结束。
  Stream<Uint8List> extract({
    required String url,
    required Map<String, String> headers,
  });

  Future<void> stop();
}

/// 片扫描器（纯逻辑，可单测）：按文件名序号排序，判断哪些片已写完。
/// 规则：一片只有在“出现更高序号的片”（FFmpeg 已切到下一片）
/// 或“进程已退出”时才算写完；正在写的片即使大小暂时不变也不取，
/// 否则尾巴会丢。
class LiveSubtitleChunkScanner {
  const LiveSubtitleChunkScanner();

  static final namePattern = RegExp(r'^chunk_(\d+)\.raw$');

  /// [files] 为工作目录当前的文件名集合（只要 chunk_*.raw）。
  /// [processExited] 为真时剩余的片全部可取。
  /// 返回按序号升序的可取片名。
  List<String> readyChunks(Set<String> files, {required bool processExited}) {
    final indexed = <int, String>{};
    for (final name in files) {
      final match = namePattern.firstMatch(name);
      if (match != null) indexed[int.parse(match.group(1)!)] = name;
    }
    if (indexed.isEmpty) return const [];
    final sorted = indexed.keys.toList()..sort();
    final max = sorted.last;
    final ready = <String>[];
    for (final index in sorted) {
      if (index < max || processExited) ready.add(indexed[index]!);
    }
    return ready;
  }
}

/// FFmpeg 运行器：起一个进程，跑完调 [onComplete]（参数为返回码，
/// 成功为 0），返回 session id（stop 时用来取消）。
/// 默认走 FFmpegKit；测试时注入假实现（往工作目录里写片文件，
/// 再调 onComplete(0)，模拟 FFmpeg 行为）。
typedef LiveSubtitleFfmpegRunner =
    Future<int?> Function(
      List<String> args, {
      required void Function(int? code) onComplete,
    });

class FfmpegLiveSubtitleAudioExtractor implements LiveSubtitleAudioExtractor {
  FfmpegLiveSubtitleAudioExtractor({
    LiveSubtitleFfmpegRunner? ffmpegRunner,
    Future<Directory> Function()? workDirProvider,
    this._pollInterval = const Duration(milliseconds: 500),
  }) : _ffmpegRunner = ffmpegRunner ?? _defaultRunner,
       _workDirProvider = workDirProvider ?? _defaultWorkDir;

  static const _segmentSeconds = 4;

  final LiveSubtitleFfmpegRunner _ffmpegRunner;
  final Future<Directory> Function() _workDirProvider;
  final Duration _pollInterval;
  final _scanner = LiveSubtitleChunkScanner();

  StreamController<Uint8List>? _controller;
  Timer? _timer;
  Directory? _workDir;
  int? _sessionId;
  bool _processExited = false;
  bool _stopped = false;
  final _yielded = <String>{};

  static Future<Directory> _defaultWorkDir() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/live_subtitle_chunks');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<int?> _defaultRunner(
    List<String> args, {
    required void Function(int? code) onComplete,
  }) async {
    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (result) async {
        try {
          final code = await result.getReturnCode();
          onComplete(code?.getValue());
        } catch (_) {
          onComplete(null);
        }
      },
    );
    return session.getSessionId();
  }

  @override
  Stream<Uint8List> extract({
    required String url,
    required Map<String, String> headers,
  }) {
    if (_controller != null) {
      throw const LiveSubtitleAudioException('取流已在进行中');
    }
    _stopped = false;
    _processExited = false;
    _yielded.clear();
    final controller = StreamController<Uint8List>();
    _controller = controller;
    unawaited(_run(url, headers, controller));
    return controller.stream;
  }

  Future<void> _run(
    String url,
    Map<String, String> headers,
    StreamController<Uint8List> controller,
  ) async {
    try {
      final dir = await _workDirProvider();
      _workDir = dir;
      if (!await dir.exists()) await dir.create(recursive: true);
      // 清掉上一轮残留的片，避免旧片混进新流。
      await for (final entity in dir.list()) {
        if (entity is File &&
            LiveSubtitleChunkScanner.namePattern.hasMatch(
              entity.path.split(Platform.pathSeparator).last,
            )) {
          await entity.delete();
        }
      }
      final headerLines = headers.entries
          .map((e) => '${e.key}: ${e.value}')
          .join('\r\n');
      final args = <String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-nostdin',
        if (headerLines.isNotEmpty) ...[
          '-headers',
          '$headerLines\r\n',
        ],
        '-reconnect',
        '1',
        '-reconnect_streamed',
        '1',
        '-reconnect_delay_max',
        '5',
        '-protocol_whitelist',
        'file,http,https,tcp,tls,crypto,data',
        '-i',
        url,
        '-vn',
        '-ac',
        '1',
        '-ar',
        '16000',
        '-f',
        'segment',
        '-segment_time',
        '$_segmentSeconds',
        '-segment_format',
        's16le',
        '-reset_timestamps',
        '1',
        '${dir.path}/chunk_%03d.raw',
      ];
      final done = Completer<int?>();
      _sessionId = await _ffmpegRunner(
        args,
        onComplete: (code) {
          if (!done.isCompleted) done.complete(code);
        },
      );
      _timer = Timer.periodic(_pollInterval, (_) => _poll(controller));
      final code = await done.future;
      _processExited = true;
      if (code != null && code != 0 && !_stopped) {
        _timer?.cancel();
        if (!controller.isClosed) {
          controller.addError(
            LiveSubtitleAudioException('取音轨失败（FFmpeg 返回 $code）'),
          );
          await controller.close();
        }
        return;
      }
      // 进程退出后把剩余的片一次性取完再关流。
      await _poll(controller, forceAll: true);
      if (!controller.isClosed) await controller.close();
    } catch (e) {
      if (!controller.isClosed) {
        controller.addError(
          e is LiveSubtitleAudioException
              ? e
              : LiveSubtitleAudioException('取音轨失败：$e'),
        );
        await controller.close();
      }
    } finally {
      _timer?.cancel();
      _timer = null;
      _controller = null;
    }
  }

  Future<void> _poll(
    StreamController<Uint8List> controller, {
    bool forceAll = false,
  }) async {
    final dir = _workDir;
    if (dir == null || controller.isClosed) return;
    try {
      final names = <String>{};
      await for (final entity in dir.list()) {
        if (entity is File) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (LiveSubtitleChunkScanner.namePattern.hasMatch(name)) {
            names.add(name);
          }
        }
      }
      final ready = _scanner.readyChunks(
        names,
        processExited: _processExited || forceAll,
      );
      for (final name in ready) {
        if (_yielded.contains(name)) continue;
        final file = File('${dir.path}/$name');
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        _yielded.add(name);
        await file.delete();
        if (bytes.isNotEmpty && !controller.isClosed) {
          controller.add(bytes);
        }
      }
    } catch (_) {
      // 轮询失败不致命：下一轮继续。
    }
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    final sessionId = _sessionId;
    if (sessionId != null) {
      try {
        await FFmpegKit.cancel(sessionId);
      } catch (_) {}
      _sessionId = null;
    }
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
    _controller = null;
  }
}
