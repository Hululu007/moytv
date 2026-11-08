import 'torrent_engine.dart';
import 'torrent_magnet.dart';

class TorrentPlaybackAdapter {
  TorrentPlaybackAdapter({TorrentEngine? engine})
    : engine = engine ?? TorrentEngineFactory.create();

  final TorrentEngine engine;

  bool get isAvailable => TorrentEngineFactory.isEngineAvailable;

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
