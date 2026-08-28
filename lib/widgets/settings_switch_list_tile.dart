import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';

/// Settings on/off row that flips on the same frame as the tap.
///
/// Material 3 [Switch] / [SwitchListTile] are controlled: the thumb only moves
/// after `value` rebuilds, and M3 hard-codes a **300ms** toggle. Combined with
/// [LibraryProvider.notifyListeners] rebuilding shell tabs in the same frame,
/// that reads as "stuck, then slow".
///
/// This tile:
/// 1. Keeps an optimistic local value so the thumb moves immediately.
/// 2. Holds that local value through the full [AppMotion.focus] (120ms) toggle
///    **and** until the parent value catches up, so a settle-frame rebuild
///    cannot micro-jump the thumb back through controlled-value sync.
/// 3. Fires [onChanged] only after the animation has painted, one extra frame,
///    and the scheduler is **idle** — so provider fan-out / parent [setState]
///    does not share a vsync with the ease-out settle.
/// 4. Uses a compact switch animated with [AppMotion.focus], matching the rest
///    of the app's motion language — not M3's 300ms switch.
class SettingsSwitchListTile extends StatefulWidget {
  const SettingsSwitchListTile({
    super.key,
    required this.value,
    required this.onChanged,
    this.onWillChange,
    this.title,
    this.subtitle,
    this.secondary,
    this.contentPadding,
    this.dense,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// Called synchronously on tap with the optimistic value (before [onChanged]).
  ///
  /// Use for cheap parent-local UI (e.g. revealing a dependent row) so that work
  /// is not piled onto the deferred settle path. Prefer scoping [setState] to a
  /// small subtree — not the whole settings [ListView].
  final ValueChanged<bool>? onWillChange;

  final Widget? title;
  final Widget? subtitle;
  final Widget? secondary;
  final EdgeInsetsGeometry? contentPadding;
  final bool? dense;

  @override
  State<SettingsSwitchListTile> createState() => _SettingsSwitchListTileState();
}

class _SettingsSwitchListTileState extends State<SettingsSwitchListTile> {
  bool? _optimistic;
  int _pendingEpoch = 0;
  Timer? _deferTimer;

  bool get _effective => _optimistic ?? widget.value;

  @override
  void dispose() {
    _deferTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SettingsSwitchListTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == oldWidget.value) return;

    if (_optimistic != null) {
      if (widget.value == _optimistic) {
        // Parent caught up. Clear without setState — [_effective] is unchanged,
        // so this avoids a second rebuild on the notify frame.
        _optimistic = null;
        return;
      }
      // External change while a flip is still pending — take parent, cancel work.
      _deferTimer?.cancel();
      _pendingEpoch++;
      _optimistic = null;
      return;
    }
  }

  void _handleChanged(bool next) {
    if (widget.onChanged == null || next == _effective) return;
    setState(() => _optimistic = next);
    widget.onWillChange?.call(next);
    final epoch = ++_pendingEpoch;
    _deferTimer?.cancel();

    final delay = AppMotion.of(context, AppMotion.focus);

    void fireIdle() {
      if (!mounted || epoch != _pendingEpoch) return;
      // Idle runs after post-frame callbacks / animations for this pipeline
      // turn — keeps LibraryProvider fan-out off the settle vsync.
      SchedulerBinding.instance.scheduleTask(() {
        if (!mounted || epoch != _pendingEpoch) return;
        widget.onChanged!(next);
      }, Priority.idle);
    }

    void fireAfterSettlePaint() {
      if (!mounted || epoch != _pendingEpoch) return;
      // One calm frame with the thumb fully settled, then idle notify work.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted || epoch != _pendingEpoch) return;
        fireIdle();
      });
      SchedulerBinding.instance.scheduleFrame();
    }

    if (delay == Duration.zero) {
      fireAfterSettlePaint();
    } else {
      _deferTimer = Timer(delay, fireAfterSettlePaint);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    final tile = ListTile(
      enabled: enabled,
      contentPadding: widget.contentPadding,
      dense: widget.dense,
      leading: widget.secondary,
      title: widget.title,
      subtitle: widget.subtitle,
      // IgnorePointer: row onTap owns the gesture (avoids double toggle).
      trailing: IgnorePointer(
        child: RepaintBoundary(
          child: _SnappySwitch(value: _effective, enabled: enabled),
        ),
      ),
      // TV: TvFocusable owns activation so Select/DPAD_CENTER works with a
      // visible focus ring (InkWell focus is easy to miss on 10-foot UI).
      onTap: TvPlatform.isAndroidTv
          ? null
          : (enabled ? () => _handleChanged(!_effective) : null),
    );

    final body = MergeSemantics(child: tile);
    if (!TvPlatform.isAndroidTv) return body;

    return TvFocusable(
      enabled: enabled,
      borderRadius: 12,
      onSelect: enabled ? () => _handleChanged(!_effective) : null,
      child: body,
    );
  }
}

/// Thumb/track driven by an [AnimationController] so a parent rebuild at
/// settle (when [onChanged] finally notifies) cannot reset/reconcile an
/// [AnimatedAlign] / [AnimatedContainer] mid-flight.
class _SnappySwitch extends StatefulWidget {
  const _SnappySwitch({required this.value, required this.enabled});

  final bool value;
  final bool enabled;

  @override
  State<_SnappySwitch> createState() => _SnappySwitchState();
}

class _SnappySwitchState extends State<_SnappySwitch>
    with SingleTickerProviderStateMixin {
  static const _trackW = 52.0;
  static const _trackH = 32.0;
  static const _thumb = 20.0;
  static const _pad = 4.0;

  late final AnimationController _controller;
  late final Animation<double> _t;
  Duration? _resolvedDuration;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppMotion.focus,
      value: widget.value ? 1.0 : 0.0,
    );
    _t = CurvedAnimation(parent: _controller, curve: AppMotion.ease);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final duration = AppMotion.of(context, AppMotion.focus);
    if (_resolvedDuration == duration) return;
    _resolvedDuration = duration;
    _controller.duration = duration;
  }

  @override
  void didUpdateWidget(covariant _SnappySwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value == widget.value) return;
    if (widget.value) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;

    return SizedBox(
      width: _trackW,
      height: kMinInteractiveDimension,
      child: Center(
        child: AnimatedBuilder(
          animation: _t,
          builder: (context, child) {
            final t = _t.value;
            final track = Color.lerp(
              AppColors.surfaceHigher,
              AppColors.accent.withValues(alpha: 0.55),
              t,
            )!;
            final outline = Color.lerp(
              AppColors.border,
              Colors.transparent,
              t,
            )!;
            final thumb = Color.lerp(
              AppColors.textMuted,
              Colors.white,
              t,
            )!;
            // 52 - 8 pad - 20 thumb = 24px travel.
            const travel = _trackW - (_pad * 2) - _thumb;

            return Container(
              width: _trackW,
              height: _trackH,
              padding: const EdgeInsets.all(_pad),
              decoration: BoxDecoration(
                color: track.withValues(alpha: enabled ? 1 : 0.45),
                borderRadius: BorderRadius.circular(_trackH / 2),
                border: Border.all(color: outline),
              ),
              alignment: Alignment.centerLeft,
              child: Transform.translate(
                offset: Offset(travel * t, 0),
                child: Container(
                  width: _thumb,
                  height: _thumb,
                  decoration: BoxDecoration(
                    color: thumb.withValues(alpha: enabled ? 1 : 0.5),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
