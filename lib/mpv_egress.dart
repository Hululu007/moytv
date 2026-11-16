import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'proxy_egress.dart';

/// 把一个 MPV（media_kit）播放器接到出口决策点。
///
/// 立即按当前决策设一次 `http-proxy`，之后决策变化时自动重设
///（经决策点的应用器登记表）。播放器销毁时调 [unbindMpvEgress] 摘掉登记。
///
/// MPV 在每次开流时读 `http-proxy`，播中途改地址下次开流才生效；
/// 直连时设空字符串清掉。非原生平台（Web 等）上 `platform` 不是
/// [NativePlayer]，调用是空操作。设属性失败静默（旧版 mpv 没有该属性
/// 也不应把播放器打断），是否真正生效以手机实测为准。
void bindMpvEgress(Player player) {
  Future<void> apply(String? httpProxyUrl) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty(
        'http-proxy',
        httpProxyUrl ?? '',
        waitForInitialization: true,
      );
    } catch (_) {}
  }

  ProxyEgressController.instance.registerMpvApplier(player, apply);
  unawaited(apply(ProxyEgressController.instance.decision.httpProxyUrl));
}

/// 摘掉 [bindMpvEgress] 登记的应用器（播放器销毁时调用）。
void unbindMpvEgress(Player player) {
  ProxyEgressController.instance.unregisterMpvApplier(player);
}
