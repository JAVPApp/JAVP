import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/sports_provider.dart';
import 'package:javp/services/live_watch_nav.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:provider/provider.dart';

/// Daily football fixtures matched to the user's live channels (BYO, no streams).
class SportsScreen extends StatefulWidget {
  const SportsScreen({super.key});

  @override
  State<SportsScreen> createState() => _SportsScreenState();
}

class _SportsScreenState extends State<SportsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        context.read<SportsProvider>().refreshToday(
          context.read<LibraryProvider>(),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sports = context.watch<SportsProvider>();
    final rows = sports.todayFixtures;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text(l10n.sportsTitle),
        actions: [
          IconButton(
            tooltip: l10n.sportsSettings,
            onPressed: () => context.push('/settings/sports'),
            icon: const Icon(Icons.tune_rounded),
          ),
          IconButton(
            tooltip: l10n.retry,
            onPressed: sports.loading
                ? null
                : () => unawaited(
                    sports.refreshToday(
                      context.read<LibraryProvider>(),
                      force: true,
                    ),
                  ),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () =>
            sports.refreshToday(context.read<LibraryProvider>(), force: true),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text(
              l10n.sportsBlurb,
              style: const TextStyle(color: AppColors.textMuted, height: 1.35),
            ),
            const SizedBox(height: 12),
            if (!sports.hasFollows)
              Card(
                color: AppColors.surface,
                child: ListTile(
                  leading: const Icon(Icons.sports_soccer_rounded),
                  title: Text(l10n.sportsFollowPrompt),
                  subtitle: Text(l10n.sportsFollowPromptSubtitle),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.push('/settings/sports'),
                ),
              ),
            if (sports.loading && rows.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (sports.error != null && rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  l10n.sportsLoadFailed(sports.error!),
                  style: const TextStyle(color: AppColors.accent),
                ),
              )
            else if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  l10n.sportsEmptyDay,
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              )
            else
              for (final row in rows) _FixtureTile(row: row),
          ],
        ),
      ),
    );
  }
}

class _FixtureTile extends StatelessWidget {
  const _FixtureTile({required this.row});

  final MatchedSportsFixture row;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final fixture = row.fixture;
    final match = row.match;
    final time =
        '${fixture.kickoff.hour.toString().padLeft(2, '0')}:'
        '${fixture.kickoff.minute.toString().padLeft(2, '0')}';
    final score = (fixture.homeScore != null && fixture.awayScore != null)
        ? '${fixture.homeScore}–${fixture.awayScore}'
        : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                fixture.leagueName,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                fixture.title,
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                [
                  time,
                  if (score != null) score,
                  if (fixture.status != null && fixture.status!.isNotEmpty)
                    fixture.status!,
                ].join(' · '),
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 10),
              if (match != null)
                FilledButton.tonalIcon(
                  onPressed: () =>
                      unawaited(openLivePlayback(context, match.channel)),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(
                    l10n.sportsWatchOnChannel(
                      context
                          .read<LibraryProvider>()
                          .officialLiveTitle(match.channel),
                    ),
                  ),
                )
              else
                Text(
                  l10n.sportsNoChannelMatch,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 13,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
