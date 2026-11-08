import '../models.dart';

class TorrentMagnet {
  const TorrentMagnet({
    required this.uri,
    required this.infoHash,
    required this.isBase32Hash,
    this.displayName = '',
    this.trackers = const [],
  });

  final String uri;
  final String infoHash;
  final bool isBase32Hash;
  final String displayName;
  final List<String> trackers;

  String get shortHash =>
      infoHash.length > 8 ? infoHash.substring(0, 8) : infoHash;

  String get nameOrHash => displayName.isEmpty ? shortHash : displayName;

  Map<String, dynamic> toJson() => {
    'uri': uri,
    'infoHash': infoHash,
    'isBase32Hash': isBase32Hash,
    'displayName': displayName,
    'trackers': trackers,
  };

  factory TorrentMagnet.fromJson(Map<String, dynamic> json) =>
      TorrentMagnet(
        uri: json['uri'] as String? ?? '',
        infoHash: json['infoHash'] as String? ?? '',
        isBase32Hash: json['isBase32Hash'] == true,
        displayName: json['displayName'] as String? ?? '',
        trackers: [
          for (final row in json['trackers'] as List? ?? const [])
            if (row != null && row.toString().isNotEmpty) row.toString(),
        ],
      );

  factory TorrentMagnet.fromMagnetLink(MagnetLink link) {
    final parsed = parseMagnetUri(link.url);
    if (parsed == null) {
      return TorrentMagnet(
        uri: link.url,
        infoHash: '',
        isBase32Hash: false,
        displayName: link.name,
      );
    }
    return TorrentMagnet(
      uri: link.url,
      infoHash: parsed.infoHash,
      isBase32Hash: parsed.isBase32Hash,
      displayName: parsed.displayName.isEmpty ? link.name : parsed.displayName,
      trackers: parsed.trackers,
    );
  }
}

bool isMagnetLink(String value) =>
    value.trim().toLowerCase().startsWith('magnet:?');

final _hexHash = RegExp(r'^[0-9a-fA-F]{40}$');
final _base32Hash = RegExp(r'^[A-Z2-7]{32}$');

TorrentMagnet? parseMagnetUri(String value) {
  final text = value.trim();
  if (!isMagnetLink(text)) return null;
  Uri uri;
  try {
    uri = Uri.parse(text);
  } catch (_) {
    return null;
  }
  final params = uri.queryParametersAll;
  final xt = params['xt'] ?? const [];
  String? hash;
  var base32 = false;
  for (final row in xt) {
    const prefix = 'urn:btih:';
    if (!row.toLowerCase().startsWith(prefix)) continue;
    final raw = row.substring(prefix.length).trim();
    if (_hexHash.hasMatch(raw)) {
      hash = raw.toLowerCase();
      base32 = false;
      break;
    }
    if (_base32Hash.hasMatch(raw.toUpperCase())) {
      hash = raw.toUpperCase();
      base32 = true;
      break;
    }
  }
  if (hash == null || hash.isEmpty) return null;
  final names = params['dn'] ?? const <String>[];
  final trackers = [
    for (final row in params['tr'] ?? const <String>[])
      if (row.isNotEmpty) row,
  ];
  return TorrentMagnet(
    uri: text,
    infoHash: hash,
    isBase32Hash: base32,
    displayName: names.isEmpty ? '' : names.first,
    trackers: trackers,
  );
}

enum TorrentLinkKind { magnet, thunder, ed2k, torrentFile, other }

TorrentLinkKind torrentLinkKind(String value) {
  final text = value.trim().toLowerCase();
  if (text.startsWith('magnet:?')) return TorrentLinkKind.magnet;
  if (text.startsWith('thunder://')) return TorrentLinkKind.thunder;
  if (text.startsWith('ed2k://')) return TorrentLinkKind.ed2k;
  final path = text.split('?').first;
  if (path.endsWith('.torrent')) return TorrentLinkKind.torrentFile;
  return TorrentLinkKind.other;
}

bool isTorrentLink(String value) =>
    torrentLinkKind(value) != TorrentLinkKind.other;
