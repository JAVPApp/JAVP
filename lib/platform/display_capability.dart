import 'dart:math' as math;
import 'dart:ui' show FlutterView, PlatformDispatcher, Size;

/// Screen / window capability probes used by live Auto quality.
class DisplayCapability {
  const DisplayCapability._();

  /// True when the primary Flutter view looks UHD / 4K-capable.
  ///
  /// Uses [FlutterView.physicalSize] (device pixels). A display counts as UHD
  /// when both edges meet a 4K floor (3840×2160 in either orientation).
  /// Windowed apps on a 4K monitor only qualify when the Flutter surface itself
  /// is that large (typical fullscreen / TV cases).
  ///
  /// Override [physicalSize] in tests.
  static bool supportsUhd({Size? physicalSize, FlutterView? view}) {
    final size = physicalSize ?? _physicalSize(view);
    if (size == null) return false;
    final w = size.width;
    final h = size.height;
    final longEdge = math.max(w, h);
    final shortEdge = math.min(w, h);
    return longEdge >= 3840 && shortEdge >= 2160;
  }

  static Size? _physicalSize(FlutterView? view) {
    final v = view ??
        PlatformDispatcher.instance.implicitView ??
        (PlatformDispatcher.instance.views.isEmpty
            ? null
            : PlatformDispatcher.instance.views.first);
    if (v == null) return null;
    final size = v.physicalSize;
    if (size.isEmpty) return null;
    return size;
  }
}
