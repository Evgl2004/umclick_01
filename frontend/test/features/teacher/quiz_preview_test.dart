import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:umclick_frontend/api/api_client.dart';
import 'package:umclick_frontend/core/app_config.dart';
import 'package:umclick_frontend/features/teacher/teacher_panel.dart';
import 'package:umclick_frontend/features/teacher/widgets/quiz_preview_dialog.dart';
import 'package:umclick_frontend/features/teacher/widgets/teacher_quiz_builder_card.dart';
import 'package:umclick_frontend/l10n/app_language.dart';
import 'package:umclick_frontend/l10n/app_strings.dart';

void main() {
  http.Response jsonResponse(Object body, {int statusCode = 200}) {
    return http.Response(
      jsonEncode(body),
      statusCode,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  Finder fieldWithLabel(String label) {
    return find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );
  }

  Future<void> pumpAuthenticatedPanel(
    WidgetTester tester,
    MockClient transport, {
    bool loadSelectedQuiz = false,
    UiLanguage language = UiLanguage.en,
    Size surfaceSize = const Size(1600, 3000),
  }) async {
    SharedPreferences.setMockInitialValues({
      prefsAccessTokenKey: 'test-access-token',
      prefsApiBaseUrlKey: 'http://test.local/api',
    });
    appLanguage.value = language;
    await tester.binding.setSurfaceSize(surfaceSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TeacherPanel(
            apiClientFactory: (baseUrl, {accessToken}) => ApiClient(
              baseUrl,
              accessToken: accessToken,
              httpClient: transport,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TeacherQuizBuilderCard), findsOneWidget);
    if (!loadSelectedQuiz) return;
    await tester.ensureVisible(find.text('Load'));
    await tester.tap(find.text('Load'));
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> storedQuiz() {
    return {
      'id': 7,
      'title': 'Saved title',
      'description': 'Saved description',
      'question_only_on_display': true,
      'show_choices_on_participant': false,
      'reading_time_sec': 18,
      'results_time_sec': 9,
      'content_revision': 4,
      'archived_at': null,
      'can_delete': true,
      'questions': [
        {
          'id': 11,
          'text': 'Saved question',
          'order': 1,
          'time_limit_sec': 25,
          'choices': [
            {
              'id': 21,
              'text': 'Correct A',
              'order': 1,
              'is_correct': true,
            },
            {
              'id': 22,
              'text': 'Wrong B',
              'order': 2,
              'is_correct': false,
            },
          ],
        },
      ],
    };
  }

  setUp(() {
    appLanguage.value = UiLanguage.en;
  });

  testWidgets('новая валидная форма открывает локальный предпросмотр без POST',
      (tester) async {
    final requests = <http.Request>[];
    final transport = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET' && request.url.path == '/api/auth/me/') {
        return jsonResponse({'id': 1, 'username': 'teacher'});
      }
      if (request.method == 'GET' && request.url.path == '/api/quizzes/') {
        return jsonResponse([]);
      }
      if (request.method == 'GET' && request.url.path == '/api/sessions/') {
        return jsonResponse([]);
      }
      return jsonResponse({'detail': 'Сетевой вызов не ожидался.'},
          statusCode: 500);
    });

    await pumpAuthenticatedPanel(tester, transport);
    await tester.enterText(
        fieldWithLabel('Quiz title'), '  New unsaved quiz  ');
    await tester.enterText(
        fieldWithLabel('Question text'), '  What is 2 + 2?  ');
    await tester.enterText(fieldWithLabel('Choice 1'), '  Four  ');
    await tester.enterText(fieldWithLabel('Choice 2'), 'Three');
    final requestsBeforePreview = requests.length;

    await tester.ensureVisible(find.text('Preview'));
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    expect(find.byType(QuizPreviewDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(QuizPreviewDialog),
        matching: find.text('New unsaved quiz'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('quiz-preview-question-text')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('quiz-preview-question-text')),
          )
          .data,
      'What is 2 + 2?',
    );
    await tester.tap(find.text('Answering'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('quiz-preview-choice-1')),
        matching: find.text('Four'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('quiz-preview-choice-2')),
        matching: find.text('Three'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('quiz-preview-choice-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('quiz-preview-choice-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('quiz-preview-choice-3')), findsNothing);
    expect(requests, hasLength(requestsBeforePreview));
    expect(requests.where((request) => request.method == 'POST'), isEmpty);

    await tester.tap(find.byKey(const ValueKey('quiz-preview-close')));
    await tester.pumpAndSettle();
    expect(find.byType(QuizPreviewDialog), findsNothing);
    expect(
      tester.widget<TextField>(fieldWithLabel('Quiz title')).controller!.text,
      '  New unsaved quiz  ',
    );
    expect(requests, hasLength(requestsBeforePreview));
  });

  testWidgets('невалидная форма не открывается и сохраняет введённые данные',
      (tester) async {
    final requests = <http.Request>[];
    final transport = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET' && request.url.path == '/api/auth/me/') {
        return jsonResponse({'id': 1, 'username': 'teacher'});
      }
      if (request.method == 'GET' && request.url.path == '/api/quizzes/') {
        return jsonResponse([]);
      }
      if (request.method == 'GET' && request.url.path == '/api/sessions/') {
        return jsonResponse([]);
      }
      return jsonResponse({'detail': 'Сетевой вызов не ожидался.'},
          statusCode: 500);
    });

    await pumpAuthenticatedPanel(tester, transport);
    await tester.enterText(fieldWithLabel('Question text'), 'Unsent question');
    final requestsBeforePreview = requests.length;

    await tester.ensureVisible(find.text('Preview'));
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    expect(find.byType(QuizPreviewDialog), findsNothing);
    expect(find.text('Quiz title is required.'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(fieldWithLabel('Question text'))
          .controller!
          .text,
      'Unsent question',
    );
    expect(requests, hasLength(requestsBeforePreview));
  });

  testWidgets(
      'длинное русское описание не перекрывает управление и сохраняется после закрытия',
      (tester) async {
    final longDescription = List.generate(
      40,
      (index) => 'Строка описания ${index + 1}',
    ).join('\n');
    final transport = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/auth/me/') {
        return jsonResponse({'id': 1, 'username': 'teacher'});
      }
      if (request.method == 'GET' && request.url.path == '/api/quizzes/') {
        return jsonResponse([]);
      }
      if (request.method == 'GET' && request.url.path == '/api/sessions/') {
        return jsonResponse([]);
      }
      return jsonResponse({'detail': 'Сетевой вызов не ожидался.'},
          statusCode: 500);
    });

    await pumpAuthenticatedPanel(
      tester,
      transport,
      language: UiLanguage.ru,
      surfaceSize: const Size(1280, 720),
    );

    Future<void> enterField(AppText label, String value) async {
      final field = fieldWithLabel(appText(label));
      await tester.ensureVisible(field);
      await tester.enterText(field, value);
    }

    Future<void> enterChoice(int number, String value) async {
      final field = fieldWithLabel(
        appText(AppText.choiceNumber, args: {'number': number}),
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, value);
    }

    await enterField(AppText.quizTitleLabel, 'Викторина с описанием');
    await enterField(AppText.quizDescriptionOptionalLabel, longDescription);
    await enterField(AppText.questionTextLabel, 'Первый вопрос');
    await enterChoice(1, 'Первый вариант');
    await enterChoice(2, 'Второй вариант');

    await tester.ensureVisible(find.text(appText(AppText.addQuestionButton)));
    await tester.tap(find.text(appText(AppText.addQuestionButton)));
    await tester.pumpAndSettle();
    await enterField(AppText.questionTextLabel, 'Второй вопрос');
    await enterChoice(1, 'Третий вариант');
    await enterChoice(2, 'Четвёртый вариант');

    await tester.ensureVisible(find.text(appText(AppText.quizPreviewButton)));
    await tester.tap(find.text(appText(AppText.quizPreviewButton)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester
        .tap(find.byKey(const ValueKey('quiz-preview-question-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Вопрос 2').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(appText(AppText.quizPreviewParticipantScreen)));
    await tester.tap(find.text(appText(AppText.quizPreviewAnsweringState)));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('quiz-preview-question-text')),
          )
          .data,
      'Второй вопрос',
    );
    await tester.tap(find.byKey(const ValueKey('quiz-preview-close')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(
            fieldWithLabel(appText(AppText.quizDescriptionOptionalLabel)),
          )
          .controller!
          .text,
      longDescription,
    );
  });

  testWidgets(
      'несохранённые изменения переживают цикл предпросмотра и обычный PUT',
      (tester) async {
    final original = storedQuiz();
    final requests = <http.Request>[];
    Map<String, dynamic>? savedBody;
    final transport = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET' && request.url.path == '/api/auth/me/') {
        return jsonResponse({'id': 1, 'username': 'teacher'});
      }
      if (request.method == 'GET' && request.url.path == '/api/quizzes/') {
        return jsonResponse([original]);
      }
      if (request.method == 'GET' && request.url.path == '/api/sessions/') {
        return jsonResponse([]);
      }
      if (request.method == 'PUT' && request.url.path == '/api/quizzes/7/') {
        savedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return jsonResponse({
          ...original,
          ...savedBody!,
          'content_revision': 5,
        });
      }
      return jsonResponse({'detail': 'Неожиданный запрос.'}, statusCode: 500);
    });

    await pumpAuthenticatedPanel(tester, transport, loadSelectedQuiz: true);
    await tester.enterText(fieldWithLabel('Quiz title'), 'Unsaved first title');
    await tester.enterText(
      fieldWithLabel('Description (optional)'),
      'Unsaved description',
    );
    await tester.enterText(fieldWithLabel('Question text'), 'Unsaved question');
    final requestsBeforePreview = requests.length;

    await tester.ensureVisible(find.text('Preview'));
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(QuizPreviewDialog),
        matching: find.text('Unsaved first title'),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('quiz-preview-question-text')),
          )
          .data,
      'Unsaved question',
    );
    expect(find.text('Saved title'), findsNothing);
    expect(requests, hasLength(requestsBeforePreview));

    await tester.tap(find.text('Participant screen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Results'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(requestsBeforePreview));
    await tester.tap(find.byKey(const ValueKey('quiz-preview-close')));
    await tester.pumpAndSettle();

    await tester.enterText(
        fieldWithLabel('Quiz title'), 'Unsaved second title');
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(QuizPreviewDialog),
        matching: find.text('Unsaved second title'),
      ),
      findsOneWidget,
    );
    expect(find.text('Unsaved first title'), findsNothing);
    expect(requests, hasLength(requestsBeforePreview));
    await tester.tap(find.byKey(const ValueKey('quiz-preview-close')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(fieldWithLabel('Quiz title')).controller!.text,
      'Unsaved second title',
    );
    expect(
      tester
          .widget<TextField>(fieldWithLabel('Description (optional)'))
          .controller!
          .text,
      'Unsaved description',
    );
    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(savedBody, isNotNull);
    expect(savedBody!['content_revision'], 4);
    expect(savedBody!['title'], 'Unsaved second title');
    expect(savedBody!['description'], 'Unsaved description');
    expect(savedBody!['question_only_on_display'], isTrue);
    expect(savedBody!['show_choices_on_participant'], isFalse);
    expect(savedBody!['reading_time_sec'], 18);
    expect(savedBody!['results_time_sec'], 9);
    final savedQuestion = (savedBody!['questions'] as List).single as Map;
    expect(savedQuestion['id'], 11);
    expect(savedQuestion['text'], 'Unsaved question');
    expect(savedQuestion['order'], 1);
    expect(savedQuestion['time_limit_sec'], 25);
    final savedChoices = savedQuestion['choices'] as List;
    expect(savedChoices.map((choice) => (choice as Map)['id']), [21, 22]);
    expect(
      savedChoices.map((choice) => (choice as Map)['text']),
      ['Correct A', 'Wrong B'],
    );
    expect(savedChoices.map((choice) => (choice as Map)['order']), [1, 2]);
    expect(
      savedChoices.map((choice) => (choice as Map)['is_correct']),
      [true, false],
    );
  });

  testWidgets(
      'чистый предпросмотр соблюдает экраны состояния и позднее раскрытие',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final previewQuiz = {
      'title': 'Visibility quiz',
      'description': 'Local only',
      'question_only_on_display': true,
      'show_choices_on_participant': false,
      'reading_time_sec': 15,
      'results_time_sec': 10,
      'questions': [
        {
          'text': 'First question',
          'order': 1,
          'time_limit_sec': 20,
          'choices': [
            {'text': 'Correct A', 'order': 1, 'is_correct': true},
            {'text': 'Wrong B', 'order': 2, 'is_correct': false},
          ],
        },
        {
          'text': 'Second question',
          'order': 2,
          'time_limit_sec': 30,
          'choices': [
            {'text': 'Second A', 'order': 1, 'is_correct': false},
            {'text': 'Second B', 'order': 2, 'is_correct': true},
          ],
        },
      ],
    };

    await tester.pumpWidget(
      MaterialApp(home: QuizPreviewDialog(quiz: previewQuiz)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Preview mode'), findsWidgets);
    expect(find.text('First question'), findsOneWidget);
    expect(find.byKey(const ValueKey('quiz-preview-choice-1')), findsNothing);
    expect(
      find.byKey(const ValueKey('quiz-preview-correct-choice-1')),
      findsNothing,
    );

    await tester.tap(find.text('Participant screen'));
    await tester.pumpAndSettle();
    expect(find.text('First question'), findsNothing);
    expect(find.text('Look at the audience screen during reading.'),
        findsOneWidget);

    await tester.tap(find.text('Answering'));
    await tester.pumpAndSettle();
    expect(find.text('Question is shown only on the audience screen.'),
        findsOneWidget);
    expect(find.text('Correct A'), findsNothing);
    expect(find.text('Choice 1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('quiz-preview-correct-choice-1')),
      findsNothing,
    );

    await tester.tap(find.text('Results'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quiz-preview-correct-choice-1')),
      findsOneWidget,
    );
    expect(find.text('Correct A'), findsNothing);

    await tester.tap(find.text('Reading'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quiz-preview-correct-choice-1')),
      findsNothing,
    );

    await tester.tap(find.text('Audience screen'));
    await tester.tap(find.text('Answering'));
    await tester.pumpAndSettle();
    expect(find.text('First question'), findsOneWidget);
    expect(find.text('Correct A'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('quiz-preview-correct-choice-1')),
      findsNothing,
    );

    await tester.tap(find.text('Results'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quiz-preview-correct-choice-1')),
      findsOneWidget,
    );

    await tester
        .tap(find.byKey(const ValueKey('quiz-preview-question-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Question 2').last);
    await tester.pumpAndSettle();
    expect(find.text('Second question'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('quiz-preview-correct-choice-2')),
      findsOneWidget,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: QuizPreviewDialog(
          key: const ValueKey('permissive-preview'),
          quiz: {
            ...previewQuiz,
            'question_only_on_display': false,
            'show_choices_on_participant': true,
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Participant screen'));
    await tester.tap(find.text('Answering'));
    await tester.pumpAndSettle();
    expect(find.text('First question'), findsOneWidget);
    expect(find.text('Correct A'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('quiz-preview-correct-choice-1')),
      findsNothing,
    );
  });

  testWidgets('все сочетания видимости следуют договору экрана участника',
      (tester) async {
    const cases = [
      (
        questionOnlyOnDisplay: true,
        showChoicesOnParticipant: false,
        questionVisible: false,
        choiceTextVisible: false,
      ),
      (
        questionOnlyOnDisplay: false,
        showChoicesOnParticipant: true,
        questionVisible: true,
        choiceTextVisible: true,
      ),
      (
        questionOnlyOnDisplay: true,
        showChoicesOnParticipant: true,
        questionVisible: false,
        choiceTextVisible: true,
      ),
      (
        questionOnlyOnDisplay: false,
        showChoicesOnParticipant: false,
        questionVisible: true,
        choiceTextVisible: false,
      ),
    ];

    for (final entry in cases.indexed) {
      final index = entry.$1;
      final visibility = entry.$2;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuizPreviewViewport(
              key: ValueKey('visibility-case-$index'),
              quiz: {
                'question_only_on_display': visibility.questionOnlyOnDisplay,
                'show_choices_on_participant':
                    visibility.showChoicesOnParticipant,
              },
              question: const {
                'text': 'Visible question',
                'choices': [
                  {'text': 'Visible choice', 'order': 1, 'is_correct': true},
                  {'text': 'Wrong choice', 'order': 2, 'is_correct': false},
                ],
              },
              screen: QuizPreviewScreen.participant,
              phase: QuizPreviewPhase.answering,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('quiz-preview-question-text')),
        visibility.questionVisible ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const ValueKey('quiz-preview-question-hidden')),
        visibility.questionVisible ? findsNothing : findsOneWidget,
      );
      expect(
        find.text('Visible choice'),
        visibility.choiceTextVisible ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('Choice 1'),
        visibility.choiceTextVisible ? findsNothing : findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('quiz-preview-correct-choice-1')),
        findsNothing,
      );
    }
  });

  testWidgets('шесть вариантов меняют обозначения вместе с выбранным экраном',
      (tester) async {
    final sixChoiceQuiz = {
      'title': 'Six choices',
      'question_only_on_display': false,
      'show_choices_on_participant': true,
      'questions': [
        {
          'text': 'Choose one',
          'order': 1,
          'choices': [
            for (var index = 0; index < 6; index += 1)
              {
                'text': 'Choice ${index + 1}',
                'order': index + 1,
                'is_correct': index == 5,
              },
          ],
        },
      ],
    };

    IconData choiceIcon(int number) {
      return tester
          .widget<Icon>(
            find
                .descendant(
                  of: find.byKey(ValueKey('quiz-preview-choice-$number')),
                  matching: find.byType(Icon),
                )
                .first,
          )
          .icon!;
    }

    Color choiceColor(int number) {
      final surface = tester.widget<Container>(
        find
            .descendant(
              of: find.byKey(ValueKey('quiz-preview-choice-$number')),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Container && widget.decoration is BoxDecoration,
              ),
            )
            .first,
      );
      return (surface.decoration! as BoxDecoration).color!;
    }

    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(home: QuizPreviewDialog(quiz: sixChoiceQuiz)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Answering'));
    await tester.pumpAndSettle();

    expect(choiceIcon(5), Icons.star_border_rounded);
    expect(choiceIcon(6), Icons.hexagon_outlined);
    expect(choiceColor(5), const Color(0xFF8E24AA));
    expect(choiceColor(6), const Color(0xFF00ACC1));
    expect(
      find.byKey(const ValueKey('quiz-preview-correct-choice-6')),
      findsNothing,
    );

    await tester.tap(find.text('Participant screen'));
    await tester.pumpAndSettle();
    expect(choiceIcon(5), Icons.change_history);
    expect(choiceIcon(6), Icons.diamond_outlined);
    expect(choiceColor(5), const Color(0xFFE21B3C));
    expect(choiceColor(6), const Color(0xFF1368CE));

    await tester.tap(find.text('Results'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quiz-preview-correct-choice-6')),
      findsOneWidget,
    );
    await tester.tap(find.text('Answering'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quiz-preview-correct-choice-6')),
      findsNothing,
    );
    expect(choiceIcon(6), Icons.diamond_outlined);
  });

  testWidgets('узкое русское окно сохраняет доступ к управлению',
      (tester) async {
    appLanguage.value = UiLanguage.ru;
    await tester.binding.setSurfaceSize(const Size(390, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final longDescription =
        List.generate(40, (index) => 'Короткая строка ${index + 1}').join('\n');
    await tester.pumpWidget(
      MaterialApp(
        home: QuizPreviewDialog(
          quiz: {
            'title': 'Узкое окно',
            'description': longDescription,
            'question_only_on_display': false,
            'show_choices_on_participant': true,
            'questions': const [
              {
                'text': 'Первый вопрос',
                'order': 1,
                'choices': [
                  {'text': 'Один', 'order': 1, 'is_correct': true},
                  {'text': 'Два', 'order': 2, 'is_correct': false},
                ],
              },
              {
                'text': 'Второй вопрос',
                'order': 2,
                'choices': [
                  {'text': 'Три', 'order': 1, 'is_correct': false},
                  {'text': 'Четыре', 'order': 2, 'is_correct': true},
                ],
              },
            ],
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester
        .tap(find.byKey(const ValueKey('quiz-preview-question-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Вопрос 2').last);
    await tester.pumpAndSettle();
    final participantLabel =
        find.text(appText(AppText.quizPreviewParticipantScreen));
    await tester.ensureVisible(participantLabel);
    await tester.tap(participantLabel);
    final answeringLabel =
        find.text(appText(AppText.quizPreviewAnsweringState));
    await tester.ensureVisible(answeringLabel);
    await tester.tap(answeringLabel);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SegmentedButton<QuizPreviewScreen>>(
            find.byKey(const ValueKey('quiz-preview-screen-selector')),
          )
          .selected,
      {QuizPreviewScreen.participant},
    );
    expect(
      tester
          .widget<SegmentedButton<QuizPreviewPhase>>(
            find.byKey(const ValueKey('quiz-preview-phase-selector')),
          )
          .selected,
      {QuizPreviewPhase.answering},
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('quiz-preview-question-text')),
          )
          .data,
      'Второй вопрос',
    );
    expect(find.byKey(const ValueKey('quiz-preview-close')), findsOneWidget);
  });
}
