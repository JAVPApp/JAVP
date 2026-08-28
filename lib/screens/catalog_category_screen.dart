import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/adaptive_layout.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/catalog_browse_controls.dart';
import 'package:javp/widgets/desktop/desktop_hover_tile.dart';
import 'package:javp/widgets/desktop/hover_marquee_text.dart';
import 'package:javp/widgets/horizontal_scroll_text.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/widgets/media_item_actions.dart';
import 'package:javp/widgets/poster_lift.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';

/// Route extra for Catalog → See all (optional multi source filter).
class CatalogCategoryArgs {
  const CatalogCategoryArgs({required this.category, this.sourceKeys});

  static const routeType = 'CatalogCategoryArgs';

  final IptvCategory category;

  /// Empty / null = all sources.
  final Set<String>? sourceKeys;

  Map<String, dynamic> toJson() => {
    '__route': routeType,
    'category': category.toJson(),
    if (sourceKeys != null) 'sourceKeys': sourceKeys!.toList(),
  };

  factory CatalogCategoryArgs.fromJson(Map<String, dynamic> json) {
    final rawKeys = json['sourceKeys'];
    final rawCategory = json['category'];
    return CatalogCategoryArgs(
      category: IptvCategory.fromJson(
        rawCategory is Map
            ? Map<String, dynamic>.from(rawCategory)
            : const <String, dynamic>{},
      ),
      sourceKeys: rawKeys is Iterable
          ? {for (final key in rawKeys) '$key'}
          : null,
    );
  }

  static Object? tryParse(Object? input) {
    if (input is CatalogCategoryArgs) return input;
    if (input is Map && input['__route'] == routeType) {
      return CatalogCategoryArgs.fromJson(Map<String, dynamic>.from(input));
    }
    return null;
  }
}

/// Poster grid for one Catalog category (“See all”).
class CatalogCategoryScreen extends StatefulWidget {
  const CatalogCategoryScreen({
    super.key,
    required this.category,
    this.sourceKeys,
  });

  final IptvCategory category;

  /// Empty / null = all sources.
  final Set<String>? sourceKeys;

  @override
  State<CatalogCategoryScreen> createState() => _CatalogCategoryScreenState();
}

class _CatalogCategoryScreenState extends State<CatalogCategoryScreen> {
  final _scroll = ScrollController();
  List<MediaItem> _items = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _limit = 60;
  static const _pageSize = 60;
  String? _error;
  int? _appliedBrowseStamp;
  int? _appliedVodRevision;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<LibraryProvider>().loadCatalogBrowsePrefs();
      if (mounted) await _load(reset: true);
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || !_hasMore || _loading || _loadingMore) return;
    final pos = _scroll.position;
    if (pos.pixels > pos.maxScrollExtent - 800) {
      unawaited(_loadMore());
    }
  }

  Future<void> _load({required bool reset}) async {
    final library = context.read<LibraryProvider>();
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _limit = _pageSize;
        _hasMore = true;
      });
      try {
        await library.ensureVodCategoryAvailable(widget.category);
      } catch (e) {
        if (mounted) {
          setState(() => _error = e.toString());
        }
      }
      if (!mounted) return;
    }
    final series = widget.category.kind == IptvCategoryKind.series;
    final browseStampAtQuery = library.catalogBrowseStamp;
    final vodRevisionAtQuery = library.vodCacheRevision;
    final items = await library.queryVodCatalogAsync(
      series: series,
      categoryName: widget.category.name,
      sourceKeys: widget.sourceKeys,
      limit: _limit,
      collapse: true,
      browse: library.catalogBrowsePrefs,
    );
    if (!mounted) return;
    setState(() {
      _items = items;
      _hasMore = items.length >= _limit;
      _loading = false;
      _loadingMore = false;
      // Stamp the revision we queried so a commit during the await still
      // schedules another pass from [build].
      _appliedBrowseStamp = browseStampAtQuery;
      _appliedVodRevision = vodRevisionAtQuery;
    });
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _loadingMore) return;
    _loadingMore = true;
    _limit += _pageSize;
    await _load(reset: false);
  }

  @override
  Widget build(BuildContext context) {
    final moviePortrait = context.select<LibraryProvider, bool>(
      (l) => l.displaySettings.moviesCoverGridPortrait,
    );
    context.select<LibraryProvider, int>(
      (l) => Object.hash(
        l.vodCacheRevision,
        l.vodBusyRevision,
        l.vodLoading,
        l.sourcesAppearanceRevision,
        l.favoriteCategoryIds.length,
        Object.hashAll(l.favoriteCategoryIds),
        l.catalogBrowseStamp,
      ),
    );
    final library = context.read<LibraryProvider>();
    final browse = library.catalogBrowsePrefs;
    final stamp = library.catalogBrowseStamp;
    final vodRev = library.vodCacheRevision;
    final browseChanged =
        _appliedBrowseStamp != null && stamp != _appliedBrowseStamp;
    final vodChanged =
        _appliedVodRevision != null && vodRev != _appliedVodRevision;
    if ((browseChanged || vodChanged) && !_loading && !_loadingMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _loading || _loadingMore) return;
        final lib = context.read<LibraryProvider>();
        final browseNow =
            _appliedBrowseStamp != null &&
            lib.catalogBrowseStamp != _appliedBrowseStamp;
        final vodNow =
            _appliedVodRevision != null &&
            lib.vodCacheRevision != _appliedVodRevision;
        if (!browseNow && !vodNow) return;
        // Browse prefs need a full reset; progressive VOD commits only need a
        // re-query so an open See-all stays current without shrinking the page.
        unawaited(_load(reset: browseNow));
      });
    }
    final starred = library.isFavoriteCategory(widget.category);
    // A full-source prefetch must not hold this page behind a global spinner:
    // this category has its own demand fetch and a directly queryable DB page.
    final showLoading = _items.isEmpty && _loading;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: HorizontalScrollText(text: widget.category.displayName),
        actions: [
          IconButton(
            tooltip: starred ? context.l10n.favorited : context.l10n.favorite,
            onPressed: () => library.toggleFavoriteCategory(widget.category),
            icon: Icon(
              starred ? Icons.star_rounded : Icons.star_outline_rounded,
              color: starred ? AppColors.accent : null,
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: CatalogBrowseBar(
            prefs: browse,
            onChanged: (next) async {
              await library.setCatalogBrowsePrefs(next);
              if (mounted) await _load(reset: true);
            },
            onOpenFilters: () async {
              await showCatalogBrowseSheet(
                context: context,
                prefs: browse,
                genres: library.catalogBrowseGenreOptions(
                  categoryName: widget.category.name,
                  series: widget.category.kind == IptvCategoryKind.series,
                ),
                onChanged: (next) async {
                  await library.setCatalogBrowsePrefs(next);
                  if (mounted) await _load(reset: true);
                },
              );
            },
          ),
        ),
      ),
      body: showLoading
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    context.l10n.loadingEllipsis,
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                ],
              ),
            )
          : _error != null && _items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              ),
            )
          : _items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(
                  browse.hideWatched || browse.hasGenreFilters
                      ? context.l10n.noTitlesMatchFilters
                      : context.l10n.noTitlesInCategory,
                  style: const TextStyle(color: AppColors.textMuted),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : GridView.builder(
              controller: _scroll,
              padding: AppLayout.pagePadding(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: AdaptiveLayout.posterGridColumns(
                  AdaptiveLayout.contentWidth(context),
                ),
                mainAxisSpacing: 12,
                crossAxisSpacing: 10,
                childAspectRatio: AdaptiveLayout.posterGridChildAspectRatio(
                  portrait: moviePortrait,
                ),
              ),
              itemCount: _items.length + (_hasMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _items.length) {
                  return const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                final item = _items[index];
                return _PosterCell(
                  item: item,
                  portrait: moviePortrait,
                  onTap: () {
                    if (item.isSeries) {
                      context.push('/series', extra: item);
                    } else {
                      context.push('/title', extra: item);
                    }
                  },
                );
              },
            ),
    );
  }
}

class _PosterCell extends StatelessWidget {
  const _PosterCell({
    required this.item,
    required this.onTap,
    this.portrait = true,
  });

  final MediaItem item;
  final VoidCallback onTap;
  final bool portrait;

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
    final title = item.isLive || item.kind == MediaKind.catchup
        ? library.liveOrCatchupDisplayTitle(item)
        : item.kind == MediaKind.vod || item.kind == MediaKind.series
        ? VodGrouping.displayTitle(item)
        : item.title;
    final art = item.artUrlFor(portrait: portrait) ?? item.thumbnailUrl;
    final body = PosterCardShell(
      radius: 10,
      expandPoster: true,
      poster: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.surfaceHigh,
              Color.lerp(AppColors.accent, AppColors.bg, 0.72)!,
            ],
          ),
        ),
        child: art == null || art.isEmpty
            ? const SizedBox.expand()
            : JavpArt(url: art, decodeWidth: 240),
      ),
      meta: HoverMarqueeText(
        text: title,
        maxLines: 2,
        style: const TextStyle(
          color: AppColors.text,
          fontWeight: FontWeight.w700,
          fontSize: 12,
          height: 1.15,
        ),
      ),
    );

    void openActions([Offset? anchor]) {
      showMediaItemActions(context: context, item: item, anchor: anchor);
    }

    if (TvPlatform.isAndroidTv) {
      return TvFocusable(
        onSelect: onTap,
        onLongSelect: () => openActions(),
        borderRadius: 10,
        expandOnFocus: true,
        child: body,
      );
    }
    if (DesktopUi.enabled) {
      return DesktopHoverTile(
        radius: 10,
        onTap: onTap,
        onSecondaryTapAt: openActions,
        showPlayBadge: true,
        child: body,
      );
    }

    return InkWell(
      onTap: onTap,
      onLongPress: () => openActions(),
      borderRadius: BorderRadius.circular(10),
      child: body,
    );
  }
}
