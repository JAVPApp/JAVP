import 'package:flutter/material.dart';
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/multi_view_provider.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:javp/widgets/javp_text_field.dart';
import 'package:provider/provider.dart';

/// Searchable sheet to pick the second live channel for multi-view.
Future<MediaItem?> showMultiViewChannelPicker(BuildContext context) async {
  final library = context.read<LibraryProvider>();
  final playback = context.read<PlaybackProvider>();
  var channels = playback.liveZapList;
  if (channels.isEmpty) {
    channels = await library.pageLiveChannels(limit: 300);
  }
  channels = library.collapseLiveQualities(channels);
  if (!context.mounted) return null;
  return showAppModal<MediaItem>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _MultiViewChannelPickerSheet(channels: channels),
  );
}

class _MultiViewChannelPickerSheet extends StatefulWidget {
  const _MultiViewChannelPickerSheet({required this.channels});

  final List<MediaItem> channels;

  @override
  State<_MultiViewChannelPickerSheet> createState() =>
      _MultiViewChannelPickerSheetState();
}

class _MultiViewChannelPickerSheetState
    extends State<_MultiViewChannelPickerSheet> {
  final _query = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final playback = context.watch<PlaybackProvider>();
    final primaryId = playback.item?.id;
    final primaryStream = playback.liveChannel?.streamId;
    final primarySource = playback.liveChannel?.sourceId;
    final q = _filter.trim().toLowerCase();
    final filtered = widget.channels
        .where((c) {
          if (c.id == primaryId) return false;
          if (primaryStream != null &&
              c.streamId == primaryStream &&
              c.sourceId == primarySource) {
            return false;
          }
          if (q.isEmpty) return true;
          return c.title.toLowerCase().contains(q) ||
              (c.group?.toLowerCase().contains(q) ?? false);
        })
        .toList(growable: false);

    final height = MediaQuery.sizeOf(context).height * 0.72;
    return SafeArea(
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                l10n.multiViewPickChannel,
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: JavpTextField(
                controller: _query,
                autofocus: true,
                style: const TextStyle(color: AppColors.text),
                decoration: InputDecoration(
                  hintText: l10n.search,
                  hintStyle: const TextStyle(color: AppColors.textMuted),
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  fillColor: AppColors.surfaceHigh,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (v) => setState(() => _filter = v),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        l10n.multiViewNoChannels,
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final ch = filtered[index];
                        return ListTile(
                          title: Text(
                            ch.title,
                            style: const TextStyle(color: AppColors.text),
                          ),
                          subtitle: ch.group == null || ch.group!.isEmpty
                              ? null
                              : Text(
                                  ch.group!,
                                  style: const TextStyle(
                                    color: AppColors.textMuted,
                                  ),
                                ),
                          onTap: () => Navigator.of(context).pop(ch),
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

Future<void> openMultiViewFromContext(BuildContext context) async {
  final multi = context.read<MultiViewProvider>();
  if (!multi.isSupported) return;
  if (multi.isActive) {
    await multi.exit();
    return;
  }
  final channel = await showMultiViewChannelPicker(context);
  if (channel == null || !context.mounted) return;
  await multi.enter(
    secondary: channel,
    library: context.read<LibraryProvider>(),
    playback: context.read<PlaybackProvider>(),
  );
  if (!context.mounted) return;
  final err = multi.error;
  if (err != null && err.isNotEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
  }
}
