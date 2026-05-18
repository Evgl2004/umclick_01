import 'package:flutter/material.dart';

import '../../../l10n/app_strings.dart';
import 'teacher_live_session_header.dart';
import 'teacher_reveal_results_card.dart';
import 'teacher_round_controls.dart';

class TeacherLiveSessionCard extends StatelessWidget {
  const TeacherLiveSessionCard({
    super.key,
    required this.session,
    required this.wsConnected,
    required this.activeQuestion,
    required this.questionTimeLeftLabel,
    required this.answeredCount,
    required this.revealPayload,
    required this.onStart,
    required this.onNextQuestion,
    required this.onRevealAnswers,
    required this.onFinish,
    required this.onShowLeaderboard,
    required this.onExportCsv,
  });

  final Map<String, dynamic> session;
  final bool wsConnected;
  final Map<String, dynamic>? activeQuestion;
  final String questionTimeLeftLabel;
  final int answeredCount;
  final Map<String, dynamic>? revealPayload;
  final VoidCallback onStart;
  final VoidCallback onNextQuestion;
  final VoidCallback onRevealAnswers;
  final VoidCallback onFinish;
  final VoidCallback onShowLeaderboard;
  final VoidCallback onExportCsv;

  @override
  Widget build(BuildContext context) {
    final joinUrl = session['join_url'] as String;
    final status = session['status']?.toString() ?? '';
    final isWaiting = status == 'waiting';
    final isLive = status == 'live';
    final isFinished = status == 'finished';
    final hasActiveQuestion = activeQuestion != null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF023047), Color(0xFF005F73), Color(0xFF0A9396)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF023047).withValues(alpha: 0.2),
            blurRadius: 26,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TeacherLiveSessionHeader(
            session: session,
            joinUrl: joinUrl,
            wsConnected: wsConnected,
            activeQuestion: activeQuestion,
            questionTimeLeftLabel: questionTimeLeftLabel,
            answeredCount: answeredCount,
          ),
          const SizedBox(height: 16),
          SelectableText(
            appText(AppText.joinUrl, args: {'url': joinUrl}),
            style: TextStyle(color: Colors.white.withValues(alpha: 0.88)),
          ),
          const SizedBox(height: 16),
          TeacherRoundControls(
            onStart: isWaiting ? onStart : null,
            onNextQuestion: isLive ? onNextQuestion : null,
            onRevealAnswers:
                isLive && hasActiveQuestion && revealPayload == null
                    ? onRevealAnswers
                    : null,
            onFinish: isFinished ? null : onFinish,
            onShowLeaderboard: onShowLeaderboard,
            onExportCsv: onExportCsv,
          ),
          if (revealPayload != null) ...[
            const SizedBox(height: 16),
            TeacherRevealResultsCard(revealPayload: revealPayload!),
          ],
        ],
      ),
    );
  }
}
