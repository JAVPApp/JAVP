import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/platform/desktop_bootstrap.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/models/home_shelf_snapshot.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/app_route_extra_codec.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/my_list_ui_prefs.dart';
import 'package:javp/models/profile.dart';
import 'package:javp/services/sync/profile_snapshot.dart';
import 'package:javp/providers/caption_style_provider.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/multi_view_provider.dart';
import 'package:javp/providers/parental_lock_provider.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/providers/profile_provider.dart';
import 'package:javp/providers/shell_actions.dart';
import 'package:javp/providers/sports_provider.dart';
import 'package:javp/providers/update_provider.dart';
import 'package:javp/services/storage/library_store.dart';
import 'package:javp/widgets/app_action_button.dart';
import 'package:javp/widgets/source_add_confirm_dialog.dart';
import 'package:javp/screens/caption_style_screen.dart';
import 'package:javp/screens/cast/cast_remote_screen.dart';
import 'package:javp/screens/catalog_category_screen.dart';
import 'package:javp/screens/catalog_screen.dart';
import 'package:javp/screens/downloaded_series_screen.dart';
import 'package:javp/screens/history_screen.dart';
import 'package:javp/screens/home_screen.dart';
import 'package:javp/screens/library_browse_screens.dart';
import 'package:javp/screens/library_screen.dart';
import 'package:javp/screens/music_screen.dart';
import 'package:javp/screens/my_list_screen.dart';
import 'package:javp/screens/player/player_screen.dart';
import 'package:javp/screens/search_screen.dart';
import 'package:javp/screens/series_detail_screen.dart';
import 'package:javp/screens/settings/settings_diagnostics_tab.dart';
import 'package:javp/screens/settings/settings_appearance_tab.dart';
import 'package:javp/screens/settings/settings_general_tab.dart';
import 'package:javp/screens/settings/settings_integrations_tab.dart';
import 'package:javp/screens/settings/settings_network_tab.dart';
import 'package:javp/screens/settings/settings_parental_tab.dart';
import 'package:javp/screens/settings/settings_playback_tab.dart';
import 'package:javp/screens/settings/settings_profiles_tab.dart';
import 'package:javp/screens/settings/settings_sports_tab.dart';
import 'package:javp/screens/settings_screen.dart';
import 'package:javp/screens/shell_screen.dart';
import 'package:javp/screens/sources_screen.dart';
import 'package:javp/screens/sports_screen.dart';
import 'package:javp/screens/title_detail_screen.dart';
import 'package:javp/screens/tv_screen.dart';
import 'package:javp/screens/tv/tv_live_overlay_screen.dart';
import 'package:javp/screens/welcome_screen.dart';
import 'package:javp/screens/pairing/device_pair_client_screen.dart';
import 'package:javp/services/deep_links/javp_pair_link.dart';
import 'package:javp/services/deep_links/javp_source_link.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/diagnostics/hwnd_sync_trace.dart';
import 'package:javp/services/discord/discord_presence_service.dart';
import 'package:javp/services/external_media_open.dart';
import 'package:javp/services/images/javp_memory.dart';
import 'package:javp/services/iptv/stalker_client.dart';
import 'package:javp/services/notifications/epg_reminder_service.dart';
import 'package:javp/services/platform/desktop_tray_service.dart';
import 'package:javp/services/platform/windows_protocol.dart';
import 'package:javp/services/sync/auto_sync_schedule.dart';
import 'package:javp/services/sync/profile_sync_service.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_scaffold_messenger.dart';
import 'package:javp/widgets/desktop/desktop_scroll_behavior.dart';
import 'package:javp/widgets/desktop/desktop_shortcuts.dart';
import 'package:javp/widgets/gamepad_navigator.dart';
import 'package:javp/widgets/library_work_debug_overlay.dart';
import 'package:javp/widgets/mini_player_bar.dart';
import 'package:javp/widgets/parental_unlock.dart';
import 'package:javp/widgets/profile_lock.dart';
import 'package:javp/widgets/shell_branch_host.dart';
import 'package:javp/widgets/sync/profile_sync_banner.dart';
import 'package:javp/widgets/torrent_privacy_tip_dialog.dart';
import 'package:javp/widgets/tracker_link_prompt.dart';
import 'package:javp/widgets/update_dialog.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:javp/compat/window_manager.dart';

/// Instant overlay page so `/player` and `/tv/watch` do not cover the shell
/// with a 300ms opaque Material transition on minimize / restore.
///
/// Sources / Search / History / My list use the same page: a zoom transition
/// keeps Home in the overlay and rebuilds accessibility while sync already
/// owns the UI isolate — Windows then looks like it is blocking itself.
Page<void> _instantOverlayPage(GoRouterState state, Widget child) {
  return NoTransitionPage<void>(
    key: state.pageKey,
    name: state.name,
    child: child,
  );
}

class JavpApp extends StatefulWidget {
  const JavpApp({super.key, required this.profiles, this.homeShelfSnapshot});

  /// Already bootstrapped in `main`, so the active profile is known here.
  final ProfileProvider profiles;

  /// Last-close Accueil shelves, loaded before [runApp] so Home paints
  /// content on frame 0 instead of a bootstrap spinner.
  final HomeShelfSnapshot? homeShelfSnapshot;

  @override
  State<JavpApp> createState() => _JavpAppState();
}

class _JavpAppState extends State<JavpApp>
    with WidgetsBindingObserver, WindowListener {
  static const _deepLinks = MethodChannel('javp/deep_links');

  late LibraryProvider _library;
  late PlaybackProvider _playback;
  late ParentalLockProvider _parental;
  late final SportsProvider _sports;
  late final MultiViewProvider _multiView;
  late final CaptionStyleProvider _captions;
  late final LocaleController _locale;
  late final UpdateProvider _updates;

  /// Stable listenable for the router: `_library` is replaced when the profile
  /// changes, and GoRouter would otherwise keep listening to the old one.
  late final _RouterRefresh _routerRefresh;

  ProfileProvider get _profiles => widget.profiles;
  late final GoRouter _router;
  late final GlobalKey<NavigatorState> _rootNavigatorKey;
  late final bool _openedViaExternalDeepLink;
  bool _handlingExternalOpen = false;
  String? _lastHandledDeepLink;
  DateTime? _lastHandledDeepLinkAt;
  Timer? _autoSyncTimer;
  Future<void>? _syncInFlight;
  bool _pendingLocalDirtySync = false;
  bool _pendingUrgentAutoSync = false;
  bool _pendingApplyAfterPlayback = false;
  bool _playbackHadSession = false;

  /// Bumped on every lifecycle transition so deferred resume work can bail out
  /// if the app was backgrounded again (or resumed twice) before it runs.
  int _lifecycleGen = 0;
  Timer? _resumeDriveSyncTimer;
  Timer? _resumeSimklTimer;

  /// Android PiP reports after onPause — briefly defer AFK suspend.
  Timer? _pipSettleTimer;

  /// True only after a real AFK suspend (not PiP / settle abort).
  bool _suspendedForBackground = false;
  bool _lastSeenPip = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _locale = LocaleController();
    DiscordPresenceService.instance.bindLocale(_locale);
    _locale.addListener(_onLocaleForTray);
    _library = LibraryProvider(
      profileId: _profiles.activeProfileId,
      homeShelfSnapshot: widget.homeShelfSnapshot,
    )..bootstrap();
    _parental = ParentalLockProvider(profileId: _profiles.activeProfileId);
    _parental.addListener(_onParentalChanged);
    unawaited(_parental.load());
    _wireCatalogLocale(_library);
    _wireParentalLock(_library);
    _attachLibrarySyncHook(_library);
    _playback = PlaybackProvider(library: _library);
    _sports = SportsProvider(
      libraryStore: LibraryStore(profileId: _profiles.activeProfileId),
      onSyncableChanged: () => _scheduleAutoSync(),
    );
    unawaited(_sports.bootstrap());
    _multiView = MultiViewProvider()..attachPlayback(_playback);
    _playback.onWindowsLongBlurPaused = () {
      unawaited(_multiView.onAppBackgrounded());
    };
    _playback.addListener(_onPlaybackForDiscord);
    _playback.addListener(_onPlaybackForSync);
    _playback.addListener(_onPlaybackPipLifecycle);
    _lastSeenPip = _playback.isInPip;
    unawaited(() async {
      await DiscordPresenceService.instance.start();
      DiscordPresenceService.instance.sync(_playback);
    }());
    _captions = CaptionStyleProvider(
      profileId: _profiles.activeProfileId,
      onSyncableChanged: () => _scheduleAutoSync(),
    );
    _updates = UpdateProvider();
    _routerRefresh = _RouterRefresh(_library);
    _rootNavigatorKey = GlobalKey<NavigatorState>();
    unawaited(_startDesktopTray());
    unawaited(_startDesktopShellHooks());
    unawaited(_startSync());

    final platformRoute =
        WidgetsBinding.instance.platformDispatcher.defaultRouteName;
    final platformUri = Uri.tryParse(platformRoute);
    // Windows protocol opens arrive as CLI args, not as defaultRouteName.
    _openedViaExternalDeepLink =
        (platformUri != null && isExternalDeepLink(platformUri)) ||
        WindowsProtocol.hasInitialLink;

    _router = _buildRouter();
    _router.routerDelegate.addListener(_noteCurrentRoute);
    _noteCurrentRoute();

    EpgReminderService.instance.onNotificationTap = _openFromEpgReminder;

    _deepLinks.setMethodCallHandler((call) async {
      if (call.method == 'onLink' && call.arguments is String) {
        unawaited(_handleExternalDeepLink(call.arguments as String));
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_consumeInitialDeepLink(platformRoute));
      unawaited(_maybePromptForAppUpdate());
    });
  }

  Future<void> _maybePromptForAppUpdate() async {
    try {
      await _waitForNavigatorReady();
      await _updates.loadPackageInfo();
      // Play / Smart TV / unsupported hosts: version label only.
      // Sideload Android + Windows/Linux/macOS zip use the quiet launch check.
      if (!_updates.supportsInAppUpdates) return;
      // Don't interrupt external open / cold deep links with an update sheet.
      if (_openedViaExternalDeepLink) return;
      // Always fetch on cold start — the 12h throttle used to skip the network
      // after any prior check, so a release published later the same day never
      // surfaced until Settings → Check for updates.
      final latest = await _updates.check(force: true);
      if (latest == null) return;
      // Completing Welcome redirects /welcome → /home and clears root-navigator
      // dialogs. Wait until onboarding is done (and any Welcome finish prompt
      // has settled) so Skip can't wipe this sheet.
      await _waitForOnboardingCompleted();
      if (!mounted || _openedViaExternalDeepLink) return;
      await _waitForRootNavigatorIdle();
      if (!mounted) return;
      final nav = _rootNavigatorKey.currentContext;
      if (nav == null || !nav.mounted) return;
      await showUpdateDialog(nav);
    } catch (_) {
      // Update checks should never block app startup.
    }
  }

  /// Welcome stays up until the user finishes or skips; don't race it.
  Future<void> _waitForOnboardingCompleted() async {
    if (_library.onboardingCompleted) return;
    final done = Completer<void>();
    void listener() {
      if ((!mounted || _library.onboardingCompleted) && !done.isCompleted) {
        done.complete();
      }
    }

    _library.addListener(listener);
    listener();
    try {
      await done.future;
    } finally {
      _library.removeListener(listener);
    }
  }

  /// Let Welcome's post-onboarding prompt claim the root navigator first.
  Future<void> _waitForRootNavigatorIdle() async {
    await WidgetsBinding.instance.endOfFrame;
    // Brief beat so `_finish` can push its tracker dialog after the redirect.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    for (var i = 0; i < 200; i++) {
      if (!mounted) return;
      final nav = _rootNavigatorKey.currentState;
      if (nav == null || !nav.mounted || !nav.canPop()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Sync settings live in secure storage, so this waits for Accueil reveal
  /// settle before pulling Drive/WebDAV — avoids the ~1s post-reveal hitch.
  Future<void> _startSync() async {
    // Brief beat so Home can mount and start reveal before we wait on it.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    await _library.waitUntilHomeRevealSettled();
    if (!mounted) return;
    // Short settle after reveal so shelf paint isn't under Drive merge.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    await _profiles.loadSyncSettings();
    if (!mounted) return;
    if (_profiles.autoSyncEnabled) {
      JavpLog.i(
        'sync',
        _library.playbackActive
            ? 'auto-sync start reason=cold-start-after-reveal (push-only)'
            : 'auto-sync start reason=cold-start-after-reveal',
      );
      await _syncNow();
    }
    // After local bootstrap (+ optional pull), prompt if this profile expects
    // a tracker login that isn't on this device yet.
    if (mounted) unawaited(_maybePromptTrackerLink());
  }

  /// Once per profile until dismissed or linked — never blocks startup.
  /// Soft setup waits for onboarding + ≥1 source so Skip-for-now / empty Home
  /// is not interrupted; first source add re-arms the offer.
  Future<void> _maybePromptTrackerLink() async {
    if (_openedViaExternalDeepLink) return;
    await _waitForLibraryReady();
    await _waitForOnboardingCompleted();
    if (!mounted || _openedViaExternalDeepLink) return;

    if (_library.needsTrackerDeviceLink) {
      if (await _library.isTrackerLinkPromptDismissed()) return;
      await _waitForNavigatorReady();
      final ctx = _rootNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      await offerTrackerLinkFlow(
        ctx,
        _library,
        kind: TrackerLinkPromptKind.linkOnDevice,
      );
      return;
    }

    if (_library.sources.isEmpty) {
      _armSoftTrackerSetupOnFirstSource();
      return;
    }

    await _offerSoftTrackerSetupIfNeeded();
  }

  bool _softTrackerSourceArmed = false;

  void _armSoftTrackerSetupOnFirstSource() {
    if (_softTrackerSourceArmed) return;
    _softTrackerSourceArmed = true;
    void listener() {
      if (!mounted) return;
      if (!_library.onboardingCompleted || _library.sources.isEmpty) return;
      _library.removeListener(listener);
      _softTrackerSourceArmed = false;
      unawaited(_offerSoftTrackerSetupIfNeeded());
    }

    _library.addListener(listener);
  }

  Future<void> _offerSoftTrackerSetupIfNeeded() async {
    if (_openedViaExternalDeepLink) return;
    if (!_library.onboardingCompleted) return;
    if (_library.sources.isEmpty) return;
    if (_library.needsTrackerDeviceLink) return;
    if (_library.simkl.isAuthenticated ||
        _library.trakt.isAuthenticated ||
        _library.serializd.isAuthenticated ||
        _library.betaseries.isAuthenticated) {
      await _library.dismissSoftTrackerSetup();
      return;
    }
    if (await _library.isSoftTrackerSetupDismissed()) return;
    await _waitForNavigatorReady();
    // Let Home paint / Welcome finish settle before the optional dialog.
    await _waitForRootNavigatorIdle();
    if (!mounted || _openedViaExternalDeepLink) return;
    // Same gate as Drive auto-sync — don't cover Accueil reveal with a sheet.
    await _library.waitUntilHomeRevealSettled();
    if (!mounted || _openedViaExternalDeepLink) return;
    final ctx = _rootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await offerTrackerLinkFlow(
      ctx,
      _library,
      kind: TrackerLinkPromptKind.softSetup,
    );
  }

  void _attachLibrarySyncHook(LibraryProvider library) {
    library.onSyncableChanged = _scheduleAutoSync;
    library.onTorrentPrivacyTipNeeded = () => _promptTorrentVpnTip(library);
  }

  void _wireCatalogLocale(LibraryProvider library) {
    library.catalogLocale = () => _locale.effectiveLanguageCode;
    library.preferredContentLocales = () =>
        _locale.preferredContentLanguageCodes;
  }

  void _wireParentalLock(LibraryProvider library) {
    library.parentalLock = _parental;
  }

  void _onParentalChanged() {
    // Live category / channel filters depend on lock session state.
    _library.invalidateParentalLiveCaches();
    _library.notifyListeners();
  }

  /// First torrent play/download: recommend VPN or proxy once.
  Future<bool> _promptTorrentVpnTip(LibraryProvider library) async {
    await _waitForNavigatorReady();
    final ctx = _rootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return true;
    final result = await showTorrentPrivacyTipDialog(ctx);
    await library.markTorrentVpnTipSeen();
    if (result == TorrentPrivacyTipResult.openSettings) {
      if (ctx.mounted) _router.go('/settings/network');
      return false;
    }
    return true;
  }

  /// Coalesce rapid syncable writes into one background push.
  ///
  /// Triggered only when local profile data changed (history, lists, …).
  /// Mid-watch: keep local soft persist, but defer the Drive/WebDAV push until
  /// playback stops (resume/open still sync for restore / CW). Always
  /// non-blocking — never await on the UI path.
  ///
  /// Non-urgent changes also wait out [kLocalDirtyAutoSyncMinInterval] since
  /// [lastSyncAt] so history soft-persist / tracker merges cannot fire a full
  /// sync ~every minute while browsing Home. Source add/remove/edit is
  /// [urgent] and only uses the short debounce — the other device cannot
  /// pull a source this one has not pushed.
  void _scheduleAutoSync({bool urgent = false}) {
    if (!_profiles.autoSyncEnabled) return;
    _pendingLocalDirtySync = true;
    if (urgent) _pendingUrgentAutoSync = true;
    _autoSyncTimer?.cancel();
    final delay = _localDirtyAutoSyncDelay();
    if (delay > kLocalDirtyAutoSyncDebounce) {
      JavpLog.i(
        'sync',
        'auto-sync schedule reason=local-dirty '
            'wait=${delay.inSeconds}s (min-interval)',
      );
    } else if (_pendingUrgentAutoSync) {
      JavpLog.i(
        'sync',
        'auto-sync schedule reason=local-dirty '
            'wait=${delay.inSeconds}s (urgent)',
      );
    }
    _autoSyncTimer = Timer(delay, () {
      _autoSyncTimer = null;
      if (!mounted) return;
      // Another sync may have landed while we waited (resume / manual).
      final remaining = _localDirtyAutoSyncDelay();
      if (remaining > kLocalDirtyAutoSyncDebounce) {
        JavpLog.i(
          'sync',
          'auto-sync defer reason=recent-sync wait=${remaining.inSeconds}s',
        );
        _scheduleAutoSync();
        return;
      }
      JavpLog.i('sync', 'auto-sync start reason=local-dirty');
      unawaited(_syncNow());
    });
  }

  /// Delay until the next local-dirty auto-sync may start.
  Duration _localDirtyAutoSyncDelay() {
    return localDirtyAutoSyncDelay(
      lastSyncAt: _profiles.lastSyncAt,
      now: DateTime.now().toUtc(),
      urgent: _pendingUrgentAutoSync,
    );
  }

  void _cancelScheduledAutoSync() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
  }

  /// Complete a pending local-dirty push before the process can die (Windows
  /// quit, Android AFK). No-op when nothing is waiting.
  Future<void> _flushPendingAutoSyncOnLeave({required String reason}) async {
    if (!_profiles.autoSyncEnabled) return;
    await _library.flushPendingWrites();
    final inFlight = _syncInFlight;
    if (inFlight != null) {
      try {
        await inFlight.timeout(const Duration(seconds: 25));
      } on TimeoutException {
        JavpLog.w(
          'sync',
          'auto-sync leave timed out reason=$reason (in-flight)',
        );
      }
      await _library.flushPendingWrites();
    }
    if (_autoSyncTimer == null && !_pendingLocalDirtySync) return;
    JavpLog.i('sync', 'auto-sync start reason=$reason');
    try {
      await _syncNow(
        skipRevealWait: true,
        skipReload: reason == 'quit',
      ).timeout(const Duration(seconds: 25));
    } on TimeoutException {
      JavpLog.w('sync', 'auto-sync leave timed out reason=$reason');
    }
  }

  /// Feeds hitch journals without walking the navigator from the timings
  /// callback. Path only — query strings stay out of the log.
  void _noteCurrentRoute() {
    try {
      final path = _router.routerDelegate.currentConfiguration.uri.path;
      JavpLog.noteRoute(path.isEmpty ? '/' : path);
    } catch (_) {
      // Router not ready yet (first frames / dispose race).
    }
  }

  /// Sync reads and writes storage directly, so the library has to flush what
  /// it is holding first and re-read afterwards.
  ///
  /// Callers must not start a fresh [_runSyncNow] while one is already in
  /// flight: that clears pending flags and then coalesces onto
  /// [ProfileProvider.syncNow]'s existing future, whose snapshot may predate
  /// the local dirty write. Leave-flush would then see nothing pending and
  /// skip the retry. Chain after the in-flight run instead, and only push
  /// again when something is still waiting.
  Future<void> _syncNow({
    bool skipRevealWait = false,
    bool skipReload = false,
  }) {
    final previous = _syncInFlight;
    final run = () async {
      if (previous != null) {
        await previous;
        if (!mounted) return;
        if (!_pendingLocalDirtySync && _autoSyncTimer == null) return;
      }
      await _runSyncNow(skipRevealWait: skipRevealWait, skipReload: skipReload);
    }();
    _syncInFlight = run;
    return run.whenComplete(() {
      if (identical(_syncInFlight, run)) _syncInFlight = null;
    });
  }

  Future<void> _runSyncNow({
    required bool skipRevealWait,
    required bool skipReload,
  }) async {
    _cancelScheduledAutoSync();
    _pendingLocalDirtySync = false;
    _pendingUrgentAutoSync = false;
    final library = _library;
    // Never pile Drive apply / reload on Accueil stagger (cold start or
    // local-dirty while reveal is still settling). Quit / AFK skip the wait
    // so a pending push is not cancelled with the process.
    if (!skipRevealWait) {
      await library.waitUntilHomeRevealSettled();
      if (!mounted) return;
    }
    // Mid-play: still push (other devices get progress) but do not apply or
    // reload — that copy/hash/write is what froze the player. Apply lands
    // when the session ends.
    final pushOnly = !skipRevealWait && library.playbackActive;
    if (pushOnly) {
      JavpLog.i('sync', 'auto-sync start reason=playback-push');
    }
    final watch = Stopwatch()..start();
    await library.flushPendingWrites();
    final flushMs = watch.elapsedMilliseconds;
    final changed = await _profiles.syncNow(applyLocal: !pushOnly);
    final syncMs = watch.elapsedMilliseconds - flushMs;
    var reloadMs = 0;
    if (pushOnly) {
      if (changed) {
        // Session may have ended during flush/push — falling edge already
        // passed, so arming the flag alone would leave the merge unapplied.
        if (_playback.hasSession) {
          _pendingApplyAfterPlayback = true;
        } else {
          JavpLog.i(
            'sync',
            'auto-sync schedule reason=playback-ended-during-push (apply)',
          );
          _scheduleAutoSync(urgent: true);
        }
      }
      JavpLog.i(
        'sync',
        'syncNow finished in ${watch.elapsedMilliseconds}ms '
            'changed=$changed flushMs=$flushMs syncMs=$syncMs '
            'reloadAfterSync=0ms apply=skip-playback',
      );
      return;
    }
    if (changed && mounted && identical(library, _library) && !skipReload) {
      // Light reload — full bootstrap was freezing the UI after every sync.
      final reload = Stopwatch()..start();
      await library.reloadAfterSync(
        changedSections: _profiles.lastChangedSections,
      );
      await _reloadSyncedAuxiliaryPrefs(_profiles.lastChangedSections);
      reloadMs = reload.elapsedMilliseconds;
      JavpLog.i('sync', 'reloadAfterSync in ${reloadMs}ms');
      // Catalog isn't in the snapshot; refill empty shelves from restored sources.
      // Waits for reveal settle internally; serial soft-sync slot caps stampede.
      unawaited(library.rebuildCatalogFromSources());
    }
    // The reload is the part users feel, so time the whole round trip and not
    // just the sync service's share of it.
    JavpLog.i(
      'sync',
      'syncNow finished in ${watch.elapsedMilliseconds}ms '
          'changed=$changed flushMs=$flushMs syncMs=$syncMs '
          'reloadAfterSync=${reloadMs}ms',
    );
  }

  /// Caption style and sports follows live outside [LibraryProvider].
  Future<void> _reloadSyncedAuxiliaryPrefs(List<String> changed) async {
    final all = changed.isEmpty;
    if (all || changed.contains(SnapshotSections.captionStyle)) {
      await _captions.reloadFromStore();
    }
    if (all || changed.contains(SnapshotSections.sportsFollows)) {
      await _sports.reloadFromStore();
    }
  }

  /// Swaps in a library bound to another profile. Recreating the providers is
  /// what guarantees no state leaks between profiles.
  Future<void> _switchProfile(
    Profile profile, {
    bool goHome = true,
    bool pinVerified = false,
  }) async {
    if (profile.id == _library.profileId) {
      if (pinVerified) _profiles.markProfileUnlocked();
      return;
    }
    if (!pinVerified && _profiles.isProfileLocked(profile.id)) {
      final ctx = _rootNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      final ok = await showProfileUnlockDialog(
        ctx,
        profileName: profile.name,
        verify: (pin) => _profiles.verifyLockPin(profile.id, pin),
      );
      if (!ok) return;
    }
    await _profiles.setActiveProfile(profile, sessionUnlocked: true);
    await _playback.stop();

    final previousLibrary = _library;
    final previousPlayback = _playback;
    // Reload parental prefs before the new library can serve Live listings.
    await _parental.bindProfile(profile.id);
    await _captions.bindProfile(profile.id);
    await _sports.bindProfile(profile.id);
    HomeShelfSnapshot? snap;
    try {
      snap = await LibraryStore(profileId: profile.id).loadHomeShelfSnapshot();
    } catch (_) {}
    final library = LibraryProvider(
      profileId: profile.id,
      homeShelfSnapshot: snap,
    );
    _wireCatalogLocale(library);
    _wireParentalLock(library);
    _attachLibrarySyncHook(library);
    setState(() {
      _library = library;
      _playback = PlaybackProvider(library: library);
    });
    _multiView.attachPlayback(_playback);
    unawaited(_multiView.exit());
    _playback.onWindowsLongBlurPaused = () {
      unawaited(_multiView.onAppBackgrounded());
    };
    _playback.addListener(_onPlaybackForDiscord);
    _playback.addListener(_onPlaybackForSync);
    _playback.addListener(_onPlaybackPipLifecycle);
    _lastSeenPip = _playback.isInPip;
    DesktopTrayService.instance.bindPlayback(_playback);
    DiscordPresenceService.instance.sync(_playback);
    _routerRefresh.attach(library);
    if (goHome) _router.go('/home');
    await library.bootstrap();

    // Dispose only once nothing can still be reading the old providers.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previousLibrary.onSyncableChanged = null;
      previousLibrary.onTorrentPrivacyTipNeeded = null;
      previousPlayback.removeListener(_onPlaybackForDiscord);
      previousPlayback.removeListener(_onPlaybackForSync);
      previousPlayback.removeListener(_onPlaybackPipLifecycle);
      previousPlayback.onWindowsLongBlurPaused = null;
      previousPlayback.dispose();
      previousLibrary.dispose();
    });

    if (_profiles.syncSettings.isConfigured) await _syncNow();
    // Restore uses goHome: false and shows its own prompt from Welcome.
    if (goHome && mounted) unawaited(_maybePromptTrackerLink());
  }

  /// Onboarding path for a device joining an existing sync folder: adopt the
  /// chosen profile and pull it down. Navigation is left to the restore screen,
  /// which is still on top of the stack at this point.
  Future<void> _restoreProfile(RemoteProfileEntry entry) async {
    final settings = _profiles.syncSettings;
    final profile = await _profiles.adoptRemoteProfile(
      entry,
      targetSettings: settings.isConfigured ? settings : null,
    );
    if (profile.id == _library.profileId) {
      await _syncNow();
    } else {
      await _switchProfile(profile, goHome: false);
    }
    if (!mounted) return;
    await _library.completeOnboarding();
  }

  void _cancelResumeWork() {
    _resumeDriveSyncTimer?.cancel();
    _resumeDriveSyncTimer = null;
    _resumeSimklTimer?.cancel();
    _resumeSimklTimer = null;
  }

  void _cancelPipSettle() {
    _pipSettleTimer?.cancel();
    _pipSettleTimer = null;
  }

  /// True AFK: stop library wake work, pause playback soft-resume bookkeeping.
  void _suspendForBackground() {
    if (_suspendedForBackground) return;
    if (_playback.isInPip) return;
    _suspendedForBackground = true;
    _lifecycleGen++;
    _cancelResumeWork();
    // setAppForeground(false) flushes pending writes — don't double-flush.
    _library.setAppForeground(false);
    unawaited(_playback.onAppBackgrounded());
    unawaited(_multiView.onAppBackgrounded());
    // Backgrounding is the last moment we are guaranteed to run, so the log
    // tail reaches disk even if the OS kills us instead of resuming.
    unawaited(JavpLog.instance.flush());
    unawaited(_flushPendingAutoSyncOnLeave(reason: 'background'));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router.routerDelegate.removeListener(_noteCurrentRoute);
    _cancelScheduledAutoSync();
    _cancelResumeWork();
    _cancelPipSettle();
    _deepLinks.setMethodCallHandler(null);
    _locale.removeListener(_onLocaleForTray);
    _locale.dispose();
    _parental.removeListener(_onParentalChanged);
    _parental.dispose();
    _updates.dispose();
    _routerRefresh.dispose();
    _captions.dispose();
    _sports.dispose();
    _multiView.dispose();
    _playback.removeListener(_onPlaybackForDiscord);
    _playback.removeListener(_onPlaybackForSync);
    _playback.removeListener(_onPlaybackPipLifecycle);
    _playback.onWindowsLongBlurPaused = null;
    unawaited(DiscordPresenceService.instance.dispose());
    final desktopQuitting = DesktopTrayService.instance.isQuitting;
    if (!desktopQuitting) {
      unawaited(DesktopTrayService.instance.dispose());
    }
    _detachDesktopShellHooks();
    // quitApp already stopped/released media_kit; avoid a second unawaited
    // engine teardown racing HWND/process shutdown on Windows.
    if (!desktopQuitting) {
      _playback.dispose();
    }
    _library.onSyncableChanged = null;
    _library.dispose();
    super.dispose();
  }

  Future<void> _startDesktopTray() async {
    await DesktopTrayService.instance.start(
      onOpenSettings: () {
        if (!mounted) return;
        _router.go('/settings/general');
      },
      onBeforeQuit: () => _flushPendingAutoSyncOnLeave(reason: 'quit'),
    );
    DesktopTrayService.instance.bindPlayback(_playback);
    _refreshTrayLabels();
  }

  /// Desktop blur/focus — defer Versions index / idle work. Playback is left
  /// running while the window is unfocused.
  Future<void> _startDesktopShellHooks() async {
    if (!isDesktopPlatform) return;
    try {
      windowManager.addListener(this);
    } catch (_) {
      // window_manager may be unavailable in tests.
    }
  }

  void _detachDesktopShellHooks() {
    if (!isDesktopPlatform) return;
    try {
      windowManager.removeListener(this);
    } catch (_) {}
  }

  @override
  void onWindowBlur() {
    // Spurious WM_NCACTIVATE "blur" fires mid-Synchroniser (category/VOD
    // work). Do NOT call windowManager.focus() here — SetForegroundWindow
    // from a blur storm leaves the HWND unable to take focus until the
    // process dies (see windows/runner/flutter_window.cpp). Only suppress
    // the Dart shell=false latch while Synchroniser holds focus.
    if (_library.shouldHoldDesktopFocusForSync) {
      JavpLog.i(
        'desktop',
        'ignore blur during manual sync (no focus() reclaim)',
      );
      HwndSyncTrace.noteDesktop('blur-ignored-manual-sync');
      return;
    }
    _library.setDesktopShellActive(false);
    _playback.onDesktopShellBlurred();
  }

  @override
  void onWindowFocus() {
    // Spurious activate after SyncEngine spawn/exit — ignore while Synchroniser
    // holds focus so we do not shell-thaw / feel focus jump mid-sync.
    if (_library.shouldHoldDesktopFocusForSync) {
      HwndSyncTrace.noteDesktop('focus-ignored-manual-sync');
      return;
    }
    _library.setDesktopShellActive(true);
    final resumeMultiView = _playback.pausedForWindowsLongBlur;
    unawaited(() async {
      await _playback.onDesktopShellFocused();
      if (resumeMultiView) {
        await _multiView.onAppForegrounded();
      }
    }());
  }

  void _onLocaleForTray() => _refreshTrayLabels();

  void _refreshTrayLabels() {
    final ctx = _rootNavigatorKey.currentContext;
    final l10n = ctx != null ? AppLocalizations.of(ctx) : null;
    if (l10n == null) {
      // Router may not have mounted yet — retry after the first frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _refreshTrayLabels();
      });
      return;
    }
    unawaited(
      DesktopTrayService.instance.setLabels(
        open: l10n.trayOpenApp,
        pause: l10n.pause,
        resume: l10n.resume,
        settings: l10n.navSettings,
        quit: l10n.trayQuit,
      ),
    );
  }

  void _onPlaybackForDiscord() {
    // DiscordPresenceService ignores position-only updates while playing
    // (heartbeat owns timestamps). Title / pause / session / art still push
    // immediately without waiting for the 15s pulse.
    DiscordPresenceService.instance.sync(_playback);
  }

  /// After a push-only sync, apply the remote merge once the player is gone.
  void _onPlaybackForSync() {
    final active = _playback.hasSession;
    if (_playbackHadSession && !active && _pendingApplyAfterPlayback) {
      _pendingApplyAfterPlayback = false;
      JavpLog.i('sync', 'auto-sync schedule reason=playback-ended (apply)');
      _scheduleAutoSync(urgent: true);
    }
    _playbackHadSession = active;
  }

  /// Leaving PiP while the activity is still paused (user closed the bubble)
  /// must apply the deferred AFK suspend.
  void _onPlaybackPipLifecycle() {
    final pip = _playback.isInPip;
    if (pip == _lastSeenPip) return;
    final wasPip = _lastSeenPip;
    _lastSeenPip = pip;
    if (!wasPip || pip) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (_suspendedForBackground) return;
    if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden) {
      _cancelPipSettle();
      _suspendForBackground();
    }
  }

  @override
  void didHaveMemoryPressure() {
    JavpMemory.handleMemoryPressure(
      onLibraryTrim: _library.dropTransientMemoryCaches,
    );
    super.didHaveMemoryPressure();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _cancelResumeWork();
        // Already in the PiP window — keep playback + bg queue warm.
        if (_playback.isInPip) {
          _cancelPipSettle();
          break;
        }
        // Android fires onPause before onPictureInPictureModeChanged. Wait a
        // beat so auto-enter PiP can claim the session before we AFK-pause and
        // unleash idle catalog syncs.
        if (_playback.hasSession && _playback.pip.isSupported) {
          _cancelPipSettle();
          // Auto-enter / OEM Home can report PiP after onPause. Wait long
          // enough that onPictureInPictureModeChanged can claim the session.
          _pipSettleTimer = Timer(_playback.pip.backgroundSettleDelay, () {
            _pipSettleTimer = null;
            if (!mounted) return;
            if (_playback.isInPip) return;
            _suspendForBackground();
          });
          break;
        }
        _cancelPipSettle();
        _suspendForBackground();
      case AppLifecycleState.resumed:
        _cancelPipSettle();
        final gen = ++_lifecycleGen;
        final wasSuspended = _suspendedForBackground;
        _suspendedForBackground = false;
        _library.setAppForeground(true);
        unawaited(_playback.onAppForegrounded());
        // Lock-on-resume applies to PiP / non-suspend resumes too.
        _parental.onAppResumed();
        // Android APK installer: recover if the user dismissed it while we
        // were still painting "Installing…".
        _updates.onAppResumed();
        unawaited(_multiView.onAppForegrounded());
        // PiP expand / settle abort never suspended — don't wake-sync stampede.
        if (!wasSuspended) break;
        // Mid-watch return: keep Drive / tracker pulls off the UI isolate.
        if (_playback.hasSession) break;
        // Defer wake work so the first frames after AFK aren't fighting Drive /
        // Simkl / media soft-resume on the UI isolate (Android ANR territory).
        _resumeDriveSyncTimer = Timer(const Duration(seconds: 5), () {
          if (!mounted || gen != _lifecycleGen) return;
          if (!_profiles.autoSyncEnabled) return;
          // Skip if we already synced recently — resume shouldn't stampede.
          final last = _profiles.lastSyncAt;
          if (last != null &&
              DateTime.now().toUtc().difference(last) <
                  const Duration(minutes: 10)) {
            return;
          }
          unawaited(_syncNow());
        });
        // After Drive window so Watching/catalog don't overlap snapshot hashing.
        _resumeSimklTimer = Timer(const Duration(seconds: 14), () {
          if (!mounted || gen != _lifecycleGen) return;
          if (_library.simkl.isAuthenticated) {
            unawaited(_library.syncSimklActivity());
          }
          if (_library.trakt.isAuthenticated) {
            unawaited(_library.syncTraktWatchlist());
          }
          if (_library.serializd.isAuthenticated) {
            unawaited(_library.syncSerializdActivity());
          }
          if (_library.betaseries.isAuthenticated) {
            unawaited(_library.syncBetaseriesLists());
          }
        });
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Future<bool> didPushRouteInformation(
    RouteInformation routeInformation,
  ) async {
    final raw = routeInformation.uri.toString();
    final uri = routeInformation.uri;
    if (isExternalDeepLink(uri) ||
        isJavpAddSourceLink(uri) ||
        isJavpPairLink(uri)) {
      unawaited(_handleExternalDeepLink(raw));
      return true;
    }
    return super.didPushRouteInformation(routeInformation);
  }

  Future<void> _consumeInitialDeepLink(String platformRoute) async {
    String? link;
    try {
      link = await _deepLinks.invokeMethod<String>('getInitialLink');
    } catch (_) {
      // Desktop / tests — channel may be missing.
    }
    link ??= WindowsProtocol.takeInitialLink();
    if (link != null && link.trim().isNotEmpty) {
      await _handleExternalDeepLink(link);
      return;
    }
    if (_openedViaExternalDeepLink) {
      await _handleExternalDeepLink(platformRoute);
    }
  }

  void _openFromEpgReminder(String mediaItemId) {
    void open() {
      if (_library.loading) {
        WidgetsBinding.instance.addPostFrameCallback((_) => open());
        return;
      }
      MediaItem? item = _library.itemById(mediaItemId);
      item ??= _library.liveChannels.cast<MediaItem?>().firstWhere(
        (c) => c?.id == mediaItemId,
        orElse: () => null,
      );
      if (item == null) return;
      if (_parental.isContentLocked && _parental.isItemHidden(item)) {
        // Locked: don't open hidden-group / hidden-source / adult items.
        return;
      }
      final resolved = _library.resolveLiveChannel(item);
      if (!_library.onboardingCompleted) {
        unawaited(_library.completeOnboarding());
      }
      // Open via player route so TV live redirect awaits the correct channel
      // before /tv/watch bootstrap (avoids retuning to first/recent).
      _router.go('/player', extra: resolved);
    }

    open();
  }

  Future<void> _handleExternalDeepLink(String uriString) async {
    final normalized = uriString.trim();
    if (normalized.isEmpty) return;
    // Ignore Flutter's default "/" and near-simultaneous warm/cold duplicates.
    // Same link may be opened again later (browser retry / QR re-scan).
    if (normalized == '/') return;
    final now = DateTime.now();
    if (normalized == _lastHandledDeepLink &&
        _lastHandledDeepLinkAt != null &&
        now.difference(_lastHandledDeepLinkAt!) < const Duration(seconds: 2)) {
      return;
    }
    final uri = Uri.tryParse(normalized);
    if (uri == null) return;
    if (!(isExternalDeepLink(uri) ||
        isJavpAddSourceLink(uri) ||
        isJavpPairLink(uri))) {
      return;
    }
    if (_handlingExternalOpen) return;
    _handlingExternalOpen = true;
    _lastHandledDeepLink = normalized;
    _lastHandledDeepLinkAt = now;
    try {
      if (isJavpPlexAuthLink(uri)) {
        // Returning from plex.tv — keep current UI (PIN poll / sheet) intact.
        return;
      }
      if (isJavpPairLink(uri)) {
        await _handleJavpPairLink(uri);
        return;
      }
      if (isJavpDeepLink(uri) || isJavpAddSourceLink(uri)) {
        await _handleJavpSourceLink(uri);
        return;
      }
      await _openExternalMedia(normalized);
    } finally {
      _handlingExternalOpen = false;
    }
  }

  Future<void> _openExternalMedia(String uriString) async {
    final item = mediaItemFromExternalUri(uriString, id: const Uuid().v4());
    final stored = await _library.upsertExternalMedia(item);
    // External open should land in the app, not force welcome.
    if (!_library.onboardingCompleted) {
      await _library.completeOnboarding();
    }
    _router.go('/home');
    _router.push('/player', extra: stored);
  }

  Future<void> _handleJavpPairLink(Uri uri) async {
    await _waitForLibraryReady();
    final request = parseJavpPairLink(uri);
    if (!_library.onboardingCompleted) {
      await _library.completeOnboarding();
    }
    _router.go('/home');
    await _waitForNavigatorReady();

    final ctx = _rootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) {
      _lastHandledDeepLink = null;
      _lastHandledDeepLinkAt = null;
      return;
    }
    if (request == null) {
      await showDialog<void>(
        context: ctx,
        useRootNavigator: true,
        builder: (context) {
          final l10n = context.l10n;
          return AlertDialog(
            title: Text(l10n.invalidLink),
            content: Text(l10n.devicePairInvalidLink),
            actions: [
              AppActionButton(
                variant: AppActionButtonVariant.text,
                onPressed: () {
                  Navigator.pop(context);
                  _router.go('/home');
                },
                label: l10n.back,
              ),
            ],
          );
        },
      );
      return;
    }
    await openDevicePairClient(ctx, request: request);
  }

  Future<void> _handleJavpSourceLink(Uri uri) async {
    await _waitForLibraryReady();
    // Parental lock starts "locked" (pessimistic) until its prefs load; the
    // dedupe check below runs against the full list while Sources renders the
    // filtered list, so wait here or a hidden-by-default source would report
    // "already added" without ever being visible.
    await _waitForParentalReady();

    final request = parseJavpSourceAddLink(uri);
    if (!_library.onboardingCompleted) {
      await _library.completeOnboarding();
    }
    // Land on Home under Sources so system/back never exits to the browser.
    _router.go('/home');
    await _waitForNavigatorReady();
    _router.push('/sources');
    await _waitForNavigatorReady();

    final ctx = _rootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) {
      // Allow a later warm delivery (e.g. single-instance WM_COPYDATA) to retry.
      _lastHandledDeepLink = null;
      _lastHandledDeepLinkAt = null;
      return;
    }

    if (_parental.hasPin && _parental.isContentLocked) {
      final unlocked = await ensureParentalUnlockedForSources(ctx);
      if (!unlocked || !ctx.mounted) {
        _router.go('/home');
        return;
      }
    }

    if (request == null) {
      await showDialog<void>(
        context: ctx,
        useRootNavigator: true,
        builder: (context) {
          final l10n = context.l10n;
          return AlertDialog(
            title: Text(l10n.invalidLink),
            content: Text(
              'This JAVP link could not be read.\n\n'
              'Received:\n$uri\n\n'
              'Expected:\n'
              'javp://add?type=custom|m3u|xtream&url=https://…',
            ),
            actions: [
              AppActionButton(
                variant: AppActionButtonVariant.text,
                onPressed: () {
                  Navigator.pop(context);
                  _router.go('/home');
                },
                label: l10n.back,
              ),
            ],
          );
        },
      );
      return;
    }

    final existing = _library.sources.cast<IptvSource?>().firstWhere((s) {
      if (s == null || s.type != request.type) return false;
      if (request.type == IptvSourceType.xtream) {
        return (s.serverUrl?.trim() == request.url) &&
            (s.username?.trim() == request.username?.trim());
      }
      if (request.type == IptvSourceType.stalker) {
        final requestMac = request.username?.trim() ?? '';
        final storedMac = s.username?.trim() ?? '';
        if (s.serverUrl?.trim() != request.url ||
            requestMac.isEmpty ||
            storedMac.isEmpty) {
          return false;
        }
        try {
          return StalkerClient.normalizeMac(storedMac) ==
              StalkerClient.normalizeMac(requestMac);
        } catch (_) {
          return storedMac == requestMac;
        }
      }
      return s.playlistUrl?.trim() == request.url;
    }, orElse: () => null);

    if (existing != null) {
      final resync = await showDialog<SourceAddConfirmAction>(
        context: ctx,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (context) {
          final l10n = context.l10n;
          return SourceAddConfirmDialog(
            title: l10n.sourceAlreadyAdded,
            summary:
                '"${existing.name}" is already in your sources.\n\n'
                '${request.confirmSummary}',
            primaryLabel: l10n.syncNow,
            busyLabel: l10n.syncing,
            // Rethrow real sync failures so the dialog shows error/retry
            // (syncSource normally swallows into library.error).
            onConfirm: () => _library.syncSource(
              existing.id,
              refreshVod: true,
              blockUi: false,
              reason: 'deep-link-resync',
              rethrowErrors: true,
            ),
          );
        },
      );
      if (resync != SourceAddConfirmAction.completed) {
        _router.go('/home');
      }
      return;
    }

    final displayName = request.name ?? request.defaultDisplayName;
    final action = await showDialog<SourceAddConfirmAction>(
      context: ctx,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (context) {
        final l10n = context.l10n;
        return SourceAddConfirmDialog(
          title: l10n.addSourceQuestion(request.typeLabel),
          summary: request.confirmSummary,
          primaryLabel: l10n.addAndSync,
          busyLabel: l10n.addingSource,
          showEdit: true,
          onConfirm: () => _addFromDeepLinkRequest(request, displayName),
        );
      },
    );

    if (action == SourceAddConfirmAction.completed) {
      _showRootSnackBar((l10n) => l10n.addedSyncingBackground(displayName));
      _router.go('/home');
      return;
    }
    if (action == SourceAddConfirmAction.edit) {
      if (!ctx.mounted) return;
      final saved = await showAddSourceSheet(ctx, prefill: request);
      if (saved) {
        _showRootSnackBar((l10n) => l10n.addedSyncingBackground(displayName));
      }
      _router.go('/home');
      return;
    }
    _router.go('/home');
  }

  Future<void> _addFromDeepLinkRequest(
    JavpSourceAddRequest request,
    String displayName,
  ) async {
    if (request.type == IptvSourceType.custom) {
      await _library.addCustomCatalogSource(
        name: displayName,
        catalogUrl: request.url,
      );
    } else if (request.type == IptvSourceType.m3u) {
      await _library.addM3uSource(
        name: displayName,
        playlistUrl: request.url,
        epgUrl: request.epgUrl,
      );
    } else if (request.type == IptvSourceType.xtream) {
      await _library.addXtreamSource(
        name: displayName,
        serverUrl: request.url,
        username: request.username ?? '',
        password: request.password ?? '',
        alternateServerUrl: request.alternateServerUrl,
      );
    } else if (request.type == IptvSourceType.stalker) {
      await _library.addStalkerSource(
        name: displayName,
        portalUrl: request.url,
        macAddress: request.username ?? '',
        serial: request.password,
      );
    }
  }

  /// SnackBars after `javp.app/add` must use the navigator context.
  /// [_JavpAppState.context] sits above [MaterialApp] and has no
  /// [AppLocalizations] (null-check crash on the confirmation snackbar).
  void _showRootSnackBar(String Function(AppLocalizations l10n) message) {
    final messenger = _rootNavigatorKey.currentContext;
    if (messenger == null || !messenger.mounted) return;
    ScaffoldMessenger.of(
      messenger,
    ).showSnackBar(SnackBar(content: Text(message(messenger.l10n))));
  }

  Future<void> _waitForLibraryReady() async {
    if (!_library.loading) return;
    final done = Completer<void>();
    void listener() {
      if (!_library.loading && !done.isCompleted) {
        done.complete();
      }
    }

    _library.addListener(listener);
    listener();
    try {
      await done.future.timeout(const Duration(seconds: 30));
    } catch (_) {
      // Proceed anyway; add/sync will surface errors if needed.
    } finally {
      _library.removeListener(listener);
    }
  }

  /// Parental state gates source visibility; resolve it before deciding
  /// whether a deep-link source is a duplicate so a just-added source that is
  /// hidden behind the lock doesn't look like it was never added.
  Future<void> _waitForParentalReady() async {
    if (_parental.ready) return;
    final done = Completer<void>();
    void listener() {
      if (_parental.ready && !done.isCompleted) done.complete();
    }

    _parental.addListener(listener);
    listener();
    try {
      await done.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      // Proceed with the pessimistic default; the duplicate dialog still
      // behaves correctly for genuinely existing sources.
    } finally {
      _parental.removeListener(listener);
    }
  }

  Future<void> _waitForNavigatorReady() async {
    for (var i = 0; i < 40; i++) {
      final nav = _rootNavigatorKey.currentState;
      if (nav != null && nav.mounted && nav.overlay != null) {
        await WidgetsBinding.instance.endOfFrame;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await WidgetsBinding.instance.endOfFrame;
  }

  GoRouter _buildRouter() {
    return GoRouter(
      navigatorKey: _rootNavigatorKey,
      initialLocation: '/home',
      refreshListenable: _routerRefresh,
      // Keep MediaItem extras typed across router refreshes / history restores.
      extraCodec: const JavpRouteExtraCodec(),
      // Android VIEW / javp:// intents pass as the platform route.
      // That is not an app path — start on /home and handle externally.
      overridePlatformDefaultLocation: _openedViaExternalDeepLink,
      redirect: (context, state) {
        if (_library.loading) return null;
        if (_openedViaExternalDeepLink || _handlingExternalOpen) return null;

        final loc = state.matchedLocation;
        final onWelcome = loc == '/welcome';
        // Deep-link add flow lands on Sources before onboarding is marked done;
        // don't bounce it back to Welcome.
        final onboardingExempt =
            loc == '/sources' || loc == '/add' || loc == '/pair';

        if (!_library.onboardingCompleted && !onWelcome && !onboardingExempt) {
          return '/welcome';
        }
        if (_library.onboardingCompleted && onWelcome) {
          return '/home';
        }
        return null;
      },
      onException: (context, state, router) {
        if (isExternalDeepLink(state.uri) ||
            isJavpAddSourceLink(state.uri) ||
            isJavpPairLink(state.uri)) {
          // Stay on the current route until the handler navigates deliberately.
          unawaited(_handleExternalDeepLink(state.uri.toString()));
          return;
        }
        router.go('/home');
      },
      routes: [
        GoRoute(
          path: '/welcome',
          builder: (context, state) => const WelcomeScreen(),
        ),
        // Path-style fallback when a platform strips `javp://` to `/add?…`.
        GoRoute(
          path: '/add',
          redirect: (context, state) {
            unawaited(_handleExternalDeepLink(state.uri.toString()));
            return '/sources';
          },
        ),
        // Path-style fallback when a platform strips `javp://` to `/pair?…`.
        GoRoute(
          path: '/pair',
          redirect: (context, state) {
            unawaited(_handleExternalDeepLink(state.uri.toString()));
            return '/home';
          },
        ),
        StatefulShellRoute(
          builder: (context, state, navigationShell) {
            return ShellScreen(navigationShell: navigationShell);
          },
          navigatorContainerBuilder: buildShellBranchContainer,
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/home',
                  builder: (context, state) => const HomeScreen(),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/tv',
                  builder: (context, state) => const TvScreen(),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/catalog',
                  builder: (context, state) => const CatalogScreen(),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/music',
                  builder: (context, state) => const MusicScreen(),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/library',
                  builder: (context, state) => const LibraryScreen(),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/settings',
                  builder: (context, state) => const SettingsScreen(),
                  routes: [
                    // Default Material zoom via builder: (no custom page).
                    // Opaque AppColors.bg on SettingsScreen / SettingsSubpage
                    // prevents the hub from showing through during the zoom.
                    GoRoute(
                      path: 'general',
                      builder: (context, state) => SettingsSubpage(
                        title: context.l10n.settingsGeneral,
                        child: const SettingsGeneralTab(),
                      ),
                    ),
                    GoRoute(
                      path: 'appearance',
                      builder: (context, state) => SettingsSubpage(
                        title: context.l10n.settingsAppearance,
                        child: const SettingsAppearanceTab(),
                      ),
                    ),
                    GoRoute(
                      path: 'parental',
                      builder: (context, state) => SettingsSubpage(
                        title: context.l10n.parentalControls,
                        child: const SettingsParentalTab(),
                      ),
                    ),
                    GoRoute(
                      path: 'profiles',
                      builder: (context, state) => SettingsSubpage(
                        title: context.l10n.settingsProfiles,
                        child: const SettingsProfilesTab(),
                      ),
                    ),
                    GoRoute(
                      path: 'integrations',
                      builder: (context, state) => SettingsSubpage(
                        title: context.l10n.settingsIntegrations,
                        child: const SettingsIntegrationsTab(),
                      ),
                    ),
                    GoRoute(
                      path: 'playback',
                      builder: (context, state) => SettingsSubpage(
                        title: context.l10n.settingsPlayback,
                        child: const SettingsPlaybackTab(),
                      ),
                    ),
                    GoRoute(
                      path: 'network',
                      builder: (context, state) => SettingsSubpage(
                        title: context.l10n.settingsNetwork,
                        child: const SettingsNetworkTab(),
                      ),
                    ),
                    GoRoute(
                      path: 'diagnostics',
                      builder: (context, state) => SettingsSubpage(
                        title: context.l10n.settingsDiagnostics,
                        child: const SettingsDiagnosticsTab(),
                      ),
                    ),
                    GoRoute(
                      path: 'sports',
                      builder: (context, state) => SettingsSubpage(
                        title: context.l10n.sportsSettings,
                        child: const SportsSettingsTab(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        // Legacy bookmark — the old IptvScreen is gone; TV is the live tab.
        GoRoute(path: '/iptv', redirect: (context, state) => '/tv'),
        GoRoute(
          path: '/sports',
          builder: (context, state) => const SportsScreen(),
        ),
        GoRoute(
          path: '/history',
          parentNavigatorKey: _rootNavigatorKey,
          pageBuilder: (context, state) =>
              _instantOverlayPage(state, const HistoryScreen()),
        ),
        GoRoute(
          path: '/sources',
          parentNavigatorKey: _rootNavigatorKey,
          pageBuilder: (context, state) =>
              _instantOverlayPage(state, const SourcesScreen()),
        ),
        GoRoute(
          path: '/search',
          parentNavigatorKey: _rootNavigatorKey,
          pageBuilder: (context, state) =>
              _instantOverlayPage(state, const SearchScreen()),
        ),
        GoRoute(
          path: '/mylist',
          parentNavigatorKey: _rootNavigatorKey,
          pageBuilder: (context, state) {
            final extra = state.extra;
            return _instantOverlayPage(
              state,
              MyListScreen(
                initialSource: extra is MyListSourceFilter ? extra : null,
              ),
            );
          },
        ),
        GoRoute(
          path: '/catalog/category',
          builder: (context, state) {
            final extra = state.extra;
            final IptvCategory category;
            Set<String>? sourceKeys;
            if (extra is CatalogCategoryArgs) {
              category = extra.category;
              sourceKeys = extra.sourceKeys;
            } else if (extra is IptvCategory) {
              category = extra;
            } else {
              return Scaffold(
                body: Center(child: Text(context.l10n.categoryNotFound)),
              );
            }
            return CatalogCategoryScreen(
              category: category,
              sourceKeys: sourceKeys,
            );
          },
        ),
        GoRoute(
          path: '/captions',
          builder: (context, state) => const CaptionStyleScreen(),
        ),
        GoRoute(
          path: '/series',
          builder: (context, state) {
            final item = mediaItemFromRouteExtra(state.extra);
            if (item == null) {
              return Scaffold(
                body: Center(child: Text(context.l10n.seriesNotFound)),
              );
            }
            return SeriesDetailScreen(series: item);
          },
        ),
        GoRoute(
          path: '/title',
          builder: (context, state) {
            final item = mediaItemFromRouteExtra(state.extra);
            if (item == null) {
              return Scaffold(
                body: Center(child: Text(context.l10n.titleNotFound)),
              );
            }
            if (_parental.isContentLocked && _parental.isItemHidden(item)) {
              return Scaffold(
                body: Center(child: Text(context.l10n.titleNotFound)),
              );
            }
            return TitleDetailScreen(item: item);
          },
        ),
        GoRoute(
          path: '/player',
          parentNavigatorKey: _rootNavigatorKey,
          pageBuilder: (context, state) {
            final item = mediaItemFromRouteExtra(state.extra);
            final Widget child;
            if (item == null) {
              child = Scaffold(
                body: Center(child: Text(context.l10n.nothingToPlay)),
              );
            } else if (_parental.isContentLocked &&
                _parental.isItemHidden(item)) {
              child = Scaffold(
                body: Center(child: Text(context.l10n.nothingToPlay)),
              );
            } else {
              child = PlayerScreen(item: item);
            }
            return _instantOverlayPage(state, child);
          },
        ),
        GoRoute(
          path: '/cast',
          builder: (context, state) => const CastRemoteScreen(),
        ),
        // Fullscreen live zapper — root route so Home → Watch live does not
        // switch the shell tab to Direct before the player covers the screen.
        GoRoute(
          path: '/tv/watch',
          parentNavigatorKey: _rootNavigatorKey,
          pageBuilder: (context, state) =>
              _instantOverlayPage(state, const TvLiveOverlayScreen()),
        ),
        GoRoute(
          path: '/genres',
          builder: (context, state) => const GenreBrowseScreen(),
        ),
        GoRoute(
          path: '/collections',
          builder: (context, state) => const CollectionsScreen(),
        ),
        GoRoute(
          path: '/playlists',
          builder: (context, state) => const PlaylistsScreen(),
        ),
        GoRoute(
          path: '/downloads',
          builder: (context, state) => const DownloadsScreen(),
        ),
        GoRoute(
          path: '/downloaded-series',
          builder: (context, state) => const DownloadedSeriesScreen(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _library),
        ChangeNotifierProvider.value(value: _playback),
        ChangeNotifierProvider.value(value: _parental),
        ChangeNotifierProvider.value(value: _sports),
        ChangeNotifierProvider.value(value: _multiView),
        ChangeNotifierProvider.value(value: _captions),
        ChangeNotifierProvider.value(value: _locale),
        ChangeNotifierProvider.value(value: _updates),
        ChangeNotifierProvider.value(value: _profiles),
        Provider<ShellActions>.value(
          value: ShellActions(
            switchProfile: (profile, {pinVerified = false}) =>
                _switchProfile(profile, pinVerified: pinVerified),
            syncNow: _syncNow,
            restoreProfile: _restoreProfile,
          ),
        ),
      ],
      child: ListenableBuilder(
        listenable: _locale,
        builder: (context, _) {
          return MaterialApp.router(
            onGenerateTitle: (context) => context.l10n.appTitle,
            debugShowCheckedModeBanner: false,
            theme: AppTheme.dark(),
            // Click-hold-drag pans lists/grids on desktop (wheel still works).
            scrollBehavior: DesktopUi.enabled
                ? const DesktopScrollBehavior()
                : const MaterialScrollBehavior(),
            routerConfig: _router,
            locale: _locale.overrideLocale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) {
              Widget tree = ProfileLockOverlay(
                child: ParentalUnlockOverlay(
                  child: ProfileSyncBanner(
                    router: _router,
                    child: TvShellShortcuts(
                      child: DesktopShortcuts(
                        router: _router,
                        child: GamepadNavigator(
                          navigatorKey: _rootNavigatorKey,
                          child: PersistentMiniPlayer(
                            router: _router,
                            child: child,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              if (LibraryWorkDebugOverlay.enabled) {
                tree = LibraryWorkDebugOverlay(child: tree);
              }
              return AppScaffoldMessenger(child: tree);
            },
          );
        },
      ),
    );
  }
}

/// Forwards only onboarding/loading flips from [LibraryProvider] so sync/VOD/
/// history notifies do not refresh the entire GoRouter shell tree.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(this._source) {
    _loading = _source.loading;
    _onboarding = _source.onboardingCompleted;
    _source.addListener(_onLibrary);
  }

  LibraryProvider _source;
  bool _loading = true;
  bool _onboarding = false;

  void _onLibrary() {
    final loading = _source.loading;
    final onboarding = _source.onboardingCompleted;
    if (loading == _loading && onboarding == _onboarding) return;
    _loading = loading;
    _onboarding = onboarding;
    notifyListeners();
  }

  void attach(LibraryProvider source) {
    _source.removeListener(_onLibrary);
    _source = source;
    _loading = source.loading;
    _onboarding = source.onboardingCompleted;
    _source.addListener(_onLibrary);
    notifyListeners();
  }

  @override
  void dispose() {
    _source.removeListener(_onLibrary);
    super.dispose();
  }
}
