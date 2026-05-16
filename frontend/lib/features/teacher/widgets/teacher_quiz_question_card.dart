import 'package:flutter/material.dart';

import '../../../l10n/app_strings.dart';
import '../quiz_draft.dart';

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

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  appText(
                    AppText.questionNumber,
                    args: {'number': questionIndex + 1},
                  ),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                IconButton(
                  onPressed: loading ? null : onRemoveQuestion,
                  icon: const Icon(Icons.delete_outline),
                  tooltip: appText(AppText.removeQuestionTooltip),
                ),
              ],
            ),
            TextField(
              controller: question.textController,
              decoration: InputDecoration(
                labelText: appText(AppText.questionTextLabel),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: question.timeLimitController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: appText(AppText.timeLimitSecLabel),
                hintText: '5-180',
                helperText: appText(AppText.timeLimitHelper),
              ),
            ),
            const SizedBox(height: 10),
            ...question.choices.asMap().entries.map((choiceEntry) {
              final choiceIndex = choiceEntry.key;
              final choice = choiceEntry.value;

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Radio<int>(
                      value: choiceIndex,
                      groupValue: correctChoiceIndex >= 0
                          ? correctChoiceIndex
                          : null,
                      onChanged: loading
                          ? null
                          : (_) => onSetCorrectChoice(choiceIndex),
                    ),
                    Expanded(
                      child: TextField(
                        controller: choice.textController,
                        decoration: InputDecoration(
                          labelText: appText(
                            AppText.choiceNumber,
                            args: {'number': choiceIndex + 1},
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: loading ? null : () => onRemoveChoice(choiceIndex),
                      icon: const Icon(Icons.close),
                      tooltip: appText(AppText.removeChoiceTooltip),
                    ),
                  ],
                ),
              );
            }),
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
