import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

class MpvNetworkSample {
  const MpvNetworkSample({
    required this.uri,
    this.rawInputRate,
    this.totalBytes,
    this.cacheEndSeconds,
    this.bitrateBps,
  });

  final String uri;
  final double? rawInputRate;
  final double? totalBytes;
  final double? cacheEndSeconds;
  final double? bitrateBps;
}

class TimedMpvSample {
  const TimedMpvSample({required this.time, required this.sample});

  final DateTime time;
  final MpvNetworkSample sample;
}

double? _asDouble(dynamic value) {
  if (value is! num) return null;
  final parsed = value.toDouble();
  if (!parsed.isFinite || parsed < 0) return null;
  return parsed;
}

MpvNetworkSample? parseDemuxerCacheState(String uri, String raw) {
  try {
    final data = jsonDecode(raw);
    if (data is! Map) return null;
    final cacheEnd = _asDouble(data['cache-end']);
    final rawInputRate = _asDouble(data['raw-input-rate']);
    final totalBytes = _asDouble(data['total-bytes']);
    if (cacheEnd == null && rawInputRate == null && totalBytes == null) {
      return null;
    }
    return MpvNetworkSample(
      uri: uri,
      rawInputRate: rawInputRate,
      totalBytes: totalBytes,
      cacheEndSeconds: cacheEnd,
    );
  } catch (_) {
    return null;
  }
}

double? parseMpvBitrate(String? raw) {
  if (raw == null) return null;
  final value = double.tryParse(raw.trim());
  if (value == null || !value.isFinite || value <= 0) return null;
  return value;
}

double? computeNetworkSpeed(List<TimedMpvSample> samples) {
  if (samples.isEmpty) return null;
  final latest = samples.last.sample;
  final rawInputRate = latest.rawInputRate;
  if (rawInputRate != null && rawInputRate.isFinite && rawInputRate >= 0) {
    return rawInputRate;
  }
  final withBytes = samples.where((s) => s.sample.totalBytes != null).toList();
  if (withBytes.length >= 2) {
    final end = withBytes.last.time;
    final kept = withBytes
        .where((s) => end.difference(s.time) <= const Duration(seconds: 10))
        .toList();
    if (kept.length >= 2) {
      final span =
          kept.last.time.difference(kept.first.time).inMilliseconds / 1000;
      final delta =
          kept.last.sample.totalBytes! - kept.first.sample.totalBytes!;
      if (span >= 2 && delta >= 0) return delta / span;
    }
  }
  var cumulative = 0.0;
  double? previousEnd;
  final points = <({DateTime time, double cumulative})>[];
  for (final timed in samples) {
    final cacheEnd = timed.sample.cacheEndSeconds;
    if (cacheEnd == null) continue;
    if (previousEnd != null) {
      final delta = cacheEnd - previousEnd;
      if (delta >= 0 && delta <= 120) cumulative += delta;
    }
    previousEnd = cacheEnd;
    points.add((time: timed.time, cumulative: cumulative));
  }
  if (points.length >= 2) {
    final end = points.last.time;
    final kept = points
        .where((p) => end.difference(p.time) <= const Duration(seconds: 10))
        .toList();
    if (kept.length >= 2) {
      final span =
          kept.last.time.difference(kept.first.time).inMilliseconds / 1000;
      final delta = kept.last.cumulative - kept.first.cumulative;
      final bitrate = latest.bitrateBps;
      if (span >= 5 && delta >= 0 && bitrate != null && bitrate > 0) {
        return delta / span * bitrate / 8;
      }
    }
  }
  return null;
}

String formatNetworkSpeed(double bytesPerSecond) {
  if (!bytesPerSecond.isFinite || bytesPerSecond < 0) return '0 KB/s';
  if (bytesPerSecond < 1024) return '${bytesPerSecond.round()} B/s';
  if (bytesPerSecond < 1024 * 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
  }
  if (bytesPerSecond < 1024 * 1024 * 1024) {
    return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }
  return '${(bytesPerSecond / 1024 / 1024 / 1024).toStringAsFixed(1)} GB/s';
}

Future<MpvNetworkSample?> fetchMpvNetworkSpeedSample(Player player) async {
  final platform = player.platform;
  if (platform is! NativePlayer) return null;
  final state = player.state;
  if (!state.playing) return null;
  final playlist = state.playlist;
  if (playlist.medias.isEmpty ||
      playlist.index < 0 ||
      playlist.index >= playlist.medias.length) {
    return null;
  }
  final uri = playlist.medias[playlist.index].uri;
  final scheme = Uri.tryParse(uri)?.scheme ?? '';
  if (scheme == 'file') return null;
  try {
    final parsed = parseDemuxerCacheState(
      uri,
      await platform.getProperty('demuxer-cache-state'),
    );
    if (parsed == null) return null;
    final audio = parseMpvBitrate(await platform.getProperty('audio-bitrate'));
    final video = parseMpvBitrate(await platform.getProperty('video-bitrate'));
    final bitrate = (audio ?? 0) + (video ?? 0);
    return MpvNetworkSample(
      uri: uri,
      rawInputRate: parsed.rawInputRate,
      totalBytes: parsed.totalBytes,
      cacheEndSeconds: parsed.cacheEndSeconds,
      bitrateBps: bitrate > 0 ? bitrate : null,
    );
  } catch (_) {
    return null;
  }
}

class NetworkSpeedTracker {
  NetworkSpeedTracker({required this.sample, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Future<MpvNetworkSample?> Function() sample;
  final DateTime Function() _now;
  final ValueNotifier<String?> speedText = ValueNotifier<String?>(null);
  final List<TimedMpvSample> _samples = [];
  DateTime? _lastAttempt;
  String? _lastUri;
  bool _sampling = false;
  bool _disposed = false;

  Future<void> tick() async {
    if (_disposed || _sampling) return;
    final now = _now();
    if (_lastAttempt != null &&
        now.difference(_lastAttempt!) < const Duration(milliseconds: 900)) {
      return;
    }
    _lastAttempt = now;
    _sampling = true;
    try {
      final current = await sample();
      if (_disposed) return;
      if (current == null) {
        _samples.clear();
        _lastUri = null;
        _setText(null);
        return;
      }
      if (_lastUri != null && _lastUri != current.uri) _samples.clear();
      _lastUri = current.uri;
      if (_samples.isNotEmpty) {
        final previous = _samples.last.sample.cacheEndSeconds;
        final next = current.cacheEndSeconds;
        if (previous != null && next != null && next < previous - 1.0) {
          _samples.clear();
          _setText(null);
        }
      }
      _samples.add(TimedMpvSample(time: now, sample: current));
      final cutoff = now.subtract(const Duration(seconds: 15));
      _samples.removeWhere((s) => s.time.isBefore(cutoff));
      final bytes = computeNetworkSpeed(_samples);
      _setText(bytes == null ? null : formatNetworkSpeed(bytes));
    } catch (_) {
      _samples.clear();
      _lastUri = null;
      _setText(null);
    } finally {
      _sampling = false;
    }
  }

  void reset() {
    _samples.clear();
    _lastUri = null;
    _setText(null);
  }

  void dispose() {
    _disposed = true;
    speedText.dispose();
  }

  void _setText(String? value) {
    if (speedText.value != value) speedText.value = value;
  }
}

Widget networkSpeedLabel(ValueListenable<String?> speedText) {
  return ValueListenableBuilder<String?>(
    valueListenable: speedText,
    builder: (context, value, _) {
      if (value == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          value,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      );
    },
  );
}
