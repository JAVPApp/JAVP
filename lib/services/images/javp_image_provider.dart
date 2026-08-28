import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:javp/services/images/javp_image_cache.dart';

/// 1×1 transparent PNG so a missing poster does not throw into Flutter's
/// image error pipeline (and dump tokens from query strings into the console).
final Uint8List _transparentPixelPng = Uint8List.fromList(const <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

/// Strip auth query params so image debug labels cannot leak Plex/Jellyfin tokens.
@visibleForTesting
String redactArtworkUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasQuery) return url;
  final redacted = <String, String>{};
  for (final entry in uri.queryParameters.entries) {
    final key = entry.key.toLowerCase();
    final secret =
        key.contains('token') ||
        key.contains('auth') ||
        key.contains('key') ||
        key.contains('sig') ||
        key.contains('password');
    redacted[entry.key] = secret ? 'REDACTED' : entry.value;
  }
  return uri.replace(queryParameters: redacted).toString();
}

/// [ImageProvider] backed by [JavpImageCache].
///
/// Behaves like `NetworkImage` but resolves through the app's disk cache and
/// bounded download queue, and decodes straight to the on-screen size so a
/// 2000px poster never costs 16 MB of decoded RGBA in a scrolling list.
@immutable
class JavpImageProvider extends ImageProvider<JavpImageProvider> {
  const JavpImageProvider(this.url, {this.targetWidth, this.scale = 1.0});

  final String url;

  /// Decode width in physical pixels. Null keeps the source resolution.
  final int? targetWidth;
  final double scale;

  @override
  Future<JavpImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<JavpImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    JavpImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: key.scale,
      debugLabel: redactArtworkUrl(key.url),
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        ErrorDescription(redactArtworkUrl(key.url)),
      ],
    );
  }

  Future<ui.Codec> _load(
    JavpImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await JavpImageCache.instance.load(key.url);
    if (bytes == null || bytes.isEmpty) {
      // Evict so a later attempt (e.g. after reconnecting) can retry.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      final buffer = await ui.ImmutableBuffer.fromUint8List(
        _transparentPixelPng,
      );
      return decode(buffer);
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final width = key.targetWidth;
    if (width == null) return decode(buffer);
    return decode(
      buffer,
      getTargetSize: (intrinsicWidth, intrinsicHeight) {
        if (intrinsicWidth <= width) {
          return ui.TargetImageSize(
            width: intrinsicWidth,
            height: intrinsicHeight,
          );
        }
        // Preserve aspect ratio; the engine scales height to match.
        return ui.TargetImageSize(width: width);
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is JavpImageProvider &&
      other.url == url &&
      other.targetWidth == targetWidth &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(url, targetWidth, scale);

  @override
  String toString() =>
      'JavpImageProvider("${redactArtworkUrl(url)}", width: $targetWidth)';
}
