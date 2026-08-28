import 'package:flutter/material.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_action_button.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:javp/widgets/download/dvr_download_dialog.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:provider/provider.dart';

Future<void> showEpgProgramSheet({
  required BuildContext context,
  required MediaItem channel,
  required EpgProgram program,
  required VoidCallback onWatchLive,
  required VoidCallback onWatchCatchup,
}) {
  return showAppModal<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      return EpgProgramSheet(
        channel: channel,
        program: program,
        onWatchLive: onWatchLive,
        onWatchCatchup: onWatchCatchup,
      );
    },
  );
}

class EpgProgramSheet extends StatelessWidget {
  const EpgProgramSheet({
    super.key,
    required this.channel,
    required this.program,
    required this.onWatchLive,
    required this.onWatchCatchup,
  });

  final MediaItem channel;
  final EpgProgram program;
  final VoidCallback onWatchLive;
  final VoidCallback onWatchCatchup;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider>();
    final now = DateTime.now();
    final isNow = program.isAiringAt(now);
    final isPast = program.end.isBefore(now);
    final isFuture = program.start.isAfter(now);
    final hasArchive =
        library.liveSupportsCatchup(channel) || program.hasArchive;
    final canCatchup = isPast && hasArchive;
    final canStartOver = isNow && hasArchive;
    final reminded = library.isProgramReminded(channel, program);
    final bottom = MediaQuery.paddingOf(context).bottom;
    final desc = program.description?.trim();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + bottom),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppModalDragHandle(top: 0, bottom: 16),
              if (program.imageUrl != null && program.imageUrl!.isNotEmpty) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: JavpArt(
                      url: program.imageUrl,
                      decodeWidth: 720,
                      fallback: Container(
                        color: AppColors.surfaceHigh,
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.live_tv_rounded,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              Text(
                program.title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: AppColors.text,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                library.officialLiveTitle(channel),
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _windowLabel(context, program.start, program.end) +
                    (isNow
                        ? ' · ${context.l10n.now}'
                        : isPast
                        ? (canCatchup
                              ? ' · ${context.l10n.catchup}'
                              : ' · ${context.l10n.ended}')
                        : ' · ${context.l10n.upcoming}') +
                    (canStartOver && !canCatchup
                        ? ' · ${context.l10n.catchup}'
                        : ''),
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 13,
                ),
              ),
              if (reminded) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Chip(
                    avatar: const Icon(
                      Icons.notifications_active_rounded,
                      size: 16,
                    ),
                    label: Text(context.l10n.reminderSet),
                    backgroundColor: AppColors.accentSoft,
                    side: BorderSide.none,
                    labelStyle: const TextStyle(
                      color: AppColors.text,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Text(
                (desc == null || desc.isEmpty)
                    ? context.l10n.noDescription
                    : desc,
                style: TextStyle(
                  color: (desc == null || desc.isEmpty)
                      ? AppColors.textMuted
                      : AppColors.text,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              if (isNow) ...[
                AppActionButton(
                  expand: true,
                  icon: Icons.play_arrow_rounded,
                  onPressed: () {
                    Navigator.pop(context);
                    onWatchLive();
                  },
                  label: context.l10n.watchLive,
                ),
                if (canStartOver) ...[
                  const SizedBox(height: 8),
                  AppActionButton(
                    expand: true,
                    variant: AppActionButtonVariant.outlined,
                    icon: Icons.restart_alt_rounded,
                    onPressed: () {
                      Navigator.pop(context);
                      onWatchCatchup();
                    },
                    label: context.l10n.startOver,
                  ),
                ],
              ] else if (canCatchup)
                AppActionButton(
                  expand: true,
                  icon: Icons.history_rounded,
                  onPressed: () {
                    Navigator.pop(context);
                    onWatchCatchup();
                  },
                  label: context.l10n.playCatchup,
                )
              else if (isFuture)
                AppActionButton(
                  expand: true,
                  icon: reminded
                      ? Icons.notifications_off_rounded
                      : Icons.notifications_active_rounded,
                  onPressed: () async {
                    if (reminded) {
                      await library.cancelProgramReminder(
                        channel: channel,
                        program: program,
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(context.l10n.reminderCancelled),
                          ),
                        );
                      }
                      return;
                    }
                    final ok = await library.scheduleProgramReminder(
                      channel: channel,
                      program: program,
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          ok
                              ? context.l10n.notifiedWhenStarts
                              : 'Could not schedule reminder (check notification permission)',
                        ),
                      ),
                    );
                  },
                  label: reminded
                      ? context.l10n.cancelReminder
                      : context.l10n.notifyMe,
                )
              else
                AppActionButton(
                  expand: true,
                  icon: Icons.sensors_rounded,
                  onPressed: () {
                    Navigator.pop(context);
                    onWatchLive();
                  },
                  label: context.l10n.watchChannel,
                ),
              if ((canCatchup || canStartOver)) ...[
                const SizedBox(height: 8),
                AppActionButton(
                  expand: true,
                  variant: AppActionButtonVariant.outlined,
                  icon: Icons.download_rounded,
                  onPressed: () async {
                    Navigator.pop(context);
                    await showDvrDownloadPadDialog(
                      context: context,
                      channel: channel,
                      program: program,
                    );
                  },
                  label: context.l10n.downloadForOffline,
                ),
              ],
              if (isFuture && !reminded) ...[
                const SizedBox(height: 8),
                AppActionButton(
                  expand: true,
                  variant: AppActionButtonVariant.outlined,
                  icon: Icons.sensors_rounded,
                  onPressed: () {
                    Navigator.pop(context);
                    onWatchLive();
                  },
                  label: context.l10n.watchChannelNow,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _hhmm(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  String _calendarDate(BuildContext context, DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now().toLocal();
    final day = DateTime(local.year, local.month, local.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = day.difference(today).inDays;
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final stamped =
        '${weekdays[local.weekday - 1]} ${local.day} ${months[local.month - 1]}';
    if (diff == 0) return context.l10n.todayStamp(stamped);
    if (diff == -1) return context.l10n.yesterdayStamp(stamped);
    if (diff == 1) return context.l10n.tomorrowStamp(stamped);
    return stamped;
  }

  String _windowLabel(BuildContext context, DateTime start, DateTime end) {
    final sameDay =
        start.toLocal().day == end.toLocal().day &&
        start.toLocal().month == end.toLocal().month &&
        start.toLocal().year == end.toLocal().year;
    if (sameDay) {
      return '${_calendarDate(context, start)} · ${_hhmm(start)}–${_hhmm(end)}';
    }
    return '${_calendarDate(context, start)} ${_hhmm(start)} – '
        '${_calendarDate(context, end)} ${_hhmm(end)}';
  }
}
