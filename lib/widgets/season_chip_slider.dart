import 'package:flutter/material.dart';
import 'package:javp/models/series_info.dart';

/// Horizontal season chips. Scrolls the selected season into view on open.
class SeasonChipSlider extends StatefulWidget {
  const SeasonChipSlider({
    super.key,
    required this.seasons,
    required this.selectedSeasonNumber,
    required this.onSelected,
  });

  final List<SeriesSeason> seasons;
  final int? selectedSeasonNumber;
  final ValueChanged<int> onSelected;

  @override
  State<SeasonChipSlider> createState() => _SeasonChipSliderState();
}

class _SeasonChipSliderState extends State<SeasonChipSlider> {
  final _scroll = ScrollController();
  final _chipKeys = <int, GlobalKey>{};
  int? _revealedSeason;

  GlobalKey _keyFor(int seasonNumber) =>
      _chipKeys.putIfAbsent(seasonNumber, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    _scheduleReveal();
  }

  @override
  void didUpdateWidget(SeasonChipSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameSeasons(oldWidget.seasons, widget.seasons)) {
      _revealedSeason = null;
    }
    if (_revealedSeason != widget.selectedSeasonNumber) {
      _scheduleReveal();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  static bool _sameSeasons(List<SeriesSeason> a, List<SeriesSeason> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].seasonNumber != b[i].seasonNumber) return false;
    }
    return true;
  }

  void _scheduleReveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_revealSelected()) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _revealSelected();
      });
    });
  }

  bool _revealSelected() {
    final n = widget.selectedSeasonNumber;
    if (n == null) return true;
    final index = widget.seasons.indexWhere((s) => s.seasonNumber == n);
    if (index <= 0) {
      _revealedSeason = n;
      return true;
    }
    final ctx = _chipKeys[n]?.currentContext;
    if (ctx == null) return false;
    _revealedSeason = n;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.4,
      duration: Duration.zero,
      alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Row(
          children: [
            for (var i = 0; i < widget.seasons.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              _chip(widget.seasons[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chip(SeriesSeason season) {
    final selected = season.seasonNumber == widget.selectedSeasonNumber;
    return KeyedSubtree(
      key: _keyFor(season.seasonNumber),
      child: ChoiceChip(
        label: Text(season.name),
        selected: selected,
        onSelected: (_) {
          _revealedSeason = season.seasonNumber;
          widget.onSelected(season.seasonNumber);
        },
        showCheckmark: false,
      ),
    );
  }
}
