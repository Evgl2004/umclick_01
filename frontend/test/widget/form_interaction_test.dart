import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:umclick_frontend/core/live_socket_supervisor.dart';
import 'package:umclick_frontend/core/role_access_token_store.dart';
import 'package:umclick_frontend/features/participant/participant_panel.dart';
import 'package:umclick_frontend/features/participant/models/join_source.dart';
import 'package:umclick_frontend/features/participant/widgets/join_connection_card.dart';
import 'package:umclick_frontend/features/participant/widgets/profile_card.dart';
import 'package:umclick_frontend/features/participant/widgets/question_card.dart';
import 'package:umclick_frontend/features/teacher/quiz_draft.dart';
import 'package:umclick_frontend/features/teacher/teacher_panel.dart';
import 'package:umclick_frontend/features/teacher/widgets/teacher_auth_card.dart';
import 'package:umclick_frontend/features/teacher/widgets/teacher_live_session_card.dart';
import 'package:umclick_frontend/features/teacher/widgets/teacher_quiz_builder_card.dart';
import 'package:umclick_frontend/features/teacher/widgets/teacher_quiz_question_card.dart';
import 'package:umclick_frontend/features/teacher/widgets/teacher_reveal_results_card.dart';
import 'package:umclick_frontend/features/teacher/widgets/teacher_session_setup_card.dart';
import 'package:umclick_frontend/l10n/app_language.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appLanguage.value = UiLanguage.en;
  });

  Future<void> pumpCard(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('TeacherAuthCard', () {
    testWidgets('accepts credentials and triggers auth actions',
        (tester) async {
      final usernameController = TextEditingController();
      final passwordController = TextEditingController();
      final emailController = TextEditingController();
      final signupCodeController = TextEditingController();
      addTearDown(usernameController.dispose);
      addTearDown(passwordController.dispose);
      addTearDown(emailController.dispose);
      addTearDown(signupCodeController.dispose);

      var registerCalls = 0;
      var loginCalls = 0;

      await pumpCard(
        tester,
        TeacherAuthCard(
          usernameController: usernameController,
          passwordController: passwordController,
          emailController: emailController,
          signupCodeController: signupCodeController,
          loading: false,
          restoringSession: false,
          isLoggedIn: false,
          hasRefreshToken: false,
          teacher: null,
          onRegister: () => registerCalls += 1,
          onLogin: () => loginCalls += 1,
          onLoadProfile: () {},
          onLogout: () {},
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'teacher');
      await tester.enterText(find.byType(TextField).at(1), 'safe-password');
      await tester.enterText(find.byType(TextField).at(2), 't@example.com');
      await tester.enterText(find.byType(TextField).at(3), 'invite-code');
      await tester.tap(find.text('Register'));
      await tester.tap(find.text('Login'));
      await tester.pump();

      expect(usernameController.text, 'teacher');
      expect(passwordController.text, 'safe-password');
      expect(emailController.text, 't@example.com');
      expect(signupCodeController.text, 'invite-code');
      expect(registerCalls, 1);
      expect(loginCalls, 1);
      expect(find.text('Not authenticated'), findsOneWidget);
      expect(find.text('Who am I'), findsNothing);
      expect(find.text('Logout'), findsNothing);
    });

    testWidgets('shows compact account summary after login', (tester) async {
      final usernameController = TextEditingController();
      final passwordController = TextEditingController();
      final emailController = TextEditingController();
      final signupCodeController = TextEditingController();
      addTearDown(usernameController.dispose);
      addTearDown(passwordController.dispose);
      addTearDown(emailController.dispose);
      addTearDown(signupCodeController.dispose);

      var profileCalls = 0;
      var logoutCalls = 0;

      await pumpCard(
        tester,
        TeacherAuthCard(
          usernameController: usernameController,
          passwordController: passwordController,
          emailController: emailController,
          signupCodeController: signupCodeController,
          loading: false,
          restoringSession: false,
          isLoggedIn: true,
          hasRefreshToken: true,
          teacher: const {'username': 'teacher'},
          onRegister: () {},
          onLogin: () {},
          onLoadProfile: () => profileCalls += 1,
          onLogout: () => logoutCalls += 1,
        ),
      );

      await tester.tap(find.text('Who am I'));
      await tester.tap(find.text('Logout'));
      await tester.pump();

      expect(profileCalls, 1);
      expect(logoutCalls, 1);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Register'), findsNothing);
      expect(find.text('Login'), findsNothing);
      expect(find.text('Logged in: teacher'), findsOneWidget);
      expect(
          find.text(
              'Refresh token is stored locally for this browser profile.'),
          findsOneWidget);
    });

    testWidgets('disables auth actions while loading', (tester) async {
      final usernameController = TextEditingController();
      final passwordController = TextEditingController();
      final emailController = TextEditingController();
      final signupCodeController = TextEditingController();
      addTearDown(usernameController.dispose);
      addTearDown(passwordController.dispose);
      addTearDown(emailController.dispose);
      addTearDown(signupCodeController.dispose);

      await pumpCard(
        tester,
        TeacherAuthCard(
          usernameController: usernameController,
          passwordController: passwordController,
          emailController: emailController,
          signupCodeController: signupCodeController,
          loading: true,
          restoringSession: true,
          isLoggedIn: false,
          hasRefreshToken: false,
          teacher: null,
          onRegister: () {},
          onLogin: () {},
          onLoadProfile: () {},
          onLogout: () {},
        ),
      );

      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Register'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Login'),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.text('Restoring saved teacher session...'),
        findsOneWidget,
      );
      expect(find.text('Not authenticated'), findsOneWidget);
    });
  });

  group('TeacherSessionSetupCard', () {
    testWidgets('enables create session only for logged-in selected quiz',
        (tester) async {
      var createCalls = 0;

      await pumpCard(
        tester,
        TeacherSessionSetupCard(
          loading: false,
          isLoggedIn: false,
          selectedQuizId: 7,
          onCreateSession: () => createCalls += 1,
        ),
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Create session'),
            )
            .onPressed,
        isNull,
      );

      await pumpCard(
        tester,
        TeacherSessionSetupCard(
          loading: false,
          isLoggedIn: true,
          selectedQuizId: null,
          onCreateSession: () => createCalls += 1,
        ),
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Create session'),
            )
            .onPressed,
        isNull,
      );

      await pumpCard(
        tester,
        TeacherSessionSetupCard(
          loading: false,
          isLoggedIn: true,
          selectedQuizId: 7,
          onCreateSession: () => createCalls += 1,
        ),
      );
      await tester.tap(find.text('Create session'));
      await tester.pump();

      expect(createCalls, 1);
      expect(find.text('Session quiz: #7'), findsOneWidget);
    });
  });

  group('TeacherLiveSessionCard', () {
    testWidgets('lobby exposes quiz start separately from session start',
        (tester) async {
      var startCalls = 0;
      var startQuizCalls = 0;
      var nextQuestionCalls = 0;
      var revealCalls = 0;
      var revokeDisplayCalls = 0;

      await pumpCard(
        tester,
        TeacherLiveSessionCard(
          session: {
            'id': 1,
            'pin': '458263',
            'status': 'live',
            'phase': 'lobby',
            'participants_count': 1,
            'join_url': 'http://localhost/join?token=abc',
          },
          wsConnected: true,
          activeQuestion: null,
          questionTimeLeftLabel: '--:--',
          answeredCount: 0,
          revealPayload: null,
          onStart: () => startCalls += 1,
          onStartQuiz: () => startQuizCalls += 1,
          onNextQuestion: () => nextQuestionCalls += 1,
          onRevealAnswers: () => revealCalls += 1,
          onFinish: () {},
          onOpenDisplay: () {},
          onRevokeDisplay: () => revokeDisplayCalls += 1,
          onShowLeaderboard: () {},
          onExportCsv: () {},
          hasNextQuestion: false,
        ),
      );

      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Start'))
            .onPressed,
        isNull,
      );
      expect(
        find.widgetWithText(FilledButton, 'Start quiz'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(
                FilledButton,
                'End answer collection early',
              ),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.text('Start quiz'));
      await tester.pump();
      await tester.ensureVisible(find.text('Revoke display access'));
      await tester.tap(find.text('Revoke display access'));
      await tester.pump();

      expect(startCalls, 0);
      expect(startQuizCalls, 1);
      expect(nextQuestionCalls, 0);
      expect(revealCalls, 0);
      expect(revokeDisplayCalls, 1);
    });

    testWidgets('delivery has no enabled phase transition', (tester) async {
      await pumpCard(
        tester,
        TeacherLiveSessionCard(
          session: const {
            'id': 1,
            'pin': '458263',
            'status': 'live',
            'phase': 'delivery',
            'participants_count': 1,
            'join_url': 'http://localhost/join?token=abc',
          },
          wsConnected: true,
          activeQuestion: const {'id': 11},
          questionTimeLeftLabel: '00:03',
          answeredCount: 1,
          revealPayload: null,
          onStart: () {},
          onStartQuiz: () {},
          onNextQuestion: () {},
          onRevealAnswers: () {},
          onFinish: () {},
          onOpenDisplay: () {},
          onRevokeDisplay: () {},
          onShowLeaderboard: () {},
          onExportCsv: () {},
          hasNextQuestion: true,
        ),
      );

      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Next question'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(
                FilledButton,
                'End answer collection early',
              ),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('answering exposes only early answer collection finish',
        (tester) async {
      await pumpCard(
        tester,
        TeacherLiveSessionCard(
          session: const {
            'id': 1,
            'pin': '458263',
            'status': 'live',
            'phase': 'answering',
            'participants_count': 1,
            'join_url': 'http://localhost/join?token=abc',
          },
          wsConnected: true,
          activeQuestion: const {'id': 11},
          questionTimeLeftLabel: '00:30',
          answeredCount: 1,
          revealPayload: null,
          onStart: () {},
          onStartQuiz: () {},
          onNextQuestion: () {},
          onRevealAnswers: () {},
          onFinish: () {},
          onOpenDisplay: () {},
          onRevokeDisplay: () {},
          onShowLeaderboard: () {},
          onExportCsv: () {},
          hasNextQuestion: true,
        ),
      );

      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(
                FilledButton,
                'End answer collection early',
              ),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Next question'),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('results exposes next question only when one remains',
        (tester) async {
      Future<void> pumpResults({required bool hasNext}) {
        return pumpCard(
          tester,
          TeacherLiveSessionCard(
            session: const {
              'id': 1,
              'pin': '458263',
              'status': 'live',
              'phase': 'results',
              'participants_count': 1,
              'join_url': 'http://localhost/join?token=abc',
            },
            wsConnected: true,
            activeQuestion: const {'id': 11},
            questionTimeLeftLabel: '00:00',
            answeredCount: 1,
            revealPayload: const {'choices': <dynamic>[]},
            onStart: () {},
            onStartQuiz: () {},
            onNextQuestion: () {},
            onRevealAnswers: () {},
            onFinish: () {},
            onOpenDisplay: () {},
            onRevokeDisplay: () {},
            onShowLeaderboard: () {},
            onExportCsv: () {},
            hasNextQuestion: hasNext,
          ),
        );
      }

      await pumpResults(hasNext: false);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Next question'),
            )
            .onPressed,
        isNull,
      );

      await pumpResults(hasNext: true);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Next question'),
            )
            .onPressed,
        isNotNull,
      );
    });

    test('следующий вопрос определяется только снимком викторины сессии', () {
      const session = {
        'quiz': {
          'id': 7,
          'questions': [
            {'id': 11},
            {'id': 12},
            {'id': 13},
          ],
        }
      };

      expect(
        hasNextQuestionInSessionQuiz(
          session: session,
          currentQuestion: const {'id': 11},
        ),
        isTrue,
      );
      expect(
        hasNextQuestionInSessionQuiz(
          session: session,
          currentQuestion: const {'id': 12},
        ),
        isTrue,
      );
      expect(
        hasNextQuestionInSessionQuiz(
          session: session,
          currentQuestion: const {'id': 13},
        ),
        isFalse,
      );
      expect(
        hasNextQuestionInSessionQuiz(
          session: const {'quiz': 7},
          currentQuestion: const {'id': 11},
        ),
        isFalse,
      );
      expect(
        hasNextQuestionInSessionQuiz(
          session: session,
          currentQuestion: const {'id': 999},
        ),
        isFalse,
      );
    });
  });

  group('TeacherQuizBuilderCard', () {
    testWidgets('switches the editor to the selected question from the rail',
        (tester) async {
      final titleController = TextEditingController(text: 'Chemistry warmup');
      final descriptionController = TextEditingController();
      final questions = [
        QuizDraftQuestion(text: 'Which gas supports burning?'),
        QuizDraftQuestion(),
      ];
      addTearDown(titleController.dispose);
      addTearDown(descriptionController.dispose);
      addTearDown(() {
        for (final question in questions) {
          question.dispose();
        }
      });

      await pumpCard(
        tester,
        TeacherQuizBuilderCard(
          quizzes: const [],
          selectedQuizId: null,
          editingQuizId: null,
          archiveMode: false,
          quizFormReadOnly: false,
          canDeleteSelectedQuiz: false,
          loading: false,
          isLoggedIn: true,
          titleController: titleController,
          descriptionController: descriptionController,
          readingTimeController: TextEditingController(text: '15'),
          resultsTimeController: TextEditingController(text: '10'),
          questionOnlyOnDisplay: false,
          showChoicesOnParticipant: true,
          questions: questions,
          onQuestionOnlyOnDisplayChanged: (_) {},
          onShowChoicesOnParticipantChanged: (_) {},
          onSelectedQuizChanged: (_) {},
          onArchiveModeChanged: (_) {},
          onLoadSelectedQuiz: () {},
          onSaveQuiz: () {},
          onResetDraft: () {},
          onRefreshQuizzes: () {},
          onArchiveSelectedQuiz: () {},
          onRestoreSelectedQuiz: () {},
          onDeleteSelectedQuiz: () {},
          onRemoveQuestion: (_) {},
          onSetCorrectChoice: (_, __) {},
          onRemoveChoice: (_, __) {},
          onAddChoice: (_) {},
          onAddQuestion: () {},
        ),
      );

      expect(find.byType(TeacherQuizQuestionCard), findsOneWidget);
      expect(find.text('Question 1'), findsOneWidget);
      expect(find.text('Question 2'), findsOneWidget);

      await tester.tap(find.text('Question 2'));
      await tester.pump();

      expect(find.byType(TeacherQuizQuestionCard), findsOneWidget);
      expect(find.text('Question 2'), findsNWidgets(2));
    });

    testWidgets('selects a newly added question immediately', (tester) async {
      final titleController = TextEditingController(text: 'Chemistry warmup');
      final descriptionController = TextEditingController();
      final questions = [
        QuizDraftQuestion(text: 'Which gas supports burning?'),
      ];
      addTearDown(titleController.dispose);
      addTearDown(descriptionController.dispose);
      addTearDown(() {
        for (final question in questions) {
          question.dispose();
        }
      });

      await pumpCard(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            return TeacherQuizBuilderCard(
              quizzes: const [],
              selectedQuizId: null,
              editingQuizId: null,
              archiveMode: false,
              quizFormReadOnly: false,
              canDeleteSelectedQuiz: false,
              loading: false,
              isLoggedIn: true,
              titleController: titleController,
              descriptionController: descriptionController,
              readingTimeController: TextEditingController(text: '15'),
              resultsTimeController: TextEditingController(text: '10'),
              questionOnlyOnDisplay: false,
              showChoicesOnParticipant: true,
              questions: questions,
              onQuestionOnlyOnDisplayChanged: (_) {},
              onShowChoicesOnParticipantChanged: (_) {},
              onSelectedQuizChanged: (_) {},
              onArchiveModeChanged: (_) {},
              onLoadSelectedQuiz: () {},
              onSaveQuiz: () {},
              onResetDraft: () {},
              onRefreshQuizzes: () {},
              onArchiveSelectedQuiz: () {},
              onRestoreSelectedQuiz: () {},
              onDeleteSelectedQuiz: () {},
              onRemoveQuestion: (_) {},
              onSetCorrectChoice: (_, __) {},
              onRemoveChoice: (_, __) {},
              onAddChoice: (_) {},
              onAddQuestion: () {
                setState(() {
                  questions.add(QuizDraftQuestion());
                });
              },
            );
          },
        ),
      );

      await tester.tap(find.text('Add question'));
      await tester.pump();

      expect(find.byType(TeacherQuizQuestionCard), findsOneWidget);
      expect(find.text('Question 2'), findsNWidgets(2));
    });

    testWidgets('adds an answer choice in the active question', (tester) async {
      final titleController = TextEditingController(text: 'Chemistry warmup');
      final descriptionController = TextEditingController();
      final questions = [
        QuizDraftQuestion(text: 'Which gas supports burning?'),
      ];
      addTearDown(titleController.dispose);
      addTearDown(descriptionController.dispose);
      addTearDown(() {
        for (final question in questions) {
          question.dispose();
        }
      });

      await pumpCard(
        tester,
        TeacherQuizBuilderCard(
          quizzes: const [],
          selectedQuizId: null,
          editingQuizId: null,
          archiveMode: false,
          quizFormReadOnly: false,
          canDeleteSelectedQuiz: false,
          loading: false,
          isLoggedIn: true,
          titleController: titleController,
          descriptionController: descriptionController,
          readingTimeController: TextEditingController(text: '15'),
          resultsTimeController: TextEditingController(text: '10'),
          questionOnlyOnDisplay: false,
          showChoicesOnParticipant: true,
          questions: questions,
          onQuestionOnlyOnDisplayChanged: (_) {},
          onShowChoicesOnParticipantChanged: (_) {},
          onSelectedQuizChanged: (_) {},
          onArchiveModeChanged: (_) {},
          onLoadSelectedQuiz: () {},
          onSaveQuiz: () {},
          onResetDraft: () {},
          onRefreshQuizzes: () {},
          onArchiveSelectedQuiz: () {},
          onRestoreSelectedQuiz: () {},
          onDeleteSelectedQuiz: () {},
          onRemoveQuestion: (_) {},
          onSetCorrectChoice: (_, __) {},
          onRemoveChoice: (_, __) {},
          onAddChoice: (_) {},
          onAddQuestion: () {},
        ),
      );

      expect(questions.first.choices.length, 2);
      expect(find.text('Choice 3'), findsNothing);

      await tester.ensureVisible(find.text('Add choice'));
      await tester.pump();
      await tester.tap(find.text('Add choice'));
      await tester.pump();

      expect(questions.first.choices.length, 3);
      expect(find.text('Choice 3'), findsOneWidget);
    });
  });

  group('ParticipantProfileCard', () {
    test('anonymous join requires only a target and a display name', () {
      expect(
        participantJoinFormErrorKey(
          hasJoinTarget: true,
          name: 'Alice',
        ),
        isNull,
      );
      expect(
        participantJoinFormErrorKey(
          hasJoinTarget: true,
          name: '   ',
        ),
        isNotNull,
      );
      expect(
        participantJoinFormErrorKey(
          hasJoinTarget: false,
          name: 'Alice',
        ),
        isNotNull,
      );
    });

    testWidgets('captures profile data and triggers participant actions',
        (tester) async {
      final nameController = TextEditingController();
      final phoneController = TextEditingController();
      addTearDown(nameController.dispose);
      addTearDown(phoneController.dispose);

      bool? consentValue;
      var openLegalCalls = 0;
      var refreshLegalCalls = 0;
      var joinCalls = 0;

      await pumpCard(
        tester,
        ParticipantProfileCard(
          nameController: nameController,
          phoneController: phoneController,
          consent: false,
          consentLabel: 'I agree to data processing',
          loading: false,
          loadingLegalDocuments: false,
          error: null,
          onConsentChanged: (value) => consentValue = value,
          onOpenLegalDocuments: () => openLegalCalls += 1,
          onRefreshLegalDocuments: () => refreshLegalCalls += 1,
          onJoin: () => joinCalls += 1,
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'Alice');
      await tester.enterText(find.byType(TextField).at(1), '+70000000001');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.tap(find.text('Privacy & consent'));
      await tester.tap(find.text('Refresh legal docs'));
      await tester.tap(find.text('Join session'));
      await tester.pump();

      expect(nameController.text, 'Alice');
      expect(phoneController.text, '+70000000001');
      expect(consentValue, isTrue);
      expect(openLegalCalls, 1);
      expect(refreshLegalCalls, 1);
      expect(joinCalls, 1);
    });

    testWidgets('disables participant actions while loading', (tester) async {
      final nameController = TextEditingController();
      final phoneController = TextEditingController();
      addTearDown(nameController.dispose);
      addTearDown(phoneController.dispose);

      await pumpCard(
        tester,
        ParticipantProfileCard(
          nameController: nameController,
          phoneController: phoneController,
          consent: false,
          consentLabel: 'I agree',
          loading: true,
          loadingLegalDocuments: false,
          error: 'Network error',
          onConsentChanged: (_) {},
          onOpenLegalDocuments: () {},
          onRefreshLegalDocuments: () {},
          onJoin: () {},
        ),
      );

      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Privacy & consent'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Refresh legal docs'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Join session'),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('Network error'), findsOneWidget);
    });
  });

  group('ParticipantJoinConnectionCard', () {
    testWidgets('supports manual PIN preview and token fallback',
        (tester) async {
      final apiController =
          TextEditingController(text: 'http://localhost:8000/api');
      final pinController = TextEditingController();
      addTearDown(apiController.dispose);
      addTearDown(pinController.dispose);

      var previewCalls = 0;
      var useTokenCalls = 0;

      await pumpCard(
        tester,
        ParticipantJoinConnectionCard(
          apiController: apiController,
          pinController: pinController,
          useJoinTokenFromLink: false,
          joinTokenFromLink: 'token-123',
          loading: false,
          loadingJoinPreview: false,
          joinPreview: const {
            'session_status': 'waiting',
            'participants_count': 3,
            'can_join': true,
            'quiz': {
              'title': 'Biology',
              'description': 'Plants and cells',
            },
          },
          onLoadJoinPreview: () => previewCalls += 1,
          onUsePinInstead: () {},
          onUseJoinToken: () => useTokenCalls += 1,
        ),
      );

      await tester.enterText(find.byType(TextField).first, '123456');
      await tester.tap(find.text('Preview session'));
      await tester.tap(find.text('Use token from join link'));
      await tester.pump();

      expect(apiController.text, 'http://localhost:8000/api');
      expect(pinController.text, '123456');
      expect(previewCalls, 1);
      expect(useTokenCalls, 1);
      expect(find.text('Biology'), findsOneWidget);
      expect(find.text('Plants and cells'), findsOneWidget);
    });

    testWidgets('supports token mode and manual PIN switch', (tester) async {
      final apiController =
          TextEditingController(text: 'http://localhost:8000/api');
      final pinController = TextEditingController();
      addTearDown(apiController.dispose);
      addTearDown(pinController.dispose);

      var previewCalls = 0;
      var usePinCalls = 0;

      await pumpCard(
        tester,
        ParticipantJoinConnectionCard(
          apiController: apiController,
          pinController: pinController,
          useJoinTokenFromLink: true,
          joinTokenFromLink: 'token-123',
          loading: false,
          loadingJoinPreview: false,
          joinPreview: null,
          onLoadJoinPreview: () => previewCalls += 1,
          onUsePinInstead: () => usePinCalls += 1,
          onUseJoinToken: () {},
        ),
      );

      await tester.tap(find.text('Refresh preview'));
      await tester.tap(find.text('Use PIN instead'));
      await tester.pump();

      expect(find.text('Game found by QR'), findsOneWidget);
      expect(find.text('Token: token-123'), findsNothing);
      expect(previewCalls, 1);
      expect(usePinCalls, 1);
    });

    testWidgets('shows closed preview reason for unavailable sessions',
        (tester) async {
      final apiController =
          TextEditingController(text: 'http://localhost:8000/api');
      final pinController = TextEditingController(text: '123456');
      addTearDown(apiController.dispose);
      addTearDown(pinController.dispose);

      await pumpCard(
        tester,
        ParticipantJoinConnectionCard(
          apiController: apiController,
          pinController: pinController,
          useJoinTokenFromLink: false,
          joinTokenFromLink: null,
          loading: false,
          loadingJoinPreview: false,
          joinPreview: const {
            'session_status': 'finished',
            'participants_count': 12,
            'can_join': false,
            'closed_reason': 'Session is already finished.',
            'quiz': {
              'title': 'Closed quiz',
              'description': '',
            },
          },
          onLoadJoinPreview: () {},
          onUsePinInstead: () {},
          onUseJoinToken: () {},
        ),
      );

      expect(find.text('Closed quiz'), findsOneWidget);
      expect(find.text('Session is already finished.'), findsOneWidget);
      expect(find.text('Status: finished'), findsOneWidget);
      expect(find.text('Participants: 12'), findsOneWidget);
    });

    testWidgets('disables preview actions while preview is loading',
        (tester) async {
      final apiController =
          TextEditingController(text: 'http://localhost:8000/api');
      final pinController = TextEditingController(text: '123456');
      addTearDown(apiController.dispose);
      addTearDown(pinController.dispose);

      await pumpCard(
        tester,
        ParticipantJoinConnectionCard(
          apiController: apiController,
          pinController: pinController,
          useJoinTokenFromLink: false,
          joinTokenFromLink: 'token-123',
          loading: false,
          loadingJoinPreview: true,
          joinPreview: null,
          onLoadJoinPreview: () {},
          onUsePinInstead: () {},
          onUseJoinToken: () {},
        ),
      );

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Preview session'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Use token from join link'),
            )
            .onPressed,
        isNotNull,
      );
    });
  });

  group('ParticipantQuestionCard', () {
    testWidgets('keeps other answer choices tappable after one answer',
        (tester) async {
      final tappedChoices = <int>[];

      await pumpCard(
        tester,
        ParticipantQuestionCard(
          question: const {
            'id': 1,
            'text': 'Which gas supports burning?',
            'text_hidden': false,
            'time_limit_sec': 20,
            'choices_text_hidden': false,
            'choices': [
              {'id': 11, 'text': 'Oxygen', 'order': 1},
              {'id': 12, 'text': 'Nitrogen', 'order': 2},
            ],
          },
          onAnswer: tappedChoices.add,
          questionLocked: false,
          selectedChoiceId: 11,
          timeLeftLabel: '00:12',
          correctChoiceId: null,
          answerRevealed: false,
        ),
      );

      await tester.tap(find.text('Nitrogen'));
      await tester.pump();

      expect(tappedChoices, [12]);
    });
  });

  group('Фазовая блокировка ParticipantPanel', () {
    const sessionUuid = '123e4567-e89b-42d3-a456-426614174000';
    const apiBaseUrl = 'http://participant.test/api';
    const participantToken = 'participant-test-token';

    Map<String, dynamic> state({
      required String phase,
      int revision = 1,
    }) =>
        {
          'schema_version': 2,
          'session_id': sessionUuid,
          'state_revision': revision,
          'status': 'live',
          'phase': phase,
          'question_run_id': 7,
          'phase_ends_at':
              DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
          'is_answer_revealed': false,
          'current_question': {
            'id': 11,
            'text': 'Вопрос участнику',
            'text_hidden': false,
            'time_limit_sec': 30,
            'choices_text_hidden': false,
            'choices': const [
              {'id': 21, 'text': 'Первый вариант', 'order': 1},
              {'id': 22, 'text': 'Второй вариант', 'order': 2},
            ],
          },
          'answer': {
            'has_answer': false,
            'selected_choice_id': null,
            'answer_version': 0,
          },
        };

    Future<(MockClient, List<String>)> clientFor(
        Map<String, dynamic> initialState) async {
      const store = RoleAccessTokenStore();
      await store.persist(
        role: RoleAccessKind.participant,
        sessionUuid: sessionUuid,
        apiBaseUrl: apiBaseUrl,
        token: participantToken,
      );
      expect(
        (await store.restoreForSession(
          role: RoleAccessKind.participant,
          sessionUuid: sessionUuid,
        ))
            ?.token,
        participantToken,
      );
      final requests = <String>[];
      final client = MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        if (request.url.path.endsWith('/sessions/legal/current/')) {
          return http.Response('{}', 200);
        }
        if (request.url.path.endsWith('/sessions/join/preview/')) {
          return http.Response('{"can_join":true}', 200);
        }
        if (request.url.path.endsWith('/participation/')) {
          return http.Response(
            jsonEncode({
              'session_participant_id': 31,
              'state': initialState,
            }),
            200,
            headers: const {
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response('{"detail":"Неожиданный тестовый маршрут"}', 404);
      });
      return (client, requests);
    }

    Future<void> pumpRestoredPanel(
      WidgetTester tester, {
      required Map<String, dynamic> initialState,
      required _SocketHarness socket,
    }) async {
      final (client, requests) = await clientFor(initialState);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              textScaler: TextScaler.linear(0.5),
            ),
            child: ParticipantPanel(
              httpClient: client,
              initialJoinSource:
                  const ParticipantJoinSource(joinToken: sessionUuid),
              socketOpener: socket.open,
            ),
          ),
        ),
      );
      for (var attempt = 0;
          attempt < 20 &&
              find.byType(ParticipantQuestionCard).evaluate().isEmpty;
          attempt += 1) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      final visibleText = find
          .byType(Text)
          .evaluate()
          .map((element) => (element.widget as Text).data)
          .whereType<String>()
          .toList();
      expect(
        find.byType(ParticipantQuestionCard),
        findsOneWidget,
        reason: 'Запросы: $requests; видимый текст: $visibleText',
      );
    }

    InkWell answerTile(WidgetTester tester, String label) =>
        tester.widget<InkWell>(
          find
              .ancestor(
                of: find.text(label),
                matching: find.byType(InkWell),
              )
              .first,
        );

    testWidgets(
        'восстановление в delivery сохраняет блокировку на первом и следующих тактах',
        (tester) async {
      final socket = _SocketHarness();
      await pumpRestoredPanel(
        tester,
        initialState: state(phase: 'delivery'),
        socket: socket,
      );

      expect(
        tester
            .widget<ParticipantQuestionCard>(
                find.byType(ParticipantQuestionCard))
            .questionLocked,
        isTrue,
      );
      expect(answerTile(tester, 'Первый вариант').onTap, isNull);

      await tester.pump(const Duration(seconds: 1));
      expect(
        tester
            .widget<ParticipantQuestionCard>(
                find.byType(ParticipantQuestionCard))
            .questionLocked,
        isTrue,
      );
      expect(answerTile(tester, 'Первый вариант').onTap, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        'переход answering в delivery блокирует варианты, не меняя доступность answering',
        (tester) async {
      final socket = _SocketHarness();
      await pumpRestoredPanel(
        tester,
        initialState: state(phase: 'answering'),
        socket: socket,
      );

      expect(
        tester
            .widget<ParticipantQuestionCard>(
                find.byType(ParticipantQuestionCard))
            .questionLocked,
        isFalse,
      );
      expect(answerTile(tester, 'Первый вариант').onTap, isNotNull);
      await tester.pump(const Duration(seconds: 1));
      expect(answerTile(tester, 'Первый вариант').onTap, isNotNull);

      socket.emit(state(phase: 'delivery', revision: 2));
      await tester.pump();
      expect(
        tester
            .widget<ParticipantQuestionCard>(
                find.byType(ParticipantQuestionCard))
            .questionLocked,
        isTrue,
      );
      expect(answerTile(tester, 'Первый вариант').onTap, isNull);
      await tester.pump(const Duration(seconds: 1));
      expect(answerTile(tester, 'Первый вариант').onTap, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('TeacherRevealResultsCard', () {
    testWidgets('shows votes with percentages for each answer', (tester) async {
      await pumpCard(
        tester,
        TeacherRevealResultsCard(
          revealPayload: const {
            'total_answers': 4,
            'total_points_awarded': 900,
            'choices': [
              {
                'id': 1,
                'text': 'Oxygen',
                'order': 1,
                'is_correct': true,
                'answers_count': 3,
                'answers_percent': 75,
                'points_awarded': 900,
              },
              {
                'id': 2,
                'text': 'Nitrogen',
                'order': 2,
                'is_correct': false,
                'answers_count': 1,
                'answers_percent': 25,
                'points_awarded': 0,
              },
            ],
          },
        ),
      );

      expect(find.text('Oxygen'), findsOneWidget);
      expect(find.textContaining('75%'), findsOneWidget);
      expect(find.text('Nitrogen'), findsOneWidget);
      expect(find.textContaining('25%'), findsOneWidget);
      expect(find.textContaining('очков'), findsNothing);
      expect(find.textContaining('900'), findsNothing);
    });
  });
}

class _SocketHarness {
  void Function(Map<String, dynamic> message)? _onMessage;

  SupervisedSocket open({
    required Map<String, dynamic> authentication,
    required void Function(Map<String, dynamic> message) onMessage,
    required void Function(Object error) onError,
    required void Function(int? closeCode, String? closeReason) onDone,
    required void Function() onInvalidPayload,
  }) {
    _onMessage = onMessage;
    return _TestSocket();
  }

  void emit(Map<String, dynamic> state) {
    final onMessage = _onMessage;
    if (onMessage == null) {
      throw StateError('Тестовое WebSocket-соединение ещё не открыто.');
    }
    onMessage({'event': 'session_state', 'payload': state});
  }
}

class _TestSocket implements SupervisedSocket {
  @override
  Future<void> close() async {}
}
