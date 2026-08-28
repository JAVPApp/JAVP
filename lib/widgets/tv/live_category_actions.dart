import 'package:flutter/material.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/iptv/live_category_pins.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:provider/provider.dart';

/// Long-press actions for a Live category tile (pin to the top, hide, open).
Future<void> showLiveCategoryActions({
  required BuildContext context,
  required IptvCategory category,
  VoidCallback? onOpen,
}) {
  return showAppModal<void>(
    context: context,
    builder: (context) =>
        _LiveCategoryActionsSheet(category: category, onOpen: onOpen),
  );
}

class _LiveCategoryActionsSheet extends StatelessWidget {
  const _LiveCategoryActionsSheet({required this.category, this.onOpen});

  final IptvCategory category;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider>();
    final parental = library.parentalLock;
    final pinned = iptvCategoryIsFavorite(
      category,
      library.favoriteCategoryIds.toSet(),
    );
    final hidden =
        parental?.hiddenLiveCategoryIds.contains(category.id) ?? false;

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppModalDragHandle(top: 10, width: 36, bottom: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Icon(Icons.folder_open_outlined, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    category.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          if (onOpen != null)
            ListTile(
              leading: const Icon(Icons.live_tv_rounded),
              title: Text(context.l10n.openCategory),
              onTap: () {
                Navigator.pop(context);
                onOpen!();
              },
            ),
          ListTile(
            leading: Icon(
              pinned ? Icons.star_rounded : Icons.star_outline_rounded,
              color: pinned ? AppColors.accent : null,
            ),
            title: Text(
              pinned ? context.l10n.unpinCategory : context.l10n.pinCategory,
            ),
            subtitle: Text(context.l10n.pinCategoryHelp),
            onTap: () async {
              Navigator.pop(context);
              await library.toggleFavoriteCategory(category);
            },
          ),
          if (parental != null)
            ListTile(
              leading: Icon(
                hidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              title: Text(
                hidden ? context.l10n.showCategory : context.l10n.hideCategory,
              ),
              subtitle: Text(
                parental.hasPin
                    ? context.l10n.hideCategoryHelp
                    : context.l10n.hideCategoryNeedsPin,
              ),
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                final needsPin = !parental.hasPin;
                final message = hidden
                    ? context.l10n.categoryShown(category.displayName)
                    : context.l10n.categoryHidden(category.displayName);
                final pinNotice = context.l10n.hideCategoryNeedsPin;
                Navigator.pop(context);
                await parental.toggleHiddenLiveCategory(category);
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      needsPin && !hidden ? '$message · $pinNotice' : message,
                    ),
                  ),
                );
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
