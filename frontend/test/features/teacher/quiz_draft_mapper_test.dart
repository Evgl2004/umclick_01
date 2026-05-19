import 'package:flutter_test/flutter_test.dart';
import 'package:umclick_frontend/features/teacher/quiz_draft.dart';
import 'package:umclick_frontend/features/teacher/quiz_draft_mapper.dart';

void main() {
  const mapper = QuizDraftMapper();

  group('QuizDraftMapper.fromMap', () {
    test('sorts questions and choices by order', () {
      final data = mapper.fromMap({
        'id': 7,
        'title': 'History quiz',
        'description': 'Warm-up',
        'questions': [
          {
            'text': 'Second question',
            'order': 2,
            'time_limit_sec': 45,
            'choices': [
              {'text': 'B', 'order': 2, 'is_correct': false},
              {'text': 'A', 'order': 1, 'is_correct': true},
            ],
          },
          {
            'text': 'First question',
            'order': 1,
            'time_limit_sec': 20,
            'choices': [
              {'text': 'No', 'order': 2, 'is_correct': false},
              {'text': 'Yes', 'order': 1, 'is_correct': true},
            ],
          },
        ],
      });
      addTearDown(() {
        for (final question in data.questions) {
          question.dispose();
        }
      });

      expect(data.quizId, 7);
      expect(data.title, 'History quiz');
      expect(data.description, 'Warm-up');
      expect(data.displaySettings.readingTimeSec, 15);
      expect(data.displaySettings.resultsTimeSec, 10);
      expect(data.displaySettings.questionOnlyOnDisplay, isFalse);
      expect(data.displaySettings.showChoicesOnParticipant, isTrue);
      expect(data.questions.first.textController.text, 'First question');
      expect(data.questions.first.choices.first.textController.text, 'Yes');
      expect(data.questions.last.textController.text, 'Second question');
      expect(data.questions.last.choices.first.textController.text, 'A');
    });

    test('creates a default question when API returns an empty quiz', () {
      final data = mapper.fromMap({
        'id': null,
        'title': 'Draft',
        'questions': [],
      });
      addTearDown(() {
        for (final question in data.questions) {
          question.dispose();
        }
      });

      expect(data.quizId, isNull);
      expect(data.questions, hasLength(1));
      expect(data.questions.single.choices, hasLength(4));
      expect(data.questions.single.choices.first.isCorrect, isTrue);
    });

    test('ensures at least two choices for imported questions', () {
      final data = mapper.fromMap({
        'questions': [
          {
            'text': 'Question',
            'choices': [
              {'text': 'Only choice', 'is_correct': true},
            ],
          },
        ],
      });
      addTearDown(() {
        for (final question in data.questions) {
          question.dispose();
        }
      });

      expect(data.questions.single.choices, hasLength(2));
      expect(data.questions.single.choices.first.isCorrect, isTrue);
    });
  });

  group('QuizDraftMapper.toPayload', () {
    test('trims text and creates ordered API payload', () {
      final question = mapper.createQuestion(
        text: '  2 + 2? ',
        timeLimitSec: 30,
        choices: [
          QuizDraftChoice(text: ' 4 ', isCorrect: true),
          QuizDraftChoice(text: ' 3 '),
          QuizDraftChoice(text: ' '),
        ],
      );
      addTearDown(question.dispose);

      final payload = mapper.toPayload(
        title: ' Math ',
        description: ' Warm-up ',
        displaySettings: const QuizDisplaySettings(
          questionOnlyOnDisplay: true,
          showChoicesOnParticipant: false,
          readingTimeSec: 12,
          resultsTimeSec: 8,
        ),
        questions: [question],
      );

      expect(payload, {
        'title': 'Math',
        'description': 'Warm-up',
        'question_only_on_display': true,
        'show_choices_on_participant': false,
        'reading_time_sec': 12,
        'results_time_sec': 8,
        'questions': [
          {
            'text': '2 + 2?',
            'order': 1,
            'time_limit_sec': 30,
            'choices': [
              {'text': '4', 'order': 1, 'is_correct': true},
              {'text': '3', 'order': 2, 'is_correct': false},
            ],
          },
        ],
      });
    });

    test('requires a non-empty quiz title', () {
      expect(
        () => mapper.toPayload(
          title: ' ',
          description: '',
          displaySettings: const QuizDisplaySettings(),
          questions: [mapper.createQuestion()],
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('requires exactly one correct non-empty choice', () {
      final question = mapper.createQuestion(
        text: 'Pick one',
        choices: [
          QuizDraftChoice(text: 'A', isCorrect: true),
          QuizDraftChoice(text: 'B', isCorrect: true),
        ],
      );
      addTearDown(question.dispose);

      expect(
        () => mapper.toPayload(
          title: 'Quiz',
          description: '',
          displaySettings: const QuizDisplaySettings(),
          questions: [question],
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('exactly one correct choice'),
          ),
        ),
      );
    });

    test('validates question time limits', () {
      final question = mapper.createQuestion(
        text: 'Too fast?',
        timeLimitSec: 4,
        choices: [
          QuizDraftChoice(text: 'Yes', isCorrect: true),
          QuizDraftChoice(text: 'No'),
        ],
      );
      addTearDown(question.dispose);

      expect(
        () => mapper.toPayload(
          title: 'Quiz',
          description: '',
          displaySettings: const QuizDisplaySettings(),
          questions: [question],
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('between 5 and 180 seconds'),
          ),
        ),
      );
    });
  });
}
