import 'dart:convert';
import 'dart:io';

import '../relay/relay_message.dart';

class CfMailboxUnavailable extends HttpException {
  CfMailboxUnavailable() : super('mailbox not configured');
}

class CfMailboxTicket {
  const CfMailboxTicket({
    required this.ticket,
    required this.uploadUrl,
    required this.name,
    required this.size,
    required this.expiresAt,
  });

  final String ticket;
  final String uploadUrl;
  final String name;
  final int size;
  final int expiresAt;
}

class CfMailboxDownload {
  const CfMailboxDownload({
    required this.downloadUrl,
    required this.name,
    required this.size,
    required this.expiresAt,
  });

  final String downloadUrl;
  final String name;
  final int size;
  final int expiresAt;
}

class CfMailboxClient {
  CfMailboxClient({required String httpBase})
    : _httpBase = httpBase.endsWith('/')
          ? httpBase.substring(0, httpBase.length - 1)
          : httpBase;

  final String _httpBase;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final uri = Uri.parse('$_httpBase$path');
    final request = await _http.openUrl(method, uri);
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    if (body != null) {
      request.add(utf8.encode(jsonEncode(body)));
    }
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode == 503) {
      throw CfMailboxUnavailable();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'mailbox $method $path failed: ${response.statusCode} $text',
      );
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('mailbox response is not an object');
    }
    return decoded;
  }

  Future<CfMailboxTicket> createTicket({
    required String name,
    required int size,
  }) async {
    if (name.isEmpty || size <= 0 || size > RelayFileAssembler.maxSize) {
      throw ArgumentError('mailbox file is out of range');
    }
    final data = await _requestJson('POST', '/mailbox/tickets', {
      'name': name,
      'size': size,
    });
    final ticket = data['ticket'];
    final uploadUrl = data['uploadUrl'];
    final expiresAt = data['expiresAt'];
    if (ticket is! String || uploadUrl is! String || expiresAt is! int) {
      throw const FormatException('mailbox ticket is invalid');
    }
    return CfMailboxTicket(
      ticket: ticket,
      uploadUrl: uploadUrl,
      name: name,
      size: size,
      expiresAt: expiresAt,
    );
  }

  Future<CfMailboxDownload> fetchDownload(String ticket) async {
    final data = await _requestJson('GET', '/mailbox/tickets/$ticket');
    final downloadUrl = data['downloadUrl'];
    final name = data['name'];
    final size = data['size'];
    final expiresAt = data['expiresAt'];
    if (downloadUrl is! String ||
        name is! String ||
        size is! int ||
        expiresAt is! int) {
      throw const FormatException('mailbox download is invalid');
    }
    return CfMailboxDownload(
      downloadUrl: downloadUrl,
      name: name,
      size: size,
      expiresAt: expiresAt,
    );
  }

  Future<void> deleteTicket(String ticket) async {
    try {
      await _requestJson('DELETE', '/mailbox/tickets/$ticket');
    } on HttpException {
      // ignore
    }
  }

  Future<void> uploadFile({
    required String uploadUrl,
    required List<int> bytes,
  }) async {
    if (bytes.isEmpty || bytes.length > RelayFileAssembler.maxSize) {
      throw ArgumentError('mailbox file is out of range');
    }
    final request = await _http.putUrl(Uri.parse(uploadUrl));
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw HttpException('mailbox upload failed: ${response.statusCode}');
    }
  }

  Future<List<int>> downloadFile({required String downloadUrl}) async {
    final request = await _http.getUrl(Uri.parse(downloadUrl));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('mailbox download failed: ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > RelayFileAssembler.maxSize) {
        throw const HttpException('mailbox file is too large');
      }
    }
    return bytes;
  }

  void close() {
    _http.close(force: true);
  }
}
