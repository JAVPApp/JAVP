import 'package:flutter/material.dart';
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/models/proxy_preset.dart';
import 'package:javp/models/proxy_settings.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/screens/settings/settings_guide_widgets.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/javp_text_field.dart';
import 'package:javp/widgets/plain_text_field.dart';
import 'package:javp/widgets/settings_switch_list_tile.dart';
import 'package:provider/provider.dart';

class SettingsNetworkTab extends StatefulWidget {
  const SettingsNetworkTab({super.key});

  @override
  State<SettingsNetworkTab> createState() => _SettingsNetworkTabState();
}

class _SettingsNetworkTabState extends State<SettingsNetworkTab> {
  late final TextEditingController _proxyHost;
  late final TextEditingController _proxyPort;
  late final TextEditingController _proxyUser;
  late final TextEditingController _proxyPass;
  bool _proxyEnabled = false;
  ProxyType _proxyType = ProxyType.http;
  ProxyPresetId _presetId = ProxyPresetId.custom;
  bool _routeIptv = false;
  bool _routeCatalogs = false;
  bool _routeMetadata = false;
  bool _routeMediaServers = false;
  bool _routeTorrents = true;
  bool _routeDownloads = false;
  bool _allowDirectFallback = false;
  String? _proxyStatus;
  bool _proxyStatusIsError = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final proxy = context.read<LibraryProvider>().proxy;
    _proxyEnabled = proxy.enabled;
    _proxyType = proxy.type;
    _proxyHost = TextEditingController(text: proxy.host);
    _proxyPort = TextEditingController(text: '${proxy.port}');
    _proxyUser = TextEditingController(text: proxy.username);
    _proxyPass = TextEditingController(text: proxy.password);
    _routeIptv = proxy.routeIptv;
    _routeCatalogs = proxy.routeCatalogs;
    _routeMetadata = proxy.routeMetadata;
    _routeMediaServers = proxy.routeMediaServers;
    _routeTorrents = proxy.routeTorrents;
    _routeDownloads = proxy.routeDownloads;
    _allowDirectFallback = proxy.allowDirectFallback;
    _presetId = ProxyPreset.matchHost(proxy.host).id;
    _proxyHost.addListener(_onHostEdited);
  }

  @override
  void dispose() {
    _proxyHost.removeListener(_onHostEdited);
    _proxyHost.dispose();
    _proxyPort.dispose();
    _proxyUser.dispose();
    _proxyPass.dispose();
    super.dispose();
  }

  void _onHostEdited() {
    final matched = ProxyPreset.matchHost(_proxyHost.text).id;
    if (matched != _presetId) {
      setState(() => _presetId = matched);
    }
  }

  void _applyPreset(ProxyPreset preset) {
    setState(() {
      _presetId = preset.id;
      if (preset.id == ProxyPresetId.custom) return;
      _proxyType = preset.type;
      _proxyHost.text = preset.hostExample;
      _proxyPort.text = '${preset.port}';
    });
  }

  String? _credentialsHint(BuildContext context) {
    return switch (_presetId) {
      ProxyPresetId.nordVpn => context.l10n.proxyPresetNordVpnCredentials,
      ProxyPresetId.pia => context.l10n.proxyPresetPiaCredentials,
      ProxyPresetId.torGuard => context.l10n.proxyPresetTorGuardCredentials,
      ProxyPresetId.privateVpn => context.l10n.proxyPresetPrivateVpnCredentials,
      ProxyPresetId.custom =>
        _proxyType == ProxyType.socks5
            ? context.l10n.proxyServiceCredentialsHint
            : null,
    };
  }

  ProxySettings _currentSettings({required int port}) {
    return ProxySettings(
      enabled: _proxyEnabled,
      type: _proxyType,
      host: _proxyHost.text.trim(),
      port: port,
      username: _proxyUser.text.trim(),
      password: _proxyPass.text,
      routeIptv: _routeIptv,
      routeCatalogs: _routeCatalogs,
      routeMetadata: _routeMetadata,
      routeMediaServers: _routeMediaServers,
      routeTorrents: _routeTorrents,
      routeDownloads: _routeDownloads,
      allowDirectFallback: _allowDirectFallback,
    );
  }

  String? _runtimeProxyStatus({
    required AppLocalizations l10n,
    required String? host,
    required String? detail,
    required bool isAuth,
  }) {
    if (detail == null) return null;
    if (isAuth) return l10n.proxyTestAuthFailed;
    final label = host?.trim() ?? '';
    return label.isEmpty
        ? l10n.proxyTestFailed(detail)
        : l10n.proxyRuntimeFailed(label, detail);
  }

  Future<void> _saveProxy() async {
    if (_busy) return;
    final l10n = context.l10n;
    final library = context.read<LibraryProvider>();
    final fallback = _proxyType == ProxyType.socks5 ? 1080 : 8080;
    final port = int.tryParse(_proxyPort.text.trim()) ?? fallback;
    final settings = _currentSettings(port: port);
    if (settings.enabled && ProxySettings.isPlaceholderHost(settings.host)) {
      setState(() {
        _proxyStatus = l10n.proxySaveFailed(
          'Use a real proxy host — example.com is only a hint, not a server',
        );
        _proxyStatusIsError = true;
      });
      return;
    }
    setState(() {
      _busy = true;
      _proxyStatus = l10n.proxyTesting;
      _proxyStatusIsError = false;
    });
    try {
      await library.saveProxySettings(settings);
      if (!mounted) return;
      if (!settings.isActive) {
        setState(() {
          _busy = false;
          _proxyStatus = l10n.proxySavedStatus(library.proxy.displayLabel);
          _proxyStatusIsError = false;
        });
        return;
      }
      setState(() => _proxyStatus = l10n.proxyTesting);
      final result = await library.testProxyConnection(settings);
      if (!mounted) return;
      if (result.ok) {
        setState(() {
          _busy = false;
          _proxyStatus = l10n.proxyTestOk(library.proxy.displayLabel);
          _proxyStatusIsError = false;
        });
      } else {
        setState(() {
          _busy = false;
          _proxyStatus = result.isAuthFailure
              ? l10n.proxyTestAuthFailed
              : l10n.proxyTestFailed(result.error ?? '');
          _proxyStatusIsError = true;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _proxyStatus = l10n.proxySaveFailed('$e');
        _proxyStatusIsError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final runtime = context
        .select<LibraryProvider, ({String? host, String? detail, bool isAuth})>(
          (lib) => (
            host: lib.lastProxyFailureHost,
            detail: lib.lastProxyFailureDetail,
            isAuth: lib.lastProxyFailureIsAuth,
          ),
        );
    final statusText =
        _proxyStatus ??
        _runtimeProxyStatus(
          l10n: l10n,
          host: runtime.host,
          detail: runtime.detail,
          isAuth: runtime.isAuth,
        );
    final statusIsError = _proxyStatus != null
        ? _proxyStatusIsError
        : runtime.detail != null;
    final hostHint = _presetId == ProxyPresetId.custom
        ? (_proxyType == ProxyType.socks5 ? 'socks-host' : 'proxy-host')
        : ProxyPreset.byId(_presetId).hostExample;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Text(
          context.l10n.networkProxy,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.networkProxyHelp,
          style: TextStyle(color: AppColors.textMuted),
        ),
        SettingsSwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(context.l10n.useProxy),
          subtitle: Text(
            _proxyEnabled
                ? context.l10n.proxyEnabledSummary(
                    _proxyType == ProxyType.socks5
                        ? context.l10n.proxyTypeSocks5
                        : context.l10n.proxyTypeHttp,
                    _proxyHost.text.trim().isEmpty
                        ? context.l10n.setHost
                        : _proxyHost.text.trim(),
                  )
                : context.l10n.off,
          ),
          value: _proxyEnabled,
          onChanged: (value) => setState(() => _proxyEnabled = value),
        ),
        if (_proxyEnabled) ...[
          const SizedBox(height: 8),
          Text(
            context.l10n.proxyProviderPreset,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _ProxyProviderList(
            selectedId: _presetId,
            credentialsHint: _credentialsHint(context),
            onSelect: _applyPreset,
          ),
          const SizedBox(height: 16),
          SegmentedButton<ProxyType>(
            segments: [
              ButtonSegment(
                value: ProxyType.http,
                label: Text(context.l10n.proxyTypeHttp),
                icon: Icon(Icons.http_rounded, size: 18),
              ),
              ButtonSegment(
                value: ProxyType.socks5,
                label: Text(context.l10n.proxyTypeSocks5),
                icon: Icon(Icons.vpn_key_outlined, size: 18),
              ),
            ],
            selected: {_proxyType},
            onSelectionChanged: (next) {
              final type = next.first;
              setState(() {
                _proxyType = type;
                if (_presetId != ProxyPresetId.custom) {
                  _presetId = ProxyPresetId.custom;
                }
                final current = int.tryParse(_proxyPort.text.trim());
                if (type == ProxyType.socks5 &&
                    (current == null || current == 8080)) {
                  _proxyPort.text = '1080';
                } else if (type == ProxyType.http &&
                    (current == null || current == 1080)) {
                  _proxyPort.text = '8080';
                }
              });
            },
          ),
          const SizedBox(height: 12),
          PlainTextField(
            controller: _proxyHost,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: context.l10n.host,
              hintText: hostHint,
            ),
          ),
          const SizedBox(height: 10),
          JavpTextField(
            controller: _proxyPort,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: context.l10n.port,
              hintText: _proxyType == ProxyType.socks5 ? '1080' : '8080',
            ),
          ),
          const SizedBox(height: 10),
          PlainTextField(
            controller: _proxyUser,
            decoration: InputDecoration(
              labelText: _proxyType == ProxyType.socks5
                  ? context.l10n.username
                  : context.l10n.usernameOptional,
              hintText: _credentialsHint(context),
            ),
          ),
          const SizedBox(height: 10),
          PlainTextField(
            controller: _proxyPass,
            obscureText: true,
            decoration: InputDecoration(
              labelText: _proxyType == ProxyType.socks5
                  ? context.l10n.password
                  : context.l10n.passwordOptional,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.proxyRouteThrough,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            context.l10n.proxyRouteThroughHelp,
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
          SettingsSwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.proxyRouteIptv),
            subtitle: Text(context.l10n.proxyRouteIptvSubtitle),
            value: _routeIptv,
            onChanged: (v) => setState(() => _routeIptv = v),
          ),
          SettingsSwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.proxyRouteCatalogs),
            subtitle: Text(context.l10n.proxyRouteCatalogsSubtitle),
            value: _routeCatalogs,
            onChanged: (v) => setState(() => _routeCatalogs = v),
          ),
          SettingsSwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.proxyRouteMetadata),
            subtitle: Text(context.l10n.proxyRouteMetadataSubtitle),
            value: _routeMetadata,
            onChanged: (v) => setState(() => _routeMetadata = v),
          ),
          SettingsSwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.proxyRouteMediaServers),
            subtitle: Text(context.l10n.proxyRouteMediaServersSubtitle),
            value: _routeMediaServers,
            onChanged: (v) => setState(() => _routeMediaServers = v),
          ),
          SettingsSwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.proxyRouteTorrents),
            subtitle: Text(context.l10n.proxyRouteTorrentsSubtitle),
            value: _routeTorrents,
            onChanged: (v) => setState(() => _routeTorrents = v),
          ),
          SettingsSwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.proxyRouteDownloads),
            subtitle: Text(context.l10n.proxyRouteDownloadsSubtitle),
            value: _routeDownloads,
            onChanged: (v) => setState(() => _routeDownloads = v),
          ),
          SettingsSwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.proxyAllowDirectFallback),
            subtitle: Text(context.l10n.proxyAllowDirectFallbackSubtitle),
            value: _allowDirectFallback,
            onChanged: (v) => setState(() => _allowDirectFallback = v),
          ),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: _busy ? null : _saveProxy,
            child: Text(
              _busy ? context.l10n.proxyTesting : context.l10n.saveProxy,
            ),
          ),
        ),
        if (statusText != null) ...[
          const SizedBox(height: 8),
          Text(
            statusText,
            style: TextStyle(
              color: statusIsError ? AppColors.accent : AppColors.live,
            ),
          ),
        ],
      ],
    );
  }
}

class _ProxyProviderList extends StatelessWidget {
  const _ProxyProviderList({
    required this.selectedId,
    required this.credentialsHint,
    required this.onSelect,
  });

  final ProxyPresetId selectedId;
  final String? credentialsHint;
  final ValueChanged<ProxyPreset> onSelect;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: AppColors.border),
      ),
      child: ClipRRect(
        borderRadius: AppRadius.mdAll,
        child: Column(
          children: [
            for (var i = 0; i < ProxyPreset.all.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: AppColors.borderSoft),
              _ProxyProviderTile(
                preset: ProxyPreset.all[i],
                selected: selectedId == ProxyPreset.all[i].id,
                credentialsHint: credentialsHint,
                onSelect: () => onSelect(ProxyPreset.all[i]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProxyProviderTile extends StatelessWidget {
  const _ProxyProviderTile({
    required this.preset,
    required this.selected,
    required this.credentialsHint,
    required this.onSelect,
  });

  final ProxyPreset preset;
  final bool selected;
  final String? credentialsHint;
  final VoidCallback onSelect;

  String _title(BuildContext context) {
    return preset.id == ProxyPresetId.custom
        ? context.l10n.proxyPresetCustom
        : preset.label;
  }

  String _subtitle(BuildContext context) {
    if (preset.id == ProxyPresetId.custom) {
      return context.l10n.proxyPresetCustomHelp;
    }
    final type = preset.type == ProxyType.socks5
        ? context.l10n.proxyTypeSocks5
        : context.l10n.proxyTypeHttp;
    return '$type · ${preset.hostExample}';
  }

  @override
  Widget build(BuildContext context) {
    final showCredentials = selected && preset.credentialsUrl != null;

    return Material(
      color: selected ? AppColors.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: onSelect,
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 10, 8, showCredentials ? 12 : 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  size: 22,
                  color: selected ? AppColors.accent : AppColors.textMuted,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _title(context),
                      style: const TextStyle(
                        color: AppColors.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle(context),
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13,
                        height: 1.3,
                      ),
                    ),
                    if (showCredentials) ...[
                      if (credentialsHint != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          credentialsHint!,
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 13,
                            height: 1.3,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      OpenLinkButton(
                        label: context.l10n.proxyGetCredentials,
                        url: preset.credentialsUrl!,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
