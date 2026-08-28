import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/services/download/catchup_air_date.dart';
import 'package:javp/services/download/dvr_download_math.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_action_button.dart';
import 'package:javp/widgets/javp_text_field.dart';
import 'package:javp/widgets/download/download_widgets.dart';
import 'package:provider/provider.dart';

Future<void> showDvrDownloadPadDialog({
  required BuildContext context,
  required MediaItem channel,
  required EpgProgram program,
}) async {
  final library = context.read<LibraryProvider>();
  var beforeMin = library.downloadSettings.dvrPadBefore.inMinutes.clamp(0, 15);
  var afterMin = library.downloadSettings.dvrPadAfter.inMinutes.clamp(0, 15);

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          final window = computeDvrDownloadWindow(
            programStart: program.start,
            programDuration: program.duration,
            padBefore: Duration(minutes: beforeMin),
            padAfter: Duration(minutes: afterMin),
            now: DateTime.now(),
            archiveWindow: Duration(days: channel.catchupDays.clamp(1, 14)),
          );
          final totalMin = window.duration.inMinutes;
          return AlertDialog(
            backgroundColor: AppColors.surface,
            title: Text(context.l10n.downloadForOffline),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    program.title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatCatchupAirDate(program.start),
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'About $totalMin min with padding'
                    '${window.clamped ? ' (clamped to archive / 4h limit)' : ''}',
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _PadStepper(
                    label: context.l10n.padBefore,
                    value: beforeMin,
                    onChanged: (v) => setState(() => beforeMin = v),
                  ),
                  const SizedBox(height: 8),
                  _PadStepper(
                    label: context.l10n.padAfter,
                    value: afterMin,
                    onChanged: (v) => setState(() => afterMin = v),
                  ),
                ],
              ),
            ),
            actions: [
              AppActionButton(
                variant: AppActionButtonVariant.text,
                onPressed: () => Navigator.pop(ctx, false),
                label: context.l10n.cancel,
              ),
              AppActionButton(
                onPressed: () => Navigator.pop(ctx, true),
                label: context.l10n.download,
              ),
            ],
          );
        },
      );
    },
  );

  if (confirmed != true || !context.mounted) return;
  final ok = await library.enqueueCatchupDownload(
    channel: channel,
    program: program,
    padBefore: Duration(minutes: beforeMin),
    padAfter: Duration(minutes: afterMin),
  );
  if (!context.mounted) return;
  showDownloadSnackBar(
    context,
    message: ok
        ? context.l10n.downloadQueuedSeeLibrary
        : context.l10n.downloadNotAvailable,
    showView: ok,
  );
}

/// Record / download a catchup window by wall-clock time (no EPG required).
///
/// The picker asks for an **end** time + duration (start = end − duration),
/// which matches live DVR / catchup-without-guide (“until when”).
Future<void> showCatchupRecordDialog({
  required BuildContext context,
  required MediaItem channel,
  DateTime? initialStart,
  int? initialDurationMin,
  String? initialTitle,
}) async {
  final library = context.read<LibraryProvider>();
  final archive = await library.resolveCatchupChannelAsync(channel);
  if (!context.mounted) return;
  if (archive == null || archive.streamId == null) {
    showDownloadSnackBar(
      context,
      message: context.l10n.channelNoCatchupArchive,
      showView: false,
    );
    return;
  }

  final now = DateTime.now();
  final archiveDays = archive.catchupDays.clamp(1, 14);
  final earliest = now.subtract(Duration(days: archiveDays));

  final suggested = suggestCatchupRecordEndWindow(
    now: now,
    earliest: earliest,
    initialStart: initialStart,
    initialDurationMin: initialDurationMin,
  );
  var end = suggested.end;
  var durationMin = suggested.durationMin;

  final channelLabel = library.officialLiveTitle(channel);
  final titleController = TextEditingController(
    text: (initialTitle != null && initialTitle.trim().isNotEmpty)
        ? initialTitle.trim()
        : '$channelLabel recording',
  );

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          final start = end.subtract(Duration(minutes: durationMin));
          final window = computeDvrDownloadWindow(
            programStart: start,
            programDuration: Duration(minutes: durationMin),
            padBefore: Duration.zero,
            padAfter: Duration.zero,
            now: DateTime.now(),
            archiveWindow: Duration(days: archiveDays),
          );
          return AlertDialog(
            backgroundColor: AppColors.surface,
            title: Text(context.l10n.recordFromArchive),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    channelLabel,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Up to ${archive.catchupDays}d catchup · max '
                    '${kMaxTimeshiftDuration.inHours}h per download'
                    '${window.clamped ? ' (window will be clamped)' : ''}',
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 16),
                  JavpTextField(
                    controller: titleController,
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(context.l10n.end),
                    subtitle: Text(_formatDateTime(end)),
                    trailing: const Icon(Icons.edit_calendar_rounded),
                    onTap: () async {
                      final first = earliest.add(
                        Duration(minutes: durationMin),
                      );
                      final picked = await _pickDateTime(
                        context: ctx,
                        initial: end,
                        first: first.isAfter(now) ? earliest : first,
                        last: DateTime.now(),
                      );
                      if (picked != null) {
                        setState(() => end = picked);
                      }
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    context.l10n.duration,
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final mins in kCatchupRecordDurationChoicesMin)
                        ChoiceChip(
                          label: Text('${mins}m'),
                          selected: durationMin == mins,
                          onSelected: (_) => setState(() => durationMin = mins),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Will download about ${window.duration.inMinutes} min',
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              AppActionButton(
                variant: AppActionButtonVariant.text,
                onPressed: () => Navigator.pop(ctx, false),
                label: context.l10n.cancel,
              ),
              AppActionButton(
                onPressed: () => Navigator.pop(ctx, true),
                label: context.l10n.download,
              ),
            ],
          );
        },
      );
    },
  );

  final title = titleController.text;
  titleController.dispose();

  if (confirmed != true || !context.mounted) return;
  final start = end.subtract(Duration(minutes: durationMin));
  final ok = await library.enqueueCatchupDownloadAt(
    channel: channel,
    start: start,
    duration: Duration(minutes: durationMin),
    title: title.trim().isEmpty ? null : title.trim(),
  );
  if (!context.mounted) return;
  showDownloadSnackBar(
    context,
    message: ok
        ? context.l10n.downloadQueuedSeeLibrary
        : context.l10n.downloadNotAvailable,
    showView: ok,
  );
}

Future<DateTime?> _pickDateTime({
  required BuildContext context,
  required DateTime initial,
  required DateTime first,
  required DateTime last,
}) async {
  final date = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(first.year, first.month, first.day),
    lastDate: DateTime(last.year, last.month, last.day),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial),
  );
  if (time == null) return null;
  var picked = DateTime(
    date.year,
    date.month,
    date.day,
    time.hour,
    time.minute,
  );
  if (picked.isBefore(first)) picked = first;
  if (picked.isAfter(last)) picked = last;
  return picked;
}

String _formatDateTime(DateTime dt) {
  final local = dt.toLocal();
  final y = local.year.toString().padLeft(4, '0');
  final mo = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  final h = local.hour.toString().padLeft(2, '0');
  final mi = local.minute.toString().padLeft(2, '0');
  return '$y-$mo-$d $h:$mi';
}

class _PadStepper extends StatelessWidget {
  const _PadStepper({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          onPressed: value > 0 ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        SizedBox(
          width: 48,
          child: Text(
            '$value min',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        IconButton(
          onPressed: value < 15 ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }
}
