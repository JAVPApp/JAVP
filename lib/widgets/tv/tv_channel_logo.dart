import 'package:flutter/material.dart';
import 'package:javp/widgets/javp_art.dart';

/// Channel `stream_icon` / thumbnail for TV live chrome (info bar, mini player).
class TvChannelLogo extends StatelessWidget {
  const TvChannelLogo({
    super.key,
    required this.url,
    this.size = 48,
  });

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0x99000000),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: JavpArt(
            url: url,
            fit: BoxFit.contain,
            decodeWidth: (size * 2).round().clamp(48, 256),
            fadeIn: false,
            fallback: Icon(
              Icons.live_tv_rounded,
              size: size * 0.45,
              color: Colors.white54,
            ),
          ),
        ),
      ),
    );
  }
}
