import 'package:flutter/material.dart';

import '../../../core/value_utils.dart';
import '../../../l10n/app_strings.dart';
import '../quiz_draft.dart';
import 'teacher_quiz_question_card.dart';

class TeacherQuizBuilderCard extends StatelessWidget {
  const TeacherQuizBuilderCard({
    super.key,
    required this.quizzes,
    required this.selectedQuizId,
    required this.editingQuizId,
    required this.loading,
    required this.isLoggedIn,
    required this.titleController,
    required this.descriptionController,
    required this.questions,
    required this.onSelectedQuizChanged,
    required this.onLoadSelectedQuiz,
    required this.onSaveQuiz,
    required this.onResetDraft,
    required this.onRefreshQuizzes,
    required this.onDeleteSelectedQuiz,
    required this.onRemoveQuestion,
    required this.onSetCorrectChoice,
    required this.onRemoveChoice,
    required this.onAddChoice,
    required this.onAddQuestion,
  });

  final List<dynamic> quizzes;
  final int? selectedQuizId;
  final int? editingQuizId;
  final bool loading;
  final bool isLoggedIn;
  final TextEditingController titleController;
  final TextEditingController descriptionController;
  final List<QuizDraftQuestion> questions;
  final ValueChanged<int?> onSelectedQuizChanged;
  final VoidCallback onLoadSelectedQuiz;
  final VoidCallback onSaveQuiz;
  final VoidCallback onResetDraft;
  final VoidCallback onRefreshQuizzes;
  final VoidCallback onDeleteSelectedQuiz;
  final ValueChanged<int> onRemoveQuestion;
  final void Function(QuizDraftQuestion question, int choiceIndex) onSetCorrectChoice;
  final void Function(QuizDraftQuestion question, int choiceIndex) onRemoveChoice;
  final ValueChanged<QuizDraftQuestion> onAddChoice;
  final VoidCallback onAddQuestion;

  @override
  Widget build(BuildContext context) {
    final canUseTeacherApi = !loading && isLoggedIn;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              appText(AppText.quizBuilderTitle),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              editingQuizId == null
                  ? appText(AppText.quizDraftMode)
                  : appText(AppText.quizEditMode, args: {'id': editingQuizId}),
            ),
            const SizedBox(height: 10),
            _QuizSelectorRow(
              quizzes: quizzes,
              selectedQuizId: selectedQuizId,
              loading: loading,
              isLoggedIn: isLoggedIn,
              onSelectedQuizChanged: onSelectedQuizChanged,
              onLoadSelectedQuiz: onLoadSelectedQuiz,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton(
                  onPressed: canUseTeacherApi ? onSaveQuiz : null,
                  child: Text(
                    editingQuizId == null
                        ? appText(AppText.saveNewQuizButton)
                        : appText(AppText.saveQuizChangesButton),
                  ),
                ),
                FilledButton.tonal(
                  onPressed: canUseTeacherApi ? onResetDraft : null,
                  child: Text(appText(AppText.newDraftButton)),
                ),
                OutlinedButton(
                  onPressed: canUseTeacherApi ? onRefreshQuizzes : null,
                  child: Text(appText(AppText.refreshQuizzesButton)),
                ),
                OutlinedButton(
                  onPressed: canUseTeacherApi && selectedQuizId != null
                      ? onDeleteSelectedQuiz
                      : null,
                  child: Text(appText(AppText.deleteSelectedButton)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: titleController,
              decoration: InputDecoration(
                labelText: appText(AppText.quizTitleLabel),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: descriptionController,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: appText(AppText.quizDescriptionOptionalLabel),
              ),
            ),
            const SizedBox(height: 12),
            ...questions.asMap().entries.map((questionEntry) {
              final questionIndex = questionEntry.key;
              final question = questionEntry.value;

              return TeacherQuizQuestionCard(
                question: question,
                questionIndex: questionIndex,
                loading: loading,
                onRemoveQuestion: () => onRemoveQuestion(questionIndex),
                onSetCorrectChoice: (choiceIndex) =>
                    onSetCorrectChoice(question, choiceIndex),
                onRemoveChoice: (choiceIndex) =>
                    onRemoveChoice(question, choiceIndex),
                onAddChoice: () => onAddChoice(question),
              );
            }),
            FilledButton.tonalIcon(
              onPressed: canUseTeacherApi ? onAddQuestion : null,
              icon: const Icon(Icons.add_circle_outline),
              label: Text(appText(AppText.addQuestionButton)),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuizSelectorRow extends StatelessWidget {
  const _QuizSelectorRow({
    required this.quizzes,
    required this.selectedQuizId,
    required this.loading,
    required this.isLoggedIn,
    required this.onSelectedQuizChanged,
    required this.onLoadSelectedQuiz,
  });

  final List<dynamic> quizzes;
  final int? selectedQuizId;
  final bool loading;
  final bool isLoggedIn;
  final ValueChanged<int?> onSelectedQuizChanged;
  final VoidCallback onLoadSelectedQuiz;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (quizzes.isNotEmpty)
          Expanded(
            child: DropdownButton<int>(
              value: selectedQuizId,
              isExpanded: true,
              items: quizzes.map((rawQuiz) {
                final quiz = mapOrNull(rawQuiz) ?? <String, dynamic>{};
                final quizId = asInt(quiz['id'], 0);
                final quizTitle =
                    quiz['title']?.toString() ?? appText(AppText.untitledQuiz);
                return DropdownMenuItem<int>(
                  value: quizId,
                  child: Text('$quizId: $quizTitle'),
                );
              }).toList(),
              onChanged: onSelectedQuizChanged,
            ),
          )
        else
          Expanded(child: Text(appText(AppText.noQuizzesYet))),
        const SizedBox(width: 12),
        FilledButton.tonal(
          onPressed: loading || !isLoggedIn || selectedQuizId == null
              ? null
              : onLoadSelectedQuiz,
          child: Text(appText(AppText.loadButton)),
        ),
      ],
    );
  }
}
