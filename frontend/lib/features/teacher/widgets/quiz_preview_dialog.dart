import 'package:flutter/material.dart';

import '../../../core/value_utils.dart';
import '../../../l10n/app_strings.dart';

enum QuizPreviewScreen { audience, participant }

enum QuizPreviewPhase { reading, answering, results }

class QuizPreviewDialog extends StatefulWidget {
  const QuizPreviewDialog({super.key, required this.quiz});

  final Map<String, dynamic> quiz;

  @override
  State<QuizPreviewDialog> createState() => _QuizPreviewDialogState();
}

class _QuizPreviewDialogState extends State<QuizPreviewDialog> {
  int _questionIndex = 0;
  QuizPreviewScreen _screen = QuizPreviewScreen.audience;
  QuizPreviewPhase _phase = QuizPreviewPhase.reading;

  List<Map<String, dynamic>> get _questions {
    final result = (widget.quiz['questions'] as List<dynamic>? ?? <dynamic>[])
        .map(mapOrNull)
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    result.sort((a, b) => asInt(a['order']).compareTo(asInt(b['order'])));
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final questions = _questions;
    final currentIndex =
        questions.isEmpty ? 0 : _questionIndex.clamp(0, questions.length - 1);
    final question =
        questions.isEmpty ? const <String, dynamic>{} : questions[currentIndex];

    return Dialog.fullscreen(
      key: const ValueKey('quiz-preview-dialog'),
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const ValueKey('quiz-preview-close'),
            tooltip: appText(AppText.quizPreviewCloseButton),
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(appText(AppText.quizPreviewTitle)),
              Text(
                widget.quiz['title']?.toString() ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PreviewNotice(description: widget.quiz['description']),
                const SizedBox(height: 14),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final useFullWidthControls = constraints.maxWidth < 720;
                    final controlWidth =
                        useFullWidthControls ? constraints.maxWidth : null;
                    return Wrap(
                      spacing: 16,
                      runSpacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: useFullWidthControls ? controlWidth : 260,
                          child: DropdownButtonFormField<int>(
                            key: const ValueKey(
                              'quiz-preview-question-picker',
                            ),
                            initialValue: currentIndex,
                            decoration: InputDecoration(
                              labelText:
                                  appText(AppText.quizPreviewQuestionPicker),
                            ),
                            items: [
                              for (var index = 0;
                                  index < questions.length;
                                  index += 1)
                                DropdownMenuItem(
                                  value: index,
                                  child: Text(
                                    appText(
                                      AppText.questionNumber,
                                      args: {'number': index + 1},
                                    ),
                                  ),
                                ),
                            ],
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() => _questionIndex = value);
                            },
                          ),
                        ),
                        SizedBox(
                          width: controlWidth,
                          child: _PreviewScreenSelector(
                            value: _screen,
                            onChanged: (value) =>
                                setState(() => _screen = value),
                          ),
                        ),
                        SizedBox(
                          width: controlWidth,
                          child: _PreviewPhaseSelector(
                            value: _phase,
                            onChanged: (value) =>
                                setState(() => _phase = value),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: QuizPreviewViewport(
                    quiz: widget.quiz,
                    question: question,
                    screen: _screen,
                    phase: _phase,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewNotice extends StatelessWidget {
  const _PreviewNotice({required this.description});

  final Object? description;

  @override
  Widget build(BuildContext context) {
    final descriptionText = description?.toString().trim() ?? '';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          const Icon(Icons.visibility_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  appText(AppText.quizPreviewModeBadge),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                Text(appText(AppText.quizPreviewModeNotice)),
                if (descriptionText.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 96),
                    child: SingleChildScrollView(
                      key: const ValueKey('quiz-preview-description-scroll'),
                      child: Text(descriptionText),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewScreenSelector extends StatelessWidget {
  const _PreviewScreenSelector({
    required this.value,
    required this.onChanged,
  });

  final QuizPreviewScreen value;
  final ValueChanged<QuizPreviewScreen> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SegmentedButton<QuizPreviewScreen>(
        key: const ValueKey('quiz-preview-screen-selector'),
        showSelectedIcon: false,
        segments: [
          ButtonSegment(
            value: QuizPreviewScreen.audience,
            icon: const Icon(Icons.connected_tv_outlined),
            label: Text(appText(AppText.quizPreviewAudienceScreen)),
          ),
          ButtonSegment(
            value: QuizPreviewScreen.participant,
            icon: const Icon(Icons.smartphone_outlined),
            label: Text(appText(AppText.quizPreviewParticipantScreen)),
          ),
        ],
        selected: {value},
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

class _PreviewPhaseSelector extends StatelessWidget {
  const _PreviewPhaseSelector({
    required this.value,
    required this.onChanged,
  });

  final QuizPreviewPhase value;
  final ValueChanged<QuizPreviewPhase> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SegmentedButton<QuizPreviewPhase>(
        key: const ValueKey('quiz-preview-phase-selector'),
        showSelectedIcon: false,
        segments: [
          ButtonSegment(
            value: QuizPreviewPhase.reading,
            label: Text(appText(AppText.quizPreviewReadingState)),
          ),
          ButtonSegment(
            value: QuizPreviewPhase.answering,
            label: Text(appText(AppText.quizPreviewAnsweringState)),
          ),
          ButtonSegment(
            value: QuizPreviewPhase.results,
            label: Text(appText(AppText.quizPreviewResultsState)),
          ),
        ],
        selected: {value},
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

class QuizPreviewViewport extends StatelessWidget {
  const QuizPreviewViewport({
    super.key,
    required this.quiz,
    required this.question,
    required this.screen,
    required this.phase,
  });

  final Map<String, dynamic> quiz;
  final Map<String, dynamic> question;
  final QuizPreviewScreen screen;
  final QuizPreviewPhase phase;

  static const _audienceChoiceColors = [
    Color(0xFFE21B3C),
    Color(0xFF1368CE),
    Color(0xFFD89E00),
    Color(0xFF26890C),
    Color(0xFF8E24AA),
    Color(0xFF00ACC1),
  ];

  static const _audienceChoiceIcons = [
    Icons.change_history,
    Icons.diamond_outlined,
    Icons.circle_outlined,
    Icons.square_outlined,
    Icons.star_border_rounded,
    Icons.hexagon_outlined,
  ];

  static const _participantChoiceColors = [
    Color(0xFFE21B3C),
    Color(0xFF1368CE),
    Color(0xFFD89E00),
    Color(0xFF26890C),
  ];

  static const _participantChoiceIcons = [
    Icons.change_history,
    Icons.diamond_outlined,
    Icons.circle_outlined,
    Icons.square_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final questionOnlyOnDisplay = quiz['question_only_on_display'] == true;
    final showChoicesOnParticipant =
        quiz['show_choices_on_participant'] != false;
    final participantReading = screen == QuizPreviewScreen.participant &&
        phase == QuizPreviewPhase.reading;
    final questionHidden = screen == QuizPreviewScreen.participant &&
        questionOnlyOnDisplay &&
        phase != QuizPreviewPhase.reading;
    final showChoices = phase != QuizPreviewPhase.reading;
    final revealCorrect = phase == QuizPreviewPhase.results;
    final choices = (question['choices'] as List<dynamic>? ?? <dynamic>[])
        .map(mapOrNull)
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    choices.sort((a, b) => asInt(a['order']).compareTo(asInt(b['order'])));
    final choiceColors = screen == QuizPreviewScreen.audience
        ? _audienceChoiceColors
        : _participantChoiceColors;
    final choiceIcons = screen == QuizPreviewScreen.audience
        ? _audienceChoiceIcons
        : _participantChoiceIcons;

    return Container(
      key: const ValueKey('quiz-preview-viewport'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F766E), Color(0xFF023047)],
        ),
      ),
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                _PreviewChip(label: appText(AppText.quizPreviewModeBadge)),
                _PreviewChip(
                  label: appText(
                    screen == QuizPreviewScreen.audience
                        ? AppText.quizPreviewAudienceScreen
                        : AppText.quizPreviewParticipantScreen,
                  ),
                ),
                _PreviewChip(
                  label: appText(
                    switch (phase) {
                      QuizPreviewPhase.reading =>
                        AppText.quizPreviewReadingState,
                      QuizPreviewPhase.answering =>
                        AppText.quizPreviewAnsweringState,
                      QuizPreviewPhase.results =>
                        AppText.quizPreviewResultsState,
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (participantReading)
              _PreviewMessage(
                key: const ValueKey('quiz-preview-participant-reading'),
                icon: Icons.connected_tv_outlined,
                text: appText(AppText.quizPreviewParticipantReadingMessage),
              )
            else ...[
              if (questionHidden)
                _PreviewMessage(
                  key: const ValueKey('quiz-preview-question-hidden'),
                  icon: Icons.connected_tv_outlined,
                  text: appText(AppText.quizPreviewQuestionHiddenMessage),
                )
              else
                Text(
                  question['text']?.toString() ?? '',
                  key: const ValueKey('quiz-preview-question-text'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                ),
              if (showChoices) ...[
                const SizedBox(height: 24),
                Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    for (final entry in choices.asMap().entries)
                      _PreviewChoice(
                        key: ValueKey(
                          'quiz-preview-choice-${entry.key + 1}',
                        ),
                        number: entry.key + 1,
                        choice: entry.value,
                        color: choiceColors[entry.key % choiceColors.length],
                        icon: choiceIcons[entry.key % choiceIcons.length],
                        showText: screen == QuizPreviewScreen.audience ||
                            showChoicesOnParticipant,
                        revealCorrect: revealCorrect,
                      ),
                  ],
                ),
                if (phase == QuizPreviewPhase.answering) ...[
                  const SizedBox(height: 18),
                  Text(
                    appText(AppText.quizPreviewNoAnswersNotice),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.82),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _PreviewChip extends StatelessWidget {
  const _PreviewChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _PreviewMessage extends StatelessWidget {
  const _PreviewMessage({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          Icon(icon, color: Colors.white, size: 48),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
          ),
        ],
      ),
    );
  }
}

class _PreviewChoice extends StatelessWidget {
  const _PreviewChoice({
    super.key,
    required this.number,
    required this.choice,
    required this.color,
    required this.icon,
    required this.showText,
    required this.revealCorrect,
  });

  final int number;
  final Map<String, dynamic> choice;
  final Color color;
  final IconData icon;
  final bool showText;
  final bool revealCorrect;

  @override
  Widget build(BuildContext context) {
    final isCorrect = choice['is_correct'] == true;
    final label = showText
        ? choice['text']?.toString() ?? ''
        : appText(AppText.choiceNumber, args: {'number': number});
    final highlightCorrect = revealCorrect && isCorrect;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 250, maxWidth: 520),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: highlightCorrect ? const Color(0xFF16A34A) : color,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: highlightCorrect
                ? const Color(0xFFB9FBC0)
                : Colors.white.withValues(alpha: 0.2),
            width: highlightCorrect ? 4 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              highlightCorrect ? Icons.check_rounded : icon,
              color: Colors.white,
              size: 34,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                    ),
              ),
            ),
            if (highlightCorrect)
              Text(
                appText(AppText.quizPreviewCorrectChoice),
                key: ValueKey('quiz-preview-correct-choice-$number'),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
