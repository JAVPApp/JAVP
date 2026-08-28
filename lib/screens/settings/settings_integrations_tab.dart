import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:flutter/services.dart';
import 'package:javp/models/betaseries_models.dart';
import 'package:javp/models/metadata_settings.dart';
import 'package:javp/models/serializd_models.dart';
import 'package:javp/models/simkl_models.dart';
import 'package:javp/models/tmdb_credentials.dart';
import 'package:javp/models/trakt_models.dart';
import 'package:javp/platform/desktop_bootstrap.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/screens/settings/settings_guide_widgets.dart';
import 'package:javp/services/network/fallback_http_client.dart';
import 'package:javp/services/trackers/tracker_sync_runner.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/device_pin_box.dart';
import 'package:javp/widgets/discord_presence_settings.dart';
import 'package:javp/widgets/plain_text_field.dart';
import 'package:javp/widgets/settings_switch_list_tile.dart';
import 'package:javp/widgets/sync/profile_sync_banner.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

class SettingsIntegrationsTab extends StatelessWidget {
  const SettingsIntegrationsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const _IntegrationsPage();
  }
}

String _statusError(BuildContext context, Object error) {
  return describeCaughtError(
    error,
    proxyHandshakeMessage: context.l10n.proxyHandshakeFailed,
  );
}

class _IntegrationsPage extends StatelessWidget {
  const _IntegrationsPage();

  @override
  Widget build(BuildContext context) {
    // Narrow selects: flipping enrich/scrobble must not rebuild SIMKL/Trakt/TMDB
    // cards (that was a settle-frame hitch on metadata toggles).
    final provider = context.select<LibraryProvider, MetadataProviderId>(
      (l) => l.metadataSettings.provider,
    );
    final tmdbConfigured = context.select<LibraryProvider, bool>(
      (l) => l.tmdb.isConfigured,
    );
    final traktConfigured = context.select<LibraryProvider, bool>(
      (l) => l.trakt.isConfigured,
    );
    final library = context.read<LibraryProvider>();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Text(
          context.l10n.metadata,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.metadataTakeoverHelp,
          style: const TextStyle(color: AppColors.textMuted, height: 1.35),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in _providerOptions(context))
              ChoiceChip(
                label: Text(option.label),
                selected: provider == option.id,
                onSelected: (_) async {
                  await library.saveMetadataSettings(
                    library.metadataSettings.copyWith(provider: option.id),
                  );
                },
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _providerOptions(context).firstWhere((o) => o.id == provider).hint ??
              '',
          style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
        const _EnrichMediaServersSwitch(),
        if (provider == MetadataProviderId.tmdb && !tmdbConfigured) ...[
          const SizedBox(height: 4),
          Text(
            context.l10n.tmdbNeedsApiKey,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.accent),
          ),
        ],
        if (provider == MetadataProviderId.trakt && !traktConfigured) ...[
          const SizedBox(height: 4),
          Text(
            context.l10n.traktNeedsClientId,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.accent),
          ),
        ],
        const SizedBox(height: 20),
        Text(
          context.l10n.settingsIntegrations,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const _SimklIntegrationCard(),
        const SizedBox(height: 10),
        const _TraktIntegrationCard(),
        const SizedBox(height: 10),
        const _BetaseriesIntegrationCard(),
        const SizedBox(height: 10),
        const _SerializdIntegrationCard(),
        const SizedBox(height: 10),
        const _LetterboxdIntegrationCard(),
        const SizedBox(height: 10),
        const _TmdbIntegrationCard(),
        if (isDesktopPlatform) ...[
          const SizedBox(height: 20),
          const DiscordPresenceSettings(),
        ],
      ],
    );
  }
}

class _EnrichMediaServersSwitch extends StatelessWidget {
  const _EnrichMediaServersSwitch();

  @override
  Widget build(BuildContext context) {
    final enrich = context.select<LibraryProvider, bool>(
      (l) => l.metadataSettings.enrichMediaServers,
    );
    return SettingsSwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(context.l10n.alsoEnrichMediaServers),
      subtitle: Text(context.l10n.replaceServerArtwork),
      value: enrich,
      onChanged: (v) {
        final library = context.read<LibraryProvider>();
        library.saveMetadataSettings(
          library.metadataSettings.copyWith(enrichMediaServers: v),
        );
      },
    );
  }
}

class _ProviderOption {
  const _ProviderOption(this.id, this.label, [this.hint]);
  final MetadataProviderId id;
  final String label;
  final String? hint;
}

List<_ProviderOption> _providerOptions(BuildContext context) => [
  _ProviderOption(
    MetadataProviderId.off,
    context.l10n.off,
    context.l10n.useCatalogServerMetadataOnly,
  ),
  _ProviderOption(
    MetadataProviderId.simkl,
    'SIMKL',
    context.l10n.simklMetadataHelp,
  ),
  _ProviderOption(
    MetadataProviderId.trakt,
    'Trakt',
    context.l10n.traktMetadataHelp,
  ),
  _ProviderOption(
    MetadataProviderId.tmdb,
    'TMDB',
    context.l10n.tmdbMetadataHelp,
  ),
];

class _StatusCheck extends StatelessWidget {
  const _StatusCheck({required this.ready, required this.label});

  final bool ready;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          ready ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
          size: 18,
          color: ready ? AppColors.live : AppColors.textMuted,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              color: ready ? AppColors.live : AppColors.textMuted,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }
}

Future<void> _launchExternal(Uri uri) async {
  final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!opened && await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.platformDefault);
  }
}

// —— SIMKL ——

class _SimklIntegrationCard extends StatefulWidget {
  const _SimklIntegrationCard();

  @override
  State<_SimklIntegrationCard> createState() => _SimklIntegrationCardState();
}

class _SimklIntegrationCardState extends State<_SimklIntegrationCard> {
  late final TextEditingController _clientId;
  late final TextEditingController _token;
  bool _pinBusy = false;
  bool _pinCancelled = false;
  String? _pinCode;
  Uri? _pinVerificationUri;
  String? _status;

  @override
  void initState() {
    super.initState();
    final simkl = context.read<LibraryProvider>().simkl;
    _clientId = TextEditingController(text: simkl.clientId);
    _token = TextEditingController(text: simkl.accessToken ?? '');
  }

  @override
  void dispose() {
    _pinCancelled = true;
    _clientId.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect(LibraryProvider library) async {
    final clientId = _clientId.text.trim();
    setState(() {
      _pinBusy = true;
      _pinCancelled = false;
      _pinCode = null;
      _pinVerificationUri = null;
      _status = context.l10n.requestingPin;
    });
    try {
      final session = await library.requestSimklPin(clientId);
      if (!mounted || _pinCancelled) return;
      setState(() {
        _pinCode = session.userCode;
        _pinVerificationUri = session.scanUri;
        _status = context.l10n.enterPinOnSimkl;
      });
      final token = await library.waitForSimklPinToken(
        clientId: clientId,
        session: session,
        isCancelled: () => _pinCancelled || !mounted,
      );
      if (!mounted || _pinCancelled) return;
      _token.text = token;
      await library.saveSimklCredentials(
        SimklCredentials(clientId: clientId, accessToken: token),
      );
      setState(() {
        _pinBusy = false;
        _pinCode = null;
        _pinVerificationUri = null;
        _status = context.l10n.connected;
      });
    } catch (e) {
      if (!mounted) return;
      final message = _statusError(context, e);
      setState(() {
        _pinBusy = false;
        _status = message.contains('cancelled')
            ? context.l10n.pinCancelled
            : message;
      });
    }
  }

  Future<void> _disconnect(LibraryProvider library) async {
    _token.clear();
    await library.saveSimklCredentials(
      SimklCredentials(clientId: _clientId.text.trim()),
    );
    setState(() => _status = context.l10n.disconnected);
  }

  @override
  Widget build(BuildContext context) {
    final linked = context.select<LibraryProvider, bool>(
      (l) => l.simkl.isAuthenticated,
    );
    final scrobbleEnabled = context.select<LibraryProvider, bool>(
      (l) => l.metadataSettings.simklScrobbleEnabled,
    );
    final isSimklSyncing = context.select<LibraryProvider, bool>(
      (l) => l.isSimklSyncing,
    );
    final simklSyncPhase = context.select<LibraryProvider, TrackerSyncPhase?>(
      (l) => l.isSimklSyncing ? l.trackerSyncPhase : null,
    );
    final library = context.read<LibraryProvider>();

    return Card(
      color: AppColors.surfaceHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'SIMKL',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        context.l10n.simklMetadataSyncBlurb,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusCheck(
                  ready: linked,
                  label: linked ? context.l10n.linked : context.l10n.notSet,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!linked)
                  FilledButton(
                    onPressed: _pinBusy ? null : () => _connect(library),
                    child: Text(
                      _pinBusy ? context.l10n.waiting : context.l10n.connect,
                    ),
                  ),
                if (linked)
                  OutlinedButton(
                    onPressed: _pinBusy ? null : () => _disconnect(library),
                    child: Text(context.l10n.disconnect),
                  ),
                if (linked)
                  FilledButton.tonal(
                    onPressed: isSimklSyncing
                        ? null
                        : () async {
                            setState(() => _status = context.l10n.syncing);
                            await library.syncSimklActivity(force: true);
                            if (!mounted) return;
                            final watching = library.simklWatching.length;
                            final plan = library.simklPlanToWatch.length;
                            setState(() {
                              if (watching == 0 && plan == 0) {
                                _status = context.l10n.syncedEmptyWatching;
                              } else {
                                _status = context.l10n.syncedNWatching(
                                  '${watching + plan}',
                                );
                              }
                            });
                          },
                    child: Text(
                      isSimklSyncing
                          ? trackerSyncPhaseLabel(context.l10n, simklSyncPhase)
                          : context.l10n.syncNow,
                    ),
                  ),
                if (_pinBusy)
                  OutlinedButton(
                    onPressed: () => setState(() {
                      _pinCancelled = true;
                      _pinBusy = false;
                      _status = context.l10n.pinCancelled;
                    }),
                    child: Text(context.l10n.cancel),
                  ),
              ],
            ),
            if (linked) ...[
              const SizedBox(height: 4),
              SettingsSwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.simklScrobbleToggle),
                subtitle: Text(context.l10n.simklScrobbleToggleSubtitle),
                value: scrobbleEnabled,
                onChanged: (v) {
                  library.saveMetadataSettings(
                    library.metadataSettings.copyWith(simklScrobbleEnabled: v),
                  );
                },
              ),
            ],
            if (_pinCode != null) ...[
              const SizedBox(height: 12),
              DevicePinBox(
                code: _pinCode!,
                scanUri:
                    _pinVerificationUri ?? Uri.parse('https://simkl.com/pin'),
                onCopy: () async {
                  await Clipboard.setData(ClipboardData(text: _pinCode!));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l10n.pinCopied)),
                  );
                },
                onOpen: () => _launchExternal(
                  _pinVerificationUri ?? Uri.parse('https://simkl.com/pin'),
                ),
              ),
            ],
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(_status!, style: TextStyle(color: AppColors.textMuted)),
            ],
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(context.l10n.developer),
              children: [
                GuideStep(number: 1, text: context.l10n.optionalCreateSimklApp),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OpenLinkButton(
                    label: context.l10n.simklDeveloperSettings,
                    url: 'https://simkl.com/settings/developer/',
                  ),
                ),
                const SizedBox(height: 8),
                PlainTextField(
                  controller: _clientId,
                  enabled: !_pinBusy,
                  decoration: InputDecoration(
                    labelText: context.l10n.clientIdOverride,
                    hintText: library.simkl.usesBundledClientId
                        ? context.l10n.usingJavpDefault
                        : null,
                    helperText: context.l10n.leaveBlankBuiltInClientId,
                  ),
                ),
                const SizedBox(height: 8),
                PlainTextField(
                  controller: _token,
                  obscureText: true,
                  enabled: !_pinBusy,
                  decoration: InputDecoration(
                    labelText: context.l10n.accessToken,
                    hintText: context.l10n.filledByConnectOrPaste,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonal(
                    onPressed: _pinBusy
                        ? null
                        : () async {
                            await library.saveSimklCredentials(
                              SimklCredentials(
                                clientId: _clientId.text.trim(),
                                accessToken: _token.text.trim().isEmpty
                                    ? null
                                    : _token.text.trim(),
                              ),
                            );
                            setState(() => _status = context.l10n.saved);
                          },
                    child: Text(context.l10n.saveOverrides),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// —— Trakt ——

class _TraktIntegrationCard extends StatefulWidget {
  const _TraktIntegrationCard();

  @override
  State<_TraktIntegrationCard> createState() => _TraktIntegrationCardState();
}

class _TraktIntegrationCardState extends State<_TraktIntegrationCard> {
  late final TextEditingController _clientId;
  late final TextEditingController _clientSecret;
  late final TextEditingController _token;
  bool _pinBusy = false;
  bool _pinCancelled = false;
  String? _pinCode;
  Uri? _pinVerificationUri;
  String? _status;

  @override
  void initState() {
    super.initState();
    final trakt = context.read<LibraryProvider>().trakt;
    _clientId = TextEditingController(text: trakt.clientId);
    _clientSecret = TextEditingController(text: trakt.clientSecret);
    _token = TextEditingController(text: trakt.accessToken ?? '');
  }

  @override
  void dispose() {
    _pinCancelled = true;
    _clientId.dispose();
    _clientSecret.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _persistDraft(LibraryProvider library) async {
    await library.saveTraktCredentials(
      TraktCredentials(
        clientId: _clientId.text.trim(),
        clientSecret: _clientSecret.text.trim(),
        accessToken: library.trakt.accessToken,
        refreshToken: library.trakt.refreshToken,
        expiresAt: library.trakt.expiresAt,
      ),
    );
  }

  Future<void> _connect(LibraryProvider library) async {
    await _persistDraft(library);
    setState(() {
      _pinBusy = true;
      _pinCancelled = false;
      _pinCode = null;
      _pinVerificationUri = null;
      _status = context.l10n.requestingDeviceCode;
    });
    try {
      final session = await library.requestTraktDeviceCode();
      if (!mounted || _pinCancelled) return;
      setState(() {
        _pinCode = session.userCode;
        _pinVerificationUri = session.scanUri;
        _status = context.l10n.enterCodeOnTrakt;
      });
      final token = await library.waitForTraktDeviceToken(
        session: session,
        isCancelled: () => _pinCancelled || !mounted,
      );
      if (!mounted || _pinCancelled) return;
      _token.text = token.accessToken;
      final expiresAt = token.expiresIn == null
          ? null
          : DateTime.now().add(Duration(seconds: token.expiresIn!));
      await library.saveTraktCredentials(
        TraktCredentials(
          clientId: _clientId.text.trim(),
          clientSecret: _clientSecret.text.trim(),
          accessToken: token.accessToken,
          refreshToken: token.refreshToken,
          expiresAt: expiresAt,
        ),
      );
      setState(() {
        _pinBusy = false;
        _pinCode = null;
        _pinVerificationUri = null;
        _status = context.l10n.connected;
      });
    } catch (e) {
      if (!mounted) return;
      final message = _statusError(context, e);
      setState(() {
        _pinBusy = false;
        _status = message.contains('cancelled')
            ? context.l10n.cancelled
            : message;
      });
    }
  }

  Future<void> _disconnect(LibraryProvider library) async {
    _token.clear();
    await library.saveTraktCredentials(
      TraktCredentials(
        clientId: _clientId.text.trim(),
        clientSecret: _clientSecret.text.trim(),
      ),
    );
    setState(() => _status = context.l10n.disconnected);
  }

  @override
  Widget build(BuildContext context) {
    final linked = context.select<LibraryProvider, bool>(
      (l) => l.trakt.isAuthenticated,
    );
    final ready = context.select<LibraryProvider, bool>(
      (l) => l.trakt.isConfigured,
    );
    final isTraktSyncing = context.select<LibraryProvider, bool>(
      (l) => l.isTraktSyncing,
    );
    final traktSyncPhase = context.select<LibraryProvider, TrackerSyncPhase?>(
      (l) => l.isTraktSyncing ? l.trackerSyncPhase : null,
    );
    final library = context.read<LibraryProvider>();

    return Card(
      color: AppColors.surfaceHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Trakt',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        context.l10n.traktMetadataOptionalBlurb,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusCheck(
                  ready: ready,
                  label: linked
                      ? context.l10n.linked
                      : ready
                      ? context.l10n.appKey
                      : context.l10n.notSet,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!linked)
                  FilledButton(
                    onPressed: _pinBusy ? null : () => _connect(library),
                    child: Text(
                      _pinBusy ? context.l10n.waiting : context.l10n.connect,
                    ),
                  ),
                if (linked)
                  OutlinedButton(
                    onPressed: _pinBusy ? null : () => _disconnect(library),
                    child: Text(context.l10n.disconnect),
                  ),
                if (linked)
                  FilledButton.tonal(
                    onPressed: isTraktSyncing
                        ? null
                        : () async {
                            setState(() => _status = context.l10n.syncing);
                            await library.syncTraktWatchlist(force: true);
                            if (!mounted) return;
                            final count = library.traktWatchlist.length;
                            setState(() {
                              _status = count == 0
                                  ? context.l10n.syncedEmptyWatching
                                  : context.l10n.syncedNWatching('$count');
                            });
                          },
                    child: Text(
                      isTraktSyncing
                          ? trackerSyncPhaseLabel(context.l10n, traktSyncPhase)
                          : context.l10n.syncNow,
                    ),
                  ),
                if (_pinBusy)
                  OutlinedButton(
                    onPressed: () => setState(() {
                      _pinCancelled = true;
                      _pinBusy = false;
                      _status = context.l10n.cancelled;
                    }),
                    child: Text(context.l10n.cancel),
                  ),
              ],
            ),
            if (_pinCode != null) ...[
              const SizedBox(height: 12),
              DevicePinBox(
                code: _pinCode!,
                scanUri:
                    _pinVerificationUri ??
                    Uri.parse('https://trakt.tv/activate'),
                onCopy: () async {
                  await Clipboard.setData(ClipboardData(text: _pinCode!));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l10n.codeCopied)),
                  );
                },
                onOpen: () => _launchExternal(
                  _pinVerificationUri ?? Uri.parse('https://trakt.tv/activate'),
                ),
              ),
            ],
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(_status!, style: TextStyle(color: AppColors.textMuted)),
            ],
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(context.l10n.developer),
              children: [
                Text(
                  context.l10n.registerTraktApiApp,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OpenLinkButton(
                    label: context.l10n.traktApiApplications,
                    url: 'https://trakt.tv/oauth/applications',
                  ),
                ),
                const SizedBox(height: 8),
                PlainTextField(
                  controller: _clientId,
                  enabled: !_pinBusy,
                  decoration: InputDecoration(
                    labelText: context.l10n.clientId,
                    hintText: TraktCredentials.bundledClientId.isEmpty
                        ? context.l10n.requiredForEnrichment
                        : context.l10n.usingBuildTimeDefault,
                  ),
                ),
                const SizedBox(height: 8),
                PlainTextField(
                  controller: _clientSecret,
                  obscureText: true,
                  enabled: !_pinBusy,
                  decoration: InputDecoration(
                    labelText: context.l10n.clientSecret,
                    helperText: context.l10n.neededOnlyForConnectLogin,
                  ),
                ),
                const SizedBox(height: 8),
                PlainTextField(
                  controller: _token,
                  obscureText: true,
                  enabled: !_pinBusy,
                  decoration: InputDecoration(
                    labelText: context.l10n.accessToken,
                    hintText: context.l10n.filledByConnectOrPaste,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonal(
                    onPressed: _pinBusy
                        ? null
                        : () async {
                            await library.saveTraktCredentials(
                              TraktCredentials(
                                clientId: _clientId.text.trim(),
                                clientSecret: _clientSecret.text.trim(),
                                accessToken: _token.text.trim().isEmpty
                                    ? null
                                    : _token.text.trim(),
                                refreshToken: library.trakt.refreshToken,
                                expiresAt: library.trakt.expiresAt,
                              ),
                            );
                            setState(() => _status = context.l10n.saved);
                          },
                    child: Text(context.l10n.saveOverrides),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// —— Serializd (TV tracker; unofficial email/token API — no OAuth/PIN) ——

class _SerializdIntegrationCard extends StatefulWidget {
  const _SerializdIntegrationCard();

  @override
  State<_SerializdIntegrationCard> createState() =>
      _SerializdIntegrationCardState();
}

class _SerializdIntegrationCardState extends State<_SerializdIntegrationCard> {
  late final TextEditingController _email;
  late final TextEditingController _password;
  late final TextEditingController _token;
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    final serializd = context.read<LibraryProvider>().serializd;
    _email = TextEditingController();
    _password = TextEditingController();
    _token = TextEditingController(text: serializd.accessToken ?? '');
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect(LibraryProvider library) async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _status = context.l10n.serializdNeedEmailPassword);
      return;
    }
    setState(() {
      _busy = true;
      _status = context.l10n.signingIn;
    });
    try {
      final creds = await library.loginSerializd(
        email: email,
        password: password,
      );
      if (!mounted) return;
      _password.clear();
      _token.text = creds.accessToken ?? '';
      setState(() {
        _busy = false;
        _status = context.l10n.connected;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = _statusError(context, e);
      });
    }
  }

  Future<void> _disconnect(LibraryProvider library) async {
    _token.clear();
    _password.clear();
    await library.saveSerializdCredentials(const SerializdCredentials());
    setState(() => _status = context.l10n.disconnected);
  }

  @override
  Widget build(BuildContext context) {
    final linked = context.select<LibraryProvider, bool>(
      (l) => l.serializd.isAuthenticated,
    );
    final username = context.select<LibraryProvider, String?>(
      (l) => l.serializd.username,
    );
    final scrobbleEnabled = context.select<LibraryProvider, bool>(
      (l) => l.metadataSettings.serializdScrobbleEnabled,
    );
    final isSyncing = context.select<LibraryProvider, bool>(
      (l) => l.isSerializdSyncing,
    );
    final syncPhase = context.select<LibraryProvider, TrackerSyncPhase?>(
      (l) => l.isSerializdSyncing ? l.trackerSyncPhase : null,
    );
    final library = context.read<LibraryProvider>();

    return Card(
      color: AppColors.surfaceHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Serializd',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        context.l10n.serializdSyncBlurb,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 13,
                        ),
                      ),
                      if (linked &&
                          username != null &&
                          username.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          '@$username',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                _StatusCheck(
                  ready: linked,
                  label: linked ? context.l10n.linked : context.l10n.notSet,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (!linked) ...[
              PlainTextField(
                controller: _email,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: context.l10n.serializdEmail,
                ),
              ),
              const SizedBox(height: 8),
              PlainTextField(
                controller: _password,
                obscureText: true,
                enabled: !_busy,
                decoration: InputDecoration(labelText: context.l10n.password),
              ),
              const SizedBox(height: 12),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!linked)
                  FilledButton(
                    onPressed: _busy ? null : () => _connect(library),
                    child: Text(
                      _busy ? context.l10n.waiting : context.l10n.connect,
                    ),
                  ),
                if (linked)
                  OutlinedButton(
                    onPressed: _busy ? null : () => _disconnect(library),
                    child: Text(context.l10n.disconnect),
                  ),
                if (linked)
                  FilledButton.tonal(
                    onPressed: isSyncing
                        ? null
                        : () async {
                            setState(() => _status = context.l10n.syncing);
                            await library.syncSerializdActivity(force: true);
                            if (!mounted) return;
                            final n =
                                library.serializdWatching.length +
                                library.serializdWatchlist.length;
                            setState(() {
                              _status = n == 0
                                  ? context.l10n.syncedEmptyWatching
                                  : context.l10n.syncedNWatching('$n');
                            });
                          },
                    child: Text(
                      isSyncing
                          ? trackerSyncPhaseLabel(context.l10n, syncPhase)
                          : context.l10n.syncNow,
                    ),
                  ),
              ],
            ),
            if (linked) ...[
              const SizedBox(height: 4),
              SettingsSwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.serializdScrobbleToggle),
                subtitle: Text(context.l10n.serializdScrobbleToggleSubtitle),
                value: scrobbleEnabled,
                onChanged: (v) {
                  library.saveMetadataSettings(
                    library.metadataSettings.copyWith(
                      serializdScrobbleEnabled: v,
                    ),
                  );
                },
              ),
            ],
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(_status!, style: TextStyle(color: AppColors.textMuted)),
            ],
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(context.l10n.developer),
              children: [
                GuideStep(
                  number: 1,
                  text: context.l10n.serializdUnofficialApiHelp,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OpenLinkButton(
                    label: 'serializd.com',
                    url: 'https://www.serializd.com/',
                  ),
                ),
                const SizedBox(height: 8),
                PlainTextField(
                  controller: _token,
                  obscureText: true,
                  enabled: !_busy,
                  decoration: InputDecoration(
                    labelText: context.l10n.accessToken,
                    hintText: context.l10n.filledByConnectOrPaste,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonal(
                    onPressed: _busy
                        ? null
                        : () async {
                            await library.saveSerializdCredentials(
                              SerializdCredentials(
                                accessToken: _token.text.trim().isEmpty
                                    ? null
                                    : _token.text.trim(),
                                username: library.serializd.username,
                              ),
                            );
                            setState(() => _status = context.l10n.saved);
                          },
                    child: Text(context.l10n.saveOverrides),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// —— BetaSeries ——

class _BetaseriesIntegrationCard extends StatefulWidget {
  const _BetaseriesIntegrationCard();

  @override
  State<_BetaseriesIntegrationCard> createState() =>
      _BetaseriesIntegrationCardState();
}

class _BetaseriesIntegrationCardState
    extends State<_BetaseriesIntegrationCard> {
  late final TextEditingController _apiKey;
  late final TextEditingController _apiSecret;
  late final TextEditingController _token;
  bool _pinBusy = false;
  bool _pinCancelled = false;
  String? _pinCode;
  Uri? _pinVerificationUri;
  String? _status;

  @override
  void initState() {
    super.initState();
    final betaseries = context.read<LibraryProvider>().betaseries;
    _apiKey = TextEditingController(text: betaseries.apiKey);
    _apiSecret = TextEditingController(text: betaseries.apiSecret);
    _token = TextEditingController(text: betaseries.accessToken ?? '');
  }

  @override
  void dispose() {
    _pinCancelled = true;
    _apiKey.dispose();
    _apiSecret.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _persistDraft(LibraryProvider library) async {
    await library.saveBetaseriesCredentials(
      BetaseriesCredentials(
        apiKey: _apiKey.text.trim(),
        apiSecret: _apiSecret.text.trim(),
        accessToken: library.betaseries.accessToken,
        login: library.betaseries.login,
      ),
    );
  }

  Future<void> _connect(LibraryProvider library) async {
    await _persistDraft(library);
    setState(() {
      _pinBusy = true;
      _pinCancelled = false;
      _pinCode = null;
      _pinVerificationUri = null;
      _status = context.l10n.requestingDeviceCode;
    });
    try {
      final session = await library.requestBetaseriesDeviceCode();
      if (!mounted || _pinCancelled) return;
      setState(() {
        _pinCode = session.userCode;
        _pinVerificationUri = session.scanUri;
        _status = context.l10n.enterCodeOnBetaseries;
      });
      final token = await library.waitForBetaseriesDeviceToken(
        session: session,
        isCancelled: () => _pinCancelled || !mounted,
      );
      if (!mounted || _pinCancelled) return;
      _token.text = token.accessToken;
      await library.saveBetaseriesCredentials(
        BetaseriesCredentials(
          apiKey: _apiKey.text.trim(),
          apiSecret: _apiSecret.text.trim(),
          accessToken: token.accessToken,
          login: token.login,
        ),
      );
      setState(() {
        _pinBusy = false;
        _pinCode = null;
        _pinVerificationUri = null;
        _status = context.l10n.connected;
      });
    } catch (e) {
      if (!mounted) return;
      final message = _statusError(context, e);
      setState(() {
        _pinBusy = false;
        _status = message.contains('cancelled')
            ? context.l10n.cancelled
            : message;
      });
    }
  }

  Future<void> _disconnect(LibraryProvider library) async {
    _token.clear();
    await library.saveBetaseriesCredentials(
      BetaseriesCredentials(
        apiKey: _apiKey.text.trim(),
        apiSecret: _apiSecret.text.trim(),
      ),
    );
    setState(() => _status = context.l10n.disconnected);
  }

  @override
  Widget build(BuildContext context) {
    final linked = context.select<LibraryProvider, bool>(
      (l) => l.betaseries.isAuthenticated,
    );
    final ready = context.select<LibraryProvider, bool>(
      (l) => l.betaseries.isConfigured,
    );
    final isBetaseriesSyncing = context.select<LibraryProvider, bool>(
      (l) => l.isBetaseriesSyncing,
    );
    final betaseriesSyncPhase = context
        .select<LibraryProvider, TrackerSyncPhase?>(
          (l) => l.isBetaseriesSyncing ? l.trackerSyncPhase : null,
        );
    final library = context.read<LibraryProvider>();

    return Card(
      color: AppColors.surfaceHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'BetaSeries',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        context.l10n.betaseriesMetadataOptionalBlurb,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusCheck(
                  ready: ready,
                  label: linked
                      ? context.l10n.linked
                      : ready
                      ? context.l10n.appKey
                      : context.l10n.notSet,
                ),
              ],
            ),
            if (!ready) ...[
              const SizedBox(height: 8),
              Text(
                context.l10n.betaseriesNeedsApiKey,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.accent),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!linked)
                  FilledButton(
                    onPressed: _pinBusy || !ready
                        ? null
                        : () => _connect(library),
                    child: Text(
                      _pinBusy ? context.l10n.waiting : context.l10n.connect,
                    ),
                  ),
                if (linked)
                  OutlinedButton(
                    onPressed: _pinBusy ? null : () => _disconnect(library),
                    child: Text(context.l10n.disconnect),
                  ),
                if (linked)
                  FilledButton.tonal(
                    onPressed: isBetaseriesSyncing
                        ? null
                        : () async {
                            setState(() => _status = context.l10n.syncing);
                            await library.syncBetaseriesLists(force: true);
                            if (!mounted) return;
                            final count =
                                library.betaseriesWatching.length +
                                library.betaseriesPlan.length;
                            setState(() {
                              _status = count == 0
                                  ? context.l10n.syncedEmptyWatching
                                  : context.l10n.syncedNWatching('$count');
                            });
                          },
                    child: Text(
                      isBetaseriesSyncing
                          ? trackerSyncPhaseLabel(
                              context.l10n,
                              betaseriesSyncPhase,
                            )
                          : context.l10n.syncNow,
                    ),
                  ),
                if (_pinBusy)
                  OutlinedButton(
                    onPressed: () => setState(() {
                      _pinCancelled = true;
                      _pinBusy = false;
                      _status = context.l10n.cancelled;
                    }),
                    child: Text(context.l10n.cancel),
                  ),
              ],
            ),
            if (_pinCode != null) ...[
              const SizedBox(height: 12),
              DevicePinBox(
                code: _pinCode!,
                scanUri:
                    _pinVerificationUri ??
                    Uri.parse('https://www.betaseries.com/device'),
                onCopy: () async {
                  await Clipboard.setData(ClipboardData(text: _pinCode!));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l10n.codeCopied)),
                  );
                },
                onOpen: () => _launchExternal(
                  _pinVerificationUri ??
                      Uri.parse('https://www.betaseries.com/device'),
                ),
              ),
            ],
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(_status!, style: TextStyle(color: AppColors.textMuted)),
            ],
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(context.l10n.developer),
              children: [
                Text(
                  context.l10n.registerBetaseriesApiKey,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OpenLinkButton(
                    label: context.l10n.betaseriesApiKeys,
                    url: 'https://www.betaseries.com/api/',
                  ),
                ),
                const SizedBox(height: 8),
                PlainTextField(
                  controller: _apiKey,
                  enabled: !_pinBusy,
                  decoration: InputDecoration(
                    labelText: 'API key',
                    hintText: BetaseriesCredentials.bundledApiKey.isEmpty
                        ? context.l10n.requiredForEnrichment
                        : context.l10n.usingBuildTimeDefault,
                  ),
                ),
                const SizedBox(height: 8),
                PlainTextField(
                  controller: _apiSecret,
                  obscureText: true,
                  enabled: !_pinBusy,
                  decoration: InputDecoration(
                    labelText: context.l10n.clientSecret,
                    helperText: context.l10n.neededOnlyForConnectLogin,
                  ),
                ),
                const SizedBox(height: 8),
                PlainTextField(
                  controller: _token,
                  obscureText: true,
                  enabled: !_pinBusy,
                  decoration: InputDecoration(
                    labelText: context.l10n.accessToken,
                    hintText: context.l10n.filledByConnectOrPaste,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonal(
                    onPressed: _pinBusy
                        ? null
                        : () async {
                            await library.saveBetaseriesCredentials(
                              BetaseriesCredentials(
                                apiKey: _apiKey.text.trim(),
                                apiSecret: _apiSecret.text.trim(),
                                accessToken: _token.text.trim().isEmpty
                                    ? null
                                    : _token.text.trim(),
                                login: library.betaseries.login,
                              ),
                            );
                            setState(() => _status = context.l10n.saved);
                          },
                    child: Text(context.l10n.saveOverrides),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// —— Letterboxd (movies; official export import — API is partner-gated) ——

class _LetterboxdIntegrationCard extends StatefulWidget {
  const _LetterboxdIntegrationCard();

  @override
  State<_LetterboxdIntegrationCard> createState() =>
      _LetterboxdIntegrationCardState();
}

class _LetterboxdIntegrationCardState
    extends State<_LetterboxdIntegrationCard> {
  String? _status;

  @override
  Widget build(BuildContext context) {
    final hasImport = context.select<LibraryProvider, bool>(
      (l) => l.hasLetterboxdImport,
    );
    final importing = context.select<LibraryProvider, bool>(
      (l) => l.isLetterboxdImporting,
    );
    final watchlistCount = context.select<LibraryProvider, int>(
      (l) => l.letterboxdWatchlist.length,
    );
    final library = context.read<LibraryProvider>();

    return Card(
      color: AppColors.surfaceHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Letterboxd',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        context.l10n.letterboxdMoviesOnlyBlurb,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusCheck(
                  ready: hasImport,
                  label: hasImport
                      ? context.l10n.imported
                      : context.l10n.notImported,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.letterboxdApiLockedHelp,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 13,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: importing
                      ? null
                      : () async {
                          setState(() => _status = context.l10n.importing);
                          final result = await library.importLetterboxdExport();
                          if (!mounted) return;
                          if (result.cancelled) {
                            setState(() => _status = context.l10n.cancelled);
                            return;
                          }
                          if (!result.ok) {
                            setState(() {
                              _status = context.l10n.letterboxdImportFailed;
                            });
                            return;
                          }
                          setState(() {
                            _status = context.l10n.letterboxdImportSummary(
                              '${result.watchlistCount}',
                              '${result.completedCount}',
                            );
                          });
                        },
                  child: Text(
                    importing
                        ? context.l10n.importing
                        : context.l10n.importExportZipCsv,
                  ),
                ),
                if (hasImport)
                  OutlinedButton(
                    onPressed: importing
                        ? null
                        : () async {
                            await library.clearLetterboxdImport();
                            if (!mounted) return;
                            setState(
                              () => _status = context.l10n.letterboxdCleared,
                            );
                          },
                    child: Text(context.l10n.clearImport),
                  ),
                OpenLinkButton(
                  label: context.l10n.letterboxdExportYourData,
                  url: 'https://letterboxd.com/user/exportdata/',
                ),
                OpenLinkButton(
                  label: context.l10n.letterboxdApiAccess,
                  url: 'https://letterboxd.com/api-beta/',
                ),
              ],
            ),
            if (hasImport) ...[
              const SizedBox(height: 8),
              Text(
                context.l10n.letterboxdWatchlistCount('$watchlistCount'),
                style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
            ],
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(_status!, style: TextStyle(color: AppColors.textMuted)),
            ],
          ],
        ),
      ),
    );
  }
}

// —— TMDB ——

Future<void> _showTmdbHelp(BuildContext context) {
  final l10n = context.l10n;
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(l10n.tmdbHelpTitle),
      content: Text(
        l10n.tmdbHelpBody,
        style: const TextStyle(color: AppColors.textMuted, height: 1.4),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.close),
        ),
      ],
    ),
  );
}

class _TmdbIntegrationCard extends StatefulWidget {
  const _TmdbIntegrationCard();

  @override
  State<_TmdbIntegrationCard> createState() => _TmdbIntegrationCardState();
}

class _TmdbIntegrationCardState extends State<_TmdbIntegrationCard> {
  late final TextEditingController _key;
  bool _testing = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController(
      text: context.read<LibraryProvider>().tmdb.apiKey,
    );
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = context.select<LibraryProvider, bool>(
      (l) => l.tmdb.isConfigured,
    );
    final library = context.read<LibraryProvider>();

    return Card(
      color: AppColors.surfaceHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'TMDB',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          IconButton(
                            tooltip: context.l10n.tmdbHelpTitle,
                            onPressed: () => _showTmdbHelp(context),
                            icon: const Icon(
                              Icons.help_outline_rounded,
                              size: 20,
                            ),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        context.l10n.tmdbByoKeyBlurb,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusCheck(
                  ready: ready,
                  label: ready ? context.l10n.apiKeySet : context.l10n.notSet,
                ),
              ],
            ),
            const SizedBox(height: 12),
            PlainTextField(
              controller: _key,
              obscureText: true,
              decoration: InputDecoration(labelText: context.l10n.apiKeyV3),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: () async {
                    await library.saveTmdbCredentials(
                      TmdbCredentials(apiKey: _key.text.trim()),
                    );
                    setState(() => _status = context.l10n.saved);
                  },
                  child: Text(context.l10n.save),
                ),
                OutlinedButton(
                  onPressed: _testing
                      ? null
                      : () async {
                          setState(() {
                            _testing = true;
                            _status = null;
                          });
                          await library.saveTmdbCredentials(
                            TmdbCredentials(apiKey: _key.text.trim()),
                          );
                          try {
                            final ok = await library.testTmdb();
                            if (!mounted) return;
                            setState(() {
                              _testing = false;
                              _status = ok
                                  ? context.l10n.connectionOk
                                  : context.l10n.couldNotValidateKey;
                            });
                          } catch (e) {
                            if (!mounted) return;
                            setState(() {
                              _testing = false;
                              _status =
                                  '${context.l10n.couldNotValidateKey}: ${_statusError(context, e)}';
                            });
                          }
                        },
                  child: Text(
                    _testing ? context.l10n.testEllipsis : context.l10n.test,
                  ),
                ),
              ],
            ),
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(_status!, style: TextStyle(color: AppColors.textMuted)),
            ],
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(context.l10n.developer),
              children: [
                Text(
                  context.l10n.tmdbDisclaimer,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textMuted,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                GuideStep(number: 1, text: context.l10n.createFreeTmdbAccount),
                GuideStep(
                  number: 2,
                  text: context.l10n.openApiSettingsRequestKey,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OpenLinkButton(
                    label: context.l10n.openTmdbApiSettings,
                    url: 'https://www.themoviedb.org/settings/api',
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
