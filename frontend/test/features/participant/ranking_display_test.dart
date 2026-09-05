import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umclick_frontend/features/participant/widgets/live_session_widgets.dart';
import 'package:umclick_frontend/l10n/app_language.dart';

void main() {
  testWidgets('participant ranking keeps close millisecond results distinct',
      (tester) async {
    appLanguage.value = UiLanguage.ru;
    addTearDown(() => appLanguage.value = UiLanguage.ru);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ParticipantPodiumCard(
              currentSessionParticipantId: 1,
              leaderboard: [
                {
                  'rank': 1,
                  'session_participant_id': 1,
                  'participant_name': 'Анна',
                  'correct_answers': 2,
                  'correct_time_ms': 40234,
                },
                {
                  'rank': 2,
                  'session_participant_id': 2,
                  'participant_name': 'Борис',
                  'correct_answers': 2,
                  'correct_time_ms': 40432,
                },
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('40,234 с'), findsNWidgets(2));
    expect(find.textContaining('40,432 с'), findsOneWidget);
    expect(find.textContaining('очк'), findsNothing);
  });

  testWidgets('participant podium includes every participant at rank three',
      (tester) async {
    appLanguage.value = UiLanguage.ru;
    addTearDown(() => appLanguage.value = UiLanguage.ru);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ParticipantPodiumCard(
              currentSessionParticipantId: 1,
              leaderboard: [
                {
                  'rank': 1,
                  'session_participant_id': 1,
                  'participant_name': 'Первая',
                },
                {
                  'rank': 2,
                  'session_participant_id': 2,
                  'participant_name': 'Вторая',
                },
                {
                  'rank': 2,
                  'session_participant_id': 3,
                  'participant_name': 'Тоже вторая',
                },
                {
                  'rank': 3,
                  'session_participant_id': 4,
                  'participant_name': 'Третья',
                },
                {
                  'rank': 4,
                  'session_participant_id': 5,
                  'participant_name': 'Четвёртая',
                },
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('Первая'), findsOneWidget);
    expect(find.text('Вторая'), findsOneWidget);
    expect(find.text('Тоже вторая'), findsOneWidget);
    expect(find.text('Третья'), findsOneWidget);
    expect(find.text('Четвёртая'), findsNothing);
  });
}
