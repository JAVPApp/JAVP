/// Side-strip volume / brightness vs hold-to-2x.
///
/// Vertical drag on the left third adjusts brightness; the right third
/// adjusts volume. A press that never moves still arms hold-to-2x.
enum PlayerSideStripKind { volume, brightness }

class PlayerSideStripDecision {
  const PlayerSideStripDecision({required this.active, this.kind});

  final bool active;
  final PlayerSideStripKind? kind;

  static const inactive = PlayerSideStripDecision(active: false);
}

/// Whether this pointer sequence should become a side-strip drag.
///
/// [side] is −1 left / 0 center / +1 right (same as seek / 2x hold).
PlayerSideStripDecision playerSideStripDecision({
  required bool touch,
  required int side,
  required double dx,
  required double dy,
  double slop = 16,
}) {
  if (!touch || side == 0) return PlayerSideStripDecision.inactive;
  if (dy.abs() < slop || dy.abs() <= dx.abs()) {
    return PlayerSideStripDecision.inactive;
  }
  return PlayerSideStripDecision(
    active: true,
    kind: side < 0
        ? PlayerSideStripKind.brightness
        : PlayerSideStripKind.volume,
  );
}

/// Map a vertical drag to a 0…100 (or 0…1) delta.
///
/// Dragging up increases the value. [extent] is the view height.
double playerSideStripDelta({
  required double dy,
  required double extent,
  double range = 100,
}) {
  if (extent <= 0) return 0;
  return (-dy / extent) * range;
}
