import 'package:flutter/material.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/compat/media_kit.dart';
import 'package:javp/compat/media_kit_video.dart';

/// Named caption looks for non-ASS tracks (and ASS when Prefer ASS is off).
enum CaptionPreset {
  standard,
  outline,
  shadow,
  boxed,
  custom,
}

extension CaptionPresetLabel on CaptionPreset {
  String get label => switch (this) {
        CaptionPreset.standard => 'Standard',
        CaptionPreset.outline => 'Outline',
        CaptionPreset.shadow => 'Shadow',
        CaptionPreset.boxed => 'Boxed',
        CaptionPreset.custom => 'Custom',
      };

  String get subtitle => switch (this) {
        CaptionPreset.standard => 'Clean white captions with a light outline',
        CaptionPreset.outline => 'White text with a hard black outline, no box',
        CaptionPreset.shadow => 'Soft drop shadow, no background box',
        CaptionPreset.boxed => 'Semi-transparent black box behind text',
        CaptionPreset.custom => 'Your own size, font, colors, and outline',
      };

  /// Maps persisted preset ids onto the current enum.
  ///
  /// Legacy `original` becomes [CaptionPreset.outline] (Prefer ASS is separate).
  static CaptionPreset fromStorage(String? raw) {
    return switch (raw) {
      'standard' => CaptionPreset.standard,
      'outline' || 'original' => CaptionPreset.outline,
      'shadow' => CaptionPreset.shadow,
      'boxed' => CaptionPreset.boxed,
      'custom' => CaptionPreset.custom,
      _ => CaptionPreset.outline,
    };
  }
}

class CaptionStyleSettings {
  const CaptionStyleSettings({
    this.preset = CaptionPreset.outline,
    this.preferAss = true,
    this.fontSize = 32,
    this.textColor = const Color(0xFFFFFFFF),
    this.outlineColor = const Color(0xFF000000),
    this.outlineWidth = 2.0,
    this.backgroundEnabled = false,
    this.backgroundColor = const Color(0xFF000000),
    this.backgroundOpacity = 0.66,
    this.fontWeight = FontWeight.w500,
    this.bottomPadding = 28,
    this.fontFamily,
  });

  final CaptionPreset preset;

  /// When true, ASS/SSA tracks keep file fonts/colors/karaoke; other formats
  /// (and ASS when this is off) use [preset].
  final bool preferAss;

  final double fontSize;
  final Color textColor;
  final Color outlineColor;
  final double outlineWidth;
  final bool backgroundEnabled;
  final Color backgroundColor;
  final double backgroundOpacity;
  final FontWeight fontWeight;
  final double bottomPadding;
  final String? fontFamily;

  /// Curated system fonts for custom captions (libass via `sub-font`).
  ///
  /// [family] null means platform default (`sans-serif` / Roboto on Android).
  static const fontChoices = <({String? family, String label})>[
    (family: null, label: 'Default'),
    (family: 'Roboto', label: 'Roboto'),
    (family: 'Trebuchet MS', label: 'Trebuchet MS'),
    (family: 'Arial', label: 'Arial'),
    (family: 'Segoe UI', label: 'Segoe UI'),
    (family: 'Verdana', label: 'Verdana'),
    (family: 'Georgia', label: 'Georgia'),
    (family: 'Times New Roman', label: 'Times New Roman'),
    (family: 'Courier New', label: 'Courier New'),
    (family: 'Comic Sans MS', label: 'Comic Sans MS'),
  ];

  /// mpv/libass font name for [fontFamily] on the current platform.
  ///
  /// Android only ships a small set under `/system/fonts`; desktop names are
  /// remapped so captions still render instead of falling back silently.
  static String resolveMpvFontFamily(
    String? fontFamily, {
    required bool isAndroid,
  }) {
    if (!isAndroid) return fontFamily ?? 'sans-serif';
    return switch (fontFamily) {
      null ||
      'Trebuchet MS' ||
      'Arial' ||
      'Segoe UI' ||
      'Verdana' ||
      'sans-serif' =>
        'Roboto',
      'Georgia' || 'Times New Roman' || 'serif' => 'Noto Serif',
      'Courier New' || 'monospace' => 'Droid Sans Mono',
      'Comic Sans MS' => 'Roboto',
      _ => fontFamily,
    };
  }

  /// Whether libass should keep authored ASS styles for the active track.
  bool shouldUseNativeFileStyle({required bool trackIsAss}) =>
      preferAss && trackIsAss;

  static const standard = CaptionStyleSettings(
    preset: CaptionPreset.standard,
    fontSize: 32,
    textColor: Color(0xFFFFFFFF),
    outlineColor: Color(0xFF000000),
    outlineWidth: 1.5,
    backgroundEnabled: false,
    fontWeight: FontWeight.w500,
    bottomPadding: 28,
  );

  /// Hard black outline, no background box.
  static const outline = CaptionStyleSettings(
    preset: CaptionPreset.outline,
    fontSize: 34,
    textColor: Color(0xFFFFFFFF),
    outlineColor: Color(0xFF000000),
    outlineWidth: 2.4,
    backgroundEnabled: false,
    fontWeight: FontWeight.w500,
    bottomPadding: 30,
    fontFamily: 'Trebuchet MS',
  );

  static const shadow = CaptionStyleSettings(
    preset: CaptionPreset.shadow,
    fontSize: 32,
    textColor: Color(0xFFFFFFFF),
    outlineColor: Color(0xCC000000),
    outlineWidth: 0,
    backgroundEnabled: false,
    fontWeight: FontWeight.w500,
    bottomPadding: 36,
  );

  static const boxed = CaptionStyleSettings(
    preset: CaptionPreset.boxed,
    fontSize: 30,
    textColor: Color(0xFFFFFFFF),
    outlineColor: Color(0xFF000000),
    outlineWidth: 0,
    backgroundEnabled: true,
    backgroundColor: Color(0xFF000000),
    backgroundOpacity: 0.66,
    fontWeight: FontWeight.w500,
    bottomPadding: 24,
  );

  static CaptionStyleSettings forPreset(CaptionPreset preset) => switch (preset) {
        CaptionPreset.standard => standard,
        CaptionPreset.outline => outline,
        CaptionPreset.shadow => shadow,
        CaptionPreset.boxed => boxed,
        CaptionPreset.custom => outline.copyWith(preset: CaptionPreset.custom),
      };

  CaptionStyleSettings copyWith({
    CaptionPreset? preset,
    bool? preferAss,
    double? fontSize,
    Color? textColor,
    Color? outlineColor,
    double? outlineWidth,
    bool? backgroundEnabled,
    Color? backgroundColor,
    double? backgroundOpacity,
    FontWeight? fontWeight,
    double? bottomPadding,
    String? fontFamily,
    bool clearFontFamily = false,
  }) {
    return CaptionStyleSettings(
      preset: preset ?? this.preset,
      preferAss: preferAss ?? this.preferAss,
      fontSize: fontSize ?? this.fontSize,
      textColor: textColor ?? this.textColor,
      outlineColor: outlineColor ?? this.outlineColor,
      outlineWidth: outlineWidth ?? this.outlineWidth,
      backgroundEnabled: backgroundEnabled ?? this.backgroundEnabled,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      fontWeight: fontWeight ?? this.fontWeight,
      bottomPadding: bottomPadding ?? this.bottomPadding,
      fontFamily: clearFontFamily ? null : (fontFamily ?? this.fontFamily),
    );
  }

  /// Soft drop-shadow when outline width is 0 and no box.
  List<Shadow> get shadows {
    if (outlineWidth > 0) {
      return _hardOutline(outlineColor, outlineWidth);
    }
    if (preset == CaptionPreset.shadow ||
        (preset == CaptionPreset.custom && !backgroundEnabled)) {
      return const [
        Shadow(
          offset: Offset(1.2, 1.6),
          blurRadius: 3.5,
          color: Color(0xCC000000),
        ),
      ];
    }
    return const [];
  }

  TextStyle get textStyle {
    final bg = backgroundEnabled
        ? backgroundColor.withValues(alpha: backgroundOpacity)
        : null;
    return TextStyle(
      height: 1.35,
      fontSize: fontSize,
      letterSpacing: preset == CaptionPreset.outline ? 0.2 : 0,
      color: textColor,
      fontWeight: fontWeight,
      fontFamily: fontFamily,
      fontFamilyFallback: const [
        'Trebuchet MS',
        'Segoe UI',
        'Roboto',
        'sans-serif',
      ],
      backgroundColor: bg,
      shadows: shadows,
    );
  }

  SubtitleViewConfiguration toSubtitleViewConfiguration() {
    // libass paints onto the video frame; media_kit skips Flutter SubtitleView
    // whenever PlayerConfiguration.libass is true. Keep the overlay hidden.
    return const SubtitleViewConfiguration(visible: false);
  }

  /// mpv/libass properties that realize this style when not using native ASS.
  ///
  /// Colors are `#AARRGGBB`.
  Map<String, String> toMpvSubProperties() {
    final mpvFontSize = (fontSize * 55 / 32).clamp(18, 96).round();
    final border = outlineWidth.clamp(0.0, 6.0);
    final shadow = (preset == CaptionPreset.shadow ||
            (preset == CaptionPreset.custom &&
                outlineWidth <= 0 &&
                !backgroundEnabled))
        ? 2.0
        : 0.0;
    final back = backgroundEnabled
        ? _mpvColor(backgroundColor.withValues(alpha: backgroundOpacity))
        : '#00000000';
    return {
      'sub-font': resolveMpvFontFamily(fontFamily, isAndroid: false),
      'sub-font-size': '$mpvFontSize',
      'sub-color': _mpvColor(textColor),
      'sub-border-color': _mpvColor(outlineColor),
      'sub-border-size': border.toStringAsFixed(1),
      'sub-back-color': back,
      'sub-shadow-offset': shadow.toStringAsFixed(1),
      'sub-shadow-color': '#CC000000',
      'sub-bold': fontWeight.value >= FontWeight.w600.value ? 'yes' : 'no',
      'sub-margin-y': bottomPadding.round().toString(),
      'sub-justify': 'center',
    };
  }

  static String _mpvColor(Color color) {
    final argb = color.toARGB32().toRadixString(16).padLeft(8, '0');
    return '#${argb.toUpperCase()}';
  }

  Map<String, dynamic> toJson() => {
        'preset': preset.name,
        'preferAss': preferAss,
        'fontSize': fontSize,
        'textColor': textColor.toARGB32(),
        'outlineColor': outlineColor.toARGB32(),
        'outlineWidth': outlineWidth,
        'backgroundEnabled': backgroundEnabled,
        'backgroundColor': backgroundColor.toARGB32(),
        'backgroundOpacity': backgroundOpacity,
        'fontWeight': fontWeight.value,
        'bottomPadding': bottomPadding,
        'fontFamily': fontFamily,
      };

  factory CaptionStyleSettings.fromJson(Map<String, dynamic> json) {
    final rawPreset = json['preset'] as String?;
    final preset = CaptionPresetLabel.fromStorage(rawPreset);
    final defaults = forPreset(
      preset == CaptionPreset.custom ? CaptionPreset.outline : preset,
    );
    // Missing key → on (including legacy `original` preset saves).
    final preferAss = json['preferAss'] as bool? ?? true;
    return CaptionStyleSettings(
      preset: preset,
      preferAss: preferAss,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? defaults.fontSize,
      textColor:
          Color(json['textColor'] as int? ?? defaults.textColor.toARGB32()),
      outlineColor: Color(
        json['outlineColor'] as int? ?? defaults.outlineColor.toARGB32(),
      ),
      outlineWidth:
          (json['outlineWidth'] as num?)?.toDouble() ?? defaults.outlineWidth,
      backgroundEnabled:
          json['backgroundEnabled'] as bool? ?? defaults.backgroundEnabled,
      backgroundColor: Color(
        json['backgroundColor'] as int? ?? defaults.backgroundColor.toARGB32(),
      ),
      backgroundOpacity: (json['backgroundOpacity'] as num?)?.toDouble() ??
          defaults.backgroundOpacity,
      fontWeight: FontWeight.values.firstWhere(
        (w) => w.value ==
            (json['fontWeight'] as int? ?? defaults.fontWeight.value),
        orElse: () => FontWeight.w500,
      ),
      bottomPadding: (json['bottomPadding'] as num?)?.toDouble() ??
          defaults.bottomPadding,
      fontFamily: json['fontFamily'] as String? ?? defaults.fontFamily,
    );
  }

  static List<Shadow> _hardOutline(Color color, double width) {
    final w = width.clamp(0.5, 6.0);
    // Dense ring of zero-blur shadows ≈ ASS hard border.
    const dirs = <Offset>[
      Offset(-1, 0),
      Offset(1, 0),
      Offset(0, -1),
      Offset(0, 1),
      Offset(-1, -1),
      Offset(1, -1),
      Offset(-1, 1),
      Offset(1, 1),
      Offset(-0.5, -1),
      Offset(0.5, -1),
      Offset(-0.5, 1),
      Offset(0.5, 1),
      Offset(-1, -0.5),
      Offset(1, -0.5),
      Offset(-1, 0.5),
      Offset(1, 0.5),
    ];
    return [
      for (final d in dirs)
        Shadow(offset: d * w, blurRadius: 0, color: color),
    ];
  }
}

/// True when [track] looks like ASS/SSA (codec, URI, or catalog format hint).
bool subtitleTrackLooksLikeAss(
  SubtitleTrack track, {
  List<ExternalSubtitle> external = const [],
}) {
  final codec = (track.codec ?? '').toLowerCase();
  if (codec.contains('ass') || codec.contains('ssa')) return true;

  final id = track.id.toLowerCase();
  if (_pathLooksLikeAss(id)) return true;

  if (track.uri) {
    for (final s in external) {
      if (s.url != track.id) continue;
      final format = (s.format ?? '').toLowerCase();
      if (format.contains('ass') || format.contains('ssa')) return true;
      if (_pathLooksLikeAss(s.url)) return true;
    }
  }
  return false;
}

bool _pathLooksLikeAss(String path) {
  final lower = path.toLowerCase();
  final q = lower.indexOf('?');
  final bare = q < 0 ? lower : lower.substring(0, q);
  return bare.endsWith('.ass') || bare.endsWith('.ssa');
}
