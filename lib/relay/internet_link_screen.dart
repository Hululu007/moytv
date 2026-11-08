import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core_bridge.dart';
import '../import_center.dart';
import '../local_store.dart';
import '../relay_cf/cf_mailbox_client.dart';
import '../relay_cf/cf_relay_client.dart';
import '../relay_cf/cf_relay_constants.dart';
import 'relay_channel.dart';
import 'relay_message.dart';
import 'relay_settings.dart';

class InternetLinkScreen extends StatefulWidget {
  const InternetLinkScreen({
    super.key,
    required this.preferences,
    required this.store,
    required this.repository,
  });
  final SharedPreferences preferences;
  final LocalStore store;
  final AppRepository repository;

  @override
  State<InternetLinkScreen> createState() => _InternetLinkScreenState();
}

class _ReceivedFile {
  const _ReceivedFile(this.name, this.path, this.size);
  final String name;
  final String path;
  final int size;
}

class _InternetLinkScreenState extends State<InternetLinkScreen> {
  late final RelaySettings _settings = RelaySettings(widget.preferences);
  RelayChannel _channel = RelayChannel();
  bool _cfRoute = false;
  late final TextEditingController _url = TextEditingController();
  late final TextEditingController _selfId = TextEditingController();
  StreamSubscription<RelayMessage>? _subscription;
  final Set<String> _members = {};
  final Map<String, RelayFileAssembler> _incoming = {};
  final List<_ReceivedFile> _received = [];
  double _sendProgress = -1;
  String _sendLabel = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _url.text = _settings.storedUrl;
    _selfId.text = _settings.selfId;
    _channel.addListener(_onChannelChanged);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _channel.removeListener(_onChannelChanged);
    _channel.dispose();
    _url.dispose();
    _selfId.dispose();
    super.dispose();
  }

  void _onChannelChanged() {
    if (mounted) setState(() {});
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _shortId(String id) => id.length <= 8 ? id : id.substring(0, 8);

  void _ensureChannelFor(String effectiveUrl) {
    final wantCf = isCfRelayUrl(effectiveUrl);
    if (wantCf == _cfRoute && (_channel is CfRelayClient) == wantCf) {
      return;
    }
    _channel.removeListener(_onChannelChanged);
    _channel.dispose();
    _channel = wantCf ? CfRelayClient() : RelayChannel();
    _channel.addListener(_onChannelChanged);
    _cfRoute = wantCf;
  }

  Future<void> _connect() async {
    final typed = _url.text.trim();
    final selfId = _selfId.text.trim();
    if (selfId.isEmpty) {
      _showMessage('请先填写自建 ID');
      return;
    }
    final effectiveUrl = typed.isEmpty ? _settings.url : typed;
    if (typed.isNotEmpty) {
      await _settings.setUrl(typed);
    }
    await _settings.setSelfId(selfId);
    _ensureChannelFor(effectiveUrl);
    final deviceId = await _settings.ensureDeviceId();
    setState(() {
      _members.clear();
      _members.add(deviceId);
    });
    await _channel.connect(
      url: effectiveUrl,
      channelId: selfId,
      senderId: deviceId,
    );
    if (!mounted) return;
    if (_channel.connected) {
      _subscription?.cancel();
      _subscription = _channel.messages.listen(_onMessage);
      setState(() {});
    } else {
      _showMessage(_channel.error);
    }
  }

  Future<void> _disconnect() async {
    await _subscription?.cancel();
    _subscription = null;
    await _channel.disconnect();
    _cfRoute = false;
    if (mounted) {
      setState(() {
        _members.clear();
        _incoming.clear();
      });
    }
  }

  Future<void> _onMessage(RelayMessage message) async {
    if (message.sender == _channel.senderId &&
        message.type != RelayMessage.listType) {
      return;
    }
    switch (message.type) {
      case RelayMessage.joinType:
        final sender = message.payload['sender'];
        if (sender is String && sender.isNotEmpty) {
          setState(() => _members.add(sender));
        }
      case RelayMessage.leaveType:
        final sender = message.payload['sender'];
        if (sender is String) {
          setState(() => _members.remove(sender));
        }
      case RelayMessage.listType:
        final members = message.payload['members'];
        if (members is List) {
          setState(() {
            for (final member in members) {
              if (member is String) {
                _members.add(member);
              } else if (member is Map<String, dynamic>) {
                final id = member['id'];
                if (id is String && id.isNotEmpty) {
                  _members.add(id);
                }
              }
            }
          });
        }
      case RelayMessage.fileOfferType:
        final id = message.id;
        final name = message.payload['name'];
        final size = message.payload['size'];
        if (name is! String || size is! int) return;
        if (size <= 0 || size > RelayFileAssembler.maxSize) return;
        if (message.to.isNotEmpty && message.to != _channel.senderId) return;
        final ticket = message.payload['ticket'];
        if (ticket is String && ticket.isNotEmpty) {
          await _receiveMailboxOffer(ticket: ticket, name: name, size: size);
          return;
        }
        if (id.isEmpty) return;
        setState(() {
          _incoming[id] = RelayFileAssembler(id: id, name: name, size: size);
        });
      case RelayMessage.fileChunkType:
        final assembler = _incoming[message.id];
        if (assembler == null) return;
        if (message.to.isNotEmpty && message.to != _channel.senderId) return;
        final index = message.payload['index'];
        final data = message.payload['data'];
        if (index is! int || data is! String) return;
        try {
          assembler.addChunk(index, data);
        } catch (_) {
          setState(() => _incoming.remove(message.id));
          return;
        }
        setState(() {});
      case RelayMessage.fileEndType:
        final assembler = _incoming.remove(message.id);
        if (assembler == null || !assembler.complete) return;
        try {
          final bytes = assembler.assemble();
          await _saveReceived(assembler.name, bytes);
        } catch (error) {
          if (mounted) _showMessage('接收失败：$error');
        }
    }
  }

  Future<void> _saveReceived(String name, List<int> bytes) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'relay_received'));
    await dir.create(recursive: true);
    final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final target = File(p.join(dir.path, safeName.isEmpty ? 'file' : safeName));
    await target.writeAsBytes(bytes);
    if (!mounted) return;
    setState(() {
      _received.insert(0, _ReceivedFile(name, target.path, bytes.length));
    });
    _showMessage('已接收 $name');
  }

  Future<void> _receiveMailboxOffer({
    required String ticket,
    required String name,
    required int size,
  }) async {
    final mailbox = CfMailboxClient(httpBase: cfHttpBaseForWs(cfRelayWsUrl));
    try {
      final download = await mailbox.fetchDownload(ticket);
      if (download.size != size) {
        if (mounted) _showMessage('接收失败：文件大小与取件票不一致');
        return;
      }
      final bytes = await mailbox.downloadFile(
        downloadUrl: download.downloadUrl,
      );
      if (bytes.length != size) {
        if (mounted) _showMessage('接收失败：文件大小与取件票不一致');
        return;
      }
      await _saveReceived(name, bytes);
      await mailbox.deleteTicket(ticket);
    } on CfMailboxUnavailable {
      if (mounted) _showMessage('文件传输暂不可用：中转邮箱未启用');
    } catch (error) {
      if (mounted) _showMessage('接收失败：$error');
    } finally {
      mailbox.close();
    }
  }

  Future<void> _sendFile() async {
    if (!_channel.connected) {
      _showMessage('请先连接');
      return;
    }
    final picked = await FilePicker.pickFiles(type: FileType.any);
    if (picked.isEmpty) return;
    final path = picked.single.path;
    if (path == null) return;
    final file = File(path);
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > RelayFileAssembler.maxSize) {
      _showMessage('文件为空或超过 32MB 上限');
      return;
    }
    final name = p.basename(path);
    final id =
        '${DateTime.now().millisecondsSinceEpoch}-${_channel.senderId.substring(0, 8)}';
    setState(() {
      _busy = true;
      _sendLabel = name;
      _sendProgress = 0;
    });
    try {
      if (_cfRoute) {
        await _sendFileViaMailbox(name: name, bytes: bytes, id: id);
      } else {
        _channel.sendMessage(RelayMessage.fileOfferType, {
          'name': name,
          'size': bytes.length,
        }, id: id);
        final chunks = relayFileChunks(id: id, bytes: bytes);
        for (var i = 0; i < chunks.length; i++) {
          _channel.sendMessage(RelayMessage.fileChunkType, chunks[i], id: id);
          setState(() => _sendProgress = (i + 1) / chunks.length);
        }
        _channel.sendMessage(RelayMessage.fileEndType, {}, id: id);
      }
      _showMessage('已发送 $name');
    } on CfMailboxUnavailable {
      _showMessage('文件传输暂不可用：中转邮箱未启用');
    } catch (error) {
      _showMessage('发送失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _sendProgress = -1;
          _sendLabel = '';
        });
      }
    }
  }

  Future<void> _sendFileViaMailbox({
    required String name,
    required List<int> bytes,
    required String id,
  }) async {
    final mailbox = CfMailboxClient(httpBase: cfHttpBaseForWs(cfRelayWsUrl));
    try {
      final ticket = await mailbox.createTicket(name: name, size: bytes.length);
      setState(() => _sendProgress = 0.5);
      await mailbox.uploadFile(uploadUrl: ticket.uploadUrl, bytes: bytes);
      setState(() => _sendProgress = 1);
      _channel.sendMessage(RelayMessage.fileOfferType, {
        'ticket': ticket.ticket,
        'name': name,
        'size': bytes.length,
      }, id: id);
    } finally {
      mailbox.close();
    }
  }

  Future<void> _importReceived(_ReceivedFile file) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await File(file.path).readAsBytes();
      final engine = ImportEngine(
        store: widget.store,
        repository: widget.repository,
      );
      final report = await engine.importAll([
        ImportCandidate(name: file.name, bytes: bytes),
      ]);
      if (mounted) _showMessage(report.summary);
    } catch (error) {
      if (mounted) _showMessage('导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = _channel.connected;
    final connecting = _channel.state == RelayConnectionState.connecting;
    return Scaffold(
      appBar: AppBar(title: const Text('设备互联 · 互联网')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('输入自建 ID，相同 ID 的设备通过中转建立通信、互传文件。'),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '中转地址 (ws/wss)',
              hintText: '留空使用内置中转',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _selfId,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: '自建 ID',
              hintText: '与对方填相同的 ID 即可配对',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: '随机生成',
                onPressed: () {
                  setState(() => _selfId.text = _settings.randomPairId());
                },
                icon: const Icon(Icons.casino_outlined),
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: connecting
                ? null
                : connected
                ? () => unawaited(_disconnect())
                : () => unawaited(_connect()),
            icon: Icon(connected ? Icons.link_off_rounded : Icons.link_rounded),
            label: Text(
              connecting
                  ? '连接中…'
                  : connected
                  ? '断开'
                  : '连接',
            ),
          ),
          if (_channel.error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _channel.error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 24),
          Text(
            '同 ID 设备（${_members.length}）',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (_members.isEmpty)
            const Text('未连接')
          else
            for (final member in _members)
              ListTile(
                leading: const Icon(Icons.devices_rounded),
                title: Text(
                  member == _channel.senderId
                      ? '本机 · ${_shortId(member)}'
                      : _shortId(member),
                ),
              ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _busy ? null : () => unawaited(_sendFile()),
            icon: const Icon(Icons.upload_rounded),
            label: const Text('发送文件'),
          ),
          if (_sendProgress >= 0) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _sendProgress),
            const SizedBox(height: 4),
            Text('正在发送 $_sendLabel'),
          ],
          const SizedBox(height: 24),
          Text(
            '已接收（${_received.length}）',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (_received.isEmpty)
            const Text('还没有收到文件')
          else
            for (final file in _received)
              ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: Text(file.name),
                subtitle: Text('${file.size} 字节 · ${file.path}'),
                trailing: file.name.toLowerCase().endsWith('.py')
                    ? IconButton(
                        tooltip: '导入为站源',
                        onPressed: _busy
                            ? null
                            : () => unawaited(_importReceived(file)),
                        icon: const Icon(Icons.download_rounded),
                      )
                    : null,
              ),
        ],
      ),
    );
  }
}
