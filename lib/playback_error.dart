enum PlaybackErrorKind { network, source, decode, permission, other }

extension PlaybackErrorKindText on PlaybackErrorKind {
  String get label => switch (this) {
    PlaybackErrorKind.network => '网络问题',
    PlaybackErrorKind.source => '站源问题',
    PlaybackErrorKind.decode => '解码问题',
    PlaybackErrorKind.permission => '权限问题',
    PlaybackErrorKind.other => '播放失败',
  };

  String get suggestion => switch (this) {
    PlaybackErrorKind.network => '请检查网络后重试',
    PlaybackErrorKind.source => '可换一集、换线路或换源试试',
    PlaybackErrorKind.decode => '可换清晰度、换线路或换一集试试',
    PlaybackErrorKind.permission => '可能需要登录或开通权限，可换线路试试',
    PlaybackErrorKind.other => '可重试或换一集试试',
  };

  bool get suggestRoute => switch (this) {
    PlaybackErrorKind.source ||
    PlaybackErrorKind.decode ||
    PlaybackErrorKind.permission => true,
    _ => false,
  };
}

PlaybackErrorKind classifyPlaybackError(String message) {
  final text = message.toLowerCase();
  if (_matches(text, const [
    '权限',
    '无权',
    '未登录',
    '登录',
    '授权',
    'vip',
    '会员',
    '试看结束',
    '401',
    '403',
    'forbidden',
    'unauthorized',
  ])) {
    return PlaybackErrorKind.permission;
  }
  if (_matches(text, const [
    '网络',
    '连接',
    '超时',
    'timeout',
    'dns',
    '无法连接',
    '断网',
    'failed host lookup',
    'socket',
    'connection refused',
    'reset by peer',
    '502',
    '503',
    '504',
  ])) {
    return PlaybackErrorKind.network;
  }
  if (_matches(text, const ['解码', '格式不支持', 'codec', '解码器', '无法解码', '渲染'])) {
    return PlaybackErrorKind.decode;
  }
  if (_matches(text, const [
    '站源',
    '未返回播放地址',
    '解析失败',
    '取流失败',
    '源站',
    '空地址',
    '无播放地址',
    '404',
  ])) {
    return PlaybackErrorKind.source;
  }
  return PlaybackErrorKind.other;
}

bool _matches(String text, List<String> needles) => needles.any(text.contains);
