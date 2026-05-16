import 'package:flutter/material.dart';

import '../../../l10n/app_strings.dart';
import '../../../shared/widgets/app_surfaces.dart';

class ParticipantHero extends StatelessWidget {
  const ParticipantHero({
    super.key,
    required this.isLive,
    required this.totalPoints,
    required this.sessionStatus,
    required this.socketConnected,
    required this.hasActiveQuestion,
    required this.timeLeftLabel,
  });

  final bool isLive;
  final int totalPoints;
  final String sessionStatus;
  final bool socketConnected;
  final bool hasActiveQuestion;
  final String timeLeftLabel;

  @override
  Widget build(BuildContext context) {
    final statusText = appText(AppText.statusValue, args: {'status': sessionStatus});
    final socketText = appText(
      AppText.webSocketState,
      args: {
        'state': socketConnected ? appText(AppText.webSocketConnected) : appText(AppText.webSocketDisconnected),
      },
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF023047), Color(0xFF0A9396), Color(0xFFFFB703)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF023047).withOpacity(0.22),
            blurRadius: 28,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppStatusChip(
            icon: isLive ? Icons.bolt : Icons.qr_code_2,
            label: isLive ? appText(AppText.participantHeroLiveBadge) : appText(AppText.participantHeroJoinBadge),
            background: Colors.white.withOpacity(0.18),
            foreground: Colors.white,
          ),
          const SizedBox(height: 18),
          Text(
            isLive ? appText(AppText.participantHeroLiveTitle) : appText(AppText.participantHeroJoinTitle),
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            isLive ? appText(AppText.participantHeroLiveSubtitle) : appText(AppText.participantHeroJoinSubtitle),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white.withOpacity(0.9),
                  height: 1.35,
                ),
          ),
          if (isLive) ...[
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                AppStatusChip(
                  icon: Icons.emoji_events_outlined,
                  label: appText(AppText.participantPoints, args: {'points': totalPoints}),
                  background: Colors.white,
                  foreground: const Color(0xFF023047),
                ),
                AppStatusChip(
                  icon: Icons.flag_outlined,
                  label: statusText,
                  background: Colors.white.withOpacity(0.18),
                  foreground: Colors.white,
                ),
                AppStatusChip(
                  icon: socketConnected ? Icons.wifi : Icons.wifi_off,
                  label: socketText,
                  background: Colors.white.withOpacity(0.18),
                  foreground: Colors.white,
                ),
                if (hasActiveQuestion)
                  AppStatusChip(
                    icon: Icons.timer_outlined,
                    label: appText(AppText.timeLeft, args: {'time': timeLeftLabel}),
                    background: Colors.white.withOpacity(0.18),
                    foreground: Colors.white,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
