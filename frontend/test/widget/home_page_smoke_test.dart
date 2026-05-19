import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:umclick_frontend/features/participant/participant_panel.dart';
import 'package:umclick_frontend/features/participant/widgets/join_connection_card.dart';
import 'package:umclick_frontend/features/participant/widgets/participant_hero.dart';
import 'package:umclick_frontend/features/participant/widgets/profile_card.dart';
import 'package:umclick_frontend/features/teacher/teacher_panel.dart';
import 'package:umclick_frontend/features/teacher/widgets/teacher_auth_card.dart';
import 'package:umclick_frontend/features/teacher/widgets/teacher_quiz_builder_card.dart';
import 'package:umclick_frontend/features/teacher/widgets/teacher_session_setup_card.dart';
import 'package:umclick_frontend/l10n/app_language.dart';
import 'package:umclick_frontend/main.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appLanguage.value = UiLanguage.ru;
  });

  testWidgets('UmclickApp mounts the home shell', (tester) async {
    await tester.pumpWidget(const UmclickApp());
    await tester.pump();

    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(LanguageSwitcher), findsOneWidget);
    expect(find.byType(TeacherPanel), findsOneWidget);
  });

  testWidgets('HomePage opens teacher tab by default', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(TeacherPanel), findsOneWidget);
    expect(find.byType(TeacherAuthCard), findsOneWidget);
    expect(find.text('Рабочий кабинет откроется после входа'), findsOneWidget);
    expect(find.byType(TeacherQuizBuilderCard), findsNothing);
    expect(find.byType(TeacherSessionSetupCard), findsNothing);
  });

  testWidgets('HomePage renders teacher tab on wide desktop layout',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 950));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(TeacherPanel), findsOneWidget);
    expect(find.byType(TeacherAuthCard), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('HomePage can switch to participant tab', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.group));
    await tester.pump();

    expect(find.byType(ParticipantPanel), findsOneWidget);
    expect(find.byType(ParticipantHero), findsOneWidget);
    expect(find.byType(ParticipantJoinConnectionCard), findsOneWidget);
    expect(find.byType(ParticipantProfileCard), findsOneWidget);
  });

  testWidgets('HomePage respects participant initial index', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage(initialIndex: 1)));
    await tester.pump();

    expect(find.byType(ParticipantPanel), findsOneWidget);
    expect(find.byType(TeacherPanel), findsNothing);
    expect(find.byType(ParticipantJoinConnectionCard), findsOneWidget);
  });
}
