import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';

/// Which shell tab is visible — children can skip heavy work when inactive.
class ShellVisibility extends InheritedWidget {
  const ShellVisibility({
    super.key,
    required this.active,
    required this.index,
    required super.child,
  });

  final bool active;
  final int index;

  static bool isActive(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<ShellVisibility>()
            ?.active ??
        true;
  }

  static bool isActiveOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<ShellVisibility>()?.active ??
        true;
  }

  @override
  bool updateShouldNotify(ShellVisibility oldWidget) =>
      active != oldWidget.active || index != oldWidget.index;
}

/// Skip layout/paint of [child] without dropping its Element tree.
///
/// Covering routes (player / search) used to return [SizedBox.expand], which
/// disposed the shelf tree and remounted it — the hitch when collapsing the
/// mini player back onto Home / Catalog.
Widget keepShellTabTree({required bool skip, required Widget child}) {
  return SkipLayout(skip: skip, child: child);
}

/// Keeps [child] mounted (State / Elements / last layout) but reports [size]
/// without laying out or painting the child while [skip] is true.
///
/// Used instead of [Offstage] for shell tabs: Offstage still lays out hidden
/// trees on every tab switch; returning [SizedBox] avoided that but forced a
/// full remount hitch when coming back to Home.
class SkipLayout extends SingleChildRenderObjectWidget {
  const SkipLayout({super.key, required this.skip, super.child});

  final bool skip;

  @override
  RenderSkipLayout createRenderObject(BuildContext context) {
    return RenderSkipLayout(skip: skip);
  }

  @override
  void updateRenderObject(BuildContext context, RenderSkipLayout renderObject) {
    renderObject.skip = skip;
  }
}

class RenderSkipLayout extends RenderProxyBox {
  RenderSkipLayout({required bool skip}) : _skip = skip;

  bool _skip;

  bool get skip => _skip;

  set skip(bool value) {
    if (_skip == value) return;
    _skip = value;
    markNeedsLayout();
    // Do not markNeedsSemanticsUpdate. Covering Home/Catalog with /player
    // used to drop tens of thousands of poster semantics nodes and hitch
    // the Windows AXTree on the UI isolate.
  }

  @override
  void performLayout() {
    if (_skip) {
      // Fill the Stack slot; leave the child's last layout intact.
      size = constraints.biggest;
      return;
    }
    super.performLayout();
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (_skip) return false;
    return super.hitTest(result, position: position);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_skip) return;
    super.paint(context, offset);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_skip) return;
    super.visitChildrenForSemantics(visitor);
  }
}

/// Keeps branch navigators alive (scroll/state) but only the active tab is
/// interactive / laid out. Inactive branches stay mounted under [SkipLayout]
/// so returning to a tab does not remount a heavy shelf tree.
///
/// Pair with [ShellVisibility] so screens can freeze shelf *recomputes* and
/// keep returning their last [_frozenTree] while inactive (see Home/TV/Catalog).
class ShellBranchHost extends StatelessWidget {
  const ShellBranchHost({
    super.key,
    required this.currentIndex,
    required this.children,
  });

  final int currentIndex;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < children.length; i++)
          ShellVisibility(
            active: i == currentIndex,
            index: i,
            child: TickerMode(
              enabled: i == currentIndex,
              child: SkipLayout(
                skip: i != currentIndex,
                // Keep the navigator + screen Element tree mounted. Screens
                // should return their frozen widget tree while inactive so
                // reactivation can skip inflate/layout when nothing changed.
                // ExcludeSemantics stops Windows AXTree rebuilds of hidden
                // Home/Catalog trees (those flooded accessibility_bridge).
                child: ExcludeSemantics(
                  excluding: i != currentIndex,
                  child: children[i],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

Widget buildShellBranchContainer(
  BuildContext context,
  StatefulNavigationShell navigationShell,
  List<Widget> children,
) {
  return ShellBranchHost(
    currentIndex: navigationShell.currentIndex,
    children: children,
  );
}
