import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/screens/tv/tv_remote_screen.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';

/// Left-side “More like this” shelf for TV VOD Big Picture.
class TvRelatedOverlay extends StatefulWidget {
  const TvRelatedOverlay({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  State<TvRelatedOverlay> createState() => _TvRelatedOverlayState();
}

class _TvRelatedOverlayState extends State<TvRelatedOverlay> {
  String? _suggestionsItemId;
  List<MediaItem> _suggestions = const [];

  Future<void> _open(BuildContext context, MediaItem item) async {
    if (item.isSeries) {
      context.push('/series', extra: item);
      return;
    }
    await context.read<PlaybackProvider>().open(item, expand: true);
    widget.onClose();
  }

  void _warmSuggestions(LibraryProvider library, MediaItem? item) {
    if (item == null) {
      _suggestionsItemId = null;
      _suggestions = const [];
      return;
    }
    if (_suggestionsItemId == item.id) return;
    _suggestionsItemId = item.id;
    _suggestions = library.vodSuggestionsFor(item, limit: 16);
    unawaited(() async {
      final next = await library.vodSuggestionsForAsync(item, limit: 16);
      if (!mounted || _suggestionsItemId != item.id) return;
      setState(() => _suggestions = next);
    }());
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackProvider>();
    final library = context.watch<LibraryProvider>();
    final item = playback.item;
    _warmSuggestions(library, item);
    final suggestions = _suggestions;

    return Material(
      color: const Color(0xE60B0D12),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.moreLikeThis,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  TvFocusable(
                    onSelect: widget.onClose,
                    borderRadius: 20,
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(Icons.close_rounded),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            Expanded(
              child: suggestions.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          context.l10n.moreTitlesAsCatalogFills,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.textMuted),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: suggestions.length,
                      itemBuilder: (context, index) {
                        final row = suggestions[index];
                        final art = row.artUrlFor(portrait: true);
                        return TvFocusable(
                          autofocus: index == 0,
                          onSelect: () => unawaited(_open(context, row)),
                          borderRadius: 10,
                          child: ListTile(
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: SizedBox(
                                width: 44,
                                height: 66,
                                child: ColoredBox(
                                  color: AppColors.surfaceHigh,
                                  child: JavpArt(
                                    url: art,
                                    decodeWidth: 88,
                                    fallback: const Icon(
                                      Icons.movie_rounded,
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            title: Text(
                              row.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              [
                                if (row.year != null) '${row.year}',
                                if (row.group != null &&
                                    row.group!.trim().isNotEmpty)
                                  row.group!.trim(),
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textMuted,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// In-player library search driven by the phone remote QR session.
class TvLibrarySearchOverlay extends StatefulWidget {
  const TvLibrarySearchOverlay({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  State<TvLibrarySearchOverlay> createState() => _TvLibrarySearchOverlayState();
}

class _TvLibrarySearchOverlayState extends State<TvLibrarySearchOverlay> {
  String _query = '';
  List<MediaItem> _results = const [];
  bool _loading = false;
  bool _remoteOpened = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_openRemote());
    });
  }

  Future<void> _openRemote() async {
    if (!phoneRemoteEntryAvailable || _remoteOpened) return;
    _remoteOpened = true;
    await openPhoneRemote(
      context,
      onSearch: (text) {
        unawaited(_runSearch(text));
      },
    );
  }

  Future<void> _runSearch(String text) async {
    final q = text.trim();
    setState(() {
      _query = q;
      _loading = q.isNotEmpty;
    });
    if (q.isEmpty) {
      setState(() {
        _results = const [];
        _loading = false;
      });
      return;
    }
    final library = context.read<LibraryProvider>();
    final hits = await library.searchLocalLibrary(q, limit: 40);
    if (!mounted) return;
    setState(() {
      _results = hits;
      _loading = false;
    });
  }

  Future<void> _open(MediaItem item) async {
    if (item.isSeries) {
      context.push('/series', extra: item);
      return;
    }
    await context.read<PlaybackProvider>().open(item, expand: true);
    if (mounted) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xE60B0D12),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.searchLibrary,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  TvFocusable(
                    onSelect: widget.onClose,
                    borderRadius: 20,
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(Icons.close_rounded),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                _query.isEmpty ? context.l10n.typeOnPhone : _query,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _query.isEmpty ? AppColors.textMuted : AppColors.text,
                  fontSize: 16,
                  fontWeight: _query.isEmpty
                      ? FontWeight.w500
                      : FontWeight.w700,
                ),
              ),
            ),
            if (phoneRemoteEntryAvailable)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TvFocusable(
                    autofocus: _results.isEmpty && !_loading,
                    onSelect: () {
                      _remoteOpened = false;
                      unawaited(_openRemote());
                    },
                    borderRadius: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        context.l10n.typeOnPhone,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            const Divider(height: 1, color: AppColors.border),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _results.isEmpty
                  ? Center(
                      child: Text(
                        _query.isEmpty
                            ? context.l10n.typeOnPhone
                            : context.l10n.noMatches,
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final row = _results[index];
                        final art = row.artUrlFor(portrait: !row.isLive);
                        return TvFocusable(
                          autofocus: index == 0,
                          onSelect: () => unawaited(_open(row)),
                          borderRadius: 10,
                          child: ListTile(
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: SizedBox(
                                width: 48,
                                height: row.isLive ? 28 : 66,
                                child: ColoredBox(
                                  color: AppColors.surfaceHigh,
                                  child: JavpArt(
                                    url: art,
                                    decodeWidth: 96,
                                    fallback: Icon(
                                      row.isLive
                                          ? Icons.live_tv_rounded
                                          : Icons.movie_rounded,
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            title: Text(
                              row.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              [
                                if (row.isLive) context.l10n.live,
                                if (row.isSeries) context.l10n.series,
                                if (row.year != null) '${row.year}',
                              ].whereType<String>().join(' · '),
                              style: const TextStyle(
                                color: AppColors.textMuted,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
