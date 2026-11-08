import 'dart:async';

import '../app_page_route.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../local_store.dart';
import '../models.dart';
import '../relay/relay_settings.dart';
import '../relay_cf/cf_relay_constants.dart';
import '../tvbox_player_bridge.dart';
import 'controller.dart';
import 'models.dart';
import 'player.dart';
import 'room_fullscreen_page.dart';
import '../playback_foreground.dart';

class WatchRoomScreen extends StatefulWidget {
  const WatchRoomScreen({
    super.key,
    required this.repository,
    required this.store,
  });

  final AppRepository repository;
  final LocalStore store;

  @override
  State<WatchRoomScreen> createState() => _WatchRoomScreenState();
}

class _WatchRoomScreenState extends State<WatchRoomScreen>
    with WidgetsBindingObserver {
  final WatchRoomController _room = WatchRoomController.instance;
  final RoomPlayerHandle _player = RoomPlayerHandle();
  final TextEditingController _chatText = TextEditingController();
  final TextEditingController _roomNumber = TextEditingController();
  DramaDetail? _detail;
  String _loadedKey = '';
  bool _loadingDetail = false;
  String? _detailError;
  String? _entryError;
  bool _busy = false;
  bool _dragging = false;
  double _dragValue = 0;
  bool _autoFollow = false;
  bool _lastBroadcastPlaying = false;
  bool _playbackServiceHeld = false;
  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    _autoFollow = RelaySettings(widget.store.preferences).autoFollow;
    _room.addListener(_onRoomChanged);
    _player.addListener(_onPlayerChanged);
    WidgetsBinding.instance.addObserver(this);
    _player.onCompleted = _onCompleted;
    _syncTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_room.isHost && _player.hasVideo && _player.playing) {
        _room.broadcastPlayState(playing: true, position: _player.position);
      }
    });
    if (_room.inRoom && _room.video != null) {
      _loadVideo();
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _room.removeListener(_onRoomChanged);
    _player.removeListener(_onPlayerChanged);
    WidgetsBinding.instance.removeObserver(this);
    if (_playbackServiceHeld) {
      _playbackServiceHeld = false;
      unawaited(PlaybackForeground.release());
    }
    _player.dispose();
    _chatText.dispose();
    _roomNumber.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (!_playbackServiceHeld &&
          shouldAcquirePlaybackService(
            playing: _player.playing,
            useTvbox: _player.useTvbox,
          )) {
        _playbackServiceHeld = true;
        unawaited(PlaybackForeground.acquire('一起看 · ${_room.roomId}'));
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_playbackServiceHeld) {
        _playbackServiceHeld = false;
        unawaited(PlaybackForeground.release());
      }
    }
  }

  void _onRoomChanged() {
    if (!mounted) return;
    if (!_room.inRoom) {
      setState(() {
        _detail = null;
        _loadedKey = '';
      });
      return;
    }
    final video = _room.video;
    if (video == null) {
      if (_loadedKey.isNotEmpty) {
        _loadedKey = '';
        _detail = null;
        unawaited(_player.close());
      }
      setState(() {});
      return;
    }
    if (video.key != _loadedKey) {
      _loadVideo();
      return;
    }
    if (!_room.isHost && _autoFollow) {
      _applyRemoteState();
    } else {
      setState(() {});
    }
  }

  void _onPlayerChanged() {
    if (!mounted) return;
    if (_room.isHost && _player.hasVideo) {
      final playing = _player.playing;
      if (playing != _lastBroadcastPlaying) {
        _lastBroadcastPlaying = playing;
        _room.broadcastPlayState(playing: playing, position: _player.position);
      }
    }
    setState(() {});
  }

  void _onCompleted() {
    if (!_room.isHost) return;
    final detail = _detail;
    final video = _room.video;
    if (detail == null || video == null) return;
    if (video.episodeIndex + 1 < detail.episodes.length) {
      final next = detail.episodes[video.episodeIndex + 1];
      _room.setVideo(
        RoomVideo(
          source: video.source,
          dramaId: video.dramaId,
          title: video.title,
          cover: video.cover,
          sourceId: video.sourceId,
          episodeIndex: video.episodeIndex + 1,
          episodeTitle: next.title,
        ),
      );
    }
  }

  Future<void> _loadVideo() async {
    final video = _room.video;
    if (video == null) return;
    _loadedKey = video.key;
    setState(() {
      _loadingDetail = true;
      _detailError = null;
    });
    try {
      final detail = await widget.repository.detail(
        Drama(
          id: video.dramaId,
          source: video.source,
          sourceId: video.sourceId,
          title: video.title,
          cover: video.cover,
        ),
      );
      if (!mounted) return;
      _detail = detail;
      setState(() => _loadingDetail = false);
      await _player.open(
        detail: detail,
        episodeIndex: video.episodeIndex,
        startPosition: _room.playState.position,
        repository: widget.repository,
        store: widget.store,
      );
      _lastBroadcastPlaying = _player.playing;
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingDetail = false;
        _detailError = error.toString();
      });
    }
  }

  Future<void> _applyRemoteState() async {
    if (_room.isHost || _dragging) return;
    final state = _room.playState;
    if (!_player.hasVideo) return;
    if (state.playing != _player.playing) {
      if (state.playing) {
        await _player.play();
      } else {
        await _player.pause();
      }
    }
    if ((state.position - _player.position).abs() > 3) {
      await _player.seek(state.position);
    }
  }

  Future<void> _togglePlay() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
    _room.broadcastPlayState(
      playing: _player.playing,
      position: _player.position,
    );
  }

  Future<void> _seekTo(double value) async {
    await _player.seek(value);
    _room.broadcastPlayState(playing: _player.playing, position: value);
  }

  void _switchEpisode(int delta) {
    final detail = _detail;
    final video = _room.video;
    if (detail == null || video == null) return;
    final nextIndex = video.episodeIndex + delta;
    if (nextIndex < 0 || nextIndex >= detail.episodes.length) return;
    final next = detail.episodes[nextIndex];
    _room.setVideo(
      RoomVideo(
        source: video.source,
        dramaId: video.dramaId,
        title: video.title,
        cover: video.cover,
        sourceId: video.sourceId,
        episodeIndex: nextIndex,
        episodeTitle: next.title,
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _createRoom() async {
    setState(() {
      _busy = true;
      _entryError = null;
    });
    try {
      await _room.createRoom(preferences: widget.store.preferences);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        setState(() => _entryError = error.toString());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _joinRoom() async {
    final number = _roomNumber.text.trim();
    if (number.isEmpty) {
      setState(() => _entryError = '请先填写房间号');
      return;
    }
    setState(() {
      _busy = true;
      _entryError = null;
    });
    try {
      await _room.joinRoom(preferences: widget.store.preferences, room: number);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        setState(() => _entryError = error.toString());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _joinPublicRoom() async {
    setState(() {
      _busy = true;
      _entryError = null;
    });
    try {
      await _room.joinPublicRoom(preferences: widget.store.preferences);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        setState(() => _entryError = error.toString());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leaveRoom() async {
    await _player.close();
    await _room.leaveRoom();
    if (mounted) setState(() {});
  }

  Future<void> _toggleAutoFollow(bool value) async {
    await RelaySettings(widget.store.preferences).setAutoFollow(value);
    setState(() => _autoFollow = value);
    if (value) _applyRemoteState();
  }

  String _shortId(String id) => id.length <= 8 ? id : id.substring(0, 8);

  String _formatTime(double seconds) {
    final total = seconds.round();
    final minutes = total ~/ 60;
    final rest = total % 60;
    return '$minutes:${rest.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_room.inRoom ? '一起看 · ${_room.roomId}' : '一起看'),
        actions: [
          if (_room.inRoom) ...[
            IconButton(
              tooltip: '复制房间号',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _room.roomId));
                _showMessage('房间号已复制');
              },
              icon: const Icon(Icons.copy_rounded),
            ),
            IconButton(
              tooltip: '退出房间',
              onPressed: () => unawaited(_leaveRoom()),
              icon: const Icon(Icons.logout_rounded),
            ),
          ],
        ],
      ),
      body: _room.inRoom ? _roomBody() : _entryBody(),
    );
  }

  Widget _entryBody() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('新建房间出房间号，别人凭房间号进房，一起看同一视频。'),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : () => unawaited(_createRoom()),
          icon: const Icon(Icons.add_rounded),
          label: const Text('新建房间'),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _roomNumber,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '房间号',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : () => unawaited(_joinRoom()),
          icon: const Icon(Icons.login_rounded),
          label: const Text('加入房间'),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : () => unawaited(_joinPublicRoom()),
          icon: const Icon(Icons.group_rounded),
          label: const Text('进入公用房间（$cfPublicRoomId）'),
        ),
        if (_entryError != null) ...[
          const SizedBox(height: 12),
          Text(
            _entryError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (_room.channelError.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            _room.channelError,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 12),
        const Text('公用房间无密码，知道号码即可进；新建与加入房间走内置中转，无需另填地址。'),
      ],
    );
  }

  void _openRoomFullscreen() {
    if (_player.useTvbox) {
      _player.tvboxStartPosition = _player.tvboxHandle.positionSeconds;
    }
    Navigator.push(
      context,
      appPageRoute<void>(
        builder: (_) => RoomFullscreenPage(
          handle: _player,
          viewType: TvboxPlayerController.viewType,
          onCompleted: _onCompleted,
          onError: (message) => _showMessage(message),
          onRetry: () {
            _loadedKey = '';
            _loadVideo();
          },
        ),
      ),
    );
  }

  Widget _roomBody() {
    final video = _room.video;
    final state = _room.playState;
    final duration = _player.duration;
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: RoomPlayerView(
            handle: _player,
            viewType: TvboxPlayerController.viewType,
            onCompleted: _onCompleted,
            onError: (message) => _showMessage(message),
            onRetry: () {
              _loadedKey = '';
              _loadVideo();
            },
            onFullscreen: _openRoomFullscreen,
          ),
        ),
        if (_loadingDetail)
          const LinearProgressIndicator()
        else if (_detailError != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _detailError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                video == null
                    ? '等待房主推送视频'
                    : '${video.title} · ${video.episodeTitle}',
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  if (_room.isHost)
                    const Chip(label: Text('房主'))
                  else
                    const Chip(label: Text('观众')),
                  const SizedBox(width: 8),
                  Text(
                    state.playing
                        ? '播放中 ${_formatTime(state.position)}'
                        : '已暂停 ${_formatTime(state.position)}',
                  ),
                  const Spacer(),
                  if (_room.isHost) ...[
                    IconButton(
                      tooltip: '上一集',
                      onPressed: () => _switchEpisode(-1),
                      icon: const Icon(Icons.skip_previous_rounded),
                    ),
                    IconButton(
                      tooltip: _player.playing ? '暂停' : '播放',
                      onPressed: _player.hasVideo
                          ? () => unawaited(_togglePlay())
                          : null,
                      icon: Icon(
                        _player.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                    IconButton(
                      tooltip: '下一集',
                      onPressed: () => _switchEpisode(1),
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                  ] else ...[
                    TextButton.icon(
                      onPressed: _player.hasVideo
                          ? () => unawaited(_applyRemoteState())
                          : null,
                      icon: const Icon(Icons.sync_rounded),
                      label: const Text('跟随播放'),
                    ),
                  ],
                ],
              ),
              StreamBuilder<double>(
                stream: _player.positionStream,
                builder: (context, snapshot) {
                  final position = _dragging
                      ? _dragValue
                      : snapshot.data ?? _player.position;
                  final max = duration > 0 ? duration : 1.0;
                  return Row(
                    children: [
                      Text(_formatTime(position)),
                      Expanded(
                        child: Slider(
                          value: position.clamp(0.0, max),
                          max: max,
                          onChangeStart: (_) => _dragging = true,
                          onChanged: (value) {
                            setState(() => _dragValue = value);
                          },
                          onChangeEnd: (value) {
                            _dragging = false;
                            if (_room.isHost) {
                              unawaited(_seekTo(value));
                            }
                          },
                        ),
                      ),
                      Text(_formatTime(duration)),
                    ],
                  );
                },
              ),
              Row(
                children: [
                  for (final member in _room.members)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Chip(
                        label: Text(
                          member.id == _room.deviceId
                              ? '我'
                              : _shortId(member.id),
                        ),
                        avatar: member.id == _room.hostId
                            ? const Icon(Icons.star_rounded, size: 16)
                            : null,
                      ),
                    ),
                  const Spacer(),
                  if (!_room.isHost) ...[
                    const Text('自动跟随'),
                    Switch(
                      value: _autoFollow,
                      onChanged: (value) => unawaited(_toggleAutoFollow(value)),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: _room.chat.isEmpty
              ? const Center(child: Text('还没有聊天消息'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _room.chat.length,
                  itemBuilder: (context, index) {
                    final message = _room.chat[index];
                    final mine = message.sender == _room.deviceId;
                    return Align(
                      alignment: mine
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: mine
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          mine
                              ? message.text
                              : '${_shortId(message.sender)}：${message.text}',
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatText,
                  decoration: const InputDecoration(
                    hintText: '发消息…',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _sendChat(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '发送',
                onPressed: _sendChat,
                icon: const Icon(Icons.send_rounded),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _sendChat() {
    final text = _chatText.text;
    if (text.trim().isEmpty) return;
    _room.sendChat(text);
    _chatText.clear();
    setState(() {});
  }
}
