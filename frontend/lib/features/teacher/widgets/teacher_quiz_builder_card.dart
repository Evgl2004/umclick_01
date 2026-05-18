import 'package:flutter/material.dart';

import '../../../core/value_utils.dart';
import '../../../l10n/app_strings.dart';
import '../../../shared/widgets/app_surfaces.dart';
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
  final void Function(QuizDraftQuestion question, int choiceIndex)
      onSetCorrectChoice;
  final void Function(QuizDraftQuestion question, int choiceIndex)
      onRemoveChoice;
  final ValueChanged<QuizDraftQuestion> onAddChoice;
  final VoidCallback onAddQuestion;

  @override
  Widget build(BuildContext context) {
    final canUseTeacherApi = !loading && isLoggedIn;

    return AppSectionCard(
      padding: const EdgeInsets.all(16),
      borderRadius: 32,
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _BuilderHeader(
            editingQuizId: editingQuizId,
            questionsCount: questions.length,
          ),
          const SizedBox(height: 16),
          _QuizSelectorRow(
            quizzes: quizzes,
            selectedQuizId: selectedQuizId,
            loading: loading,
            isLoggedIn: isLoggedIn,
            onSelectedQuizChanged: onSelectedQuizChanged,
            onLoadSelectedQuiz: onLoadSelectedQuiz,
          ),
          const SizedBox(height: 12),
          _BuilderActions(
            canUseTeacherApi: canUseTeacherApi,
            hasSelectedQuiz: selectedQuizId != null,
            editingQuizId: editingQuizId,
            onSaveQuiz: onSaveQuiz,
            onResetDraft: onResetDraft,
            onRefreshQuizzes: onRefreshQuizzes,
            onDeleteSelectedQuiz: onDeleteSelectedQuiz,
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 860;
              final rail = _QuestionRail(
                questions: questions,
                onAddQuestion: canUseTeacherApi ? onAddQuestion : null,
              );
              final editor = _QuizEditor(
                titleController: titleController,
                descriptionController: descriptionController,
                questions: questions,
                loading: loading,
                canUseTeacherApi: canUseTeacherApi,
                onRemoveQuestion: onRemoveQuestion,
                onSetCorrectChoice: onSetCorrectChoice,
                onRemoveChoice: onRemoveChoice,
                onAddChoice: onAddChoice,
                onAddQuestion: onAddQuestion,
              );

              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    rail,
                    const SizedBox(height: 12),
                    editor,
                  ],
                );
              }

              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 230, child: rail),
                    const SizedBox(width: 16),
                    Expanded(child: editor),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _BuilderHeader extends StatelessWidget {
  const _BuilderHeader({
    required this.editingQuizId,
    required this.questionsCount,
  });

  final int? editingQuizId;
  final int questionsCount;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: const Color(0xFFE0F7FA),
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(Icons.quiz_outlined, color: Color(0xFF00796B)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                appText(AppText.quizBuilderTitle),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                editingQuizId == null
                    ? appText(AppText.quizDraftMode)
                    : appText(AppText.quizEditMode,
                        args: {'id': editingQuizId}),
              ),
            ],
          ),
        ),
        AppStatusChip(
          icon: Icons.format_list_numbered_rounded,
          label: '$questionsCount',
          background: const Color(0xFFFFF3CD),
          foreground: const Color(0xFF805300),
        ),
      ],
    );
  }
}

class _BuilderActions extends StatelessWidget {
  const _BuilderActions({
    required this.canUseTeacherApi,
    required this.hasSelectedQuiz,
    required this.editingQuizId,
    required this.onSaveQuiz,
    required this.onResetDraft,
    required this.onRefreshQuizzes,
    required this.onDeleteSelectedQuiz,
  });

  final bool canUseTeacherApi;
  final bool hasSelectedQuiz;
  final int? editingQuizId;
  final VoidCallback onSaveQuiz;
  final VoidCallback onResetDraft;
  final VoidCallback onRefreshQuizzes;
  final VoidCallback onDeleteSelectedQuiz;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        FilledButton.icon(
          onPressed: canUseTeacherApi ? onSaveQuiz : null,
          icon: const Icon(Icons.save_outlined),
          label: Text(
            editingQuizId == null
                ? appText(AppText.saveNewQuizButton)
                : appText(AppText.saveQuizChangesButton),
          ),
        ),
        FilledButton.tonalIcon(
          onPressed: canUseTeacherApi ? onResetDraft : null,
          icon: const Icon(Icons.add_box_outlined),
          label: Text(appText(AppText.newDraftButton)),
        ),
        OutlinedButton.icon(
          onPressed: canUseTeacherApi ? onRefreshQuizzes : null,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(appText(AppText.refreshQuizzesButton)),
        ),
        OutlinedButton.icon(
          onPressed:
              canUseTeacherApi && hasSelectedQuiz ? onDeleteSelectedQuiz : null,
          icon: const Icon(Icons.delete_outline_rounded),
          label: Text(appText(AppText.deleteSelectedButton)),
        ),
      ],
    );
  }
}

class _QuestionRail extends StatelessWidget {
  const _QuestionRail({
    required this.questions,
    required this.onAddQuestion,
  });

  final List<QuizDraftQuestion> questions;
  final VoidCallback? onAddQuestion;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF4FBFA),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFFD2E8E6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.view_list_rounded, color: Color(0xFF00796B)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  appText(AppText.teacherFlowQuizTitle),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final entry in questions.asMap().entries) ...[
            _QuestionRailItem(index: entry.key, question: entry.value),
            if (entry.key != questions.length - 1) const SizedBox(height: 8),
          ],
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: onAddQuestion,
            icon: const Icon(Icons.add_circle_outline),
            label: Text(appText(AppText.addQuestionButton)),
          ),
        ],
      ),
    );
  }
}

class _QuestionRailItem extends StatelessWidget {
  const _QuestionRailItem({
    required this.index,
    required this.question,
  });

  final int index;
  final QuizDraftQuestion question;

  @override
  Widget build(BuildContext context) {
    final title = question.textController.text.trim();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: index == 0 ? const Color(0xFFE0F2F1) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: index == 0 ? const Color(0xFF80CBC4) : const Color(0xFFDDEBE9),
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 15,
            backgroundColor:
                index == 0 ? const Color(0xFF00796B) : const Color(0xFFEAF4F2),
            foregroundColor:
                index == 0 ? Colors.white : const Color(0xFF31524F),
            child: Text('${index + 1}'),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title.isEmpty
                  ? appText(AppText.questionNumber, args: {'number': index + 1})
                  : title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuizEditor extends StatelessWidget {
  const _QuizEditor({
    required this.titleController,
    required this.descriptionController,
    required this.questions,
    required this.loading,
    required this.canUseTeacherApi,
    required this.onRemoveQuestion,
    required this.onSetCorrectChoice,
    required this.onRemoveChoice,
    required this.onAddChoice,
    required this.onAddQuestion,
  });

  final TextEditingController titleController;
  final TextEditingController descriptionController;
  final List<QuizDraftQuestion> questions;
  final bool loading;
  final bool canUseTeacherApi;
  final ValueChanged<int> onRemoveQuestion;
  final void Function(QuizDraftQuestion question, int choiceIndex)
      onSetCorrectChoice;
  final void Function(QuizDraftQuestion question, int choiceIndex)
      onRemoveChoice;
  final ValueChanged<QuizDraftQuestion> onAddChoice;
  final VoidCallback onAddQuestion;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFFDDEBE9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: titleController,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.title_rounded),
              labelText: appText(AppText.quizTitleLabel),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: descriptionController,
            maxLines: 2,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.subject_rounded),
              labelText: appText(AppText.quizDescriptionOptionalLabel),
            ),
          ),
          const SizedBox(height: 16),
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
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: canUseTeacherApi ? onAddQuestion : null,
              icon: const Icon(Icons.add_circle_outline),
              label: Text(appText(AppText.addQuestionButton)),
            ),
          ),
        ],
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
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBF0),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFFFE0A3)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 640;
          final selector = quizzes.isNotEmpty
              ? DropdownButton<int>(
                  value: selectedQuizId,
                  isExpanded: true,
                  items: quizzes.map((rawQuiz) {
                    final quiz = mapOrNull(rawQuiz) ?? <String, dynamic>{};
                    final quizId = asInt(quiz['id'], 0);
                    final quizTitle = quiz['title']?.toString() ??
                        appText(AppText.untitledQuiz);
                    return DropdownMenuItem<int>(
                      value: quizId,
                      child: Text('$quizId: $quizTitle'),
                    );
                  }).toList(),
                  onChanged: onSelectedQuizChanged,
                )
              : Text(appText(AppText.noQuizzesYet));
          final button = FilledButton.tonalIcon(
            onPressed: loading || !isLoggedIn || selectedQuizId == null
                ? null
                : onLoadSelectedQuiz,
            icon: const Icon(Icons.download_for_offline_outlined),
            label: Text(appText(AppText.loadButton)),
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                selector,
                const SizedBox(height: 10),
                button,
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: selector),
              const SizedBox(width: 12),
              button,
            ],
          );
        },
      ),
    );
  }
}
