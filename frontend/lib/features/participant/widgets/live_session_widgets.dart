import 'package:flutter/material.dart';

import '../../../core/ranking_format.dart';
import '../../../core/value_utils.dart';
import '../../../l10n/app_language.dart';
import '../../../l10n/app_strings.dart';

List<Map<String, dynamic>> participantPodiumRows(List<dynamic> leaderboard) {
  return leaderboard
      .map((row) => mapOrNull(row) ?? <String, dynamic>{})
      .where((row) {
    final rank = asInt(row['rank'], 0);
    return row.isNotEmpty && rank >= 1 && rank <= 3;
  }).toList(growable: false);
}

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
          const SizedBox(height: 8),
          ...((revealPayload['choices'] as List<dynamic>? ?? <dynamic>[])
              .map((rawChoice) {
            final choice = mapOrNull(rawChoice) ?? <String, dynamic>{};
            final isCorrect = choice['is_correct'] == true;
            final votes = asInt(choice['answers_count']);
            final percent = asInt(choice['answers_percent']);
            return ListTile(
              dense: true,
              leading:
                  Icon(isCorrect ? Icons.check_circle : Icons.circle_outlined),
              title: Text(
                (choice['text']?.toString().trim().isNotEmpty ?? false)
                    ? '${choice['text']}'
                    : uiText(
                        ru: 'Вариант ${choice['order'] ?? '-'}',
                        en: 'Choice ${choice['order'] ?? '-'}',
                      ),
              ),
              trailing: Text(
                uiText(
                  ru: '$votes голосов · $percent%',
                  en: '$votes votes · $percent%',
                ),
              ),
            );
          })),
          const SizedBox(height: 12),
          _ParticipantLeaderboardPreview(
            leaderboard:
                (revealPayload['leaderboard'] as List<dynamic>? ?? <dynamic>[]),
          ),
        ],
      ),
    );
  }
}

class ParticipantPodiumCard extends StatelessWidget {
  const ParticipantPodiumCard({
    super.key,
    required this.leaderboard,
    required this.currentSessionParticipantId,
  });

  final List<dynamic> leaderboard;
  final int currentSessionParticipantId;

  @override
  Widget build(BuildContext context) {
    final rows = leaderboard
        .map((row) => mapOrNull(row) ?? <String, dynamic>{})
        .where((row) => row.isNotEmpty)
        .toList();
    final podiumRows = participantPodiumRows(rows);
    Map<String, dynamic>? myRow;
    for (final row in rows) {
      if (asInt(row['session_participant_id'], -1) ==
          currentSessionParticipantId) {
        myRow = row;
        break;
      }
    }
    final myRank = asInt(myRow?['rank'], 0);
    final myCorrect = asInt(myRow?['correct_answers'], 0);
    final myCorrectTimeMs = asInt(myRow?['correct_time_ms'], 0);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF023047), Color(0xFF0A9396), Color(0xFFFFB703)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.emoji_events, color: Colors.white, size: 34),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      appText(AppText.participantFinalPodiumTitle),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                          ),
                    ),
                    Text(
                      appText(AppText.participantFinalPodiumSubtitle),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.88),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (podiumRows.isEmpty)
            Text(
              appText(AppText.participantNoLeaderboardYet),
              style: const TextStyle(color: Colors.white),
            )
          else
            ...podiumRows.map((row) => _PodiumRow(
                  row: row,
                  isCurrentUser: asInt(row['session_participant_id'], -1) ==
                      currentSessionParticipantId,
                )),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
            ),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                Text(
                  appText(AppText.participantYourFinalResult, args: {
                    'correct': myCorrect,
                    'time': formatRankingTimeMs(myCorrectTimeMs),
                  }),
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w800),
                ),
                if (myRank > 0)
                  Text(
                    appText(AppText.participantFinalRank,
                        args: {'rank': myRank}),
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w800),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ParticipantLeaderboardPreview extends StatelessWidget {
  const _ParticipantLeaderboardPreview({required this.leaderboard});

  final List<dynamic> leaderboard;

  @override
  Widget build(BuildContext context) {
    final rows = participantPodiumRows(leaderboard);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          appText(AppText.participantRoundLeaderboardTitle),
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 6),
        if (rows.isEmpty)
          Text(appText(AppText.participantNoLeaderboardYet))
        else
          ...rows.map((row) => _PodiumRow(row: row, compact: true)),
      ],
    );
  }
}

class _PodiumRow extends StatelessWidget {
  const _PodiumRow({
    required this.row,
    this.compact = false,
    this.isCurrentUser = false,
  });

  final Map<String, dynamic> row;
  final bool compact;
  final bool isCurrentUser;

  @override
  Widget build(BuildContext context) {
    final rank = asInt(row['rank'], 0);
    final medalColor = switch (rank) {
      1 => const Color(0xFFFFD166),
      2 => const Color(0xFFE5E7EB),
      3 => const Color(0xFFD08C60),
      _ => Theme.of(context).colorScheme.primaryContainer,
    };
    final textColor = compact ? null : Colors.white;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(compact ? 10 : 12),
      decoration: BoxDecoration(
        color: compact
            ? Theme.of(context).colorScheme.surface.withValues(alpha: 0.8)
            : Colors.white.withValues(alpha: isCurrentUser ? 0.24 : 0.14),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: compact
              ? Theme.of(context).colorScheme.outlineVariant
              : Colors.white.withValues(alpha: isCurrentUser ? 0.48 : 0.18),
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: compact ? 16 : 20,
            backgroundColor: medalColor,
            foregroundColor: const Color(0xFF023047),
            child: Text(
              rank > 0 ? '$rank' : '-',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${row['participant_name'] ?? '-'}',
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            uiText(
              ru: '${asInt(row['correct_answers'])} верных · ${formatRankingTimeMs(asInt(row['correct_time_ms']))}',
              en: '${asInt(row['correct_answers'])} correct · ${formatRankingTimeMs(asInt(row['correct_time_ms']))}',
            ),
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.w900,
            ),
          ),
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
