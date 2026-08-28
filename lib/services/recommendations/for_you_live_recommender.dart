import 'dart:ui' show Locale;

import 'package:javp/models/epg_program.dart';
import 'package:javp/models/for_you_shelf.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/iptv_locale_hints.dart';

/// Local live For you shelves — favorites/recents first, then affinity + locale.
class ForYouLiveRecommender {
  const ForYouLiveRecommender();

  /// Build ranked shelves. [localeSamples] should already be fetched (paged).
  List<ForYouShelf> build({
    required List<MediaItem> favorites,
    required List<MediaItem> recents,
    required List<MediaItem> localeSamples,
    required Locale locale,
    EpgProgram? Function(MediaItem channel)? nowPlaying,
    int perShelf = 12,
  }) {
    final seenGlobal = <String>{};
    final shelves = <ForYouShelf>[];

    List<MediaItem> takeUnique(
      Iterable<MediaItem> source, {
      int limit = 12,
      bool Function(MediaItem)? keep,
    }) {
      final out = <MediaItem>[];
      for (final channel in source) {
        if (out.length >= limit) break;
        if (keep != null && !keep(channel)) continue;
        if (!seenGlobal.add(channel.id)) continue;
        out.add(channel);
      }
      return out;
    }

    final jumpBack = takeUnique(recents, limit: perShelf);
    if (jumpBack.isNotEmpty) {
      shelves.add(
        ForYouShelf(
          id: 'jump_back',
          title: 'Jump back in',
          subtitle: 'Recently watched',
          channels: jumpBack,
        ),
      );
    }

    final favs = takeUnique(favorites, limit: perShelf);
    if (favs.isNotEmpty) {
      shelves.add(
        ForYouShelf(
          id: 'favorites',
          title: 'Favorites',
          channels: favs,
        ),
      );
    }

    if (nowPlaying != null) {
      final onNowSource = <MediaItem>[
        ...favorites,
        ...recents,
        ...localeSamples,
      ];
      // Allow channels already shown above — On now is a different job.
      final onNow = <MediaItem>[];
      final onNowSeen = <String>{};
      for (final channel in onNowSource) {
        if (onNow.length >= perShelf) break;
        if (!onNowSeen.add(channel.id)) continue;
        final program = nowPlaying(channel);
        if (program == null) continue;
        onNow.add(channel.copyWith(subtitle: program.title));
      }
      if (onNow.isNotEmpty) {
        shelves.add(
          ForYouShelf(
            id: 'on_now',
            title: 'On now for you',
            subtitle: 'Airing on channels you know',
            channels: onNow,
          ),
        );
      }
    }

    final affinityGroup = _topAffinityGroup(favorites, recents);
    if (affinityGroup != null) {
      final because = takeUnique(
        [...favorites, ...recents, ...localeSamples],
        limit: perShelf,
        keep: (c) => (c.group ?? '') == affinityGroup,
      );
      if (because.isNotEmpty) {
        shelves.add(
          ForYouShelf(
            id: 'because_$affinityGroup',
            title: 'Because you watch',
            subtitle: affinityGroup,
            channels: because,
          ),
        );
      }
    }

    // Show a fuller locale row than other shelves (2×) — it's the main
    // discovery shelf when favorites/recents are thin.
    final localeLimit = perShelf * 2;
    final inLanguage = takeUnique(localeSamples, limit: localeLimit);
    if (inLanguage.isNotEmpty) {
      shelves.add(
        ForYouShelf(
          id: 'locale',
          title: 'In your language',
          subtitle: 'Matched to ${IptvLocaleHints.matchCode(locale)}',
          channels: inLanguage,
        ),
      );
    }

    // Cold start: nothing starred/watched yet — keep locale shelf only.
    if (shelves.isEmpty && localeSamples.isNotEmpty) {
      shelves.add(
        ForYouShelf(
          id: 'locale',
          title: 'Suggested for you',
          subtitle: IptvLocaleHints.tokensFor(locale).take(2).join(' · '),
          channels: takeUnique(localeSamples, limit: localeLimit),
        ),
      );
    }

    return shelves;
  }

  String? _topAffinityGroup(
    List<MediaItem> favorites,
    List<MediaItem> recents,
  ) {
    final scores = <String, int>{};
    for (var i = 0; i < recents.length; i++) {
      final group = recents[i].group?.trim();
      if (group == null || group.isEmpty) continue;
      scores[group] = (scores[group] ?? 0) + (recents.length - i);
    }
    for (final channel in favorites) {
      final group = channel.group?.trim();
      if (group == null || group.isEmpty) continue;
      scores[group] = (scores[group] ?? 0) + 8;
    }
    if (scores.isEmpty) return null;
    final ranked = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ranked.first.key;
  }
}
