import 'package:flutter/material.dart';

import '../../../l10n/app_strings.dart';

class TeacherRoundControls extends StatelessWidget {
  const TeacherRoundControls({
    super.key,
    required this.onStart,
    required this.onNextQuestion,
    required this.onRevealAnswers,
    required this.onFinish,
    required this.onOpenDisplay,
    required this.onShowLeaderboard,
    required this.onExportCsv,
  });

  final VoidCallback? onStart;
  final VoidCallback? onNextQuestion;
  final VoidCallback? onRevealAnswers;
  final VoidCallback? onFinish;
  final VoidCallback? onOpenDisplay;
  final VoidCallback? onShowLeaderboard;
  final VoidCallback? onExportCsv;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          appText(AppText.teacherRoundControlsTitle),
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              onPressed: onStart,
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(appText(AppText.startButton)),
            ),
            FilledButton.tonalIcon(
              onPressed: onNextQuestion,
              icon: const Icon(Icons.skip_next_outlined),
              label: Text(appText(AppText.nextQuestionButton)),
            ),
            FilledButton.tonalIcon(
              onPressed: onRevealAnswers,
              icon: const Icon(Icons.visibility_outlined),
              label: Text(appText(AppText.revealAnswersButton)),
            ),
            FilledButton.tonalIcon(
              onPressed: onFinish,
              icon: const Icon(Icons.flag_outlined),
              label: Text(appText(AppText.finishButton)),
            ),
            OutlinedButton.icon(
              onPressed: onOpenDisplay,
              icon: const Icon(Icons.connected_tv_outlined),
              label: Text(appText(AppText.openDisplayButton)),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
            ),
            OutlinedButton.icon(
              onPressed: onShowLeaderboard,
              icon: const Icon(Icons.leaderboard_outlined),
              label: Text(appText(AppText.leaderboardButton)),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
            ),
            OutlinedButton.icon(
              onPressed: onExportCsv,
              icon: const Icon(Icons.download_outlined),
              label: Text(appText(AppText.exportCsvButton)),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
            ),
          ],
        ),
      ],
    );
  }
}
