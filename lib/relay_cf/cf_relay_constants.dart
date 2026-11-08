const String cfPublicRoomId = '123456';

const String cfRelayWsUrl = 'wss://huoyi-relay.97471201.workers.dev';

bool isCfRelayUrl(String url) => url == cfRelayWsUrl;

String cfHttpBaseForWs(String wsUrl) {
  final trimmed = wsUrl.endsWith('/')
      ? wsUrl.substring(0, wsUrl.length - 1)
      : wsUrl;
  if (trimmed.startsWith('wss://')) {
    return 'https://${trimmed.substring(6)}';
  }
  if (trimmed.startsWith('ws://')) {
    return 'http://${trimmed.substring(5)}';
  }
  return trimmed;
}

const int cfHeartbeatSeconds = 30;
const int cfPongGraceSeconds = 40;
const List<int> cfReconnectBackoffSeconds = [1, 2, 4, 8, 15, 30];
const int cfMaxChatChars = 2000;
const String cfPingType = 'ping';
const String cfPongType = 'pong';
