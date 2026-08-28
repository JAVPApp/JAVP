import 'package:flutter/painting.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/images/javp_image_cache.dart';

/// Decoded-image budgets + memory-pressure cleanup for artwork-heavy shelves.
///
/// Flutter's stock image cache (~100 MB) thrashs on IPTV home shelves; the
/// raised budgets here are still capped, and [handleMemoryPressure] drops them
/// when the OS asks.
class JavpMemory {
  JavpMemory._();

  /// Configure [PaintingBinding.instance.imageCache] for this device class.
  ///
  /// Call after [TvPlatform.ensureInitialized] so TV shells get a tighter
  /// budget. [memoryClassMb] is Android's `ActivityManager.memoryClass` when
  /// known (rough heap guidance, not total device RAM).
  static void configureImageCache({
    required bool isTvShell,
    int? memoryClassMb,
  }) {
    final cache = PaintingBinding.instance.imageCache;
    final lowHeap =
        memoryClassMb != null && memoryClassMb > 0 && memoryClassMb <= 128;
    final tight = isTvShell || lowHeap;

    if (lowHeap) {
      // Cheap sticks / low-memoryClass phones: keep decoded art modest.
      cache
        ..maximumSizeBytes = 64 << 20
        ..maximumSize = 500;
    } else if (tight) {
      cache
        ..maximumSizeBytes = 96 << 20
        ..maximumSize = 800;
    } else {
      // Phones / desktop: shelves scroll back through many posters.
      cache
        ..maximumSizeBytes = 192 << 20
        ..maximumSize = 1500;
    }
  }

  /// OS / Flutter asked for RAM back — drop decoded art and session scratch.
  ///
  /// Disk artwork stays (not resident). [onLibraryTrim] should clear re-fetchable
  /// session caches (e.g. raw EPG HTTP bodies), not catalog state.
  static void handleMemoryPressure({void Function()? onLibraryTrim}) {
    final cache = PaintingBinding.instance.imageCache;
    final beforeBytes = cache.currentSizeBytes;
    final beforeCount = cache.currentSize;
    cache.clear();
    cache.clearLiveImages();
    JavpImageCache.instance.dropTransientMemory();
    onLibraryTrim?.call();
    JavpLog.i(
      'memory',
      'pressure: cleared imageCache '
          '(was $beforeCount imgs / ${(beforeBytes / (1 << 20)).toStringAsFixed(1)} MB)',
    );
  }
}
