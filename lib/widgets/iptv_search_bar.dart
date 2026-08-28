import 'package:flutter/material.dart';
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/iptv/iptv_search_query.dart';
import 'package:javp/services/storage/live_channel_db.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/javp_text_field.dart';

/// Compact IPTV search field used across Live / VOD / EPG tabs.
class IptvSearchBar extends StatelessWidget {
  const IptvSearchBar({
    super.key,
    required this.controller,
    required this.hintText,
    this.onChanged,
    this.onClear,
    this.autofocus = false,
    this.focusNode,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: JavpTextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: const TextStyle(color: AppColors.text, fontSize: 14),
        decoration: InputDecoration(
          isDense: true,
          hintText: hintText,
          hintStyle: const TextStyle(fontSize: 13),
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 36,
          ),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: context.l10n.clear,
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    controller.clear();
                    onClear?.call();
                    onChanged?.call('');
                  },
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
          filled: true,
          fillColor: AppColors.surfaceHigh,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 8,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.accent),
          ),
        ),
      ),
    );
  }
}

enum IptvLiveFilter { all, favorites, recents, catchup, hasEpg }

enum IptvSort { playlist, nameAsc, categoryAsc, catchupFirst }

extension IptvLiveFilterLabel on IptvLiveFilter {
  String label(AppLocalizations l10n) => switch (this) {
    IptvLiveFilter.all => l10n.all,
    IptvLiveFilter.favorites => l10n.favorites,
    IptvLiveFilter.recents => l10n.recents,
    IptvLiveFilter.catchup => l10n.catchup,
    IptvLiveFilter.hasEpg => l10n.hasEpg,
  };
}

extension IptvSortLabel on IptvSort {
  String label(AppLocalizations l10n) => switch (this) {
    IptvSort.playlist => l10n.playlistOrder,
    IptvSort.nameAsc => l10n.nameAZ,
    IptvSort.categoryAsc => l10n.category,
    IptvSort.catchupFirst => l10n.catchupFirst,
  };

  /// Maps UI sort to the live-channel DB order.
  LiveListingSort get listingSort => switch (this) {
    IptvSort.playlist => LiveListingSort.position,
    IptvSort.nameAsc => LiveListingSort.name,
    IptvSort.categoryAsc => LiveListingSort.category,
    IptvSort.catchupFirst => LiveListingSort.catchupFirst,
  };
}

/// Case-insensitive multi-token match across haystacks (NFKD + punctuation).
bool iptvMatchesQuery(String query, Iterable<String?> fields) {
  return IptvSearchQuery.matchesFields(query, fields);
}
