import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/models/media_details.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
import 'package:javp/services/metadata/metadata_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_button.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:javp/widgets/download/download_widgets.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/services/images/javp_image_provider.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:javp/widgets/vod_source_groups.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Wraps [child] in [TvFocusable] on Android TV so D-pad can land on detail
/// action buttons that are otherwise easy to miss beside autofocus Play.
Widget _tvAction({required VoidCallback onSelect, required Widget child}) {
  if (!TvPlatform.isAndroidTv) return child;
  return TvFocusable(borderRadius: 10, onSelect: onSelect, child: child);
}

class TitleDetailScreen extends StatefulWidget {
  const TitleDetailScreen({super.key, required this.item});

  final MediaItem item;

  @override
  State<TitleDetailScreen> createState() => _TitleDetailScreenState();
}

class _TitleDetailScreenState extends State<TitleDetailScreen> {
  late Future<MediaDetails?> _future;
  MediaDetails? _details;
  bool _matching = false;
  List<MediaItem> _pinnedVariants = const [];
  String? _heroBackdrop;
  String? _heroPoster;
  bool _stickyHasTrailer = false;

  @override
  void initState() {
    super.initState();
    final library = context.read<LibraryProvider>();
    unawaited(library.hydrateVodFamilyFromDb(widget.item));
    _bindDetails(library.loadMediaDetails(_detailsSeed(library, widget.item)));
  }

  @override
  void didUpdateWidget(TitleDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _pinnedVariants = const [];
      unawaited(
        context.read<LibraryProvider>().hydrateVodFamilyFromDb(widget.item),
      );
    }
  }

  /// Never shrink a known family to one row while the Versions index rebuilds.
  List<MediaItem> _stableVariants(List<MediaItem> latest) {
    if (latest.length > 1) {
      _pinnedVariants = latest;
      return latest;
    }
    if (_pinnedVariants.length > 1) {
      if (latest.isEmpty) return _pinnedVariants;
      final keep = <String, MediaItem>{
        for (final v in _pinnedVariants) v.id: v,
      };
      keep[latest.first.id] = latest.first;
      return keep.values.toList(growable: false);
    }
    _pinnedVariants = latest;
    return latest;
  }

  /// Prefer a catalog/TMDB sibling for plot and art — the preferred stream may
  /// be a sparse IPTV row with no backdrop.
  static int _detailsRichness(MediaItem m) {
    var score = 0;
    if (m.tmdbId != null && m.tmdbId! > 0) score += 8;
    if ((m.backdropUrl ?? '').trim().isNotEmpty) score += 4;
    if ((m.plot ?? '').trim().isNotEmpty) score += 2;
    if ((m.artUrl ?? '').trim().isNotEmpty) score += 1;
    if (m.origin == MediaOrigin.customCatalog) score += 1;
    return score;
  }

  MediaItem _detailsSeed(LibraryProvider library, MediaItem seed) {
    var best = seed;
    var bestScore = _detailsRichness(seed);
    for (final v in library.vodVariantsFor(seed)) {
      final score = _detailsRichness(v);
      if (score > bestScore) {
        best = v;
        bestScore = score;
      }
    }
    return best;
  }

  void _bindDetails(Future<MediaDetails?> future) {
    _future = future;
    future.then((d) {
      if (!mounted || !identical(_future, future)) return;
      setState(() => _details = d);
    });
  }

  /// Keep the last good poster/backdrop so a sparse IPTV row cannot blank the hero.
  String? _stickyArt(String? preferred, String? fallback, String? remembered) {
    if (preferred != null && preferred.trim().isNotEmpty) {
      return preferred.trim();
    }
    if (fallback != null && fallback.trim().isNotEmpty) {
      return fallback.trim();
    }
    return remembered;
  }

  MediaItem get _item {
    final library = context.read<LibraryProvider>();
    return library.itemById(widget.item.id) ?? widget.item;
  }

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
    final itemId = widget.item.id;
    final saved = context.select<LibraryProvider, bool>(
      (l) => l.isInWatchlist(l.itemById(itemId) ?? widget.item),
    );
    // Rebuild download button when queue/progress changes.
    context.select<LibraryProvider, int>((l) {
      final task = l.downloadTaskFor(l.itemById(itemId) ?? widget.item);
      return Object.hash(task?.status, task?.progress);
    });
    // Rebuild when VOD preference / cache changes — not on every library tick.
    // Do NOT put this on a Scaffold/ValueKey: changing the key remounts the
    // scroll view and the Versions chips appear to "disappear" after a tap.
    context.select<LibraryProvider, int>((l) {
      final seed = l.itemById(itemId) ?? widget.item;
      final prefKey = VodGrouping.preferenceKey(seed);
      final canonical = l.canonicalVodGroupKey(seed);
      return Object.hash(
        l.vodCacheRevision,
        l.vodGroupingRevision,
        l.vodVariantCountFor(seed),
        l.preferredVodVariants[prefKey],
        canonical == null ? null : l.preferredVodVariants[canonical],
      );
    });
    final seed = library.itemById(itemId) ?? widget.item;
    // Variants are anchored to the route title family, not only the preferred
    // edition — availability and player switching still see every encode.
    final variants = _stableVariants(library.vodVariantsFor(seed));
    final item = library.resolveVodVariant(seed);
    final preferredLangs = context
        .read<LocaleController>()
        .preferredContentLanguageCodes;
    final familyLayout = VodGrouping.familyLayout(
      variants,
      preferredLangs: preferredLangs,
      sourceLabelFor: library.sourceLabelFor,
    );

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: FutureBuilder<MediaDetails?>(
        future: _future,
        builder: (context, snap) {
          final details = snap.data ?? _details;
          final backdrop = _stickyArt(
            details?.backdropUrl,
            item.backdropUrl,
            _heroBackdrop,
          );
          final poster = _stickyArt(
            details?.posterUrl,
            item.artUrl,
            _heroPoster,
          );
          _heroBackdrop = backdrop;
          _heroPoster = poster;
          final plot = details?.plot ?? item.plot;
          final runtime = item.duration ?? details?.runtime;
          final genres = details?.genres.isNotEmpty == true
              ? details!.genres
              : item.genres;
          final rating = details?.rating ?? item.rating;
          final year = details?.year ?? item.year;
          final cast = details?.cast ?? const <CastMember>[];
          final title = details?.title.isNotEmpty == true
              ? details!.title
              : VodGrouping.displayTitle(item);
          final hasTrailer =
              details?.hasTrailer == true ||
              (item.trailerUrl != null && item.trailerUrl!.isNotEmpty);
          if (hasTrailer) _stickyHasTrailer = true;
          final showTrailer = hasTrailer || _stickyHasTrailer;
          final contentRating = details?.contentRating ?? item.contentRating;
          final studio = details?.studio ?? item.studio;

          return CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: 240,
                pinned: true,
                backgroundColor: AppColors.bg,
                actions: [
                  if (library.isMetadataEnricherAvailable)
                    if (_matching)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    else if (TvPlatform.isAndroidTv)
                      TvFocusable(
                        borderRadius: 24,
                        onSelect: () => _matchMetadata(library),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Icon(
                            Icons.auto_awesome_rounded,
                            color: AppColors.accent,
                          ),
                        ),
                      )
                    else
                      PopupMenuButton<String>(
                        tooltip: context.l10n.matchMetadata,
                        onSelected: (value) {
                          if (value == 'match') {
                            _matchMetadata(library);
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'match',
                            child: Text(context.l10n.matchMetadata),
                          ),
                        ],
                      ),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (backdrop != null && backdrop.isNotEmpty)
                        JavpArt(url: backdrop, decodeWidth: 1080)
                      else
                        Container(color: AppColors.surfaceHigh),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Color(0xFF0B0C0F)],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (poster != null && poster.isNotEmpty)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox(
                                width: 110,
                                height: 165,
                                child: JavpArt(url: poster, decodeWidth: 330),
                              ),
                            )
                          else
                            Container(
                              width: 110,
                              height: 165,
                              decoration: BoxDecoration(
                                color: AppColors.surfaceHigh,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.movie_outlined),
                            ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  [
                                    if (year != null) '$year',
                                    if (contentRating != null &&
                                        contentRating.isNotEmpty)
                                      contentRating,
                                    if (rating != null)
                                      '★ ${rating.toStringAsFixed(1)}',
                                    if (runtime != null) _fmtDuration(runtime),
                                    if (studio != null && studio.isNotEmpty)
                                      studio,
                                    if (!familyLayout.hasMultipleSources)
                                      library.sourceLabelFor(item),
                                  ].join(' · '),
                                  style: const TextStyle(
                                    color: AppColors.textMuted,
                                  ),
                                ),
                                if (genres.isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      for (final g in genres.take(6))
                                        Chip(
                                          label: Text(g),
                                          visualDensity: VisualDensity.compact,
                                          backgroundColor:
                                              AppColors.surfaceHigh,
                                          side: BorderSide.none,
                                          labelStyle: const TextStyle(
                                            fontSize: 12,
                                            color: AppColors.text,
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                                VodAvailabilityLine(
                                  layout: familyLayout,
                                  preferredLangs: preferredLangs,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          if (TvPlatform.isAndroidTv)
                            TvFocusable(
                              autofocus: true,
                              enabled: item.isPlayable,
                              onSelect: item.isPlayable
                                  ? () => context.push('/player', extra: item)
                                  : null,
                              child: FilledButton.icon(
                                onPressed: item.isPlayable
                                    ? () => context.push('/player', extra: item)
                                    : null,
                                icon: const Icon(Icons.play_arrow_rounded),
                                label: Text(context.l10n.play),
                              ),
                            )
                          else
                            AppButton(
                              onPressed: item.isPlayable
                                  ? () => context.push('/player', extra: item)
                                  : null,
                              icon: Icons.play_arrow_rounded,
                              label: context.l10n.play,
                            ),
                          _tvAction(
                            onSelect: () => library.toggleWatchlist(item),
                            child: OutlinedButton.icon(
                              onPressed: () => library.toggleWatchlist(item),
                              icon: Icon(
                                saved
                                    ? Icons.bookmark_rounded
                                    : Icons.bookmark_border_rounded,
                              ),
                              label: Text(
                                saved
                                    ? context.l10n.inMyList
                                    : context.l10n.myList,
                              ),
                            ),
                          ),
                          if (showTrailer)
                            _tvAction(
                              onSelect: () => _openTrailer(
                                details: details,
                                item: item,
                                title: title,
                              ),
                              child: OutlinedButton.icon(
                                onPressed: () => _openTrailer(
                                  details: details,
                                  item: item,
                                  title: title,
                                ),
                                icon: const Icon(Icons.ondemand_video_outlined),
                                label: Text(context.l10n.trailer),
                              ),
                            ),
                          if (item.isSeries)
                            _tvAction(
                              onSelect: () => _showSeriesDownloadOptions(
                                context,
                                library,
                                item,
                              ),
                              child: OutlinedButton.icon(
                                onPressed: () => _showSeriesDownloadOptions(
                                  context,
                                  library,
                                  item,
                                ),
                                icon: const Icon(Icons.download_rounded),
                                label: Text(context.l10n.download),
                              ),
                            )
                          else
                            DownloadStatusButton(item: item, outlined: true),
                        ],
                      ),
                      if (snap.connectionState != ConnectionState.done &&
                          _details == null)
                        Padding(
                          padding: EdgeInsets.only(top: 20),
                          child: LinearProgressIndicator(),
                        ),
                      if (plot != null && plot.isNotEmpty) ...[
                        const SizedBox(height: 22),
                        Text(
                          context.l10n.overview,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          plot,
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            height: 1.45,
                          ),
                        ),
                      ],
                      if (cast.isNotEmpty) ...[
                        const SizedBox(height: 22),
                        Text(
                          context.l10n.cast,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 120,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: cast.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 12),
                            itemBuilder: (context, i) {
                              final c = cast[i];
                              return SizedBox(
                                width: 88,
                                child: Column(
                                  children: [
                                    CircleAvatar(
                                      radius: 32,
                                      backgroundColor: AppColors.surfaceHigh,
                                      backgroundImage: c.profileUrl != null
                                          ? JavpImageProvider(
                                              c.profileUrl!,
                                              targetWidth: 128,
                                            )
                                          : null,
                                      child: c.profileUrl == null
                                          ? Text(
                                              c.name.isEmpty
                                                  ? '?'
                                                  : c.name.characters.first,
                                            )
                                          : null,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      c.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (c.character != null)
                                      Text(
                                        c.character!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: AppColors.textMuted,
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                      if (details?.collectionName != null) ...[
                        const SizedBox(height: 18),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(
                            Icons.collections_bookmark_outlined,
                          ),
                          title: Text(details!.collectionName!),
                          subtitle: Text(context.l10n.collection),
                          onTap: details.collectionId == null
                              ? null
                              : () => library.ensureTmdbCollection(
                                  details.collectionId!,
                                  details.collectionName!,
                                  item.id,
                                ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showSeriesDownloadOptions(
    BuildContext context,
    LibraryProvider library,
    MediaItem series,
  ) async {
    await showAppModal<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.library_add_rounded),
                title: Text(context.l10n.downloadEntireSeries),
                subtitle: Text(context.l10n.queueEveryEpisodeOffline),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    final info = await library.loadSeriesInfo(series);
                    if (!context.mounted) return;
                    await enqueueDownloadsWithFeedback(
                      context,
                      library,
                      () => library.enqueueDownloadEntireSeries(
                        series,
                        info: info,
                      ),
                      singular: 'episode',
                      plural: 'episodes',
                    );
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          context.l10n.couldNotLoadSeriesError(e.toString()),
                        ),
                      ),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.tv_rounded),
                title: Text(context.l10n.chooseSeasonEpisodes),
                onTap: () {
                  Navigator.pop(ctx);
                  context.push('/series', extra: series);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _matchMetadata(LibraryProvider library) async {
    setState(() => _matching = true);
    try {
      final hits = await library.searchMetadata(_item.title);
      if (!mounted) return;
      if (hits.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.noMetadataMatches)));
        return;
      }
      final picked = await showAppModal<MetadataSearchHit>(
        context: context,
        builder: (context) {
          return ListView.builder(
            shrinkWrap: true,
            itemCount: hits.length,
            itemBuilder: (context, i) {
              final hit = hits[i];
              return ListTile(
                leading: hit.posterUrl == null
                    ? const Icon(Icons.movie_outlined)
                    : SizedBox(
                        width: 40,
                        child: JavpArt(url: hit.posterUrl, decodeWidth: 96),
                      ),
                title: Text(hit.title),
                subtitle: Text(
                  '${hit.mediaType}${hit.year != null ? ' · ${hit.year}' : ''}',
                ),
                onTap: () => Navigator.pop(context, hit),
              );
            },
          );
        },
      );
      if (picked == null) return;
      await library.applyMetadataMatch(
        _item,
        externalId: picked.id,
        mediaType: picked.mediaType,
      );
      setState(() {
        _bindDetails(library.loadMediaDetails(_item, forceRefresh: true));
      });
    } finally {
      if (mounted) setState(() => _matching = false);
    }
  }

  Future<void> _openTrailer({
    MediaDetails? details,
    required MediaItem item,
    required String title,
  }) async {
    final url = details?.youtubeTrailerUrl ?? item.trailerUrl;
    if (url == null || url.isEmpty) return;
    if (!mounted) return;
    final trailerItem = MediaItem(
      id: 'trailer-${details?.id ?? item.id}',
      title: context.l10n.trailerNamed(title),
      playUrl: url,
      kind: MediaKind.network,
      origin: MediaOrigin.url,
      thumbnailUrl: details?.backdropUrl ?? details?.posterUrl ?? item.artUrl,
    );
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
    } catch (_) {}
    if (mounted) context.push('/player', extra: trailerItem);
  }

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }
}
