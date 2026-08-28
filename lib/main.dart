import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:javp/app.dart';
import 'package:javp/models/home_shelf_snapshot.dart';
import 'package:javp/platform/desktop_bootstrap.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/layout_mode.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/profile_provider.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/diagnostics/ui_stall_watchdog.dart';
import 'package:javp/services/images/javp_memory.dart';
import 'package:javp/services/platform/windows_protocol.dart';
import 'package:javp/services/storage/library_store.dart';
import 'package:javp/platform/portable_mode.dart';
import 'package:javp/platform/web_path_provider.dart';
import 'package:javp/sync_worker/sync_worker_main.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  registerWebPathProviderIfNeeded();
  registerPortablePathProviderIfNeeded();
  // Catalog SyncEngine child process — no UI, no window_manager.
  if (isJavpSyncWorkerArgs(args)) {
    await runSyncWorkerMain(args);
    return;
  }
  if (kIsWeb) {
    // So https://web.javp.app/add?… works without hash routes.
    usePathUrlStrategy();
  }
  await _startDiagnosticsLogging();
  WindowsProtocol.captureLaunchArgs(args);

  // On desktop, resolve layout mode (TV vs desktop shell) before the shell is
  // built. This checks env vars, dart-defines, persisted prefs, and heuristics
  // (SteamOS, gamescope, etc.). Must run before TvPlatform.ensureInitialized()
  // so the forced layout takes effect.
  if (DesktopUi.isDesktopOs) {
    final layoutPref = await _loadLayoutModePreference();
    await LayoutModeResolver.resolve(persistedPreference: layoutPref);
  }

  // Which profile is active decides which storage namespace the library opens,
  // so it has to be resolved before the first frame. Nothing here depends on
  // anything else here, and window setup plus the TV probe are both waiting on
  // platform channels — running them together cuts the pre-frame stall to the
  // slowest one instead of their sum.
  final profiles = ProfileProvider();
  await Future.wait([
    bootstrapDesktop(),
    TvPlatform.ensureInitialized(),
    profiles.bootstrap(),
  ]);
  // Shelves reference far more artwork than the stock budget holds, so
  // scrolling back up used to re-decode every poster. Decodes are already
  // clamped to display size; budgets tighten on TV / low-memoryClass devices,
  // and Flutter still drops the cache on memory pressure (see JavpMemory).
  JavpMemory.configureImageCache(
    isTvShell: TvPlatform.isTvShell,
    memoryClassMb: TvPlatform.memoryClassMb,
  );
  if (isWindowsDesktop) {
    unawaited(WindowsProtocol.ensureRegistered());
  }
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Color(0xFF0B0C0F),
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  unawaited(
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
    ]),
  );
  // Last-close Accueil tiles — load before runApp so frame 0 is content,
  // not a spinner racing [LibraryProvider.bootstrap].
  HomeShelfSnapshot? homeSnap;
  try {
    homeSnap = await LibraryStore(
      profileId: profiles.activeProfileId,
    ).loadHomeShelfSnapshot();
  } catch (_) {}
  runApp(JavpApp(profiles: profiles, homeShelfSnapshot: homeSnap));
}

/// Routes everything the app already prints, plus both uncaught-error channels,
/// into the rotating on-device log.
///
/// This runs before the bootstrap below because startup is one of the phases
/// worth diagnosing. `PlatformDispatcher.onError` covers uncaught async errors,
/// so there is no `runZonedGuarded` and no zone overhead on every callback.
Future<void> _startDiagnosticsLogging() async {
  await JavpLog.instance.start();

  final previousPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    JavpLog.instance.capture(message);
    previousPrint(message, wrapWidth: wrapWidth);
  };

  FlutterError.onError = (details) {
    JavpLog.e('flutter', details.exceptionAsString(), stack: details.stack);
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    JavpLog.e('uncaught', '$error', stack: stack);
    // False keeps the default handler's behaviour: the error still surfaces.
    return false;
  };

  _installJankCallback();
  UiStallWatchdog.start();

  // Package info needs a platform channel, so the header lands a beat later
  // rather than holding up the first frame for it.
  unawaited(_logSessionHeader());
}

/// Logs Flutter frame hitches above [JavpLog.jankThresholdMs], rate-limited.
///
/// Production default is 40ms / ~1/s. Verbose hitch mode (Diagnostics, ON by
/// default on Dev) drops to 16ms / ~400ms so desktop lag under a missed 60fps
/// budget still leaves breadcrumbs. Over-threshold frames always increment the
/// hitch summary counter; only the journal line is rate-limited. This only sees
/// Flutter frame timings — native libmpv / IPC stalls without a long frame stay
/// invisible here.
void _installJankCallback() {
  var lastLoggedMs = 0;
  SchedulerBinding.instance.addTimingsCallback((timings) {
    final log = JavpLog.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    FrameTiming? worst;
    for (final timing in timings) {
      if (worst == null || timing.totalSpan > worst.totalSpan) {
        worst = timing;
      }
    }
    if (worst == null) return;
    final totalMs = worst.totalSpan.inMilliseconds;
    if (totalMs <= log.jankThresholdMs) return;
    // Always count for hitch summaries — rate-limit only the journal spam.
    // (A burst of 20–30ms scroll frames used to report janks=0 between lines.)
    JavpLog.noteJank(totalMs);
    if (now - lastLoggedMs < log.jankMinIntervalMs) return;
    lastLoggedMs = now;
    final buildMs = worst.buildDuration.inMilliseconds;
    final rasterMs = worst.rasterDuration.inMilliseconds;
    final route = JavpLog.currentRoute;
    final routePart = route == null ? '' : ' route=$route';
    final stall = UiStallWatchdog.phase;
    final stallPart = stall == '-' ? '' : ' stall=$stall';
    final summary =
        'frame ${totalMs}ms build=$buildMs raster=$rasterMs$routePart$stallPart';
    if (totalMs >= 100) {
      JavpLog.w('jank', summary);
    } else {
      JavpLog.i('jank', summary);
    }
  });
}

Future<void> _logSessionHeader() async {
  try {
    final info = await PackageInfo.fromPlatform();
    await JavpLog.instance.writeHeader(
      version: info.version,
      build: info.buildNumber,
      packageName: info.packageName,
    );
  } catch (_) {
    await JavpLog.instance.writeHeader(version: 'unknown', build: '0');
  }
}

/// Load layout mode preference from SharedPreferences (early, before library).
///
/// Uses the same key as DisplaySettings but reads just the layout field to
/// avoid coupling to the full model at this stage.
Future<LayoutModePreference?> _loadLayoutModePreference() async {
  const key = 'javp_display_settings';
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    final json = raw;
    // Simple parse: look for "layoutMode":"auto|desktop|tv"
    final match = RegExp(r'"layoutMode"\s*:\s*"(\w+)"').firstMatch(json);
    if (match == null) return null;
    return switch (match.group(1)) {
      'auto' => LayoutModePreference.auto,
      'desktop' => LayoutModePreference.desktop,
      'tv' => LayoutModePreference.tv,
      _ => null,
    };
  } catch (_) {
    return null;
  }
}
