import 'package:flutter/material.dart';

import '../../../l10n/app_strings.dart';
import '../../../shared/widgets/app_surfaces.dart';
import '../quiz_draft.dart';

const _choiceColors = [
  Color(0xFFE53935),
  Color(0xFF1E88E5),
  Color(0xFFF9A825),
  Color(0xFF43A047),
  Color(0xFF8E24AA),
  Color(0xFF00897B),
];

class TeacherQuizQuestionCard extends StatelessWidget {
  const TeacherQuizQuestionCard({
    super.key,
    required this.question,
    required this.questionIndex,
    required this.loading,
    required this.onRemoveQuestion,
    required this.onSetCorrectChoice,
    required this.onRemoveChoice,
    required this.onAddChoice,
  });

  final QuizDraftQuestion question;
  final int questionIndex;
  final bool loading;
  final VoidCallback onRemoveQuestion;
  final ValueChanged<int> onSetCorrectChoice;
  final ValueChanged<int> onRemoveChoice;
  final VoidCallback onAddChoice;

  @override
  Widget build(BuildContext context) {
    final correctChoiceIndex = question.choices.indexWhere(
      (choice) => choice.isCorrect,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: AppSectionCard(
        padding: const EdgeInsets.all(16),
        borderRadius: 28,
        color: const Color(0xFFF8FCFB),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _QuestionHeader(
              questionIndex: questionIndex,
              loading: loading,
              onRemoveQuestion: onRemoveQuestion,
            ),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 720;
                final questionField = TextField(
                  controller: question.textController,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.help_outline_rounded),
                    labelText: appText(AppText.questionTextLabel),
                  ),
                );
                final timeField = TextField(
                  controller: question.timeLimitController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.timer_outlined),
                    labelText: appText(AppText.timeLimitSecLabel),
                    hintText: '5-180',
                    helperText: appText(AppText.timeLimitHelper),
                  ),
                );

                if (compact) {
                  return Column(
                    children: [
                      questionField,
                      const SizedBox(height: 10),
                      timeField,
                    ],
                  );
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: questionField),
                    const SizedBox(width: 14),
                    SizedBox(width: 260, child: timeField),
                  ],
                );
              },
            ),
            const SizedBox(height: 14),
            RadioGroup<int>(
              groupValue: correctChoiceIndex >= 0 ? correctChoiceIndex : null,
              onChanged: (choiceIndex) {
                if (loading || choiceIndex == null) return;
                onSetCorrectChoice(choiceIndex);
              },
              child: Column(
                children: question.choices.asMap().entries.map((choiceEntry) {
                  final choiceIndex = choiceEntry.key;
                  final choice = choiceEntry.value;
                  final color =
                      _choiceColors[choiceIndex % _choiceColors.length];
                  final selected = choiceIndex == correctChoiceIndex;

                  return _AnswerChoiceTile(
                    choiceIndex: choiceIndex,
                    choice: choice,
                    color: color,
                    selected: selected,
                    loading: loading,
                    onRemoveChoice: () => onRemoveChoice(choiceIndex),
                  );
                }).toList(),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: loading ? null : onAddChoice,
                icon: const Icon(Icons.add),
                label: Text(appText(AppText.addChoiceButton)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuestionHeader extends StatelessWidget {
  const _QuestionHeader({
    required this.questionIndex,
    required this.loading,
    required this.onRemoveQuestion,
  });

  final int questionIndex;
  final bool loading;
  final VoidCallback onRemoveQuestion;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFFE0F2F1),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Center(
            child: Text(
              '${questionIndex + 1}',
              style: const TextStyle(
                color: Color(0xFF00695C),
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            appText(
              AppText.questionNumber,
              args: {'number': questionIndex + 1},
            ),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
          ),
        ),
        IconButton.filledTonal(
          onPressed: loading ? null : onRemoveQuestion,
          icon: const Icon(Icons.delete_outline),
          tooltip: appText(AppText.removeQuestionTooltip),
        ),
      ],
    );
  }
}

class _AnswerChoiceTile extends StatelessWidget {
  const _AnswerChoiceTile({
    required this.choiceIndex,
    required this.choice,
    required this.color,
    required this.selected,
    required this.loading,
    required this.onRemoveChoice,
  });

  final int choiceIndex;
  final QuizDraftChoice choice;
  final Color color;
  final bool selected;
  final bool loading;
  final VoidCallback onRemoveChoice;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: selected ? 0.15 : 0.08),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: selected ? color : color.withValues(alpha: 0.32),
          width: selected ? 2 : 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Center(
              child: Text(
                '${choiceIndex + 1}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          Radio<int>(
            value: choiceIndex,
            enabled: !loading,
          ),
          Expanded(
            child: TextField(
              controller: choice.textController,
              decoration: InputDecoration(
                labelText: appText(
                  AppText.choiceNumber,
                  args: {'number': choiceIndex + 1},
                ),
                border: InputBorder.none,
              ),
            ),
          ),
          IconButton(
            onPressed: loading ? null : onRemoveChoice,
            icon: const Icon(Icons.close),
            tooltip: appText(AppText.removeChoiceTooltip),
          ),
        ],
      ),
    );
  }
}
