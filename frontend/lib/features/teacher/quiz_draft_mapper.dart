import '../../core/value_utils.dart';
import 'quiz_draft.dart';

class QuizDraftData {
  const QuizDraftData({
    required this.quizId,
    required this.contentRevision,
    required this.title,
    required this.description,
    required this.displaySettings,
    required this.questions,
  });

  final int? quizId;
  final int? contentRevision;
  final String title;
  final String description;
  final QuizDisplaySettings displaySettings;
  final List<QuizDraftQuestion> questions;
}

class QuizDraftMapper {
  const QuizDraftMapper();

  QuizDraftQuestion createQuestion({
    int? id,
    String text = '',
    int timeLimitSec = 20,
    List<QuizDraftChoice>? choices,
  }) {
    final resolvedChoices = choices ??
        [
          QuizDraftChoice(isCorrect: true),
          QuizDraftChoice(),
          QuizDraftChoice(),
          QuizDraftChoice(),
        ];

    if (resolvedChoices.isNotEmpty &&
        !resolvedChoices.any((choice) => choice.isCorrect)) {
      resolvedChoices.first.isCorrect = true;
    }

    return QuizDraftQuestion(
      id: id,
      text: text,
      timeLimitSec: timeLimitSec,
      choices: resolvedChoices,
    );
  }

  QuizDraftData fromMap(Map<String, dynamic> quiz) {
    final parsedQuizId = asInt(quiz['id'], -1);
    final questions = <QuizDraftQuestion>[];
    final questionMaps = ((quiz['questions'] as List<dynamic>? ?? <dynamic>[])
        .map(mapOrNull)
        .whereType<Map<String, dynamic>>()
        .toList())
      ..sort((a, b) => asInt(a['order']).compareTo(asInt(b['order'])));

    for (final questionMap in questionMaps) {
      final choiceMaps = ((questionMap['choices'] as List<dynamic>? ??
              <dynamic>[])
          .map(mapOrNull)
          .whereType<Map<String, dynamic>>()
          .toList())
        ..sort(
          (a, b) => asInt(a['order']).compareTo(asInt(b['order'])),
        );

      final draftChoices = choiceMaps
          .map(
            (choice) => QuizDraftChoice(
              id: asInt(choice['id'], -1) > 0 ? asInt(choice['id'], -1) : null,
              text: choice['text']?.toString() ?? '',
              isCorrect: choice['is_correct'] == true,
            ),
          )
          .toList();

      while (draftChoices.length < 2) {
        draftChoices.add(QuizDraftChoice());
      }

      questions.add(
        createQuestion(
          id: asInt(questionMap['id'], -1) > 0
              ? asInt(questionMap['id'], -1)
              : null,
          text: questionMap['text']?.toString() ?? '',
          timeLimitSec: asInt(questionMap['time_limit_sec'], 20),
          choices: draftChoices,
        ),
      );
    }

    if (questions.isEmpty) {
      questions.add(createQuestion());
    }

    return QuizDraftData(
      quizId: parsedQuizId > 0 ? parsedQuizId : null,
      contentRevision: asInt(quiz['content_revision'], -1) > 0
          ? asInt(quiz['content_revision'], -1)
          : null,
      title: quiz['title']?.toString() ?? '',
      description: quiz['description']?.toString() ?? '',
      displaySettings: QuizDisplaySettings(
        questionOnlyOnDisplay: quiz['question_only_on_display'] == true,
        showChoicesOnParticipant: quiz['show_choices_on_participant'] != false,
        readingTimeSec: asInt(quiz['reading_time_sec'], 15),
        resultsTimeSec: asInt(quiz['results_time_sec'], 10),
      ),
      questions: questions,
    );
  }

  Map<String, dynamic> toPayload({
    int? contentRevision,
    required String title,
    required String description,
    required QuizDisplaySettings displaySettings,
    required List<QuizDraftQuestion> questions,
  }) {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) {
      throw const FormatException('Quiz title is required.');
    }

    if (questions.isEmpty) {
      throw const FormatException('Add at least one question.');
    }

    if (displaySettings.readingTimeSec < 3 ||
        displaySettings.readingTimeSec > 120) {
      throw const FormatException(
          'Reading time must be between 3 and 120 seconds.');
    }
    if (displaySettings.resultsTimeSec < 3 ||
        displaySettings.resultsTimeSec > 60) {
      throw const FormatException(
          'Results time must be between 3 and 60 seconds.');
    }

    final payloadQuestions = <Map<String, dynamic>>[];

    for (final questionEntry in questions.asMap().entries) {
      final questionIndex = questionEntry.key;
      final question = questionEntry.value;
      final questionNumber = questionIndex + 1;
      final questionText = question.textController.text.trim();
      if (questionText.isEmpty) {
        throw FormatException('Question $questionNumber text is required.');
      }

      final timeLimit = int.tryParse(question.timeLimitController.text.trim());
      if (timeLimit == null || timeLimit < 5 || timeLimit > 180) {
        throw FormatException(
          'Question $questionNumber time limit must be between 5 and 180 seconds.',
        );
      }

      final choices = <Map<String, dynamic>>[];
      var correctCount = 0;

      for (final choice in question.choices) {
        final choiceText = choice.textController.text.trim();
        if (choiceText.isEmpty) {
          continue;
        }

        if (choice.isCorrect) {
          correctCount += 1;
        }

        choices.add({
          if (choice.id != null) 'id': choice.id,
          'text': choiceText,
          'order': choices.length + 1,
          'is_correct': choice.isCorrect,
        });
      }

      if (choices.length < 2) {
        throw FormatException(
          'Question $questionNumber must have at least two non-empty choices.',
        );
      }
      if (correctCount != 1) {
        throw FormatException(
          'Question $questionNumber must have exactly one correct choice.',
        );
      }

      payloadQuestions.add({
        if (question.id != null) 'id': question.id,
        'text': questionText,
        'order': questionNumber,
        'time_limit_sec': timeLimit,
        'choices': choices,
      });
    }

    return {
      if (contentRevision != null) 'content_revision': contentRevision,
      'title': trimmedTitle,
      'description': description.trim(),
      'question_only_on_display': displaySettings.questionOnlyOnDisplay,
      'show_choices_on_participant': displaySettings.showChoicesOnParticipant,
      'reading_time_sec': displaySettings.readingTimeSec,
      'results_time_sec': displaySettings.resultsTimeSec,
      'questions': payloadQuestions,
    };
  }
}
