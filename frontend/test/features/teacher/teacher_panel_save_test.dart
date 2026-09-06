import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:umclick_frontend/api/api_client.dart';
import 'package:umclick_frontend/core/app_config.dart';
import 'package:umclick_frontend/core/live_socket_supervisor.dart';
import 'package:umclick_frontend/features/teacher/teacher_panel.dart';
import 'package:umclick_frontend/features/teacher/widgets/teacher_quiz_builder_card.dart';
import 'package:umclick_frontend/l10n/app_language.dart';

class _TestSocket implements SupervisedSocket {
  _TestSocket(this._onMessage);

  final void Function(Map<String, dynamic> message) _onMessage;

  void emitSessionState(Map<String, dynamic> state) {
    _onMessage({'event': 'session_state', 'payload': state});
  }

  @override
  Future<void> close() async {}
}

void main() {
  Map<String, dynamic> quizState({
    required int revision,
    required int questionId,
    required List<int> choiceIds,
    required String title,
  }) {
    return {
      'id': 7,
      'title': title,
      'description': 'Описание',
      'question_only_on_display': true,
      'show_choices_on_participant': false,
      'reading_time_sec': 21,
      'results_time_sec': 12,
      'content_revision': revision,
      'questions': [
        {
          'id': questionId,
          'text': 'Вопрос',
          'order': 1,
          'time_limit_sec': 30,
          'choices': [
            {
              'id': choiceIds[0],
              'text': 'Да',
              'is_correct': true,
              'order': 1,
            },
            {
              'id': choiceIds[1],
              'text': 'Нет',
              'is_correct': false,
              'order': 2,
            },
          ],
        },
      ],
    };
  }

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
    SupervisedSocketOpener? sessionSocketOpener,
    bool loadSelectedQuiz = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      prefsAccessTokenKey: 'test-access-token',
      prefsApiBaseUrlKey: 'http://test.local/api',
    });
    appLanguage.value = UiLanguage.en;
    await tester.binding.setSurfaceSize(const Size(1600, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TeacherPanel(
            sessionSocketOpener: sessionSocketOpener,
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

  testWidgets(
      'successful save remains authoritative when the following list refresh fails',
      (tester) async {
    final original = quizState(
      revision: 1,
      questionId: 11,
      choiceIds: [21, 22],
      title: 'Initial title',
    );
    final saved = quizState(
      revision: 2,
      questionId: 101,
      choiceIds: [201, 202],
      title: 'Saved server state',
    );
    final putBodies = <Map<String, dynamic>>[];
    var quizListCalls = 0;

    final transport = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/auth/me/') {
        return jsonResponse({'id': 1, 'username': 'teacher'});
      }
      if (request.method == 'GET' && request.url.path == '/api/sessions/') {
        return jsonResponse([]);
      }
      if (request.method == 'GET' && request.url.path == '/api/quizzes/') {
        quizListCalls += 1;
        if (quizListCalls == 1) {
          return jsonResponse([original]);
        }
        return jsonResponse(
          {'detail': 'Список временно недоступен.'},
          statusCode: 503,
        );
      }
      if (request.method == 'PUT' && request.url.path == '/api/quizzes/7/') {
        putBodies.add(
          jsonDecode(request.body) as Map<String, dynamic>,
        );
        return jsonResponse(saved);
      }
      return jsonResponse({'detail': 'Неожиданный запрос.'}, statusCode: 500);
    });

    await pumpAuthenticatedPanel(tester, transport);
    await tester.enterText(fieldWithLabel('Quiz title'), 'Edited locally');
    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(fieldWithLabel('Quiz title')).controller!.text,
      'Saved server state',
    );
    expect(find.textContaining('Quiz saved, but the list was not refreshed'),
        findsOneWidget);
    expect(putBodies, hasLength(1));

    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(putBodies, hasLength(2));
    expect(putBodies[1]['content_revision'], 2);
    expect(putBodies[1]['questions'][0]['id'], 101);
    expect(putBodies[1]['questions'][0]['choices'][0]['id'], 201);
    expect(putBodies[1]['questions'][0]['choices'][1]['id'], 202);
  });

  testWidgets(
      'revision conflict keeps the entire form and never retries itself',
      (tester) async {
    final original = quizState(
      revision: 1,
      questionId: 11,
      choiceIds: [21, 22],
      title: 'Initial title',
    );
    final putBodies = <Map<String, dynamic>>[];
    var quizListCalls = 0;

    final transport = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/auth/me/') {
        return jsonResponse({'id': 1, 'username': 'teacher'});
      }
      if (request.method == 'GET' && request.url.path == '/api/sessions/') {
        return jsonResponse([]);
      }
      if (request.method == 'GET' && request.url.path == '/api/quizzes/') {
        quizListCalls += 1;
        return jsonResponse([original]);
      }
      if (request.method == 'PUT' && request.url.path == '/api/quizzes/7/') {
        putBodies.add(
          jsonDecode(request.body) as Map<String, dynamic>,
        );
        return jsonResponse(
          {
            'code': 'quiz_revision_conflict',
            'detail': 'Викторина уже изменена.',
            'current_content_revision': 9,
          },
          statusCode: 409,
        );
      }
      return jsonResponse({'detail': 'Неожиданный запрос.'}, statusCode: 500);
    });

    await pumpAuthenticatedPanel(tester, transport);
    await tester.enterText(fieldWithLabel('Quiz title'), 'Unsaved local title');
    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(putBodies, hasLength(1));
    expect(quizListCalls, 1);
    expect(
      tester.widget<TextField>(fieldWithLabel('Quiz title')).controller!.text,
      'Unsaved local title',
    );
    expect(putBodies.single['content_revision'], 1);
    expect(putBodies.single['question_only_on_display'], isTrue);
    expect(putBodies.single['show_choices_on_participant'], isFalse);
    expect(putBodies.single['questions'][0]['id'], 11);
    expect(putBodies.single['questions'][0]['choices'][0]['id'], 21);

    await tester.pump(const Duration(seconds: 1));
    expect(putBodies, hasLength(1));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(putBodies, hasLength(2));
    expect(putBodies[1], putBodies[0]);
    expect(quizListCalls, 1);
  });

  testWidgets(
      'снимок сессии управляет переходом после обновлений списка и состояния',
      (tester) async {
    const sessionUuid = '11111111-1111-4111-8111-111111111111';
    const fixedQuiz = {
      'id': 7,
      'title': 'Зафиксированная викторина',
      'description': '',
      'question_only_on_display': false,
      'show_choices_on_participant': true,
      'reading_time_sec': 15,
      'results_time_sec': 10,
      'questions': [
        {
          'id': 11,
          'text': 'Первый вопрос версии',
          'order': 1,
          'time_limit_sec': 20,
          'choices': <dynamic>[],
        },
        {
          'id': 12,
          'text': 'Последний вопрос версии',
          'order': 2,
          'time_limit_sec': 20,
          'choices': <dynamic>[],
        },
      ],
    };
    const originalQuizList = <dynamic>[
      {
        'id': 7,
        'title': 'Исходный список',
        'questions': [
          {'id': 11},
          {'id': 12},
        ],
      },
    ];
    const draftQuizList = <dynamic>[
      {
        'id': 7,
        'title': 'Новый черновик',
        'questions': [
          {'id': 101},
          {'id': 102},
        ],
      },
    ];

    Map<String, dynamic> sessionState({
      required int revision,
      required int questionId,
      required int questionRunId,
    }) {
      return {
        'schema_version': 2,
        'session_id': sessionUuid,
        'state_revision': revision,
        'status': 'live',
        'phase': 'results',
        'question_run_id': questionRunId,
        'current_question': {
          'id': questionId,
          'text': 'Вопрос $questionId',
        },
        'is_answer_revealed': true,
      };
    }

    var quizListCalls = 0;
    late _TestSocket socket;
    final transport = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/auth/me/') {
        return jsonResponse({'id': 1, 'username': 'teacher'});
      }
      if (request.method == 'GET' && request.url.path == '/api/quizzes/') {
        quizListCalls += 1;
        return switch (quizListCalls) {
          1 => jsonResponse(originalQuizList),
          2 => jsonResponse(draftQuizList),
          3 => jsonResponse([]),
          _ => jsonResponse(
              {'detail': 'Список временно недоступен.'},
              statusCode: 503,
            ),
        };
      }
      if (request.method == 'GET' && request.url.path == '/api/sessions/') {
        return jsonResponse([]);
      }
      if (request.method == 'POST' && request.url.path == '/api/sessions/') {
        return jsonResponse({'join_token': sessionUuid}, statusCode: 201);
      }
      if (request.method == 'GET' &&
          request.url.path == '/api/sessions/$sessionUuid/') {
        return jsonResponse({
          'id': sessionUuid,
          'quiz': fixedQuiz,
          'host_name': 'Teacher',
          'status': 'live',
          'phase': 'results',
          'state_revision': 1,
          'pin': '458263',
          'join_token': sessionUuid,
          'join_url': 'http://test.local/join?token=$sessionUuid',
          'participants_count': 1,
        });
      }
      if (request.method == 'GET' &&
          request.url.path == '/api/sessions/$sessionUuid/state/') {
        return jsonResponse(
          sessionState(revision: 1, questionId: 11, questionRunId: 1),
        );
      }
      return jsonResponse({'detail': 'Неожиданный запрос.'}, statusCode: 500);
    });

    await pumpAuthenticatedPanel(
      tester,
      transport,
      loadSelectedQuiz: false,
      sessionSocketOpener: ({
        required authentication,
        required onMessage,
        required onError,
        required onDone,
        required onInvalidPayload,
      }) {
        socket = _TestSocket(onMessage);
        return socket;
      },
    );

    await tester.ensureVisible(find.text('Create session'));
    await tester.tap(find.text('Create session'));
    await tester.pumpAndSettle();

    FilledButton nextQuestionButton() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Next question'),
        );

    expect(nextQuestionButton().onPressed, isNotNull);

    await tester.ensureVisible(find.text('Refresh quizzes'));
    await tester.tap(find.text('Refresh quizzes'));
    await tester.pumpAndSettle();
    expect(quizListCalls, 2);
    expect(nextQuestionButton().onPressed, isNotNull);

    await tester.tap(find.text('Refresh quizzes'));
    await tester.pumpAndSettle();
    expect(quizListCalls, 3);
    expect(nextQuestionButton().onPressed, isNotNull);

    await tester.tap(find.text('Refresh quizzes'));
    await tester.pumpAndSettle();
    expect(quizListCalls, 4);
    expect(nextQuestionButton().onPressed, isNotNull);

    socket.emitSessionState(
      sessionState(revision: 2, questionId: 11, questionRunId: 1),
    );
    await tester.pump();
    expect(nextQuestionButton().onPressed, isNotNull);

    socket.emitSessionState(
      sessionState(revision: 3, questionId: 12, questionRunId: 2),
    );
    await tester.pump();
    expect(nextQuestionButton().onPressed, isNull);
  });
}
