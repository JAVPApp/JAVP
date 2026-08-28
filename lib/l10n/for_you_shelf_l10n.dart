import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/models/for_you_shelf.dart';

/// Identity tokens for Live category chips. Keep English so playlist names
/// never collide with translated chrome; [liveBrowseChipLabel] is the UI copy.
const kLiveChipForYou = 'For you';
const kLiveChipAll = 'All';
const kLiveChipLocale = 'In your language';

/// Display label for Live chrome chips. Playlist category names pass through.
String liveBrowseChipLabel(AppLocalizations l10n, String chipId) {
  if (chipId == kLiveChipForYou) return l10n.forYou;
  if (chipId == kLiveChipAll) return l10n.all;
  if (chipId == kLiveChipLocale) return l10n.inYourLanguage;
  return chipId;
}

/// Resolve For you shelf chrome from stable shelf ids (titles in the model
/// stay English for persistence/debug; UI always goes through l10n).
({String title, String? subtitle}) localizeForYouShelf(
  AppLocalizations l10n,
  ForYouShelf shelf,
) {
  final id = shelf.id;
  if (id == 'jump_back') {
    return (title: l10n.jumpBackIn, subtitle: l10n.recentlyWatched);
  }
  if (id == 'favorites') {
    return (title: l10n.favorites, subtitle: shelf.subtitle);
  }
  if (id == 'on_now') {
    return (title: l10n.onNowForYou, subtitle: l10n.airingOnChannelsYouKnow);
  }
  if (id.startsWith('because_')) {
    return (title: l10n.becauseYouWatch, subtitle: shelf.subtitle);
  }
  if (id == 'locale') {
    final suggested = shelf.title == 'Suggested for you';
    final subtitle = shelf.subtitle;
    if (suggested) {
      return (title: l10n.suggestedForYou, subtitle: subtitle);
    }
    // Recommender stores "Matched to XX" — keep the token after the last space.
    final token = subtitle != null && subtitle.contains(' ')
        ? subtitle.split(' ').last
        : subtitle;
    return (
      title: l10n.inYourLanguage,
      subtitle: token == null || token.isEmpty
          ? null
          : l10n.matchedToLang(token),
    );
  }
  if (id == 'fav_categories') {
    return (title: l10n.fromFavoriteCategories, subtitle: shelf.subtitle);
  }
  return (title: shelf.title, subtitle: shelf.subtitle);
}
