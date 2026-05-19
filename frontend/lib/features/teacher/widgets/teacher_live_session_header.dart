import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../l10n/app_strings.dart';
import '../../../shared/widgets/app_surfaces.dart';

class TeacherLiveSessionHeader extends StatelessWidget {
  const TeacherLiveSessionHeader({
    super.key,
    required this.session,
    required this.joinUrl,
    required this.wsConnected,
    required this.activeQuestion,
    required this.questionTimeLeftLabel,
    required this.answeredCount,
  });

  final Map<String, dynamic> session;
  final String joinUrl;
  final bool wsConnected;
  final Map<String, dynamic>? activeQuestion;
  final String questionTimeLeftLabel;
  final int answeredCount;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final summary = _LiveSessionSummary(
          session: session,
          wsConnected: wsConnected,
          activeQuestion: activeQuestion,
          questionTimeLeftLabel: questionTimeLeftLabel,
          answeredCount: answeredCount,
        );
        final qrCard = _LiveSessionQrCard(joinUrl: joinUrl);

        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              summary,
              const SizedBox(height: 16),
              qrCard,
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: summary),
            const SizedBox(width: 18),
            qrCard,
          ],
        );
      },
    );
  }
}

class _LiveSessionSummary extends StatelessWidget {
  const _LiveSessionSummary({
    required this.session,
    required this.wsConnected,
    required this.activeQuestion,
    required this.questionTimeLeftLabel,
    required this.answeredCount,
  });

  final Map<String, dynamic> session;
  final bool wsConnected;
  final Map<String, dynamic>? activeQuestion;
  final String questionTimeLeftLabel;
  final int answeredCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          appText(AppText.teacherLivePanelTitle),
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            AppStatusChip(
              icon: Icons.pin_outlined,
              label: 'PIN: ${session['pin']}',
              background: Colors.white,
              foreground: const Color(0xFF023047),
            ),
            AppStatusChip(
              icon: Icons.flag_outlined,
              label: appText(
                AppText.statusValue,
                args: {'status': sessionStatusText(session['status'])},
              ),
              background: Colors.white.withValues(alpha: 0.16),
              foreground: Colors.white,
            ),
            AppStatusChip(
              icon: Icons.group_outlined,
              label: appText(
                AppText.participantsCount,
                args: {'count': session['participants_count'] ?? 0},
              ),
              background: Colors.white.withValues(alpha: 0.16),
              foreground: Colors.white,
            ),
            AppStatusChip(
              icon: wsConnected ? Icons.wifi : Icons.wifi_off,
              label: appText(
                AppText.webSocketState,
                args: {
                  'state': wsConnected
                      ? appText(AppText.webSocketConnected)
                      : appText(AppText.webSocketDisconnected),
                },
              ),
              background: Colors.white.withValues(alpha: 0.16),
              foreground: Colors.white,
            ),
            if (activeQuestion != null)
              AppStatusChip(
                icon: Icons.timer_outlined,
                label: appText(
                  AppText.timeLeft,
                  args: {'time': questionTimeLeftLabel},
                ),
                background: Colors.white.withValues(alpha: 0.16),
                foreground: Colors.white,
              ),
            if (answeredCount > 0)
              AppStatusChip(
                icon: Icons.how_to_vote_outlined,
                label: appText(
                  AppText.answersReceived,
                  args: {'count': answeredCount},
                ),
                background: Colors.white.withValues(alpha: 0.16),
                foreground: Colors.white,
              ),
          ],
        ),
        if (activeQuestion != null) ...[
          const SizedBox(height: 16),
          Text(
            appText(
              AppText.currentQuestion,
              args: {'text': activeQuestion!['text']},
            ),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
          ),
        ],
      ],
    );
  }
}

class _LiveSessionQrCard extends StatelessWidget {
  const _LiveSessionQrCard({required this.joinUrl});

  final String joinUrl;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          Text(
            appText(AppText.teacherQrCodeTitle),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          QrImageView(data: joinUrl, size: 170),
        ],
      ),
    );
  }
}
