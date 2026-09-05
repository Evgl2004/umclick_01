import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../core/app_config.dart';
import '../../core/live_socket_supervisor.dart';
import '../../core/ranking_format.dart';
import '../../core/role_access_token_store.dart';
import '../../core/session_uuid.dart';
import '../../core/session_state_reducer.dart';
import '../../core/value_utils.dart';
import '../../l10n/app_language.dart';
import '../../l10n/app_strings.dart';
import '../../shared/user_error_text.dart';

enum DisplayScene { lobby, reading, answering, delivery, results, finalView }

DisplayScene resolveDisplayScene(String status, String phase) {
  if (status == 'finished' || status == 'aborted' || phase == 'final') {
    return DisplayScene.finalView;
  }
  return switch (phase) {
    'reading' => DisplayScene.reading,
    'answering' => DisplayScene.answering,
    'delivery' => DisplayScene.delivery,
    'results' => DisplayScene.results,
    _ => DisplayScene.lobby,
  };
}

List<Map<String, dynamic>> _normalizedLeaderboardRows(List<dynamic> rows) {
  return rows
      .map((row) => mapOrNull(row) ?? <String, dynamic>{})
      .where((row) => row.isNotEmpty)
      .toList(growable: false);
}

List<Map<String, dynamic>> displayPodiumRows(List<dynamic> rows) {
  return _normalizedLeaderboardRows(rows).where((row) {
    final rank = asInt(row['rank'], 0);
    return rank >= 1 && rank <= 3;
  }).toList(growable: false);
}

List<Map<String, dynamic>> displayRemainingLeaderboardRows(List<dynamic> rows) {
  return _normalizedLeaderboardRows(rows).where((row) {
    final rank = asInt(row['rank'], 0);
    return rank < 1 || rank > 3;
  }).toList(growable: false);
}

class DisplaySessionPage extends StatefulWidget {
  const DisplaySessionPage({super.key});

  @override
  State<DisplaySessionPage> createState() => _DisplaySessionPageState();
}

class _DisplaySessionPageState extends State<DisplaySessionPage> {
  final _roleAccessStore = const RoleAccessTokenStore();
  Timer? _refreshTimer;
  Map<String, dynamic>? _state;
  String? _error;
  String _apiBaseUrl = defaultApiBaseUrl;
  String? _displayToken;
  String? _displayGrantId;
  String? _sessionUuid;
  SessionStateReducer? _stateReducer;
  LiveSocketSupervisor? _socketSupervisor;
  bool _loading = true;
  bool _fetching = false;

  @override
  void initState() {
    super.initState();
    _restoreAndStart();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _socketSupervisor?.stop();
    super.dispose();
  }

  ApiClient _client() => ApiClient(_apiBaseUrl);

  Future<void> _restoreAndStart() async {
    final uri = Uri.base;
    final rawSessionUuid = uri.queryParameters['session']?.trim();

    if (rawSessionUuid == null || rawSessionUuid.isEmpty) {
      setState(() {
        _loading = false;
        _error = uiText(
          ru: 'Не указан UUID сессии для экрана демонстрации.',
          en: 'Display session UUID is missing.',
        );
      });
      return;
    }
    late final String sessionUuid;
    try {
      sessionUuid = normalizeSessionUuid(rawSessionUuid);
    } on FormatException {
      setState(() {
        _loading = false;
        _error = uiText(
          ru: 'Указан некорректный UUID сессии.',
          en: 'The session UUID is invalid.',
        );
      });
      return;
    }

    final savedAccess = await _roleAccessStore.restoreForSession(
      role: RoleAccessKind.display,
      sessionUuid: sessionUuid,
    );
    if (!mounted) return;
    if (savedAccess == null) {
      setState(() {
        _sessionUuid = sessionUuid;
        _loading = false;
        _error = uiText(
          ru: 'Доступ к показу не найден. Откройте экран из панели преподавателя.',
          en: 'Display access was not found. Open the display from the teacher panel.',
        );
      });
      return;
    }

    setState(() {
      _sessionUuid = sessionUuid;
      _apiBaseUrl = savedAccess.apiBaseUrl;
      _displayToken = savedAccess.token;
      _displayGrantId = savedAccess.grantId;
    });

    await _refreshState();
    if (_displayToken == null) return;
    if (_state != null && _displayToken != null) {
      await _connectSocket();
    }
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _refreshState(showLoading: false);
    });
  }

  Future<void> _connectSocket() async {
    final sessionUuid = _sessionUuid;
    final displayToken = _displayToken;
    if (sessionUuid == null || displayToken == null) return;
    await _socketSupervisor?.stop();
    _socketSupervisor = LiveSocketSupervisor(
      url: _client().sessionWebSocketUrl(sessionUuid),
      authentication: {
        'event': 'auth',
        'access_type': 'display',
        'token': displayToken,
      },
      onMessage: _handleSocketMessage,
      onConnectionError: (error) {
        final code = error['code']?.toString();
        if (code == 'access_invalid' ||
            code == 'access_revoked' ||
            code == 'access_expired') {
          unawaited(_invalidateDisplayAccess(code!));
        }
        if (mounted) {
          setState(() {
            _error =
                'Соединение показа отклонено: ${code ?? 'неизвестная причина'}.';
          });
        }
      },
      onInvalidPayload: () {
        if (mounted) {
          setState(() {
            _error = 'Получено некорректное сообщение показа.';
          });
        }
      },
      onTransportError: (_) {
        if (mounted) {
          setState(() {
            _error = 'Соединение показа временно недоступно.';
          });
        }
      },
      onStopped: (_, reason) {
        if (mounted && _displayToken != null) {
          setState(() {
            _error = 'Повтор соединения показа прекращён.';
          });
        }
      },
    );
    await _socketSupervisor!.start();
  }

  void _handleSocketMessage(Map<String, dynamic> message) {
    final payload = mapOrNull(message['payload']);
    final reducer = _stateReducer;
    if (payload == null || reducer == null) return;
    final reduction = reducer.apply(
      payload,
      source: SessionStateSource.websocket,
    );
    if (!reduction.accepted || !mounted) return;
    setState(() {
      _state = reduction.state;
      _error = null;
    });
  }

  Future<void> _invalidateDisplayAccess(String code) async {
    final sessionUuid = _sessionUuid;
    final grantId = _displayGrantId;
    if (sessionUuid == null || grantId == null) return;
    await _roleAccessStore.clear(
      role: RoleAccessKind.display,
      sessionUuid: sessionUuid,
      apiBaseUrl: _apiBaseUrl,
      grantId: grantId,
    );
    _displayToken = null;
    _displayGrantId = null;
    _refreshTimer?.cancel();
    await _socketSupervisor?.stop();
    if (!mounted) return;
    setState(() {
      _error = switch (code) {
        'access_revoked' => 'Доступ к показу отозван.',
        'access_expired' => 'Срок доступа к показу истёк.',
        _ => 'Доступ к показу недействителен.',
      };
    });
  }

  Future<void> _refreshState({bool showLoading = true}) async {
    final sessionUuid = _sessionUuid;
    final displayToken = _displayToken;
    if (sessionUuid == null || displayToken == null || _fetching) return;

    if (showLoading && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    _fetching = true;
    try {
      final state = await _client().getSessionDisplayState(
        sessionUuid,
        displayToken: displayToken,
      );
      if (!mounted) return;
      var reducer = _stateReducer;
      if (reducer == null) {
        reducer = SessionStateReducer(sessionUuid);
        _stateReducer = reducer;
      }
      final reduction = reducer.apply(
        state,
        source: SessionStateSource.displayRead,
      );
      if (!reduction.accepted) {
        throw StateError(
          reduction.reason ?? 'Сервер вернул несовместимое состояние показа.',
        );
      }
      setState(() {
        _state = reduction.state;
        _error = null;
      });
    } on ApiException catch (e) {
      if (e.invalidatesRoleAccess) {
        await _invalidateDisplayAccess(e.code!);
        return;
      }
      if (!mounted) return;
      setState(() {
        _error = userErrorText(e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userErrorText(e);
      });
    } finally {
      _fetching = false;
      if (mounted && showLoading) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  String _countdownLabel(Object? rawEndsAt) {
    final endsAt = parseDateTimeLocal(rawEndsAt);
    if (endsAt == null) return '--:--';
    final remaining = endsAt.difference(DateTime.now());
    if (remaining.isNegative) return '00:00';
    return formatRemaining(remaining);
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final currentQuestion = mapOrNull(state?['display_question']);
    return Scaffold(
      backgroundColor: const Color(0xFF061A23),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        child: _loading && state == null
            ? const _DisplayLoading()
            : _error != null && state == null
                ? _DisplayError(message: _error!)
                : _DisplayStage(
                    key: ValueKey(
                      '${state?['status']}-${state?['phase']}-${currentQuestion?['id']}',
                    ),
                    state: state ?? <String, dynamic>{},
                    countdownLabel: _countdownLabel,
                    error: _error,
                  ),
      ),
    );
  }
}

class _DisplayStage extends StatelessWidget {
  const _DisplayStage({
    super.key,
    required this.state,
    required this.countdownLabel,
    required this.error,
  });

  final Map<String, dynamic> state;
  final String Function(Object? rawEndsAt) countdownLabel;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final status = state['status']?.toString() ?? 'waiting';
    final phase = state['phase']?.toString() ?? 'lobby';
    final quiz = mapOrNull(state['quiz']) ?? <String, dynamic>{};
    final content = switch (resolveDisplayScene(status, phase)) {
      DisplayScene.finalView => _FinalDisplaySlide(
          state: state,
          aborted: status == 'aborted',
        ),
      DisplayScene.results => _ResultsDisplaySlide(
          state: state,
          countdown: countdownLabel(state['phase_ends_at']),
        ),
      DisplayScene.answering => _AnsweringDisplaySlide(
          state: state,
          countdown: countdownLabel(state['phase_ends_at']),
        ),
      DisplayScene.delivery => _DeliveryDisplaySlide(
          state: state,
          countdown: countdownLabel(state['phase_ends_at']),
        ),
      DisplayScene.reading => _ReadingDisplaySlide(
          state: state,
          countdown: countdownLabel(state['phase_ends_at']),
        ),
      DisplayScene.lobby => _LobbyDisplaySlide(state: state),
    };

    return Container(
      key: const ValueKey('display-stage'),
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: double.infinity),
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.topRight,
          radius: 1.25,
          colors: [Color(0xFF14B8A6), Color(0xFF063B3D), Color(0xFF061A23)],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DisplayTopBar(
                title: quiz['title']?.toString() ?? appText(AppText.appTitle),
                pin: state['pin']?.toString() ?? '-',
                participants: asInt(state['participants_count']),
                status: sessionStatusText(status),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                _InlineDisplayError(message: error!),
              ],
              const SizedBox(height: 20),
              Expanded(child: content),
            ],
          ),
        ),
      ),
    );
  }
}

class _DisplayTopBar extends StatelessWidget {
  const _DisplayTopBar({
    required this.title,
    required this.pin,
    required this.participants,
    required this.status,
  });

  final String title;
  final String pin;
  final int participants;
  final String status;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
          ),
        ),
        const SizedBox(width: 18),
        _DisplayChip(label: 'PIN: $pin', icon: Icons.pin_outlined),
        const SizedBox(width: 10),
        _DisplayChip(label: '$participants', icon: Icons.group_outlined),
        const SizedBox(width: 10),
        _DisplayChip(label: status, icon: Icons.flag_outlined),
      ],
    );
  }
}

class _LobbyDisplaySlide extends StatelessWidget {
  const _LobbyDisplaySlide({required this.state});

  final Map<String, dynamic> state;

  @override
  Widget build(BuildContext context) {
    return _SlideShell(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.qr_code_2_rounded, color: Colors.white, size: 92),
          const SizedBox(height: 24),
          Text(
            uiText(
              ru: 'Ожидаем запуск вопроса',
              en: 'Waiting for the question',
            ),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displayMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
          ),
          const SizedBox(height: 18),
          Text(
            uiText(
              ru: 'Участники могут подключаться по PIN или QR-коду на экране ведущего.',
              en: 'Participants can join with the PIN or QR code on the host screen.',
            ),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.82),
                ),
          ),
        ],
      ),
    );
  }
}

class _ReadingDisplaySlide extends StatelessWidget {
  const _ReadingDisplaySlide({
    required this.state,
    required this.countdown,
  });

  final Map<String, dynamic> state;
  final String countdown;

  @override
  Widget build(BuildContext context) {
    final question =
        mapOrNull(state['display_question']) ?? <String, dynamic>{};
    return _SlideShell(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _CountdownOrb(label: countdown),
          const SizedBox(height: 28),
          Text(
            uiText(ru: 'Вопрос', en: 'Question'),
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 16),
          Text(
            question['text']?.toString() ?? '',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displayLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  height: 1.05,
                ),
          ),
        ],
      ),
    );
  }
}

class _AnsweringDisplaySlide extends StatelessWidget {
  const _AnsweringDisplaySlide({
    required this.state,
    required this.countdown,
  });

  final Map<String, dynamic> state;
  final String countdown;

  @override
  Widget build(BuildContext context) {
    final question =
        mapOrNull(state['display_question']) ?? <String, dynamic>{};
    final choices = _sortedChoices(question['choices']);
    return _SlideShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  question['text']?.toString() ?? '',
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        height: 1.08,
                      ),
                ),
              ),
              const SizedBox(width: 24),
              _CountdownOrb(label: countdown),
            ],
          ),
          const SizedBox(height: 26),
          Expanded(
            child: _DisplayChoiceGrid(choices: choices),
          ),
        ],
      ),
    );
  }
}

class _DeliveryDisplaySlide extends StatelessWidget {
  const _DeliveryDisplaySlide({
    required this.state,
    required this.countdown,
  });

  final Map<String, dynamic> state;
  final String countdown;

  @override
  Widget build(BuildContext context) {
    final question =
        mapOrNull(state['display_question']) ?? <String, dynamic>{};
    return _SlideShell(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _CountdownOrb(label: countdown),
          const SizedBox(height: 28),
          const Icon(Icons.sync_rounded, color: Colors.white, size: 72),
          const SizedBox(height: 20),
          Text(
            'Завершаем приём ответов',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displayMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
          ),
          const SizedBox(height: 16),
          Text(
            question['text']?.toString() ?? '',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.82),
                ),
          ),
        ],
      ),
    );
  }
}

class _ResultsDisplaySlide extends StatelessWidget {
  const _ResultsDisplaySlide({
    required this.state,
    required this.countdown,
  });

  final Map<String, dynamic> state;
  final String countdown;

  @override
  Widget build(BuildContext context) {
    final reveal = mapOrNull(state['reveal']) ?? <String, dynamic>{};
    final question = mapOrNull(reveal['question']) ??
        mapOrNull(state['display_question']) ??
        <String, dynamic>{};
    final choices = _sortedChoices(reveal['choices']);
    final maxVotes = choices.fold<int>(
      1,
      (maxValue, choice) => asInt(choice['answers_count']) > maxValue
          ? asInt(choice['answers_count'])
          : maxValue,
    );

    return _SlideShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  question['text']?.toString() ?? '',
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                ),
              ),
              const SizedBox(width: 18),
              _CountdownOrb(label: countdown),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            uiText(ru: 'Статистика ответов', en: 'Answer statistics'),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.86),
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Column(
              children: [
                for (final entry in choices.asMap().entries) ...[
                  _HistogramRow(
                    choice: entry.value,
                    index: entry.key,
                    maxVotes: maxVotes,
                  ),
                  if (entry.key != choices.length - 1)
                    const SizedBox(height: 14),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FinalDisplaySlide extends StatelessWidget {
  const _FinalDisplaySlide({
    required this.state,
    required this.aborted,
  });

  final Map<String, dynamic> state;
  final bool aborted;

  @override
  Widget build(BuildContext context) {
    final leaderboard = (state['leaderboard'] as List<dynamic>? ?? <dynamic>[])
        .map((row) => mapOrNull(row) ?? <String, dynamic>{})
        .where((row) => row.isNotEmpty)
        .toList();
    final podium = displayPodiumRows(leaderboard);
    final rest = displayRemainingLeaderboardRows(leaderboard);

    return _SlideShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            aborted
                ? uiText(
                    ru: 'Игра остановлена ведущим',
                    en: 'Game stopped by host',
                  )
                : uiText(ru: 'Финальный рейтинг', en: 'Final leaderboard'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displayMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
          ),
          const SizedBox(height: 24),
          if (podium.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  appText(AppText.participantNoLeaderboardYet),
                  style: const TextStyle(color: Colors.white, fontSize: 28),
                ),
              ),
            )
          else ...[
            _PodiumDisplay(rows: podium),
            const SizedBox(height: 20),
            Expanded(
              child: ListView(
                children: [
                  for (final row in rest)
                    _LeaderboardDisplayRow(row: row, compact: true),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SlideShell extends StatelessWidget {
  const _SlideShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(34),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(42),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.24),
            blurRadius: 42,
            offset: const Offset(0, 24),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _DisplayChoiceGrid extends StatelessWidget {
  const _DisplayChoiceGrid({required this.choices});

  final List<Map<String, dynamic>> choices;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final useTwoColumns = constraints.maxWidth >= 840;
        final width = useTwoColumns
            ? (constraints.maxWidth - 18) / 2
            : constraints.maxWidth;
        return SingleChildScrollView(
          child: Wrap(
            spacing: 18,
            runSpacing: 18,
            children: choices.asMap().entries.map((entry) {
              final color = _choiceColor(entry.key);
              final icon = _choiceIcon(entry.key);
              return SizedBox(
                width: width,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 150),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(34),
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: 0.28),
                        blurRadius: 24,
                        offset: const Offset(0, 14),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Icon(icon, color: Colors.white, size: 50),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Text(
                          entry.value['text']?.toString() ?? '',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }
}

class _HistogramRow extends StatelessWidget {
  const _HistogramRow({
    required this.choice,
    required this.index,
    required this.maxVotes,
  });

  final Map<String, dynamic> choice;
  final int index;
  final int maxVotes;

  @override
  Widget build(BuildContext context) {
    final votes = asInt(choice['answers_count']);
    final percent = asInt(choice['answers_percent']);
    final isCorrect = choice['is_correct'] == true;
    final color = isCorrect ? const Color(0xFF22C55E) : _choiceColor(index);
    final fraction = (votes / maxVotes).clamp(0.05, 1.0).toDouble();

    return Expanded(
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Icon(
              isCorrect ? Icons.check_rounded : _choiceIcon(index),
              color: Colors.white,
              size: 38,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  children: [
                    Container(
                      height: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.13),
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: constraints.maxWidth * fraction,
                      height: double.infinity,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              choice['text']?.toString() ?? '',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w900,
                                  ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '$votes',
                                style: Theme.of(context)
                                    .textTheme
                                    .displaySmall
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w900,
                                    ),
                              ),
                              Text(
                                '$percent%',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(
                                      color:
                                          Colors.white.withValues(alpha: 0.86),
                                      fontWeight: FontWeight.w800,
                                    ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PodiumDisplay extends StatelessWidget {
  const _PodiumDisplay({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (rows.length > 1)
          Expanded(child: _PodiumPlace(row: rows[1], height: 170)),
        if (rows.isNotEmpty)
          Expanded(child: _PodiumPlace(row: rows[0], height: 230)),
        if (rows.length > 2)
          Expanded(child: _PodiumPlace(row: rows[2], height: 135)),
      ],
    );
  }
}

class _PodiumPlace extends StatelessWidget {
  const _PodiumPlace({
    required this.row,
    required this.height,
  });

  final Map<String, dynamic> row;
  final double height;

  @override
  Widget build(BuildContext context) {
    final place = asInt(row['rank']);
    final color = switch (place) {
      1 => const Color(0xFFFFC857),
      2 => const Color(0xFFC0C6D4),
      _ => const Color(0xFFCD7F32),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            row['participant_name']?.toString() ?? '',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
          ),
          const SizedBox(height: 8),
          Container(
            height: height,
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: color,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '#$place',
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        color: const Color(0xFF111827),
                        fontWeight: FontWeight.w900,
                      ),
                ),
                Text(
                  uiText(
                    ru: "${asInt(row['correct_answers'])} верных",
                    en: "${asInt(row['correct_answers'])} correct",
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF111827),
                    fontWeight: FontWeight.w900,
                    fontSize: 20,
                  ),
                ),
                Text(
                  formatRankingTimeMs(asInt(row['correct_time_ms'])),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF111827),
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LeaderboardDisplayRow extends StatelessWidget {
  const _LeaderboardDisplayRow({required this.row, this.compact = false});

  final Map<String, dynamic> row;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Text(
            '#${row['rank'] ?? '-'}',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              row['participant_name']?.toString() ?? '',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: compact ? 18 : 24,
              ),
            ),
          ),
          Text(
            uiText(
              ru: '${asInt(row['correct_answers'])} верных · ${formatRankingTimeMs(asInt(row['correct_time_ms']))}',
              en: '${asInt(row['correct_answers'])} correct · ${formatRankingTimeMs(asInt(row['correct_time_ms']))}',
            ),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 24,
            ),
          ),
        ],
      ),
    );
  }
}

class _CountdownOrb extends StatelessWidget {
  const _CountdownOrb({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 148,
      height: 148,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.26),
            blurRadius: 28,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Center(
        child: Text(
          label,
          style: Theme.of(context).textTheme.displaySmall?.copyWith(
                color: const Color(0xFF023047),
                fontWeight: FontWeight.w900,
              ),
        ),
      ),
    );
  }
}

class _DisplayChip extends StatelessWidget {
  const _DisplayChip({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _DisplayLoading extends StatelessWidget {
  const _DisplayLoading();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        uiText(ru: 'Загружаем экран демонстрации...', en: 'Loading display...'),
        style: const TextStyle(color: Colors.white, fontSize: 28),
      ),
    );
  }
}

class _DisplayError extends StatelessWidget {
  const _DisplayError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: const Color(0xFF061A23),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineDisplayError extends StatelessWidget {
  const _InlineDisplayError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        message,
        style: const TextStyle(color: Colors.white),
      ),
    );
  }
}

List<Map<String, dynamic>> _sortedChoices(Object? rawChoices) {
  return (rawChoices as List<dynamic>? ?? <dynamic>[])
      .map((raw) => mapOrNull(raw) ?? <String, dynamic>{})
      .where((choice) => choice.isNotEmpty)
      .toList()
    ..sort((a, b) => asInt(a['order']).compareTo(asInt(b['order'])));
}

Color _choiceColor(int index) {
  const colors = [
    Color(0xFFE21B3C),
    Color(0xFF1368CE),
    Color(0xFFD89E00),
    Color(0xFF26890C),
    Color(0xFF8E24AA),
    Color(0xFF00ACC1),
  ];
  return colors[index % colors.length];
}

IconData _choiceIcon(int index) {
  const icons = [
    Icons.change_history,
    Icons.diamond_outlined,
    Icons.circle_outlined,
    Icons.square_outlined,
    Icons.star_border_rounded,
    Icons.hexagon_outlined,
  ];
  return icons[index % icons.length];
}
