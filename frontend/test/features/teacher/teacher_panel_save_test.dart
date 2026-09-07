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
    int id = 7,
    required int revision,
    required int questionId,
    required List<int> choiceIds,
    required String title,
    bool canDelete = true,
    String? archivedAt,
  }) {
    return {
      'id': id,
      'title': title,
      'description': 'Описание',
      'question_only_on_display': true,
      'show_choices_on_participant': false,
      'reading_time_sec': 21,
      'results_time_sec': 12,
      'content_revision': revision,
      'archived_at': archivedAt,
      'can_delete': canDelete,
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
      'конфликт архива сохраняет выбранную карточку и форму без обновления',
      (tester) async {
    final original = quizState(
      revision: 1,
      questionId: 11,
      choiceIds: [21, 22],
      title: 'Open session quiz',
      canDelete: false,
    );
    var quizListCalls = 0;
    var archiveCalls = 0;
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
      if (request.method == 'POST' &&
          request.url.path == '/api/quizzes/7/archive/') {
        archiveCalls += 1;
        return jsonResponse(
          {
            'code': 'quiz_open_session_conflict',
            'detail': 'Сначала завершите или остановите открытую сессию',
          },
          statusCode: 409,
        );
      }
      return jsonResponse({'detail': 'Неожиданный запрос.'}, statusCode: 500);
    });

    await pumpAuthenticatedPanel(tester, transport);
    await tester.enterText(fieldWithLabel('Quiz title'), 'Unsaved local title');
    expect(find.text('Delete permanently'), findsNothing);
    await tester.ensureVisible(find.text('Archive quiz'));
    await tester.tap(find.text('Archive quiz'));
    await tester.pumpAndSettle();

    expect(archiveCalls, 1);
    expect(quizListCalls, 1);
    expect(
      tester.widget<TextField>(fieldWithLabel('Quiz title')).controller!.text,
      'Unsaved local title',
    );
    expect(
      tester
          .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
          .value,
      7,
    );
    expect(find.text('Finish or stop the open session first.'), findsOneWidget);
  });

  testWidgets(
      'архивирование и восстановление обновляют списки и сохраняют режим чтения',
      (tester) async {
    final active = quizState(
      revision: 1,
      questionId: 11,
      choiceIds: [21, 22],
      title: 'Working quiz',
    );
    final archived = quizState(
      revision: 1,
      questionId: 11,
      choiceIds: [21, 22],
      title: 'Working quiz',
      archivedAt: '2026-09-06T12:00:00Z',
    );
    var archiveCalls = 0;
    var restoreCalls = 0;
    final transport = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/auth/me/') {
        return jsonResponse({'id': 1, 'username': 'teacher'});
      }
      if (request.method == 'GET' && request.url.path == '/api/sessions/') {
        return jsonResponse([]);
      }
      if (request.method == 'GET' && request.url.path == '/api/quizzes/') {
        return jsonResponse(
          request.url.queryParameters['archived'] == 'true'
              ? [archived]
              : [active],
        );
      }
      if (request.method == 'POST' &&
          request.url.path == '/api/quizzes/7/archive/') {
        archiveCalls += 1;
        return jsonResponse(archived);
      }
      if (request.method == 'POST' &&
          request.url.path == '/api/quizzes/7/restore/') {
        restoreCalls += 1;
        return jsonResponse(active);
      }
      return jsonResponse({'detail': 'Неожиданный запрос.'}, statusCode: 500);
    });

    await pumpAuthenticatedPanel(tester, transport, loadSelectedQuiz: false);
    await tester.ensureVisible(find.text('Archive quiz'));
    await tester.tap(find.text('Archive quiz'));
    await tester.pumpAndSettle();
    expect(archiveCalls, 1);
    expect(find.text('No quizzes yet'), findsOneWidget);

    await tester.ensureVisible(find.text('Archive'));
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Load'));
    await tester.tap(find.text('Load'));
    await tester.pumpAndSettle();

    expect(find.text('Archived quizzes are read-only.'), findsOneWidget);
    expect(find.text('Restore'), findsOneWidget);
    expect(find.text('Delete permanently'), findsOneWidget);
    expect(find.text('Archive quiz'), findsNothing);
    expect(
      tester.widget<TextField>(fieldWithLabel('Quiz title')).readOnly,
      isTrue,
    );
    expect(
      tester
          .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save changes'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Create session'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(restoreCalls, 1);
    expect(find.text('No quizzes yet'), findsOneWidget);
  });

  testWidgets(
      'безвозвратное удаление зависит от can_delete и требует подтверждения',
      (tester) async {
    final deletable = quizState(
      revision: 1,
      questionId: 11,
      choiceIds: [21, 22],
      title: 'Disposable quiz',
    );
    var deleteCalls = 0;
    final transport = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/auth/me/') {
        return jsonResponse({'id': 1, 'username': 'teacher'});
      }
      if (request.method == 'GET' && request.url.path == '/api/sessions/') {
        return jsonResponse([]);
      }
      if (request.method == 'GET' && request.url.path == '/api/quizzes/') {
        return jsonResponse([deletable]);
      }
      if (request.method == 'DELETE' && request.url.path == '/api/quizzes/7/') {
        deleteCalls += 1;
        return http.Response('', 204);
      }
      return jsonResponse({'detail': 'Неожиданный запрос.'}, statusCode: 500);
    });

    await pumpAuthenticatedPanel(tester, transport, loadSelectedQuiz: false);
    await tester.ensureVisible(find.text('Delete permanently'));
    await tester.tap(find.text('Delete permanently'));
    await tester.pumpAndSettle();
    expect(find.text('Delete quiz?'), findsOneWidget);
    expect(deleteCalls, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deleteCalls, 0);

    await tester.tap(find.text('Delete permanently'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deleteCalls, 1);
    expect(find.text('No quizzes yet'), findsOneWidget);
  });

  testWidgets('архивная загруженная форма не разблокируется рабочим списком',
      (tester) async {
    final active = quizState(
      id: 7,
      revision: 1,
      questionId: 11,
      choiceIds: [21, 22],
      title: 'Working A',
    );
    final archived = quizState(
      id: 8,
      revision: 4,
      questionId: 81,
      choiceIds: [82, 83],
      title: 'Archived B',
      archivedAt: '2026-09-07T08:00:00Z',
    );
    var putCalls = 0;
    final transport = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/auth/me/') {
        return jsonResponse({'id': 1, 'username': 'teacher'});
      }
      if (request.method == 'GET' && request.url.path == '/api/sessions/') {
        return jsonResponse([]);
      }
      if (request.method == 'GET' && request.url.path == '/api/quizzes/') {
        return jsonResponse(
          request.url.queryParameters['archived'] == 'true'
              ? [archived]
              : [active],
        );
      }
      if (request.method == 'PUT') {
        putCalls += 1;
        return jsonResponse({'detail': 'Запись не ожидалась.'},
            statusCode: 500);
      }
      return jsonResponse({'detail': 'Неожиданный запрос.'}, statusCode: 500);
    });

    await pumpAuthenticatedPanel(tester, transport, loadSelectedQuiz: false);
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(fieldWithLabel('Quiz title')).controller!.text,
      'Archived B',
    );

    await tester.tap(find.text('Working'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(fieldWithLabel('Quiz title')).controller!.text,
      'Archived B',
    );
    expect(
      tester.widget<TextField>(fieldWithLabel('Quiz title')).readOnly,
      isTrue,
    );
    expect(
      tester
          .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save changes'))
          .onPressed,
      isNull,
    );
    await tester.tap(
      find.widgetWithText(FilledButton, 'Save changes'),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(putCalls, 0);
  });

  testWidgets(
      'смена списков сохраняет несохранённую рабочую форму и её редакцию',
      (tester) async {
    final active = quizState(
      id: 7,
      revision: 3,
      questionId: 11,
      choiceIds: [21, 22],
      title: 'Working A',
    );
    final archived = quizState(
      id: 8,
      revision: 1,
      questionId: 81,
      choiceIds: [82, 83],
      title: 'Archived B',
      archivedAt: '2026-09-07T08:00:00Z',
    );
    final putBodies = <Map<String, dynamic>>[];
    final transport = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/auth/me/') {
        return jsonResponse({'id': 1, 'username': 'teacher'});
      }
      if (request.method == 'GET' && request.url.path == '/api/sessions/') {
        return jsonResponse([]);
      }
      if (request.method == 'GET' && request.url.path == '/api/quizzes/') {
        return jsonResponse(
          request.url.queryParameters['archived'] == 'true'
              ? [archived]
              : [active],
        );
      }
      if (request.method == 'PUT' && request.url.path == '/api/quizzes/7/') {
        putBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return jsonResponse(
            {...active, 'title': 'Unsaved A', 'content_revision': 4});
      }
      return jsonResponse({'detail': 'Неожиданный запрос.'}, statusCode: 500);
    });

    await pumpAuthenticatedPanel(tester, transport);
    await tester.enterText(fieldWithLabel('Quiz title'), 'Unsaved A');
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(fieldWithLabel('Quiz title')).readOnly,
      isTrue,
    );
    await tester.tap(find.text('Working'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(fieldWithLabel('Quiz title')).controller!.text,
      'Unsaved A',
    );
    expect(
      tester.widget<TextField>(fieldWithLabel('Quiz title')).readOnly,
      isFalse,
    );
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(putBodies, hasLength(1));
    expect(putBodies.single['content_revision'], 3);
    expect(putBodies.single['title'], 'Unsaved A');
  });

  testWidgets(
      'восстановленная карточка после рабочей загрузки снова редактируется',
      (tester) async {
    final activeA = quizState(
      id: 7,
      revision: 1,
      questionId: 11,
      choiceIds: [21, 22],
      title: 'Working A',
    );
    final archivedB = quizState(
      id: 8,
      revision: 4,
      questionId: 81,
      choiceIds: [82, 83],
      title: 'Archived B',
      archivedAt: '2026-09-07T08:00:00Z',
    );
    final restoredB = {...archivedB, 'archived_at': null};
    final putBodies = <Map<String, dynamic>>[];
    var restored = false;
    final transport = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/auth/me/') {
        return jsonResponse({'id': 1, 'username': 'teacher'});
      }
      if (request.method == 'GET' && request.url.path == '/api/sessions/') {
        return jsonResponse([]);
      }
      if (request.method == 'GET' && request.url.path == '/api/quizzes/') {
        if (request.url.queryParameters['archived'] == 'true') {
          return jsonResponse(restored ? [] : [archivedB]);
        }
        return jsonResponse(restored ? [activeA, restoredB] : [activeA]);
      }
      if (request.method == 'POST' &&
          request.url.path == '/api/quizzes/8/restore/') {
        restored = true;
        return jsonResponse(restoredB);
      }
      if (request.method == 'PUT' && request.url.path == '/api/quizzes/8/') {
        putBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return jsonResponse(
            {...restoredB, 'title': 'Edited B', 'content_revision': 5});
      }
      return jsonResponse({'detail': 'Неожиданный запрос.'}, statusCode: 500);
    });

    await pumpAuthenticatedPanel(tester, transport, loadSelectedQuiz: false);
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Working'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('8: Archived B').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(fieldWithLabel('Quiz title')).readOnly,
      isFalse,
    );
    await tester.enterText(fieldWithLabel('Quiz title'), 'Edited B');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(putBodies, hasLength(1));
    expect(putBodies.single['content_revision'], 4);
    expect(putBodies.single['title'], 'Edited B');
  });

  testWidgets(
      'ошибка загрузки другого списка сохраняет форму и режим интерфейса',
      (tester) async {
    final active = quizState(
      id: 7,
      revision: 2,
      questionId: 11,
      choiceIds: [21, 22],
      title: 'Working A',
    );
    final putBodies = <Map<String, dynamic>>[];
    final transport = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/auth/me/') {
        return jsonResponse({'id': 1, 'username': 'teacher'});
      }
      if (request.method == 'GET' && request.url.path == '/api/sessions/') {
        return jsonResponse([]);
      }
      if (request.method == 'GET' && request.url.path == '/api/quizzes/') {
        if (request.url.queryParameters['archived'] == 'true') {
          return jsonResponse(
            {'detail': 'Архив временно недоступен.'},
            statusCode: 503,
          );
        }
        return jsonResponse([active]);
      }
      if (request.method == 'PUT' && request.url.path == '/api/quizzes/7/') {
        putBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return jsonResponse(
            {...active, 'title': 'Unsaved A', 'content_revision': 3});
      }
      return jsonResponse({'detail': 'Неожиданный запрос.'}, statusCode: 500);
    });

    await pumpAuthenticatedPanel(tester, transport);
    await tester.enterText(fieldWithLabel('Quiz title'), 'Unsaved A');
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
          .selected,
      {false},
    );
    expect(
      tester.widget<TextField>(fieldWithLabel('Quiz title')).controller!.text,
      'Unsaved A',
    );
    expect(
      tester.widget<TextField>(fieldWithLabel('Quiz title')).readOnly,
      isFalse,
    );
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(putBodies, hasLength(1));
    expect(putBodies.single['content_revision'], 2);
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
