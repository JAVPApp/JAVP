import 'dart:async';
import 'dart:io';

import 'package:javp/compat/tray_manager.dart';
import 'package:javp/compat/window_manager.dart';

class TrayMenuItem {
  const TrayMenuItem({
    this.key,
    this.label,
    this.disabled = false,
  }) : _isSeparator = false;

  const TrayMenuItem._separator()
      : key = '__separator__',
        label = null,
        disabled = false,
        _isSeparator = true;

  factory TrayMenuItem.separator() => const TrayMenuItem._separator();

  final String? key;
  final String? label;
  final bool disabled;
  final bool _isSeparator;
}

void Function()? _onWindowClose;
void Function()? _onTrayIconClick;
void Function()? _onTrayIconRightClick;
void Function(String key)? _onMenuItemClick;

final _TrayHandler _handler = _TrayHandler();

class _TrayHandler with TrayListener, WindowListener {
  @override
  void onWindowClose() {
    _onWindowClose?.call();
  }

  @override
  void onTrayIconMouseDown() {
    _onTrayIconClick?.call();
  }

  @override
  void onTrayIconRightMouseDown() {
    _onTrayIconRightClick?.call();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key;
    if (key != null) {
      _onMenuItemClick?.call(key);
    }
  }
}

Future<void> initTray({
  required String iconAsset,
  required String tooltip,
  required void Function() onWindowClose,
  required void Function() onTrayIconClick,
  required void Function() onTrayIconRightClick,
  required void Function(String key) onMenuItemClick,
}) async {
  _onWindowClose = onWindowClose;
  _onTrayIconClick = onTrayIconClick;
  _onTrayIconRightClick = onTrayIconRightClick;
  _onMenuItemClick = onMenuItemClick;

  await windowManager.setPreventClose(true);
  windowManager.addListener(_handler);
  trayManager.addListener(_handler);
  await trayManager.setIcon(iconAsset);
  await trayManager.setToolTip(tooltip);
}

void removeTrayListeners() {
  windowManager.removeListener(_handler);
  trayManager.removeListener(_handler);
}

Future<void> destroyTray() => trayManager.destroy();

Future<void> setPreventClose(bool prevent) => windowManager.setPreventClose(prevent);

Future<void> showWindow() async {
  await windowManager.show();
  await windowManager.focus();
  if (await windowManager.isMinimized()) {
    await windowManager.restore();
  }
}

Future<void> hideWindow() => windowManager.hide();

Future<void> popUpContextMenu() => trayManager.popUpContextMenu();

Future<void> setTrayMenu(List<TrayMenuItem> items) async {
  await trayManager.setContextMenu(
    Menu(
      items: items.map((item) {
        if (item._isSeparator) return MenuItem.separator();
        return MenuItem(
          key: item.key,
          label: item.label,
          disabled: item.disabled,
        );
      }).toList(),
    ),
  );
}

void exitApp(int code) => exit(code);
