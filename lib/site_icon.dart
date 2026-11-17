import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'core_bridge.dart';
import 'site_builtin_icons.dart';
import 'site_homepages.dart';
import 'zakatv_builtin.dart';

/// 站点图标：圆角图标块，优先显示站点自己的站标，取不到时显示
/// 自制图案标（渐变底 + 白色通用图案，不带文字）。海阔页自有
/// 的字块兜底（_haikuoIconGlyph）与此无关，未动。
///
/// 站标只在给了候选地址时才联网取：调用方传 [iconUrls]，或
/// jar 站从 ext 里的站点地址派生（[jarSiteIconCandidates]），或
/// py/Go/阅读站从桥接表里的主页派生（[siteHomepageCandidates]）。
/// 没有候选地址的站直接显示图案标，零网络请求。图标获取绝不阻塞
/// 列表、绝不抛错：加载中与失败都显示图案标。
///
/// 显示优先级：内置站标（[builtinSiteIconAsset]，离线即显）→
/// favicon 候选（懒加载 + 磁盘缓存）→ 自制图案标（永远有，绝不留空）。

/// 从站点地址派生站标候选地址：origin + 常见站标路径。
/// 地址本身已是图片地址时把它放第一位（svg 除外，Flutter 解不了）。
/// 非 http(s) 地址、空地址一律返回空。
List<String> siteIconCandidates(String address) {
  final trimmed = address.trim();
  if (trimmed.isEmpty) return const [];
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return const [];
  }
  if (uri.host.isEmpty) return const [];
  final origin =
      '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
  final candidates = <String>[];
  final lowerPath = uri.path.toLowerCase();
  if (lowerPath.endsWith('.png') ||
      lowerPath.endsWith('.jpg') ||
      lowerPath.endsWith('.jpeg') ||
      lowerPath.endsWith('.webp') ||
      lowerPath.endsWith('.gif') ||
      lowerPath.endsWith('.bmp')) {
    candidates.add(trimmed);
  }
  // apple-touch-icon 与 favicon.png 在前：它们是 PNG，Flutter 能解；
  // favicon.ico 常是 ICO 格式，解不了时会回落图案标，不阻塞。
  candidates.add('$origin/apple-touch-icon.png');
  candidates.add('$origin/favicon.png');
  candidates.add('$origin/favicon.ico');
  return candidates;
}

/// 地址是否像个公开站点首页：域名、有点、非内网/回环、非 t.me、
/// 非纯 IP。ext 里常混着接口地址、中转地址、TG 链接，只取像
/// 站点首页的，取不到就回落图案标，不硬猜。
bool _isPublicSiteAddress(String address) {
  final uri = Uri.tryParse(address.trim());
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  if (host.isEmpty || host == 'localhost') return false;
  if (host == 't.me' || host.endsWith('.t.me')) return false;
  if (host.startsWith('192.168.') ||
      host.startsWith('10.') ||
      host.startsWith('127.')) {
    return false;
  }
  if (host.startsWith('172.')) {
    final second = int.tryParse(host.split('.')[1]);
    if (second != null && second >= 16 && second <= 31) return false;
  }
  if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host)) return false;
  return host.contains('.');
}

/// jar 站的站标候选：从该站 ext JSON 里 host/base/site/url/homepage
/// 字段取第一个像站点首页的地址再派生。ext 缺失、不是 JSON、没有
/// 可用地址时返回空——调用方一律回落图案标。
///
/// 站 id 形如 `jar:<配置>:<key>`；key 与 [zakatvBuiltinSites] 对上
/// 才查得到，其余 id 直接返回空。
List<String> jarSiteIconCandidates(String siteId) {
  final key = siteId.contains(':') ? siteId.split(':').last : siteId;
  if (key.isEmpty) return const [];
  ZakatvBuiltinSite? match;
  for (final site in zakatvBuiltinSites) {
    if (site.key == key) {
      match = site;
      break;
    }
  }
  if (match == null || match.ext.isEmpty) return const [];
  try {
    final decoded = jsonDecode(match.ext);
    if (decoded is! Map) return const [];
    for (final field in ['host', 'base', 'site', 'url', 'homepage']) {
      final value = decoded[field];
      if (value is String && _isPublicSiteAddress(value)) {
        final candidates = siteIconCandidates(value);
        if (candidates.isNotEmpty) return candidates;
      }
    }
  } catch (_) {
    // ext 不是合法 JSON 时当没有地址，回落图案标。
  }
  return const [];
}

/// 站 id → 主页地址桥接：按站 id 查
/// [pySiteHomepages]、[goSiteHomepages]、[legadoSiteHomepages] 三张
/// 桥接表（值取自树内源文件原文，见 site_homepages.dart），取到
/// 主页再派生。id 带 `jar:` 这类前缀时取最后一段；查不到、地址
/// 不像公开站点首页时返回空——调用方一律回落图案标。
List<String> siteHomepageCandidates(String siteId) {
  final key = siteId.contains(':') ? siteId.split(':').last : siteId;
  if (key.isEmpty) return const [];
  final url =
      pySiteHomepages[key] ?? goSiteHomepages[key] ?? legadoSiteHomepages[key];
  if (url == null || !_isPublicSiteAddress(url)) return const [];
  return siteIconCandidates(url);
}

/// 自制图案标：无真站标的站显示渐变底 + 中央白色通用图案，
/// 不带任何文字，不模仿任何站的真实标志。渐变与图案都按站 id
/// 哈希确定性选取，同站永远同一组合；纯计算、零网络、零 IO。
///
/// 渐变色板 8 对：色相与海阔页图标色板协调（橙/蓝/紫/绿/红/
/// 青/黄/靛），每对浅→深。图案 8 个：Flutter 自带圆体粗图案，
/// 30 像素下能看清。
const List<List<Color>> _kSitePatternGradients = [
  [Color(0xFFFF9E5E), Color(0xFFF97316)],
  [Color(0xFF60A5FA), Color(0xFF2563EB)],
  [Color(0xFFC084FC), Color(0xFF9333EA)],
  [Color(0xFF4ADE80), Color(0xFF16A34A)],
  [Color(0xFFF87171), Color(0xFFDC2626)],
  [Color(0xFF2DD4BF), Color(0xFF0D9488)],
  [Color(0xFFFBBF24), Color(0xFFD97706)],
  [Color(0xFF818CF8), Color(0xFF4F46E5)],
];

const List<IconData> _kSitePatternIcons = [
  Icons.play_arrow_rounded,
  Icons.movie_rounded,
  Icons.live_tv_rounded,
  Icons.menu_book_rounded,
  Icons.headphones_rounded,
  Icons.image_rounded,
  Icons.music_note_rounded,
  Icons.star_rounded,
];

int _sitePatternHash(String seed) {
  var hash = 0;
  for (final unit in seed.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return hash;
}

/// 图案标渐变色（浅→深两色）：同站 id 永远同一对。
List<Color> siteIconPatternColors(String siteId) =>
    _kSitePatternGradients[_sitePatternHash(siteId) %
        _kSitePatternGradients.length];

/// 图案标中央图案：同站 id 永远同一个，与渐变独立分散。
IconData siteIconPatternIcon(String siteId) =>
    _kSitePatternIcons[(_sitePatternHash(siteId) ~/
            _kSitePatternGradients.length) %
        _kSitePatternIcons.length];

/// 站标磁盘缓存：复用封面缓存设施——同一应用支持目录下的
/// py_covers/、同一 sha1(url).img 键名、同一 [normalizeCoverBytes]
/// 归一（base64 文本存盘会解不出图，归一后自愈）。
/// 不另建缓存目录、不另起缓存机制。
///
/// 并发上限 4 个在途请求；失败地址记入内存黑名单，本次启动内
/// 不再重取，避免每次开弹窗都重复打失败地址。
class SiteIconCache {
  SiteIconCache({
    Future<Directory> Function()? directoryProvider,
    Future<List<int>?> Function(String url)? fetcher,
  }) : _directoryProvider =
           directoryProvider ?? SiteIconCache._defaultDirectory,
       _fetcher = fetcher ?? SiteIconCache._downloadViaHttp;

  static final SiteIconCache instance = SiteIconCache();

  static const int _maxConcurrent = 4;
  static const int _maxBytes = 512 * 1024;

  final Future<Directory> Function() _directoryProvider;

  /// 取图函数：默认真实 HTTP 下载；测试注入假函数，避免真联网
  /// （flutter_test 的假时钟会让网络超时永不触发）。
  final Future<List<int>?> Function(String url) _fetcher;
  final Map<String, Future<File?>> _pending = {};
  final Set<String> _failed = {};
  int _inFlight = 0;
  final List<Completer<void>> _waiters = [];

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(path.join(support.path, 'py_covers'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 取某地址的站标文件：磁盘命中直接回，否则下载后存盘。
  /// 任何失败都回 null（调用方显示图案标），绝不抛错。
  Future<File?> resolve(String url) {
    if (_failed.contains(url)) return Future.value(null);
    return _pending.putIfAbsent(url, () => _resolve(url));
  }

  Future<File?> _resolve(String url) async {
    try {
      await _acquire();
      try {
        final file = await _cacheFile(url);
        if (await file.exists() && await file.length() > 0) {
          final cached = await file.readAsBytes();
          final normalized = normalizeCoverBytes(cached);
          if (!identical(normalized, cached)) {
            await file.writeAsBytes(normalized, flush: true);
          }
          if (!_looksLikeImage(normalized)) {
            // 盘上有旧的非图片文件时删掉并记失败，免得每次都解码失败。
            try {
              await file.delete();
            } catch (_) {}
            _failed.add(url);
            return null;
          }
          return file;
        }
        final bytes = await _fetcher(url);
        if (bytes == null || bytes.isEmpty) {
          _failed.add(url);
          return null;
        }
        final normalized = normalizeCoverBytes(bytes);
        if (!_looksLikeImage(normalized)) {
          // 非图片 body（如错误页 HTML、ICO 字节）不存盘，免得
          // 每次都解码失败；记失败，本次启动内不再重取。
          _failed.add(url);
          return null;
        }
        await file.writeAsBytes(normalized, flush: true);
        return file;
      } finally {
        _release();
      }
    } catch (_) {
      _failed.add(url);
      return null;
    } finally {
      _pending.remove(url);
    }
  }

  Future<File> _cacheFile(String url) async {
    final dir = await _directoryProvider();
    return File(path.join(dir.path, '${sha1.convert(utf8.encode(url))}.img'));
  }

  static Future<List<int>?> _downloadViaHttp(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != 200) return null;
      final buffer = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        buffer.addAll(chunk);
        if (buffer.length > _maxBytes) return null;
      }
      return buffer;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 常见位图魔数：PNG/JPEG/GIF/WebP/BMP。ICO（00 00 01 00）不在
  /// 内——Flutter 解不了 ICO，收到也当失败，候选顺位会继续往下试。
  bool _looksLikeImage(List<int> bytes) {
    if (bytes.length < 12) return false;
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return true;
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    return false;
  }

  Future<void> _acquire() async {
    while (_inFlight >= _maxConcurrent) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _inFlight++;
  }

  void _release() {
    _inFlight--;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }
}

/// 一个站点的图标块：有站标显示站标（圆角裁切），加载中或失败
/// 显示图案标。构造时不做 IO，图标在后台解析，解析到
/// 就 setState 换上；widget 销毁后不再 setState。
class SiteIcon extends StatefulWidget {
  const SiteIcon({
    super.key,
    required this.siteId,
    required this.siteName,
    this.iconUrls = const [],
    this.size = 60,
    this.borderRadius = 14,
    this.cache,
  });

  final String siteId;
  final String siteName;

  /// 调用方给定的站标候选地址（按序尝试）。为空时先按 [siteId] 查
  /// jar 站 ext 派生，再查 py/Go/阅读桥接表；都为空则只显示图案标，
  /// 不联网。
  final List<String> iconUrls;
  final double size;
  final double borderRadius;

  /// 可注入的缓存（测试用）；为空时用 [SiteIconCache.instance]。
  final SiteIconCache? cache;

  @override
  State<SiteIcon> createState() => _SiteIconState();
}

class _SiteIconState extends State<SiteIcon> {
  File? _file;
  String? _builtinAsset;
  List<String> _candidates = const [];

  @override
  void initState() {
    super.initState();
    _builtinAsset = builtinSiteIconAsset(widget.siteId);
    _candidates = _resolveCandidates();
    if (_builtinAsset == null && _candidates.isNotEmpty) {
      unawaited(_load());
    }
  }

  @override
  void didUpdateWidget(SiteIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.siteId != widget.siteId ||
        oldWidget.iconUrls != widget.iconUrls) {
      _builtinAsset = builtinSiteIconAsset(widget.siteId);
      _candidates = _resolveCandidates();
      _file = null;
      if (_builtinAsset == null && _candidates.isNotEmpty) {
        unawaited(_load());
      }
    }
  }

  List<String> _resolveCandidates() {
    if (widget.iconUrls.isNotEmpty) return widget.iconUrls;
    final jar = jarSiteIconCandidates(widget.siteId);
    if (jar.isNotEmpty) return jar;
    return siteHomepageCandidates(widget.siteId);
  }

  Future<void> _load() async {
    final cache = widget.cache ?? SiteIconCache.instance;
    for (final url in _candidates) {
      final file = await cache.resolve(url);
      if (!mounted) return;
      if (file != null) {
        setState(() => _file = file);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    final builtinAsset = _builtinAsset;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: builtinAsset != null
            ? Image.asset(
                builtinAsset,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _patternTile(),
              )
            : file != null
            ? Image.file(
                file,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _patternTile(),
              )
            : _patternTile(),
      ),
    );
  }

  Widget _patternTile() {
    final colors = siteIconPatternColors(widget.siteId);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        siteIconPatternIcon(widget.siteId),
        color: Colors.white,
        size: widget.size * 0.58,
      ),
    );
  }
}
