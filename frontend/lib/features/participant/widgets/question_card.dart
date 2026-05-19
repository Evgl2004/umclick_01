import 'package:flutter/material.dart';

import '../../../core/value_utils.dart';
import '../../../l10n/app_strings.dart';

class ParticipantQuestionCard extends StatelessWidget {
  const ParticipantQuestionCard({
    super.key,
    required this.question,
    required this.onAnswer,
    required this.questionLocked,
    required this.selectedChoiceId,
    required this.timeLeftLabel,
    required this.correctChoiceId,
    required this.answerRevealed,
  });

  final Map<String, dynamic> question;
  final ValueChanged<int> onAnswer;
  final bool questionLocked;
  final int? selectedChoiceId;
  final String timeLeftLabel;
  final int? correctChoiceId;
  final bool answerRevealed;

  static const _answerColors = [
    Color(0xFFE21B3C),
    Color(0xFF1368CE),
    Color(0xFFD89E00),
    Color(0xFF26890C),
  ];

  static const _answerIcons = [
    Icons.change_history,
    Icons.diamond_outlined,
    Icons.circle_outlined,
    Icons.square_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final choices =
        (question['choices'] as List<dynamic>? ?? <dynamic>[]).toList()
          ..sort((a, b) {
            final aMap = mapOrNull(a) ?? <String, dynamic>{};
            final bMap = mapOrNull(b) ?? <String, dynamic>{};
            return asInt(aMap['order']).compareTo(asInt(bMap['order']));
          });

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF111827), Color(0xFF023047)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF111827).withValues(alpha: 0.22),
            blurRadius: 26,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          appText(AppText.questionTimeLimitLabel, args: {
                            'seconds': question['time_limit_sec'] ?? '-'
                          }),
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (questionLocked)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            appText(AppText.answerLockedMessage),
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _QuestionCountdownBadge(timeLeftLabel: timeLeftLabel),
              ],
            ),
            const SizedBox(height: 18),
            if (question['text_hidden'] == true ||
                (question['text']?.toString().trim().isEmpty ?? true))
              _DisplayOnlyQuestionBanner()
            else ...[
              Text(
                '${question['text']}',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      height: 1.15,
                    ),
              ),
              const SizedBox(height: 18),
            ],
            LayoutBuilder(
              builder: (context, constraints) {
                final useTwoColumns = constraints.maxWidth >= 680;
                final itemWidth = useTwoColumns
                    ? (constraints.maxWidth - 12) / 2
                    : constraints.maxWidth;

                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: choices.asMap().entries.map((entry) {
                    final choiceIndex = entry.key;
                    final rawChoice = entry.value;
                    final choice = mapOrNull(rawChoice) ?? <String, dynamic>{};
                    final choiceId = asInt(choice['id'], -1);
                    final isSelected = selectedChoiceId == choiceId;
                    final isCorrect = correctChoiceId == choiceId;
                    final shouldHideText =
                        question['choices_text_hidden'] == true ||
                            (choice['text']?.toString().trim().isEmpty ?? true);
                    final label = shouldHideText
                        ? appText(
                            AppText.participantChoiceFallback,
                            args: {'number': choiceIndex + 1},
                          )
                        : '${choice['text']}';
                    final color =
                        _answerColors[choiceIndex % _answerColors.length];
                    final icon =
                        _answerIcons[choiceIndex % _answerIcons.length];

                    return SizedBox(
                      width: itemWidth,
                      child: _buildAnswerTile(
                        context,
                        color: color,
                        icon: icon,
                        label: label,
                        isSelected: isSelected,
                        isCorrect: isCorrect,
                        answerRevealed: answerRevealed,
                        isDimmed: questionLocked && !isSelected && !isCorrect,
                        onTap: questionLocked ? null : () => onAnswer(choiceId),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnswerTile(
    BuildContext context, {
    required Color color,
    required IconData icon,
    required String label,
    required bool isSelected,
    required bool isCorrect,
    required bool answerRevealed,
    required bool isDimmed,
    required VoidCallback? onTap,
  }) {
    final radius = BorderRadius.circular(24);

    final borderColor = answerRevealed && isCorrect
        ? const Color(0xFFB9FBC0)
        : isSelected
            ? Colors.white
            : Colors.white.withValues(alpha: 0.18);
    final borderWidth = answerRevealed && isCorrect
        ? 5.0
        : isSelected
            ? 4.0
            : 1.0;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: isDimmed ? 0.58 : 1,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            constraints: const BoxConstraints(minHeight: 88),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: color,
              borderRadius: radius,
              border: Border.all(
                color: borderColor,
                width: borderWidth,
              ),
              boxShadow: [
                if (isSelected)
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.28),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          height: 1.2,
                        ),
                  ),
                ),
                if (answerRevealed && isCorrect) ...[
                  const SizedBox(width: 10),
                  const Icon(Icons.check_circle,
                      color: Color(0xFFB9FBC0), size: 34),
                ] else if (isSelected) ...[
                  const SizedBox(width: 10),
                  const Icon(Icons.check_circle, color: Colors.white),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DisplayOnlyQuestionBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          const Icon(Icons.connected_tv_outlined, color: Colors.white),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              appText(AppText.participantQuestionOnDisplayTitle),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuestionCountdownBadge extends StatelessWidget {
  const _QuestionCountdownBadge({required this.timeLeftLabel});

  final String timeLeftLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 118,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          const Icon(Icons.timer_outlined, color: Color(0xFF023047)),
          const SizedBox(height: 4),
          Text(
            timeLeftLabel,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: const Color(0xFF023047),
                  fontWeight: FontWeight.w900,
                ),
          ),
          Text(
            appText(AppText.participantTimeLeftBadge, args: {'time': ''})
                .replaceAll(': ', '')
                .trim(),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: const Color(0xFF023047).withValues(alpha: 0.72),
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}
