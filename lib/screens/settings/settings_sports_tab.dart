import 'dart:async';

import 'package:flutter/material.dart';
import 'package:javp/models/sports_models.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/sports_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/javp_text_field.dart';
import 'package:javp/widgets/settings_switch_list_tile.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Followed leagues/teams + optional TheSportsDB API key.
class SportsSettingsTab extends StatefulWidget {
  const SportsSettingsTab({super.key});

  @override
  State<SportsSettingsTab> createState() => _SportsSettingsTabState();
}

class _SportsSettingsTabState extends State<SportsSettingsTab> {
  late final TextEditingController _apiKey;
  late final TextEditingController _teamQuery;
  List<SportsTeamRef> _teamHits = const [];
  bool _searching = false;
  String? _searchError;

  @override
  void initState() {
    super.initState();
    final sports = context.read<SportsProvider>();
    unawaited(sports.bootstrap());
    _apiKey = TextEditingController(text: sports.prefs.apiKey);
    _teamQuery = TextEditingController();
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _teamQuery.dispose();
    super.dispose();
  }

  Future<void> _saveApiKey() async {
    final sports = context.read<SportsProvider>();
    await sports.savePrefs(sports.prefs.copyWith(apiKey: _apiKey.text.trim()));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.sportsApiKeySaved)));
  }

  Future<void> _searchTeams() async {
    final q = _teamQuery.text.trim();
    if (q.length < 2) return;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final hits = await context.read<SportsProvider>().searchTeams(q);
      if (!mounted) return;
      setState(() => _teamHits = hits);
    } catch (e) {
      if (!mounted) return;
      setState(() => _searchError = e.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sports = context.watch<SportsProvider>();
    final followed = sports.prefs.followedLeagueIds;
    final teams = sports.prefs.followedTeams;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Text(
          l10n.sportsSettingsBlurb,
          style: const TextStyle(color: AppColors.textMuted, height: 1.35),
        ),
        const SizedBox(height: 16),
        Text(
          l10n.sportsApiKey,
          style: const TextStyle(
            color: AppColors.text,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        _SportsApiKeyHelpText(text: l10n.sportsApiKeyHelp),
        const SizedBox(height: 8),
        JavpTextField(
          controller: _apiKey,
          obscureText: true,
          decoration: InputDecoration(
            hintText: l10n.sportsApiKeyHint,
            filled: true,
            fillColor: AppColors.surfaceHigh,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(onPressed: _saveApiKey, child: Text(l10n.save)),
        ),
        const SizedBox(height: 24),
        Text(
          l10n.sportsFollowedLeagues,
          style: const TextStyle(
            color: AppColors.text,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        for (final league in kCuratedSoccerLeagues)
          SettingsSwitchListTile(
            title: Text(league.name),
            subtitle: league.country == null ? null : Text(league.country!),
            value: followed.contains(league.id),
            onChanged: (v) => unawaited(sports.toggleLeague(league, v)),
          ),
        const SizedBox(height: 24),
        Text(
          l10n.sportsFollowedTeams,
          style: const TextStyle(
            color: AppColors.text,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        if (teams.isEmpty)
          Text(
            l10n.sportsNoTeamsFollowed,
            style: const TextStyle(color: AppColors.textMuted),
          )
        else
          for (final team in teams)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(team.name),
              trailing: IconButton(
                tooltip: l10n.remove,
                onPressed: () => unawaited(sports.unfollowTeam(team.id)),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
        const SizedBox(height: 12),
        JavpTextField(
          controller: _teamQuery,
          decoration: InputDecoration(
            hintText: l10n.sportsSearchTeamsHint,
            filled: true,
            fillColor: AppColors.surfaceHigh,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            suffixIcon: IconButton(
              onPressed: _searching ? null : _searchTeams,
              icon: _searching
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search_rounded),
            ),
          ),
          onSubmitted: (_) => _searchTeams(),
        ),
        if (_searchError != null) ...[
          const SizedBox(height: 8),
          Text(
            _searchError!,
            style: const TextStyle(color: AppColors.accent, fontSize: 13),
          ),
        ],
        for (final hit in _teamHits)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(hit.name),
            trailing: TextButton(
              onPressed: () => unawaited(sports.followTeam(hit)),
              child: Text(l10n.sportsFollow),
            ),
          ),
      ],
    );
  }
}

/// Help copy with a tappable TheSportsDB site link (same host as the API client).
class _SportsApiKeyHelpText extends StatelessWidget {
  const _SportsApiKeyHelpText({required this.text});

  final String text;

  static const _linkLabel = 'thesportsdb.com';
  static final _siteUri = Uri.https('www.thesportsdb.com', '/');

  Future<void> _openSite() async {
    final launched = await launchUrl(
      _siteUri,
      mode: LaunchMode.externalApplication,
    );
    if (!launched && await canLaunchUrl(_siteUri)) {
      await launchUrl(_siteUri, mode: LaunchMode.platformDefault);
    }
  }

  @override
  Widget build(BuildContext context) {
    const baseStyle = TextStyle(color: AppColors.textMuted, fontSize: 13);
    const linkStyle = TextStyle(
      color: AppColors.accent,
      fontSize: 13,
      decoration: TextDecoration.underline,
      decorationColor: AppColors.accent,
    );

    final idx = text.indexOf(_linkLabel);
    if (idx < 0) {
      return Text(text, style: baseStyle);
    }

    return Text.rich(
      TextSpan(
        style: baseStyle,
        children: [
          if (idx > 0) TextSpan(text: text.substring(0, idx)),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: InkWell(
              onTap: _openSite,
              child: const Text(_linkLabel, style: linkStyle),
            ),
          ),
          if (idx + _linkLabel.length < text.length)
            TextSpan(text: text.substring(idx + _linkLabel.length)),
        ],
      ),
    );
  }
}
