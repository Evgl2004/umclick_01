import '../../core/value_utils.dart';
import 'quiz_draft.dart';

class QuizDraftData {
  const QuizDraftData({
    required this.quizId,
    required this.title,
    required this.description,
    required this.questions,
  });

  final int? quizId;
  final String title;
  final String description;
  final List<QuizDraftQuestion> questions;
}

class QuizDraftMapper {
  const QuizDraftMapper();

  QuizDraftQuestion createQuestion({
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
      final choiceMaps =
          ((questionMap['choices'] as List<dynamic>? ?? <dynamic>[])
              .map(mapOrNull)
              .whereType<Map<String, dynamic>>()
              .toList())
            ..sort(
              (a, b) => asInt(a['order']).compareTo(asInt(b['order'])),
            );

      final draftChoices = choiceMaps
          .map(
            (choice) => QuizDraftChoice(
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
      title: quiz['title']?.toString() ?? '',
      description: quiz['description']?.toString() ?? '',
      questions: questions,
    );
  }

  Map<String, dynamic> toPayload({
    required String title,
    required String description,
    required List<QuizDraftQuestion> questions,
  }) {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) {
      throw const FormatException('Quiz title is required.');
    }

    if (questions.isEmpty) {
      throw const FormatException('Add at least one question.');
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
        'text': questionText,
        'order': questionNumber,
        'time_limit_sec': timeLimit,
        'choices': choices,
      });
    }

    return {
      'title': trimmedTitle,
      'description': description.trim(),
      'questions': payloadQuestions,
    };
  }
}
