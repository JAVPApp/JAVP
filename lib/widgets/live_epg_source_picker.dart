import 'package:flutter/material.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/live_epg_input.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/theme/app_theme.dart';

const _kEpgOff = '__epg_off__';
const _kEpgProvider = '__epg_provider__';
const _kEpgUrl = '__epg_url__';

/// Unified EPG source row for live IPTV and media-server sources.
class LiveEpgSourcePicker extends StatelessWidget {
  const LiveEpgSourcePicker({
    super.key,
    required this.providerKind,
    required this.input,
    required this.attachedSourceId,
    required this.xmltvSources,
    required this.onChanged,
    this.urlOrFileField,
  });

  final LiveEpgProviderKind providerKind;
  final LiveEpgInput input;
  final String? attachedSourceId;
  final List<IptvSource> xmltvSources;
  final void Function(LiveEpgInput input, String? attachedSourceId) onChanged;

  /// Shown under the dropdown when [input] is [LiveEpgInput.urlOrFile].
  final Widget? urlOrFileField;

  static const dropdownKey = Key('liveEpgSourceDropdown');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final attachedId = attachedSourceId?.trim();
    final attachedValid =
        attachedId != null &&
        attachedId.isNotEmpty &&
        xmltvSources.any((s) => s.id == attachedId);
    final value = switch (input) {
      LiveEpgInput.off => _kEpgOff,
      LiveEpgInput.provider => _kEpgProvider,
      LiveEpgInput.urlOrFile => _kEpgUrl,
      LiveEpgInput.attached => attachedValid ? attachedId : _kEpgProvider,
    };
    final providerLabel = switch (providerKind) {
      LiveEpgProviderKind.playlist => l10n.epgSourceFromPlaylist,
      LiveEpgProviderKind.iptvProvider => l10n.epgSourceFromProvider,
      LiveEpgProviderKind.mediaServer => l10n.epgSourceServerGuide,
    };
    final help = providerKind == LiveEpgProviderKind.mediaServer
        ? l10n.epgSourceHelpMediaServer
        : l10n.epgSourceHelpIptv;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InputDecorator(
          decoration: InputDecoration(
            labelText: l10n.epgSourceLabel,
            border: const OutlineInputBorder(),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              key: dropdownKey,
              isExpanded: true,
              menuMaxHeight: (MediaQuery.sizeOf(context).height * 0.4).clamp(
                160,
                360,
              ),
              value: value,
              items: [
                DropdownMenuItem(
                  value: _kEpgOff,
                  child: Text(l10n.epgSourceOff),
                ),
                DropdownMenuItem(
                  value: _kEpgProvider,
                  child: Text(providerLabel),
                ),
                DropdownMenuItem(
                  value: _kEpgUrl,
                  child: Text(l10n.epgSourceUrlOrFile),
                ),
                for (final s in xmltvSources)
                  DropdownMenuItem(value: s.id, child: Text(s.name)),
              ],
              onChanged: (id) {
                if (id == null) return;
                if (id == _kEpgOff) {
                  onChanged(LiveEpgInput.off, attachedSourceId);
                } else if (id == _kEpgProvider) {
                  onChanged(LiveEpgInput.provider, null);
                } else if (id == _kEpgUrl) {
                  onChanged(LiveEpgInput.urlOrFile, null);
                } else {
                  onChanged(LiveEpgInput.attached, id);
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          help,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
        if (input == LiveEpgInput.urlOrFile && urlOrFileField != null) ...[
          const SizedBox(height: 10),
          urlOrFileField!,
        ],
      ],
    );
  }
}
