import 'package:flutter/material.dart';

import '../../../core/value_utils.dart';
import '../../../l10n/app_strings.dart';

class TeacherRevealResultsCard extends StatelessWidget {
  const TeacherRevealResultsCard({
    super.key,
    required this.revealPayload,
  });

  final Map<String, dynamic> revealPayload;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withOpacity(0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            appText(AppText.revealResultsTitle),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            appText(
              AppText.totalAnswers,
              args: {'count': revealPayload['total_answers'] ?? 0},
            ),
            style: const TextStyle(color: Colors.white),
          ),
          Text(
            appText(
              AppText.pointsAwarded,
              args: {'points': revealPayload['total_points_awarded'] ?? 0},
            ),
            style: const TextStyle(color: Colors.white),
          ),
          Text(
            appText(
              AppText.revealedBy,
              args: {'value': revealPayload['revealed_by'] ?? 'teacher'},
            ),
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 8),
          ...((revealPayload['choices'] as List<dynamic>? ?? <dynamic>[]).map(
            (rawChoice) {
              final choice = mapOrNull(rawChoice) ?? <String, dynamic>{};
              final correct = choice['is_correct'] == true;
              return ListTile(
                dense: true,
                textColor: Colors.white,
                iconColor: Colors.white,
                leading: Icon(
                  correct ? Icons.check_circle : Icons.circle_outlined,
                ),
                title: Text('${choice['text']}'),
                trailing: Text(
                  appText(
                    AppText.choiceStats,
                    args: {
                      'votes': choice['answers_count'] ?? 0,
                      'points': choice['points_awarded'] ?? 0,
                    },
                  ),
                ),
              );
            },
          )),
        ],
      ),
    );
  }
}
