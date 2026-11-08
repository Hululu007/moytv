const Set<String> kMiniAppAdDomains = {
  'doubleclick.net',
  'googlesyndication.com',
  'googleadservices.com',
  'googletagmanager.com',
  'googletagservices.com',
  'adservice.google.com',
  'pagead2.googlesyndication.com',
  'ads.yahoo.com',
  'adnxs.com',
  'adsrvr.org',
  'criteo.com',
  'criteo.net',
  'taboola.com',
  'outbrain.com',
  'pubmatic.com',
  'rubiconproject.com',
  'moatads.com',
  'scorecardresearch.com',
  'advertising.com',
  'amazon-adsystem.com',
  'connect.facebook.net',
};

bool miniAppShouldBlockUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return false;
  for (final domain in kMiniAppAdDomains) {
    if (host == domain || host.endsWith('.$domain')) return true;
  }
  return false;
}
