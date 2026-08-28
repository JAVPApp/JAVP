import 'dart:async';

class TrayMenuItem {
  const TrayMenuItem({
    this.key,
    this.label,
    this.disabled = false,
  });

  factory TrayMenuItem.separator() => const TrayMenuItem(key: '__separator__');

  final String? key;
  final String? label;
  final bool disabled;
}

Future<void> initTray({
  required String iconAsset,
  required String tooltip,
  required void Function() onWindowClose,
  required void Function() onTrayIconClick,
  required void Function() onTrayIconRightClick,
  required void Function(String key) onMenuItemClick,
}) async {}

void removeTrayListeners() {}

Future<void> destroyTray() async {}

Future<void> setPreventClose(bool prevent) async {}

Future<void> showWindow() async {}

Future<void> hideWindow() async {}

Future<void> popUpContextMenu() async {}

Future<void> setTrayMenu(List<TrayMenuItem> items) async {}

void exitApp(int code) {
  // Web cannot exit; no-op.
}
