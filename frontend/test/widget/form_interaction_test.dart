import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:umclick_frontend/features/participant/widgets/join_connection_card.dart';
import 'package:umclick_frontend/features/participant/widgets/profile_card.dart';
import 'package:umclick_frontend/features/teacher/widgets/teacher_auth_card.dart';
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

  group('ParticipantProfileCard', () {
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

      await tester.enterText(find.byType(TextField).at(1), '123456');
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

      expect(find.text('Token: token-123'), findsOneWidget);
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
}
