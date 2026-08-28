import 'package:flutter/material.dart';
import 'package:javp/platform/adaptive_layout.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/widgets/mini_player_bar.dart';

/// Responsive live-channel scroller: one column on phones, a multi-column
/// grid on desktop / tablet rail and Android TV when the content area is wide.
///
/// Each cell is expected to be a dense [MediaTile]-style row (~[itemExtent]
/// tall). On TV, [MediaTile] already wraps in [TvFocusable]; Flutter's
/// directional focus policy walks left/right across columns and up/down
/// across rows.
class LiveChannelList extends StatelessWidget {
  const LiveChannelList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.padding,
    this.itemExtent = 72,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ScrollController? controller;
  final EdgeInsetsGeometry? padding;
  final double itemExtent;

  @override
  Widget build(BuildContext context) {
    final resolvedPadding =
        padding ??
        (TvPlatform.isAndroidTv
            ? EdgeInsets.only(bottom: miniPlayerScrollBottomInset(context))
            : null);
    final columns = AdaptiveLayout.liveChannelColumns(context);
    if (columns <= 1) {
      return ListView.builder(
        controller: controller,
        padding: resolvedPadding,
        itemCount: itemCount,
        itemExtent: itemExtent,
        itemBuilder: itemBuilder,
      );
    }

    Widget grid = GridView.builder(
      controller: controller,
      padding: resolvedPadding,
      // Clip the viewport. Clip.none lets scrolled rows paint over the
      // sticky search field / category chips on desktop (Windows) rail.
      // TV focus rings get breathing room from [liveChannelGridDelegate]
      // spacing instead of escaping the list.
      clipBehavior: Clip.hardEdge,
      gridDelegate: AdaptiveLayout.liveChannelGridDelegate(
        context,
        mainAxisExtent: itemExtent,
      ),
      itemCount: itemCount,
      itemBuilder: itemBuilder,
    );

    if (TvPlatform.isAndroidTv) {
      grid = FocusTraversalGroup(child: grid);
    }
    return grid;
  }
}

/// Sliver variant for [CustomScrollView] For You shelves / mixed layouts.
class LiveChannelSliverList extends StatelessWidget {
  const LiveChannelSliverList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.itemExtent = 72,
  });

  final int itemCount;
  final NullableIndexedWidgetBuilder itemBuilder;
  final double itemExtent;

  @override
  Widget build(BuildContext context) {
    final columns = AdaptiveLayout.liveChannelColumns(context);
    if (columns <= 1) {
      return SliverFixedExtentList(
        itemExtent: itemExtent,
        delegate: SliverChildBuilderDelegate(
          itemBuilder,
          childCount: itemCount,
        ),
      );
    }

    // No FocusTraversalGroup here — it cannot wrap a sliver. Directional
    // (D-pad) focus still walks the grid geometrically via each TvFocusable.
    return SliverGrid(
      gridDelegate: AdaptiveLayout.liveChannelGridDelegate(
        context,
        mainAxisExtent: itemExtent,
      ),
      delegate: SliverChildBuilderDelegate(itemBuilder, childCount: itemCount),
    );
  }
}
