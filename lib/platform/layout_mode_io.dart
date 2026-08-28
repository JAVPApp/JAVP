import 'dart:io' show Platform;

String? get javpUiEnv => Platform.environment['JAVP_UI'];

String? get steamDeck => Platform.environment['SteamDeck'];

bool get isGamescopeSession {
  if (!Platform.isLinux) return false;
  final gamescopeDisplay = Platform.environment['GAMESCOPE_WAYLAND_DISPLAY'];
  if (gamescopeDisplay != null && gamescopeDisplay.isNotEmpty) {
    return true;
  }
  final desktop = Platform.environment['XDG_CURRENT_DESKTOP']?.toLowerCase();
  final session = Platform.environment['XDG_SESSION_DESKTOP']?.toLowerCase();
  return desktop == 'gamescope' || session == 'gamescope';
}
