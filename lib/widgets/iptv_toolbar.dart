import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/screens/tv/tv_remote_screen.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/javp_text_field.dart';

/// Single-row IPTV chrome: optional source menu + dense search + filter action.
class IptvToolbar extends StatelessWidget {
  const IptvToolbar({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onChanged,
    required this.onClear,
    required this.onOpenFilters,
    this.sourceLabel,
    this.onPickSource,
    this.filtersActive = false,
    this.resultCount,
    this.showPhoneRemote = false,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final VoidCallback onOpenFilters;
  final String? sourceLabel;
  final VoidCallback? onPickSource;
  final bool filtersActive;
  final String? resultCount;

  /// When true, forces the QR remote button even if auto-detect would hide it.
  final bool showPhoneRemote;

  @override
  Widget build(BuildContext context) {
    final remote = showPhoneRemote || phoneRemoteEntryAvailable;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            if (onPickSource != null) ...[
              InkWell(
                onTap: onPickSource,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 96),
                        child: Text(
                          sourceLabel ?? 'Source',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.arrow_drop_down_rounded,
                        size: 18,
                        color: AppColors.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: JavpTextField(
                controller: controller,
                onChanged: onChanged,
                textInputAction: TextInputAction.search,
                style: const TextStyle(color: AppColors.text, fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: hintText,
                  hintStyle: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  suffixIcon: controller.text.isEmpty
                      ? (resultCount == null
                            ? null
                            : Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Center(
                                  child: Text(
                                    resultCount!,
                                    style: const TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ))
                      : IconButton(
                          tooltip: context.l10n.clear,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                          onPressed: () {
                            controller.clear();
                            onClear();
                            onChanged('');
                          },
                          icon: const Icon(Icons.close_rounded, size: 16),
                        ),
                  filled: true,
                  fillColor: AppColors.surfaceHigh,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 0,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.accent),
                  ),
                ),
              ),
            ),
            if (remote)
              IconButton(
                tooltip: context.l10n.typeOnPhone,
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  openPhoneRemote(
                    context,
                    onSearch: (text) {
                      controller.text = text;
                      controller.selection = TextSelection.collapsed(
                        offset: text.length,
                      );
                      onChanged(text);
                    },
                  );
                },
                icon: const Icon(Icons.smartphone_rounded, size: 20),
              ),
            IconButton(
              tooltip: context.l10n.filters,
              visualDensity: VisualDensity.compact,
              onPressed: onOpenFilters,
              icon: Badge(
                isLabelVisible: filtersActive,
                smallSize: 8,
                backgroundColor: AppColors.accent,
                child: Icon(
                  Icons.tune_rounded,
                  size: 20,
                  color: filtersActive ? AppColors.accent : AppColors.textMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
