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
  });

  final Map<String, dynamic> question;
  final ValueChanged<int> onAnswer;
  final bool questionLocked;
  final int? selectedChoiceId;

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
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    appText(AppText.questionTimeLimitLabel,
                        args: {'seconds': question['time_limit_sec'] ?? '-'}),
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                ),
                if (questionLocked)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      appText(AppText.answerLockedMessage),
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              '${question['text']}',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    height: 1.15,
                  ),
            ),
            const SizedBox(height: 18),
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
                        label: '${choice['text']}',
                        isSelected: isSelected,
                        isDimmed: questionLocked && !isSelected,
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
    required bool isDimmed,
    required VoidCallback? onTap,
  }) {
    final radius = BorderRadius.circular(24);

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
                color: isSelected
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.18),
                width: isSelected ? 4 : 1,
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
                if (isSelected) ...[
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
