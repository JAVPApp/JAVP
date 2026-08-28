import 'package:flutter/material.dart';
import 'package:javp/services/images/javp_image_provider.dart';

/// Drop-in replacement for `Image.network` for all remote artwork.
///
/// Adds disk caching, bounded download concurrency, right-sized decoding and a
/// fade-in that only plays for images that actually had to load, so scrolling
/// back through a shelf stays flicker-free.
class JavpArt extends StatelessWidget {
  const JavpArt({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.decodeWidth,
    this.fallback,
    this.fadeIn = true,
  });

  final String? url;
  final BoxFit fit;

  /// Decode width in physical pixels. Keep this close to the on-screen size.
  final int? decodeWidth;

  /// Shown while loading and when the artwork cannot be fetched.
  final Widget? fallback;
  final bool fadeIn;

  @override
  Widget build(BuildContext context) {
    final source = url?.trim();
    final placeholder = fallback ?? const SizedBox.shrink();
    if (source == null || source.isEmpty) return placeholder;

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.passthrough,
        alignment: Alignment.center,
        children: [
          placeholder,
          Image(
            image: JavpImageProvider(source, targetWidth: decodeWidth),
            fit: fit,
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
            frameBuilder: !fadeIn
                ? null
                : (context, child, frame, wasSynchronouslyLoaded) {
                    if (wasSynchronouslyLoaded) return child;
                    return AnimatedOpacity(
                      opacity: frame == null ? 0 : 1,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      child: child,
                    );
                  },
          ),
        ],
      ),
    );
  }
}
