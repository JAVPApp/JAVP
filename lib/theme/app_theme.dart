import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:javp/theme/app_tokens.dart';

export 'package:javp/theme/app_tokens.dart';

class AppTheme {
  static ThemeData dark() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.bg,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.accent,
        onPrimary: Colors.white,
        secondary: AppColors.surfaceHigh,
        surface: AppColors.surface,
        onSurface: AppColors.text,
        outline: AppColors.border,
      ),
    );

    final display = GoogleFonts.spaceGroteskTextTheme(base.textTheme);
    final body = GoogleFonts.sourceSans3TextTheme(base.textTheme);

    return base.copyWith(
      textTheme: body.copyWith(
        displayLarge: display.displayLarge?.copyWith(
          color: AppColors.text,
          fontWeight: FontWeight.w700,
          letterSpacing: -1.2,
        ),
        displayMedium: display.displayMedium?.copyWith(
          color: AppColors.text,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.8,
        ),
        headlineLarge: display.headlineLarge?.copyWith(
          color: AppColors.text,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.6,
        ),
        headlineMedium: display.headlineMedium?.copyWith(
          color: AppColors.text,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
        ),
        headlineSmall: display.headlineSmall?.copyWith(
          color: AppColors.text,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
        titleLarge: display.titleLarge?.copyWith(
          color: AppColors.text,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        titleMedium: body.titleMedium?.copyWith(color: AppColors.text),
        bodyLarge: body.bodyLarge?.copyWith(color: AppColors.text),
        bodyMedium: body.bodyMedium?.copyWith(color: AppColors.textMuted),
        labelLarge: body.labelLarge?.copyWith(
          color: AppColors.text,
          fontWeight: FontWeight.w600,
        ),
        // The site's section kicker: small, wide-tracked, accent-lit.
        labelSmall: display.labelSmall?.copyWith(
          color: AppColors.accentHi,
          fontWeight: FontWeight.w600,
          fontSize: 12.5,
          letterSpacing: 2.2,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: display.titleLarge?.copyWith(
          color: AppColors.text,
          fontWeight: FontWeight.w700,
          fontSize: 22,
          letterSpacing: -0.4,
        ),
        iconTheme: const IconThemeData(color: AppColors.text),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surfaceHigh,
        selectedColor: AppColors.accent,
        disabledColor: AppColors.surface,
        labelStyle: body.labelLarge?.copyWith(color: AppColors.text),
        secondaryLabelStyle: body.labelLarge?.copyWith(color: Colors.white),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.pillAll,
          side: BorderSide(color: AppColors.border),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surface.withValues(alpha: 0.96),
        indicatorColor: AppColors.accentSoft,
        indicatorShape: const RoundedRectangleBorder(
          borderRadius: AppRadius.pillAll,
        ),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? AppColors.text : AppColors.textMuted,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? AppColors.accent : AppColors.textMuted,
          );
        }),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceHigh,
        border: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: AppColors.accent, width: 1.4),
        ),
        labelStyle: TextStyle(color: AppColors.textMuted),
        hintStyle: TextStyle(color: AppColors.textDim),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surfaceHigh,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.lgAll,
          side: BorderSide(color: AppColors.border),
        ),
        titleTextStyle: display.titleLarge?.copyWith(
          color: AppColors.text,
          fontWeight: FontWeight.w600,
          fontSize: 20,
        ),
        contentTextStyle: body.bodyMedium?.copyWith(color: AppColors.textMuted),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surfaceHigh,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: AppColors.border,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surfaceHigh,
        contentTextStyle: body.bodyMedium?.copyWith(color: AppColors.text),
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        closeIconColor: AppColors.textMuted,
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.mdAll,
          side: BorderSide(color: AppColors.border),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: const BoxDecoration(
          color: AppColors.surfaceHigher,
          borderRadius: AppRadius.smAll,
        ),
        textStyle: body.bodySmall?.copyWith(color: AppColors.text),
        // Overlay tooltips reparent semantics nodes. On Windows that
        // corrupts ui::AXTree ("N will not be in the tree") and the
        // failed CommitUpdates run on the Win32 thread during sync.
        excludeFromSemantics: true,
      ),
      filledButtonTheme: FilledButtonThemeData(style: _accentButtonStyle()),
      elevatedButtonTheme: ElevatedButtonThemeData(style: _accentButtonStyle()),
      outlinedButtonTheme: OutlinedButtonThemeData(style: _outlinedButtonStyle()),
      textButtonTheme: TextButtonThemeData(style: _textButtonStyle()),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: segmentedButtonStyle(),
      ),
      dividerColor: AppColors.border,
      dividerTheme: const DividerThemeData(
        color: AppColors.borderSoft,
        thickness: 1,
        space: 1,
      ),
      // M3 Switch paints a large primary-colored state layer on hover; with our
      // red accent that reads as a big red blob. Keep the track accent-tinted
      // when on, but use a neutral, tight overlay for hover/press/focus.
      switchTheme: SwitchThemeData(
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) {
            return AppColors.text.withValues(alpha: 0.12);
          }
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            return AppColors.text.withValues(alpha: 0.08);
          }
          return Colors.transparent;
        }),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return AppColors.textMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppColors.accent.withValues(alpha: 0.55);
          }
          return AppColors.surfaceHigher;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.transparent;
          }
          return AppColors.border;
        }),
      ),
    );
  }

  /// M3 defaults use secondary/onSecondary from [ColorScheme], which are too
  /// close on our dark palette — selected segments read as black-on-black.
  static ButtonStyle segmentedButtonStyle({
    VisualDensity visualDensity = VisualDensity.standard,
    bool compact = false,
  }) {
    return ButtonStyle(
      visualDensity: visualDensity,
      tapTargetSize:
          compact ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded,
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.white;
        return AppColors.textMuted;
      }),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return AppColors.accent;
        return AppColors.surfaceHigh;
      }),
    );
  }

  /// Accent CTAs (Filled / Elevated).
  ///
  /// TV focus chrome lives on [AppActionButton] / [TvFocusable] — Material
  /// styles stay phone/desktop-oriented so leftover buttons do not invent a
  /// second leanback look.
  static ButtonStyle _accentButtonStyle() {
    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return AppColors.surfaceHigher;
        }
        return AppColors.accent;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return AppColors.textDim;
        return Colors.white;
      }),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) {
          return Colors.white.withValues(alpha: 0.12);
        }
        if (states.contains(WidgetState.hovered)) {
          return Colors.white.withValues(alpha: 0.08);
        }
        return Colors.transparent;
      }),
      side: const WidgetStatePropertyAll(BorderSide.none),
      elevation: const WidgetStatePropertyAll(0),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
      shape: const WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: AppRadius.buttonAll),
      ),
      textStyle: const WidgetStatePropertyAll(
        TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }

  static ButtonStyle _outlinedButtonStyle() {
    return ButtonStyle(
      foregroundColor: const WidgetStatePropertyAll(AppColors.text),
      backgroundColor: const WidgetStatePropertyAll(AppColors.surfaceHigh),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) {
          return AppColors.text.withValues(alpha: 0.12);
        }
        if (states.contains(WidgetState.hovered)) {
          return AppColors.text.withValues(alpha: 0.06);
        }
        return Colors.transparent;
      }),
      side: const WidgetStatePropertyAll(BorderSide(color: AppColors.border)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
      shape: const WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: AppRadius.buttonAll),
      ),
      textStyle: const WidgetStatePropertyAll(
        TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }

  static ButtonStyle _textButtonStyle() {
    return ButtonStyle(
      foregroundColor: const WidgetStatePropertyAll(AppColors.text),
      backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) {
          return AppColors.text.withValues(alpha: 0.12);
        }
        if (states.contains(WidgetState.hovered)) {
          return AppColors.text.withValues(alpha: 0.06);
        }
        return Colors.transparent;
      }),
      side: const WidgetStatePropertyAll(BorderSide.none),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
      shape: const WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: AppRadius.buttonAll),
      ),
      textStyle: const WidgetStatePropertyAll(
        TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }
}
