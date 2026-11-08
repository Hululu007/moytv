import 'dart:async';
import 'dart:convert';
import 'dart:io';

class DownloadProgress {
  const DownloadProgress(this.received, this.total);

  final int received;
  final int total;

  double? get fraction => total > 0 ? received / total : null;
}

Future<String> fetchUpdateText(
  String url, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 30),
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        '请求失败（HTTP ${response.statusCode}）',
        uri: Uri.parse(url),
      );
    }
    return body;
  } finally {
    client.close(force: true);
  }
}

class ResumableDownloader {
  ResumableDownloader({
    HttpClient Function()? clientFactory,
    this.maxAttempts = 4,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;
  final int maxAttempts;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
  }

  Future<File> download({
    required String url,
    required File target,
    void Function(DownloadProgress progress)? onProgress,
    Map<String, String> headers = const {},
  }) async {
    final part = File('${target.path}.part');
    await part.parent.create(recursive: true);
    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (_cancelled) throw StateError('下载已取消');
      try {
        await _attempt(url, part, headers, onProgress);
        if (_cancelled) throw StateError('下载已取消');
        if (await target.exists()) await target.delete();
        return await part.rename(target.path);
      } on StateError {
        rethrow;
      } catch (error) {
        lastError = error;
        if (attempt + 1 < maxAttempts) {
          await Future<void>.delayed(Duration(seconds: 1 + attempt));
        }
      }
    }
    throw StateError('下载失败：${lastError ?? '网络错误'}');
  }

  Future<void> _attempt(
    String url,
    File part,
    Map<String, String> headers,
    void Function(DownloadProgress progress)? onProgress,
  ) async {
    var resumeFrom = await part.exists() ? await part.length() : 0;
    final client = _clientFactory();
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(url));
      headers.forEach(request.headers.set);
      if (resumeFrom > 0) {
        request.headers.set('Range', 'bytes=$resumeFrom-');
      }
      final response = await request.close();
      if (response.statusCode == 416) {
        await part.delete();
        throw const HttpException('本地分片已失效，重新下载');
      }
      if (response.statusCode == 200) {
        resumeFrom = 0;
      } else if (response.statusCode != 206) {
        throw HttpException('下载失败（HTTP ${response.statusCode}）');
      }
      var total = response.contentLength;
      final range = response.headers.value('content-range');
      if (range != null) {
        final slash = range.lastIndexOf('/');
        final parsed = slash >= 0
            ? int.tryParse(range.substring(slash + 1))
            : null;
        if (parsed != null && parsed > 0) total = parsed;
      } else if (total > 0) {
        total += resumeFrom;
      }
      sink = part.openWrite(
        mode: resumeFrom > 0 ? FileMode.append : FileMode.write,
      );
      var received = resumeFrom;
      await for (final chunk in response) {
        if (_cancelled) throw StateError('下载已取消');
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(DownloadProgress(received, total));
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (total > 0 && received != total) {
        throw const HttpException('下载不完整');
      }
    } finally {
      await sink?.close();
      client.close(force: true);
    }
  }
}
