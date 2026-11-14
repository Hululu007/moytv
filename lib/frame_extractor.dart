import 'dart:async';

import 'package:flutter/services.dart';

import 'models.dart';

/// 选集卡真帧提取：经平台通道调 Android 原生 MediaMetadataRetriever，
/// 取 [PlaybackPlan.url] 在 [at] 处的一帧，返回 JPEG 字节。
///
/// 任何失败（无原生桥、超时、解析失败、无帧、黑帧）都只返回 null，
/// 调用方静默回落海报，绝不抛错、绝不拿海报冒充帧。
class FrameExtractor {
  FrameExtractor({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('moyi/frame_extractor');

  final MethodChannel _channel;

  Future<Uint8List?> extract(
    PlaybackPlan plan, {
    Duration at = const Duration(seconds: 5),
  }) async {
    if (plan.url.isEmpty) return null;
    try {
      final bytes = await _channel
          .invokeMethod<Uint8List>('extractFrame', {
            'url': plan.url,
            'headers': plan.headers,
            'positionUs': at.inMicroseconds,
          })
          .timeout(const Duration(seconds: 25));
      if (bytes == null || bytes.isEmpty) return null;
      return bytes;
    } catch (_) {
      // 原生侧无此通道、超时或取帧失败：回落海报。
      return null;
    }
  }
}
