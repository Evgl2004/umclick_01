import 'package:flutter_test/flutter_test.dart';
import 'package:umclick_frontend/features/display/display_session_page.dart';

void main() {
  test('maps every server phase to a distinct display scene', () {
    expect(resolveDisplayScene('waiting', 'lobby'), DisplayScene.lobby);
    expect(resolveDisplayScene('live', 'reading'), DisplayScene.reading);
    expect(resolveDisplayScene('live', 'answering'), DisplayScene.answering);
    expect(resolveDisplayScene('live', 'delivery'), DisplayScene.delivery);
    expect(resolveDisplayScene('live', 'results'), DisplayScene.results);
    expect(resolveDisplayScene('finished', 'final'), DisplayScene.finalView);
    expect(resolveDisplayScene('aborted', 'final'), DisplayScene.finalView);
  });

  test('display podium includes all rank-three ties and splits the rest', () {
    const rows = <dynamic>[
      {'rank': 1, 'participant_name': 'A'},
      {'rank': 2, 'participant_name': 'B'},
      {'rank': 2, 'participant_name': 'C'},
      {'rank': 3, 'participant_name': 'D'},
      {'rank': 4, 'participant_name': 'E'},
    ];

    expect(
      displayPodiumRows(rows).map((row) => row['participant_name']),
      ['A', 'B', 'C', 'D'],
    );
    expect(
      displayRemainingLeaderboardRows(rows)
          .map((row) => row['participant_name']),
      ['E'],
    );
  });
}
