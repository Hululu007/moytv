import 'torrent_engine.dart';
import 'torrent_magnet.dart';

class TorrentPlaybackAdapter {
  TorrentPlaybackAdapter({TorrentEngine? engine})
    : engine = engine ?? TorrentEngineFactory.create();

  final TorrentEngine engine;

  /// 有真引擎（非未接入占位）才算可用：生产上工厂在安卓给原生引擎、
  /// 其它平台给未接入占位；注入假引擎的测试也能走通取流链路。
  bool get isAvailable => engine is! UnavailableTorrentEngine;

  bool canHandle(String url) => isTorrentLink(url);

  Future<Uri> resolvePlayableUrl(
    TorrentSession session, {
    int fileIndex = 0,
  }) async {
    if (!isAvailable) {
      throw const TorrentEngineUnavailable(
        '种子引擎未接入，无法取流',
        whatIsNeeded: TorrentEngineFactory.missingPieces,
      );
    }
    if (session.state != TorrentSessionState.ready &&
        session.state != TorrentSessionState.streaming) {
      throw StateError(
        '种子尚未就绪（当前：${torrentSessionStateLabel(session.state)}），不能取流',
      );
    }
    return engine.streamUrl(session.id, fileIndex);
  }
}
