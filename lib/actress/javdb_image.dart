// JavDB 图片组件：取字节 → XOR 解密判定 → 内存图（进程内
// 缓存）。JavDB 图床（c0.jdbstatic.com）的封面/头像/剧照字
// 节带 XOR 加密，普通网络图组件解不出，必须走这条路径
// （API_MAP 实证）。原先住在 javdb_view.dart，2026-11-26 因
// 详情页剧照区也要用同一条解密路径显示 JavDB 剧照，挪到
// 独立文件供两边共用，行为一字未改。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../content_http.dart';
import 'actress_av_style.dart';
import 'javdb_api.dart';

/// JavDB 图片：取字节 → XOR 解密判定 → 内存图（进程内缓存）。
class JavdbImage extends StatefulWidget {
  const JavdbImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.http,
  });

  final String url;
  final BoxFit fit;
  final ContentHttp? http;

  static final _cache = <String, Uint8List>{};

  @override
  State<JavdbImage> createState() => _JavdbImageState();
}

class _JavdbImageState extends State<JavdbImage> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(JavdbImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final url = widget.url;
    if (url.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    final cached = JavdbImage._cache[url];
    if (cached != null) {
      setState(() => _bytes = cached);
      return;
    }
    try {
      final raw = await (widget.http ?? ContentHttp()).getBytes(
        url,
        timeout: const Duration(seconds: 20),
      );
      final decoded = javdbDecryptImageBytes(raw);
      JavdbImage._cache[url] = decoded;
      if (mounted && widget.url == url) setState(() => _bytes = decoded);
    } catch (_) {
      if (mounted && widget.url == url) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) return Image.memory(bytes, fit: widget.fit);
    return Container(
      color: const Color(0xFFF0EDE9),
      alignment: Alignment.center,
      child: Icon(
        _failed ? Icons.broken_image_outlined : Icons.image_outlined,
        color: AvStyle.dim,
        size: 22,
      ),
    );
  }
}
