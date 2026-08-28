import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:javp/models/caption_style.dart';
import 'package:javp/models/custom_caption_font.dart';
import 'package:javp/providers/caption_style_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/javp_text_field.dart';
import 'package:provider/provider.dart';

class CaptionStyleScreen extends StatelessWidget {
  const CaptionStyleScreen({super.key});

  static const _previewLines = [
    'I\'ll protect everyone…',
    'Even if it costs me everything!',
  ];

  Future<void> _apply(
    BuildContext context,
    Future<void> Function(CaptionStyleProvider) action,
  ) async {
    final captions = context.read<CaptionStyleProvider>();
    await action(captions);
    if (!context.mounted) return;
    await context.read<PlaybackProvider>().applyCaptionStyle(
          captions.style,
          extraFontsDir: captions.extraFontsDir,
        );
  }

  @override
  Widget build(BuildContext context) {
    final captions = context.watch<CaptionStyleProvider>();
    final style = captions.style;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    final preview = _PreviewCard(style: style, lines: _previewLines);
    final presets = _PresetSection(
      style: style,
      onPreset: (preset) => _apply(context, (c) => c.applyPreset(preset)),
    );
    final preferAss = SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(context.l10n.preferAssStyling),
      subtitle: Text(context.l10n.preferAssStylingSubtitle),
      value: style.preferAss,
      activeThumbColor: AppColors.accent,
      onChanged: (v) => _apply(context, (c) => c.setPreferAss(v)),
    );
    final fineTune = _FineTuneSection(
      style: style,
      onApply: (action) => _apply(context, action),
    );

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.captions)),
      body: isLandscape
          ? SafeArea(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 5,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            context.l10n.style,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            context.l10n.howSubtitlesLook,
                            style: const TextStyle(color: AppColors.textMuted),
                          ),
                          const SizedBox(height: 10),
                          preview,
                          const SizedBox(height: 12),
                          Expanded(
                            child: SingleChildScrollView(child: presets),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    flex: 6,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        preferAss,
                        const SizedBox(height: 12),
                        fineTune,
                      ],
                    ),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Text(
                  context.l10n.style,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 6),
                Text(
                  context.l10n.howSubtitlesLook,
                  style: const TextStyle(color: AppColors.textMuted),
                ),
                const SizedBox(height: 14),
                preview,
                const SizedBox(height: 18),
                presets,
                const SizedBox(height: 18),
                preferAss,
                const SizedBox(height: 28),
                fineTune,
              ],
            ),
    );
  }
}

class _PresetSection extends StatelessWidget {
  const _PresetSection({required this.style, required this.onPreset});

  final CaptionStyleSettings style;
  final ValueChanged<CaptionPreset> onPreset;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in CaptionPreset.values)
              ChoiceChip(
                label: Text(preset.label),
                selected: style.preset == preset,
                onSelected: (_) => onPreset(preset),
                selectedColor: AppColors.accentSoft,
                labelStyle: TextStyle(
                  color: style.preset == preset
                      ? AppColors.text
                      : AppColors.textMuted,
                  fontWeight: style.preset == preset
                      ? FontWeight.w700
                      : FontWeight.w500,
                ),
                side: BorderSide(
                  color: style.preset == preset
                      ? AppColors.accent
                      : AppColors.border,
                ),
                backgroundColor: AppColors.surfaceHigh,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          style.preset.subtitle,
          style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
        if (style.preset == CaptionPreset.outline) ...[
          const SizedBox(height: 10),
          _HintBanner(
            icon: Icons.movie_filter_outlined,
            text: context.l10n.outlinePresetHelp,
          ),
        ],
      ],
    );
  }
}

class _FineTuneSection extends StatelessWidget {
  const _FineTuneSection({required this.style, required this.onApply});

  final CaptionStyleSettings style;
  final Future<void> Function(
    Future<void> Function(CaptionStyleProvider) action,
  ) onApply;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.fineTune,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.adjustingSwitchesCustom,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        const SizedBox(height: 12),
        Text(
          context.l10n.font,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        _FontPicker(
          style: style,
          onApply: onApply,
        ),
        const SizedBox(height: 12),
        _SliderTile(
          label: context.l10n.size,
          valueLabel: style.fontSize.round().toString(),
          value: style.fontSize,
          min: 18,
          max: 56,
          onChanged: (v) => onApply(
            (c) => c.tweak((s) => s.copyWith(fontSize: v)),
          ),
        ),
        _SliderTile(
          label: context.l10n.outline,
          valueLabel: style.outlineWidth.toStringAsFixed(1),
          value: style.outlineWidth,
          min: 0,
          max: 5,
          onChanged: (v) => onApply(
            (c) => c.tweak((s) => s.copyWith(outlineWidth: v)),
          ),
        ),
        _SliderTile(
          label: context.l10n.bottomMargin,
          valueLabel: style.bottomPadding.round().toString(),
          value: style.bottomPadding,
          min: 8,
          max: 64,
          onChanged: (v) => onApply(
            (c) => c.tweak((s) => s.copyWith(bottomPadding: v)),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(context.l10n.backgroundBox),
          subtitle: Text(context.l10n.backgroundBoxSubtitle),
          value: style.backgroundEnabled,
          activeThumbColor: AppColors.accent,
          onChanged: (v) => onApply(
            (c) => c.tweak((s) => s.copyWith(backgroundEnabled: v)),
          ),
        ),
        if (style.backgroundEnabled)
          _SliderTile(
            label: context.l10n.boxOpacity,
            valueLabel: '${(style.backgroundOpacity * 100).round()}%',
            value: style.backgroundOpacity,
            min: 0.2,
            max: 0.9,
            onChanged: (v) => onApply(
              (c) => c.tweak((s) => s.copyWith(backgroundOpacity: v)),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          context.l10n.textColor,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          children: [
            for (final color in const [
              Color(0xFFFFFFFF),
              Color(0xFFFFEB3B),
              Color(0xFFB3E5FC),
              Color(0xFFFFCDD2),
            ])
              _ColorDot(
                color: color,
                selected: style.textColor.toARGB32() == color.toARGB32(),
                onTap: () => onApply(
                  (c) => c.tweak((s) => s.copyWith(textColor: color)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => onApply(
              (c) async {
                await c.applyPreset(CaptionPreset.outline);
                await c.setPreferAss(true);
              },
            ),
            icon: const Icon(Icons.restart_alt_rounded),
            label: Text(context.l10n.resetToOutline),
          ),
        ),
      ],
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.style, required this.lines});

  final CaptionStyleSettings style;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final isLandscape = screen.width > screen.height;
    // Full-width 16:9 balloons in landscape; keep a compact strip instead.
    final maxHeight = isLandscape
        ? (screen.height * 0.42).clamp(112.0, 168.0)
        : 200.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final idealHeight = width * 9 / 16;
        final heightCap = constraints.hasBoundedHeight
            ? math.min(constraints.maxHeight, maxHeight)
            : maxHeight;
        final height = math.min(idealHeight, heightCap);

        // Reference ~180px tall card; keep caption sample readable but not huge.
        final scale = (height / 180).clamp(0.55, 1.0);
        final previewFontSize = style.fontSize * 0.48 * scale;
        final blobScale = scale;

        return ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: width,
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF1A2332),
                        Color(0xFF3D1F2B),
                        Color(0xFF0E1420),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: -20 * blobScale,
                  top: 18 * blobScale,
                  child: Container(
                    width: 120 * blobScale,
                    height: 120 * blobScale,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.orange.withValues(alpha: 0.22),
                    ),
                  ),
                ),
                Positioned(
                  right: 10 * blobScale,
                  top: 28 * blobScale,
                  child: Container(
                    width: 76 * blobScale,
                    height: 76 * blobScale,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16 * blobScale),
                      color: Colors.teal.withValues(alpha: 0.25),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      12,
                      0,
                      12,
                      math.max(8, style.bottomPadding * 0.35 * scale),
                    ),
                    child: Text(
                      lines.join('\n'),
                      textAlign: TextAlign.center,
                      style: style.textStyle.copyWith(
                        fontSize: previewFontSize,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  left: 10,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      style.preferAss
                          ? 'Preview · ${style.preset.label} · ASS preferred'
                          : 'Preview · ${style.preset.label}',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: (11 * scale).clamp(10, 12),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FontPicker extends StatelessWidget {
  const _FontPicker({required this.style, required this.onApply});

  final CaptionStyleSettings style;
  final Future<void> Function(
    Future<void> Function(CaptionStyleProvider) action,
  ) onApply;

  static const _fallbacks = [
    'Trebuchet MS',
    'Segoe UI',
    'Roboto',
    'sans-serif',
  ];

  @override
  Widget build(BuildContext context) {
    final captions = context.watch<CaptionStyleProvider>();
    final custom = captions.customFonts;
    final selected = style.fontFamily;
    final orphan = selected != null &&
        !CaptionStyleSettings.fontChoices
            .any((c) => c.family == selected) &&
        !custom.any((f) => f.family == selected);

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final choice in CaptionStyleSettings.fontChoices)
          _fontChip(
            context,
            label: choice.family == null
                ? context.l10n.systemDefault
                : choice.label,
            family: choice.family,
            selected: selected == choice.family,
            onSelected: () => onApply(
              (c) => c.tweak(
                (s) => choice.family == null
                    ? s.copyWith(clearFontFamily: true)
                    : s.copyWith(fontFamily: choice.family),
              ),
            ),
          ),
        for (final font in custom)
          _fontChip(
            context,
            label: font.family,
            family: font.family,
            selected: selected == font.family,
            onSelected: () => onApply(
              (c) => c.tweak((s) => s.copyWith(fontFamily: font.family)),
            ),
            onDelete: () => _confirmRemove(context, font),
          ),
        if (orphan)
          _fontChip(
            context,
            label: selected,
            family: selected,
            selected: true,
            onSelected: () {},
          ),
        ActionChip(
          avatar: const Icon(Icons.add, size: 18),
          label: Text(context.l10n.addFont),
          onPressed: () => _showAddFontDialog(context),
          backgroundColor: AppColors.surfaceHigh,
          side: const BorderSide(color: AppColors.border),
        ),
      ],
    );
  }

  Widget _fontChip(
    BuildContext context, {
    required String label,
    required String? family,
    required bool selected,
    required VoidCallback onSelected,
    VoidCallback? onDelete,
  }) {
    return InputChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
      onDeleted: onDelete,
      deleteIcon:
          onDelete == null ? null : const Icon(Icons.close, size: 16),
      selectedColor: AppColors.accentSoft,
      labelStyle: TextStyle(
        color: selected ? AppColors.text : AppColors.textMuted,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        fontFamily: family,
        fontFamilyFallback: _fallbacks,
      ),
      side: BorderSide(
        color: selected ? AppColors.accent : AppColors.border,
      ),
      backgroundColor: AppColors.surfaceHigh,
      showCheckmark: false,
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    CustomCaptionFont font,
  ) async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.removeFontTitle(font.family)),
        content: Text(l10n.removeFontBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await onApply((c) => c.removeCustomFont(font));
  }

  Future<void> _showAddFontDialog(BuildContext context) async {
    final l10n = context.l10n;
    final controller = TextEditingController();
    String? error;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setState) {
            return AlertDialog(
              backgroundColor: AppColors.surface,
              title: Text(l10n.addFont),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.fontNameHelp,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 12),
                  JavpTextField(
                    controller: controller,
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      labelText: l10n.fontNameHint,
                      errorText: error,
                    ),
                    onSubmitted: (_) async {
                      final name = controller.text.trim();
                      if (name.isEmpty) {
                        setState(() => error = l10n.fontNameHint);
                        return;
                      }
                      await onApply((c) => c.addCustomFontByName(name));
                      if (dialogContext.mounted) {
                        Navigator.pop(dialogContext);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        final picked = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: const ['ttf', 'otf', 'ttc', 'otc'],
                          withData: false,
                        );
                        final path = picked?.files.single.path;
                        if (path == null) return;
                        String? importError;
                        await onApply((c) async {
                          importError = await c.importFontFile(path);
                          return;
                        });
                        if (!dialogContext.mounted) return;
                        if (importError != null) {
                          setState(() {
                            error = switch (importError) {
                              'notFound' => l10n.fontImportNotFound,
                              'badFormat' => l10n.fontImportBadFormat,
                              'noFamily' => l10n.fontImportNoFamily,
                              _ => l10n.fontImportNoFamily,
                            };
                          });
                          return;
                        }
                        Navigator.pop(dialogContext);
                      },
                      icon: const Icon(Icons.folder_open_rounded),
                      label: Text(l10n.importFontFile),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(l10n.cancel),
                ),
                FilledButton(
                  onPressed: () async {
                    final name = controller.text.trim();
                    if (name.isEmpty) {
                      setState(() => error = l10n.fontNameHint);
                      return;
                    }
                    await onApply((c) => c.addCustomFontByName(name));
                    if (dialogContext.mounted) {
                      Navigator.pop(dialogContext);
                    }
                  },
                  child: Text(l10n.add),
                ),
              ],
            );
          },
        );
      },
    );
    controller.dispose();
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: const TextStyle(color: AppColors.text)),
            ),
            Text(valueLabel, style: const TextStyle(color: AppColors.textMuted)),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          activeColor: AppColors.accent,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.border,
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }
}

class _HintBanner extends StatelessWidget {
  const _HintBanner({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.accent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: AppColors.textMuted, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
