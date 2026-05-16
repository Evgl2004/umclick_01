import 'package:flutter/material.dart';

import '../../../core/value_utils.dart';
import '../../../l10n/app_strings.dart';

class ParticipantRoundMessage extends StatelessWidget {
  const ParticipantRoundMessage({
    super.key,
    required this.icon,
    required this.message,
    required this.color,
  });

  final IconData icon;
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

class ParticipantRevealResultsCard extends StatelessWidget {
  const ParticipantRevealResultsCard({
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
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appText(AppText.revealResultsTitle),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(appText(AppText.totalAnswers,
              args: {'count': revealPayload['total_answers'] ?? 0})),
          Text(appText(AppText.pointsAwarded,
              args: {'points': revealPayload['total_points_awarded'] ?? 0})),
          Text(appText(AppText.revealedBy,
              args: {'value': revealPayload['revealed_by'] ?? 'teacher'})),
          const SizedBox(height: 8),
          ...((revealPayload['choices'] as List<dynamic>? ?? <dynamic>[])
              .map((rawChoice) {
            final choice = mapOrNull(rawChoice) ?? <String, dynamic>{};
            final isCorrect = choice['is_correct'] == true;
            return ListTile(
              dense: true,
              leading:
                  Icon(isCorrect ? Icons.check_circle : Icons.circle_outlined),
              title: Text('${choice['text']}'),
              trailing: Text(appText(
                AppText.choiceStats,
                args: {
                  'votes': choice['answers_count'] ?? 0,
                  'points': choice['points_awarded'] ?? 0,
                },
              )),
            );
          })),
        ],
      ),
    );
  }
}

class ParticipantLiveEventsCard extends StatelessWidget {
  const ParticipantLiveEventsCard({
    super.key,
    required this.events,
  });

  final List<String> events;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appText(AppText.liveEventsTitle),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (events.isEmpty)
            Text(appText(AppText.noEventsYet))
          else
            ...events.map((event) => Text(event)),
        ],
      ),
    );
  }
}
