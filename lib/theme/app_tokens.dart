import 'package:flutter/widgets.dart';

/// JAVP visual language: cinema charcoal, signal red, crisp type.
///
/// These mirror the `:root` custom properties on javp.app so the app and the
/// marketing site stay in step. Values are the source of truth for both.
class AppColors {
  const AppColors._();

  static const bg = Color(0xFF0B0C0F);
  static const bgDeep = Color(0xFF08090C);
  static const surface = Color(0xFF14161C);
  static const surfaceHigh = Color(0xFF1C1F28);
  static const surfaceHigher = Color(0xFF232734);
  static const border = Color(0xFF2A2F3A);
  static const borderSoft = Color(0xFF21252E);
  static const text = Color(0xFFF4F5F7);
  static const textMuted = Color(0xFF9AA3B2);
  static const textDim = Color(0xFF6C7484);
  static const accent = Color(0xFFE11D48);
  static const accentHi = Color(0xFFF43F5E);
  static const accentSoft = Color(0x33E11D48);
  static const live = Color(0xFF22C55E);
}

/// Corner radii, converted from the site's rem scale at a 16px root.
class AppRadius {
  const AppRadius._();

  static const double sm = 9;
  static const double md = 14;
  static const double lg = 18;
  static const double xl = 26;
  static const double pill = 999;

  /// Buttons sit between [sm] and [md] on the site (0.7rem).
  static const double button = 11;

  static const BorderRadius buttonAll = BorderRadius.all(Radius.circular(button));
  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));
}

/// One easing curve and a small set of durations for the whole app.
///
/// The site's 700ms reveal is deliberately not carried over; past roughly
/// 250ms an in-app transition reads as lag rather than polish.
class AppMotion {
  const AppMotion._();

  static const Curve ease = Cubic(0.22, 1, 0.36, 1);

  static const Duration focus = Duration(milliseconds: 120);
  static const Duration fast = Duration(milliseconds: 180);
  static const Duration normal = Duration(milliseconds: 240);
  static const Duration reveal = Duration(milliseconds: 200);

  /// Delay between consecutive siblings in a staggered reveal.
  static const Duration revealStagger = Duration(milliseconds: 40);

  /// Poster grow on desktop hover and TV focus. Enough to pop above the row
  /// without covering half the next shelf.
  static const posterLiftScale = 1.12;

  /// In-place D-pad pop for buttons / settings rows (ring, fill, and label).
  static const rowFocusScale = 1.05;

  /// Beyond this many siblings the stagger stops growing, so a long list
  /// never leaves its tail waiting.
  static const int revealStaggerCap = 5;

  /// Collapses [duration] to zero when the platform asks for reduced motion.
  static Duration of(BuildContext context, Duration duration) {
    return MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;
  }
}

/// Glows and drop shadows.
///
/// Everything here except [progressGlow] is meant for a single element at a
/// time. A 26px blur repeated down a scrolling list is expensive.
class AppShadows {
  const AppShadows._();

  /// Primary button lift: `0 10px 26px -10px rgba(225, 29, 72, 0.75)`.
  static const List<BoxShadow> accentGlow = [
    BoxShadow(
      color: Color(0xBFE11D48),
      blurRadius: 26,
      offset: Offset(0, 10),
      spreadRadius: -10,
    ),
  ];

  /// Large one-off panels: `0 40px 90px -40px rgba(0, 0, 0, 0.95)`.
  static const List<BoxShadow> panel = [
    BoxShadow(
      color: Color(0xF2000000),
      blurRadius: 90,
      offset: Offset(0, 40),
      spreadRadius: -40,
    ),
  ];

  /// Pointer hover lift on cards: soft, short, and cheap enough for a list
  /// where only one card is hovered at a time.
  static const List<BoxShadow> cardHover = [
    BoxShadow(
      color: Color(0x99000000),
      blurRadius: 22,
      offset: Offset(0, 8),
      spreadRadius: -12,
    ),
  ];

  /// D-pad focus ring on Android TV — bright enough for 10-foot viewing.
  static const List<BoxShadow> focusRing = [
    BoxShadow(
      color: Color(0x66FFFFFF),
      blurRadius: 0,
      spreadRadius: 1.5,
    ),
    BoxShadow(
      color: Color(0xA0E11D48),
      blurRadius: 22,
      spreadRadius: 2,
    ),
  ];

  /// Watch-progress bar on a poster: `0 0 6px rgba(225, 29, 72, 0.8)`.
  ///
  /// The one per-item glow we allow. The blur is small and clipped to the
  /// tile, so it costs a fraction of the shadows above.
  static const List<BoxShadow> progressGlow = [
    BoxShadow(color: Color(0xCCE11D48), blurRadius: 6),
  ];
}
