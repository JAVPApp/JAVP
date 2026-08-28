/// Web stub for tray_manager — no-op implementations.
library tray_manager_stub;

import 'dart:async';

final TrayManager trayManager = TrayManager._();

class TrayManager {
  TrayManager._();

  final List<TrayListener> _listeners = [];

  Future<void> setIcon(String iconPath) async {}
  Future<void> setToolTip(String toolTip) async {}
  Future<void> setContextMenu(Menu menu) async {}
  Future<void> popUpContextMenu() async {}
  Future<void> destroy() async {}

  void addListener(TrayListener listener) {
    _listeners.add(listener);
  }

  void removeListener(TrayListener listener) {
    _listeners.remove(listener);
  }
}

class Menu {
  const Menu({this.items = const []});
  final List<MenuItem> items;
}

class MenuItem {
  const MenuItem({
    this.key,
    this.label,
    this.icon,
    this.toolTip,
    this.disabled = false,
    this.checked,
    this.submenu,
    this.onClick,
  });

  factory MenuItem.separator() => const MenuItem(key: '__separator__');
  factory MenuItem.checkbox({
    String? key,
    String? label,
    bool checked = false,
    void Function(MenuItem)? onClick,
  }) => MenuItem(key: key, label: label, checked: checked, onClick: onClick);

  final String? key;
  final String? label;
  final String? icon;
  final String? toolTip;
  final bool disabled;
  final bool? checked;
  final Menu? submenu;
  final void Function(MenuItem)? onClick;
}

mixin TrayListener {
  void onTrayIconMouseDown() {}
  void onTrayIconMouseUp() {}
  void onTrayIconRightMouseDown() {}
  void onTrayIconRightMouseUp() {}
  void onTrayMenuItemClick(MenuItem menuItem) {}
}
