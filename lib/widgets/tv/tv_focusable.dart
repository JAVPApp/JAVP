import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/poster_lift.dart';
import 'package:javp/widgets/tv/tv_shell_focus.dart';

/// How long OK / Select must be held for [TvFocusable.onLongSelect].
const tvLongPressDuration = Duration(milliseconds: 500);

/// When this returns true, [TvFocusable.onLongSelect] is skipped.
///
/// Used so hold-OK can close the mini player from any focused tile.
bool Function()? tvConsumeLongSelect;

/// True while the corner mini player is up — OK is hold-to-close, so Select
/// is deferred to key-up even on tiles that have no [TvFocusable.onLongSelect].
bool Function()? tvHoldOkClosesMiniPlayer;

/// Focusable wrapper with a clear 10-foot highlight ring.
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    this.onSelect,
    this.onLongSelect,
    this.onFocusChange,
    this.autofocus = false,
    this.focusNode,
    this.borderRadius = 12,
    this.padding = EdgeInsets.zero,
    this.enabled = true,
    this.skipTraversalUnlessNearby = false,
    this.expandOnFocus = false,
  });

  final Widget child;
  final VoidCallback? onSelect;

  /// Held OK / Select (or the remote's menu key) — the TV equivalent of a
  /// long-press. When set, [onSelect] fires on key release instead of key down
  /// so a hold cannot also activate the tile.
  final VoidCallback? onLongSelect;
  final ValueChanged<bool>? onFocusChange;
  final bool autofocus;
  final FocusNode? focusNode;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final bool enabled;

  /// Skip D-pad traversal unless the focused widget is nearby — or this
  /// control is the only way Down (next shelf still loading / not built).
  ///
  /// Shelf Favorite / See all sit between poster rows; without this, Down
  /// from a left-side poster prefers those header actions over the next row.
  /// They stay reachable with Up from a nearby or last poster, Left/Right
  /// between the two actions, and Down when the next row has no tiles yet.
  final bool skipTraversalUnlessNearby;

  /// Poster tiles grow shelf-style in the nearest overlay so neighbors do
  /// not cover the focused card, and the lift stays inside the content pane
  /// instead of painting over the rail. Buttons / list rows keep the small
  /// in-place scale.
  final bool expandOnFocus;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  static final _selectKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.gameButtonA,
  };
  static final _menuKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.contextMenu,
    LogicalKeyboardKey.gameButtonY,
  };

  FocusNode? _ownedNode;
  bool _focused = false;
  Timer? _holdTimer;
  bool _longFired = false;
  bool _holdConsumed = false;
  DateTime? _holdConsumeUntil;
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _visualKey = GlobalKey();
  Size? _size;
  bool _expanded = false;

  FocusNode get _node => widget.focusNode ?? _ownedNode!;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _ownedNode = FocusNode(debugLabel: 'TvFocusable');
    }
    _node.addListener(_onFocus);
    _node.onKeyEvent = _onNodeKey;
    _attachProximityTraversal(enabled: widget.skipTraversalUnlessNearby);
  }

  @override
  void didUpdateWidget(covariant TvFocusable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      _stopProximityTraversal(node: oldWidget.focusNode ?? _ownedNode);
      final previous = oldWidget.focusNode ?? _ownedNode;
      previous?.removeListener(_onFocus);
      previous?.onKeyEvent = null;
      if (widget.focusNode == null && _ownedNode == null) {
        _ownedNode = FocusNode(debugLabel: 'TvFocusable');
      }
      if (widget.focusNode != null && _ownedNode != null) {
        _ownedNode!.dispose();
        _ownedNode = null;
      }
      _node.addListener(_onFocus);
      _node.onKeyEvent = _onNodeKey;
      _focused = _node.hasFocus;
      _attachProximityTraversal(enabled: widget.skipTraversalUnlessNearby);
    } else if (oldWidget.skipTraversalUnlessNearby !=
        widget.skipTraversalUnlessNearby) {
      _stopProximityTraversal(node: widget.focusNode ?? _ownedNode);
      _attachProximityTraversal(enabled: widget.skipTraversalUnlessNearby);
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    if (_portal.isShowing) _portal.hide();
    _stopProximityTraversal(node: widget.focusNode ?? _ownedNode);
    _node.removeListener(_onFocus);
    _node.onKeyEvent = null;
    _ownedNode?.dispose();
    super.dispose();
  }

  bool _proximityListening = false;

  static final _proximityHeaderNodes = <FocusNode>{};

  void _attachProximityTraversal({required bool enabled}) {
    if (!enabled) {
      _proximityHeaderNodes.remove(_node);
      _node.skipTraversal = false;
      return;
    }
    _proximityHeaderNodes.add(_node);
    _node.skipTraversal = true;
    if (!_proximityListening) {
      FocusManager.instance.addListener(_syncSkipTraversal);
      _proximityListening = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncSkipTraversal());
  }

  void _stopProximityTraversal({FocusNode? node}) {
    if (_proximityListening) {
      FocusManager.instance.removeListener(_syncSkipTraversal);
      _proximityListening = false;
    }
    final target = node ?? _ownedNode;
    if (target != null) {
      _proximityHeaderNodes.remove(target);
      target.skipTraversal = false;
    }
  }

  Rect? _globalRect(FocusNode node) {
    final box = node.context?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _syncSkipTraversal() {
    if (!mounted || !widget.skipTraversalUnlessNearby) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncSkipTraversal());
      return;
    }
    if (_node.hasFocus) {
      _node.skipTraversal = false;
      return;
    }
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || identical(primary, _node)) {
      _node.skipTraversal = true;
      return;
    }
    final from = _globalRect(primary);
    final self = _globalRect(_node);
    if (from == null || self == null) {
      _node.skipTraversal = true;
      return;
    }
    final scope = _node.nearestScope;
    _node.skipTraversal = !tvHeaderActionAcceptsFocusFrom(
      from,
      self,
      hasContentBelow: _hasNonHeaderTarget(
        scope: scope,
        primary: primary,
        match: (rect) => rect.top >= from.bottom - 8,
      ),
      hasNeighborToTheRight: _hasNonHeaderTarget(
        scope: scope,
        primary: primary,
        match: (rect) {
          if (rect.left < from.right - 4) return false;
          return (rect.center.dy - from.center.dy).abs() <= 80;
        },
      ),
    );
  }

  bool _hasNonHeaderTarget({
    required FocusScopeNode? scope,
    required FocusNode primary,
    required bool Function(Rect rect) match,
  }) {
    if (scope == null) return false;
    var found = false;
    void visit(FocusNode node) {
      if (found) return;
      for (final child in node.children) {
        visit(child);
        if (found) return;
      }
      if (identical(node, _node) || identical(node, primary)) return;
      if (node is FocusScopeNode) return;
      if (!node.canRequestFocus) return;
      if (_proximityHeaderNodes.contains(node)) return;
      if (node.skipTraversal) return;
      final rect = _globalRect(node);
      if (rect == null) return;
      if (match(rect)) found = true;
    }

    visit(scope);
    return found;
  }

  void _onFocus() {
    if (!mounted) return;
    if (!_node.hasFocus) _cancelHold();
    final focused = _node.hasFocus;
    if (widget.expandOnFocus) {
      if (focused) {
        _expanded = false;
        setState(() => _focused = true);
        _beginPosterLift();
      } else {
        _expanded = false;
        if (_portal.isShowing) _portal.hide();
        setState(() => _focused = false);
      }
    } else {
      setState(() => _focused = focused);
    }
    widget.onFocusChange?.call(focused);
  }

  void _beginPosterLift() {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) _size = box.size;
    if (_size == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_node.hasFocus) return;
        _beginPosterLift();
      });
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) return;
    if (!_portal.isShowing) _portal.show();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_node.hasFocus) return;
      setState(() => _expanded = true);
    });
  }

  void _activate() {
    if (!widget.enabled || widget.onSelect == null) return;
    if (_stillConsumingHold) return;
    widget.onSelect!();
  }

  void _longActivate({bool fromMenuKey = false}) {
    if (!widget.enabled) return;
    if (!fromMenuKey && (tvConsumeLongSelect?.call() ?? false)) {
      _markHoldConsumed();
      return;
    }
    widget.onLongSelect?.call();
    if (!fromMenuKey) _markHoldConsumed();
  }

  void _markHoldConsumed() {
    _holdConsumed = true;
    _holdConsumeUntil = DateTime.now().add(const Duration(milliseconds: 250));
  }

  bool get _stillConsumingHold {
    if (!_holdConsumed) return false;
    if (_anySelectKeyPressed) return true;
    final until = _holdConsumeUntil;
    if (until != null && DateTime.now().isBefore(until)) return true;
    _holdConsumed = false;
    _longFired = false;
    _holdConsumeUntil = null;
    return false;
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  bool get _deferSelectForMiniPlayer =>
      tvHoldOkClosesMiniPlayer?.call() ?? false;

  bool get _deferSelect =>
      widget.onLongSelect != null || _deferSelectForMiniPlayer;

  bool get _anySelectKeyPressed =>
      HardwareKeyboard.instance.logicalKeysPressed.any(_selectKeys.contains);

  /// Press-and-hold OK on a remote: repeat events are unreliable across TV
  /// boxes, so the hold is timed from key down and cancelled on release.
  ///
  /// Fire TV often pairs Select with a synthetic Enter. After a hold closes
  /// the mini player, that extra KeyUp must not ActivateIntent the tile.
  KeyEventResult _onNodeKey(FocusNode node, KeyEvent event) {
    if (!widget.enabled) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (_menuKeys.contains(key)) {
      if (widget.onLongSelect == null) return KeyEventResult.ignored;
      if (event is KeyDownEvent) _longActivate(fromMenuKey: true);
      return KeyEventResult.handled;
    }
    if (!_selectKeys.contains(key)) return KeyEventResult.ignored;
    if (!_deferSelect && !_stillConsumingHold) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      if (_stillConsumingHold) return KeyEventResult.handled;
      if (_holdTimer == null && !_longFired) {
        _longFired = false;
        _cancelHold();
        _holdTimer = Timer(tvLongPressDuration, () {
          _holdTimer = null;
          _longFired = true;
          _markHoldConsumed();
          _longActivate();
        });
      }
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is KeyUpEvent) {
      if (_stillConsumingHold) return KeyEventResult.handled;
      if (_holdTimer != null || _longFired) {
        _cancelHold();
        if (!_longFired) _activate();
        _longFired = false;
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _decorated({required bool focused}) {
    final lift = widget.expandOnFocus;
    // Scale the ring, fill, and label together. Scaling only the child left
    // settings rows / buttons with oversized text inside a static outline.
    final chrome = AnimatedContainer(
      duration: AppMotion.focus,
      curve: AppMotion.ease,
      padding: widget.padding,
      // White ring stays readable on accent-filled children (pink CTAs);
      // soft accent glow is secondary depth, not the only cue.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        border: Border.all(
          color: focused ? Colors.white : Colors.transparent,
          width: 3.5,
        ),
        boxShadow: focused
            ? (lift ? AppShadows.cardHover : AppShadows.focusRing)
            : null,
      ),
      child: widget.child,
    );
    if (lift) return chrome;
    return AnimatedScale(
      scale: focused ? AppMotion.rowFocusScale : 1.0,
      duration: AppMotion.focus,
      curve: AppMotion.ease,
      child: chrome,
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    final lift = widget.expandOnFocus && _focused && !reduce;
    final visual = KeyedSubtree(
      key: _visualKey,
      child: _decorated(focused: _focused),
    );
    // FocusableActionDetector handles Android TV Select/DPAD_CENTER reliably.
    // descendantsAreFocusable:false keeps nested Material buttons from
    // stealing the focus ring away from this wrapper.
    final detector = FocusableActionDetector(
      focusNode: _node,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      descendantsAreFocusable: false,
      descendantsAreTraversable: false,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            // Deferred Select (hold-OK / long-press) activates on KeyUp in
            // [_onNodeKey]. Fire TV's twin Enter KeyUp must not also fire.
            if (_stillConsumingHold || _deferSelect) return null;
            _activate();
            return null;
          },
        ),
      },
      onShowFocusHighlight: (show) {
        if (!mounted) return;
        setState(() => _focused = show || _node.hasFocus);
      },
      child: GestureDetector(
        onTap: widget.enabled ? _activate : null,
        onLongPress: widget.enabled && widget.onLongSelect != null
            ? _longActivate
            : null,
        child: lift && _size != null
            ? SizedBox(width: _size!.width, height: _size!.height)
            : visual,
      ),
    );

    if (!widget.expandOnFocus) return detector;

    final size = _size;
    final scale = (_expanded && !reduce) ? AppMotion.posterLiftScale : 1.0;
    return OverlayPortal(
      controller: _portal,
      overlayLocation: OverlayChildLocation.nearestOverlay,
      overlayChildBuilder: (context) {
        if (size == null || !lift) return const SizedBox.shrink();
        return PosterLiftFollower(
          link: _link,
          size: size,
          scale: scale,
          child: IgnorePointer(child: visual),
        );
      },
      child: CompositedTransformTarget(link: _link, child: detector),
    );
  }
}
