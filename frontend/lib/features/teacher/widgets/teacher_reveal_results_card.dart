import 'package:flutter/material.dart';

import '../../../core/value_utils.dart';
import '../../../l10n/app_language.dart';
import '../../../l10n/app_strings.dart';

class TeacherRevealResultsCard extends StatelessWidget {
  const TeacherRevealResultsCard({
    super.key,
    required this.revealPayload,
  });

  final Map<String, dynamic> revealPayload;

  static const _choiceColors = [
    Color(0xFFE21B3C),
    Color(0xFF1368CE),
    Color(0xFFD89E00),
    Color(0xFF26890C),
  ];

  static const _choiceIcons = [
    Icons.change_history,
    Icons.diamond_outlined,
    Icons.circle_outlined,
    Icons.square_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final totalAnswers = asInt(revealPayload['total_answers']);
    final choices = (revealPayload['choices'] as List<dynamic>? ?? <dynamic>[])
        .map((rawChoice) => mapOrNull(rawChoice) ?? <String, dynamic>{})
        .where((choice) => choice.isNotEmpty)
        .toList()
      ..sort((a, b) => asInt(a['order']).compareTo(asInt(b['order'])));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      appText(AppText.revealResultsTitle),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                          ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      uiText(
                        ru: 'Как участники распределили ответы в этом раунде.',
                        en: 'How participants answered this round.',
                      ),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.82),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _SummaryPill(
                icon: Icons.how_to_vote_outlined,
                label: appText(
                  AppText.totalAnswers,
                  args: {'count': totalAnswers},
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (choices.isEmpty)
            Text(
              appText(AppText.participantNoLeaderboardYet),
              style: const TextStyle(color: Colors.white),
            )
          else
            Column(
              children: [
                for (final entry in choices.asMap().entries) ...[
                  _ChoiceResultRow(
                    choice: entry.value,
                    index: entry.key,
                    totalAnswers: totalAnswers,
                    color: _choiceColors[entry.key % _choiceColors.length],
                    icon: _choiceIcons[entry.key % _choiceIcons.length],
                  ),
                  if (entry.key != choices.length - 1)
                    const SizedBox(height: 10),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _SummaryPill extends StatelessWidget {
  const _SummaryPill({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChoiceResultRow extends StatelessWidget {
  const _ChoiceResultRow({
    required this.choice,
    required this.index,
    required this.totalAnswers,
    required this.color,
    required this.icon,
  });

  final Map<String, dynamic> choice;
  final int index;
  final int totalAnswers;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final votes = asInt(choice['answers_count']);
    final percent = asInt(
      choice['answers_percent'],
      totalAnswers == 0 ? 0 : ((votes / totalAnswers) * 100).round(),
    );
    final isCorrect = choice['is_correct'] == true;
    final title = (choice['text']?.toString().trim().isNotEmpty ?? false)
        ? choice['text'].toString()
        : uiText(ru: 'Вариант ${index + 1}', en: 'Choice ${index + 1}');
    final progress = totalAnswers == 0 ? 0.0 : votes / totalAnswers;
    final effectiveColor = isCorrect ? const Color(0xFF22C55E) : color;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isCorrect
              ? const Color(0xFFB9FBC0)
              : Colors.white.withValues(alpha: 0.14),
          width: isCorrect ? 2 : 1,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: effectiveColor,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  isCorrect ? Icons.check_rounded : icon,
                  color: Colors.white,
                  size: 30,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    uiText(ru: '$votes голосов', en: '$votes votes'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    '$percent%',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.78),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 10,
              backgroundColor: Colors.white.withValues(alpha: 0.16),
              valueColor: AlwaysStoppedAnimation<Color>(effectiveColor),
            ),
          ),
        ],
      ),
    );
  }
}
