import 'package:flutter/material.dart';

import '../../../core/value_utils.dart';
import '../../../l10n/app_strings.dart';
import '../../../shared/widgets/app_surfaces.dart';
import '../quiz_draft.dart';
import 'teacher_quiz_question_card.dart';

class TeacherQuizBuilderCard extends StatefulWidget {
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
  State<TeacherQuizBuilderCard> createState() => _TeacherQuizBuilderCardState();
}

class _TeacherQuizBuilderCardState extends State<TeacherQuizBuilderCard> {
  int _selectedQuestionIndex = 0;

  @override
  void didUpdateWidget(covariant TeacherQuizBuilderCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.questions.isEmpty) {
      _selectedQuestionIndex = 0;
      return;
    }
    if (_selectedQuestionIndex >= widget.questions.length) {
      _selectedQuestionIndex = widget.questions.length - 1;
    }
  }

  int get _activeQuestionIndex {
    if (widget.questions.isEmpty) return 0;
    return _selectedQuestionIndex.clamp(0, widget.questions.length - 1);
  }

  void _selectQuestion(int index) {
    if (index < 0 || index >= widget.questions.length) return;
    setState(() {
      _selectedQuestionIndex = index;
    });
  }

  void _addQuestionAndSelect() {
    final nextQuestionIndex = widget.questions.length;
    widget.onAddQuestion();
    setState(() {
      _selectedQuestionIndex = nextQuestionIndex;
    });
  }

  void _removeQuestionAndKeepContext(int questionIndex) {
    widget.onRemoveQuestion(questionIndex);
    setState(() {
      if (_selectedQuestionIndex > 0 &&
          questionIndex <= _selectedQuestionIndex) {
        _selectedQuestionIndex -= 1;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final canUseTeacherApi = !widget.loading && widget.isLoggedIn;
    final activeQuestionIndex = _activeQuestionIndex;
    final activeQuestion =
        widget.questions.isEmpty ? null : widget.questions[activeQuestionIndex];

    return AppSectionCard(
      padding: const EdgeInsets.all(16),
      borderRadius: 32,
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _BuilderHeader(
            editingQuizId: widget.editingQuizId,
            questionsCount: widget.questions.length,
          ),
          const SizedBox(height: 16),
          _QuizSelectorRow(
            quizzes: widget.quizzes,
            selectedQuizId: widget.selectedQuizId,
            loading: widget.loading,
            isLoggedIn: widget.isLoggedIn,
            onSelectedQuizChanged: widget.onSelectedQuizChanged,
            onLoadSelectedQuiz: widget.onLoadSelectedQuiz,
          ),
          const SizedBox(height: 12),
          _BuilderActions(
            canUseTeacherApi: canUseTeacherApi,
            hasSelectedQuiz: widget.selectedQuizId != null,
            editingQuizId: widget.editingQuizId,
            onSaveQuiz: widget.onSaveQuiz,
            onResetDraft: widget.onResetDraft,
            onRefreshQuizzes: widget.onRefreshQuizzes,
            onDeleteSelectedQuiz: widget.onDeleteSelectedQuiz,
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 860;
              final rail = _QuestionRail(
                questions: widget.questions,
                selectedQuestionIndex: activeQuestionIndex,
                onSelectQuestion: _selectQuestion,
                onAddQuestion: canUseTeacherApi ? _addQuestionAndSelect : null,
              );
              final editor = _QuizEditor(
                titleController: widget.titleController,
                descriptionController: widget.descriptionController,
                question: activeQuestion,
                questionIndex: activeQuestionIndex,
                loading: widget.loading,
                onRemoveQuestion: _removeQuestionAndKeepContext,
                onSetCorrectChoice: widget.onSetCorrectChoice,
                onRemoveChoice: widget.onRemoveChoice,
                onAddChoice: widget.onAddChoice,
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
    required this.selectedQuestionIndex,
    required this.onSelectQuestion,
    required this.onAddQuestion,
  });

  final List<QuizDraftQuestion> questions;
  final int selectedQuestionIndex;
  final ValueChanged<int> onSelectQuestion;
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
            _QuestionRailItem(
              index: entry.key,
              question: entry.value,
              selected: entry.key == selectedQuestionIndex,
              onTap: () => onSelectQuestion(entry.key),
            ),
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
    required this.selected,
    required this.onTap,
  });

  final int index;
  final QuizDraftQuestion question;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: question.textController,
      builder: (context, _) {
        final title = question.textController.text.trim();

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: selected ? const Color(0xFFE0F2F1) : Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: selected
                      ? const Color(0xFF80CBC4)
                      : const Color(0xFFDDEBE9),
                  width: selected ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 15,
                    backgroundColor: selected
                        ? const Color(0xFF00796B)
                        : const Color(0xFFEAF4F2),
                    foregroundColor:
                        selected ? Colors.white : const Color(0xFF31524F),
                    child: Text('${index + 1}'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title.isEmpty
                          ? appText(
                              AppText.questionNumber,
                              args: {'number': index + 1},
                            )
                          : title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight:
                            selected ? FontWeight.w800 : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _QuizEditor extends StatelessWidget {
  const _QuizEditor({
    required this.titleController,
    required this.descriptionController,
    required this.question,
    required this.questionIndex,
    required this.loading,
    required this.onRemoveQuestion,
    required this.onSetCorrectChoice,
    required this.onRemoveChoice,
    required this.onAddChoice,
  });

  final TextEditingController titleController;
  final TextEditingController descriptionController;
  final QuizDraftQuestion? question;
  final int questionIndex;
  final bool loading;
  final ValueChanged<int> onRemoveQuestion;
  final void Function(QuizDraftQuestion question, int choiceIndex)
      onSetCorrectChoice;
  final void Function(QuizDraftQuestion question, int choiceIndex)
      onRemoveChoice;
  final ValueChanged<QuizDraftQuestion> onAddChoice;

  @override
  Widget build(BuildContext context) {
    final activeQuestion = question;

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
          if (activeQuestion == null)
            AppSectionCard(
              color: const Color(0xFFFFF8E1),
              child: Text(appText(AppText.noQuizzesYet)),
            )
          else
            TeacherQuizQuestionCard(
              question: activeQuestion,
              questionIndex: questionIndex,
              loading: loading,
              onRemoveQuestion: () => onRemoveQuestion(questionIndex),
              onSetCorrectChoice: (choiceIndex) =>
                  onSetCorrectChoice(activeQuestion, choiceIndex),
              onRemoveChoice: (choiceIndex) =>
                  onRemoveChoice(activeQuestion, choiceIndex),
              onAddChoice: () => onAddChoice(activeQuestion),
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
