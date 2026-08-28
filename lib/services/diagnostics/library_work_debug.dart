/// Compact HUD / log dump of library work that can freeze the Windows UI.
class LibraryWorkDebugSnapshot {
  const LibraryWorkDebugSnapshot({
    required this.route,
    required this.stallPhase,
    required this.lastYieldMs,
    required this.foreground,
    required this.shellActive,
    required this.thawing,
    required this.uiQuiet,
    required this.playbackActive,
    required this.syncPhase,
    required this.playlistSync,
    required this.epgPending,
    required this.vodPrefetch,
    required this.liveFill,
    required this.deepSync,
    this.status,
  });

  final String route;
  final String stallPhase;
  final int lastYieldMs;
  final bool foreground;
  final bool shellActive;
  final bool thawing;
  final bool uiQuiet;
  final bool playbackActive;
  final String syncPhase;
  final List<String> playlistSync;
  final List<String> epgPending;
  final List<String> vodPrefetch;
  final List<String> liveFill;
  final List<String> deepSync;
  final String? status;

  bool get hasLatchedJob =>
      playlistSync.isNotEmpty ||
      epgPending.isNotEmpty ||
      vodPrefetch.isNotEmpty ||
      liveFill.isNotEmpty ||
      deepSync.isNotEmpty;

  /// On-screen only while a named follow-on job is latched. Quiet leftover,
  /// thaw, and an idle `stall=-` dump must not keep an orange box up.
  bool get showHud => hasLatchedJob;

  bool get hasWork => showHud || uiQuiet;

  /// On-screen HUD. Keep it short — this paints every 250ms in debug.
  String toOverlayText() {
    final statusLine = (status == null || status!.isEmpty) ? '-' : status!;
    return 'stall=$stallPhase  yield=${lastYieldMs}ms\n'
        'fg=${_bit(foreground)} shell=${_bit(shellActive)} '
        'thaw=${_bit(thawing)} quiet=${_bit(uiQuiet)} '
        'play=${_bit(playbackActive)}\n'
        'phase=$syncPhase\n'
        'playlist=[${playlistSync.join(',')}] '
        'epg=[${epgPending.join(',')}]\n'
        'vod=[${vodPrefetch.join(',')}] '
        'live=[${liveFill.join(',')}] '
        'deep=[${deepSync.join(',')}]\n'
        'status=$statusLine\n'
        'route=$route';
  }

  /// One-line journal (stalls + heartbeat).
  String toLogLine() {
    return 'stall=$stallPhase yield=${lastYieldMs}ms '
        'fg=${_bit(foreground)} shell=${_bit(shellActive)} '
        'thaw=${_bit(thawing)} quiet=${_bit(uiQuiet)} '
        'phase=$syncPhase '
        'playlist=${playlistSync.join('|')} '
        'epg=${epgPending.join('|')} '
        'vod=${vodPrefetch.join('|')} '
        'live=${liveFill.join('|')} '
        'deep=${deepSync.join('|')} '
        'route=$route '
        'status=${status ?? '-'}';
  }

  static String _bit(bool v) => v ? '1' : '0';
}

String shortSourceId(String id) => id.length <= 8 ? id : id.substring(0, 8);
