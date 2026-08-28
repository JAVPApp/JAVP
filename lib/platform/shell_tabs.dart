/// Fixed shell branches. [music] can be hidden from the nav without
/// dropping the `/music` route (Library still opens it).
enum ShellTab { home, tv, catalog, music, library, settings }

/// Maps visible bottom-nav / rail destinations onto [StatefulNavigationShell]
/// branch indices when the Music tab is optional.
class ShellTabs {
  ShellTabs._();

  static const List<ShellTab> _withoutMusic = [
    ShellTab.home,
    ShellTab.tv,
    ShellTab.catalog,
    ShellTab.library,
    ShellTab.settings,
  ];

  static List<ShellTab> visible({required bool showMusic}) =>
      showMusic ? ShellTab.values : _withoutMusic;

  /// Nav highlight for [branchIndex]. Music-while-hidden maps to Library.
  static int visibleIndex({required int branchIndex, required bool showMusic}) {
    final tabs = visible(showMusic: showMusic);
    final i = tabs.indexWhere((t) => t.index == branchIndex);
    if (i >= 0) return i;
    if (branchIndex == ShellTab.music.index) {
      return tabs.indexOf(ShellTab.library);
    }
    return 0;
  }

  static int branchIndexForVisible({
    required int visibleIndex,
    required bool showMusic,
  }) {
    final tabs = visible(showMusic: showMusic);
    if (visibleIndex < 0 || visibleIndex >= tabs.length) {
      return ShellTab.home.index;
    }
    return tabs[visibleIndex].index;
  }
}
