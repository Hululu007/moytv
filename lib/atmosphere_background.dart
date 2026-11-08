import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'models.dart';

class AtmospherePalette {
  const AtmospherePalette(this.primary, this.secondary);

  final Color primary;
  final Color secondary;
}

AtmospherePalette? atmospherePaletteFromPixels(
  Uint8List rgba,
  int width,
  int height,
) {
  final total = width * height;
  if (total <= 0 || rgba.length < total * 4) return null;
  final step = (total / 64).ceil();
  final samples = <Color>[];
  for (var i = 0; i < total; i += step) {
    final offset = i * 4;
    samples.add(
      Color.fromRGBO(rgba[offset], rgba[offset + 1], rgba[offset + 2], 1),
    );
  }
  if (samples.isEmpty) return null;
  var r = 0, g = 0, b = 0;
  for (final sample in samples) {
    r += (sample.r * 255).round();
    g += (sample.g * 255).round();
    b += (sample.b * 255).round();
  }
  final count = samples.length;
  final average = Color.fromRGBO(r ~/ count, g ~/ count, b ~/ count, 1);
  var secondary = samples.first;
  var distance = -1.0;
  for (final sample in samples) {
    final dr = (sample.r * 255).round() - r ~/ count;
    final dg = (sample.g * 255).round() - g ~/ count;
    final db = (sample.b * 255).round() - b ~/ count;
    final current = (dr * dr + dg * dg + db * db).toDouble();
    if (current > distance) {
      distance = current;
      secondary = sample;
    }
  }
  return AtmospherePalette(average, secondary);
}

Future<AtmospherePalette?> atmospherePaletteFromBytes(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 32,
      targetHeight: 32,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width;
    final height = image.height;
    image.dispose();
    if (data == null) return null;
    return atmospherePaletteFromPixels(
      data.buffer.asUint8List(),
      width,
      height,
    );
  } catch (_) {
    return null;
  }
}

typedef AtmospherePaletteLoader =
    Future<AtmospherePalette?> Function(AppRepository repository, Drama drama);

Future<AtmospherePalette?> defaultAtmosphereLoader(
  AppRepository repository,
  Drama drama,
) async {
  try {
    final path = await repository.cover(drama);
    if (path.isEmpty) return null;
    final bytes = await File(path).readAsBytes();
    return await atmospherePaletteFromBytes(bytes);
  } catch (_) {
    return null;
  }
}

final _atmospherePaletteCache = <String, AtmospherePalette>{};

class AtmosphereBackground extends StatefulWidget {
  const AtmosphereBackground({
    super.key,
    required this.url,
    required this.repository,
    required this.drama,
    this.loader,
  });

  final String url;
  final AppRepository repository;
  final Drama drama;
  final AtmospherePaletteLoader? loader;

  @override
  State<AtmosphereBackground> createState() => _AtmosphereBackgroundState();
}

class _AtmosphereBackgroundState extends State<AtmosphereBackground> {
  AtmospherePalette? _palette;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant AtmosphereBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _resolve();
  }

  Future<void> _resolve() async {
    final url = widget.url;
    if (url.isEmpty) {
      if (mounted) setState(() => _palette = null);
      return;
    }
    final cached = _atmospherePaletteCache[url];
    if (cached != null) {
      if (mounted) setState(() => _palette = cached);
      return;
    }
    final loader = widget.loader ?? defaultAtmosphereLoader;
    final palette = await loader(widget.repository, widget.drama);
    if (!mounted || widget.url != url) return;
    if (palette != null) {
      if (_atmospherePaletteCache.length > 128) _atmospherePaletteCache.clear();
      _atmospherePaletteCache[url] = palette;
    }
    setState(() => _palette = palette);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = _palette;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette == null
              ? [scheme.surfaceContainerHighest, scheme.surfaceContainer]
              : [
                  palette.primary.withValues(alpha: .55),
                  palette.secondary.withValues(alpha: .75),
                ],
        ),
      ),
    );
  }
}
