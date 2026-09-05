import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../api/api_client.dart';
import '../../core/app_config.dart';
import '../../core/countdown_ticker.dart';
import '../../core/live_event_log.dart';
import '../../core/live_socket_supervisor.dart';
import '../../core/participant_answer_controller.dart';
import '../../core/participant_join_location.dart';
import '../../core/request_id.dart';
import '../../core/role_access_token_store.dart';
import '../../core/session_uuid.dart';
import '../../core/session_state_reducer.dart';
import '../../core/value_utils.dart';
import '../../l10n/app_strings.dart';
import '../../shared/user_error_text.dart';
import '../../shared/widgets/app_surfaces.dart';
import '../legal/legal_documents.dart';
import 'models/join_source.dart';
import 'widgets/join_connection_card.dart';
import 'widgets/live_session_widgets.dart';
import 'widgets/participant_hero.dart';
import 'widgets/profile_card.dart';
import 'widgets/question_card.dart';

AppText? participantJoinFormErrorKey({
  required bool hasJoinTarget,
  required String name,
}) {
  if (!hasJoinTarget) return AppText.participantJoinTargetRequired;
  if (name.trim().isEmpty) return AppText.participantNameRequiredError;
  return null;
}

class ParticipantPanel extends StatefulWidget {
  const ParticipantPanel({
    super.key,
    this.httpClient,
    this.initialJoinSource,
    this.socketOpener,
  });

  final http.Client? httpClient;
  final ParticipantJoinSource? initialJoinSource;
  final SupervisedSocketOpener? socketOpener;

  @override
  State<ParticipantPanel> createState() => _ParticipantPanelState();
}

class _ParticipantPanelState extends State<ParticipantPanel> {
  final _apiController = TextEditingController(text: defaultApiBaseUrl);
  final _pinController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  Map<String, dynamic>? _joinPayload;
  Map<String, dynamic>? _activeQuestion;
  Map<String, dynamic>? _revealPayload;
  List<dynamic> _finalLeaderboard = [];
  bool _consent = false;
  bool _loading = false;
  String? _error;
  String _sessionStatus = 'waiting';
  String _sessionPhase = 'lobby';
  bool _questionAnswered = false;
  int? _selectedChoiceId;
  bool _sessionFinished = false;
  String _timeLeftLabel = '--:--';
  bool _isQuestionExpired = false;
  Map<String, dynamic>? _legalDocuments;
  bool _loadingLegalDocuments = false;
  Map<String, dynamic>? _joinPreview;
  bool _loadingJoinPreview = false;
  bool _syncingSessionState = false;
  String? _joinTokenFromLink;
  bool _useJoinTokenFromLink = false;
  String? _participantToken;
  String? _sessionUuid;
  Map<String, dynamic>? _pendingJoinPayload;
  bool _participantTokenPersisted = false;
  final _roleAccessStore = const RoleAccessTokenStore();
  SessionStateReducer? _sessionStateReducer;
  ParticipantAnswerController? _answerController;
  ParticipantAnswerRequest? _uncertainAnswer;
  ParticipantAnswerRequest? _latestAnswerRequest;

  LiveSocketSupervisor? _socketSupervisor;
  bool _socketConnected = false;
  Timer? _countdownTimer;
  Timer? _statePollingTimer;
  final _countdownTicker = const CountdownTicker();
  final _eventLog = const LiveEventLog();
  final List<String> _events = [];

  ApiClient _client() => ApiClient(
        _apiController.text.trim(),
        httpClient: widget.httpClient,
      );

  String? get _activeJoinToken =>
      _useJoinTokenFromLink ? _joinTokenFromLink : null;

  int? get _correctChoiceId {
    final choices =
        (_revealPayload?['choices'] as List<dynamic>? ?? <dynamic>[])
            .map((raw) => mapOrNull(raw) ?? <String, dynamic>{});
    for (final choice in choices) {
      if (choice['is_correct'] == true) {
        return asInt(choice['id'], -1);
      }
    }
    return null;
  }

  String? get _activePin {
    if (_useJoinTokenFromLink) {
      return null;
    }
    final pin = _pinController.text.trim();
    return pin.isEmpty ? null : pin;
  }

  String? _joinFormErrorText() {
    final issue = participantJoinFormErrorKey(
      hasJoinTarget: _activeJoinToken != null || _activePin != null,
      name: _nameController.text,
    );
    return issue == null ? null : appText(issue);
  }

  bool _shouldShowManualPinFallback(Object error) {
    if (!_useJoinTokenFromLink) {
      return false;
    }
    if (error is StateError) {
      return true;
    }
    if (error is! ApiException) {
      return false;
    }
    if (error.statusCode == 404) {
      return true;
    }

    final body = error.body.toLowerCase();
    return body.contains('not found') ||
        body.contains('expired') ||
        body.contains('finished') ||
        body.contains('closed');
  }

  @override
  void initState() {
    super.initState();
    final initialJoinSource =
        widget.initialJoinSource ?? ParticipantJoinSource.fromUri(Uri.base);
    _configureJoinSource(initialJoinSource);
    _loadLegalDocuments(showError: false);
    _loadJoinPreview(showError: initialJoinSource.hasJoinTarget);
    unawaited(_restoreParticipantAccess(initialJoinSource));
  }

  Future<void> _restoreParticipantAccess(
    ParticipantJoinSource joinSource,
  ) async {
    final rawUuid = joinSource.joinToken;
    if (rawUuid == null) return;
    late final String sessionUuid;
    try {
      sessionUuid = normalizeSessionUuid(rawUuid);
    } on FormatException {
      return;
    }

    final stored = await _roleAccessStore.restoreForSession(
      role: RoleAccessKind.participant,
      sessionUuid: sessionUuid,
    );
    if (stored == null || !mounted || _joinPayload != null) return;

    _apiController.text = stored.apiBaseUrl;
    _participantToken = stored.token;
    _sessionUuid = sessionUuid;
    _participantTokenPersisted = true;
    try {
      final payload = await _client().getParticipationState(
        sessionUuid,
        participantToken: stored.token,
      );
      if (!mounted) return;
      await _activateParticipation(payload, sessionUuid);
      _appendEvent('Участие восстановлено из локального хранилища.');
    } on ApiException catch (e) {
      await _clearParticipantAccessIfInvalid(e);
      if (!mounted) return;
      setState(() {
        _error = userErrorText(e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userErrorText(e);
      });
    }
  }

  Future<void> _clearParticipantAccessIfInvalid(ApiException error) async {
    final sessionUuid = _sessionUuid;
    if (!error.invalidatesRoleAccess || sessionUuid == null) return;
    await _roleAccessStore.clear(
      role: RoleAccessKind.participant,
      sessionUuid: sessionUuid,
      apiBaseUrl: _apiController.text.trim(),
    );
    _answerController?.cancelPending();
    _statePollingTimer?.cancel();
    await _closeSocket();
    _participantToken = null;
    _participantTokenPersisted = false;
    _sessionStateReducer = null;
    _answerController = null;
    _uncertainAnswer = null;
    _latestAnswerRequest = null;
    if (mounted) {
      setState(() {
        _joinPayload = null;
      });
    }
  }

  void _configureJoinSource(ParticipantJoinSource joinSource) {
    final joinToken = joinSource.joinToken;
    if (joinToken != null) {
      _joinTokenFromLink = joinToken;
      _useJoinTokenFromLink = joinSource.shouldUseJoinToken;
      return;
    }

    final pin = joinSource.pin;
    if (pin != null) {
      _pinController.text = pin;
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _statePollingTimer?.cancel();
    _answerController?.cancelPending();
    _closeSocket();
    _apiController.dispose();
    _pinController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _appendEvent(String text) {
    if (!mounted) return;
    setState(() {
      _eventLog.prepend(_events, text);
    });
  }

  Future<void> _loadJoinPreview({bool showError = true}) async {
    if (_loadingJoinPreview) {
      return;
    }

    final joinToken = _activeJoinToken;
    final pin = _activePin;
    if ((joinToken == null || joinToken.isEmpty) &&
        (pin == null || pin.isEmpty)) {
      if (showError) {
        setState(() {
          _error = appText(AppText.participantJoinTargetRequired);
        });
      }
      return;
    }

    setState(() {
      _loadingJoinPreview = true;
      if (showError) {
        _error = null;
      }
    });

    try {
      final preview = await _client().previewJoinSession(
        pin: pin,
        joinToken: joinToken,
      );
      if (!mounted) return;
      setState(() {
        _joinPreview = preview;
        _legalDocuments =
            mapOrNull(preview['legal_documents']) ?? _legalDocuments;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _joinPreview = null;
        if (showError) {
          _error = userErrorText(e);
        }
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingJoinPreview = false;
      });
    }
  }

  String _legalVersion(String section) {
    final sectionMap = mapOrNull(_legalDocuments?[section]);
    final version = sectionMap?['version']?.toString() ?? '';
    return version.isEmpty ? 'n/a' : version;
  }

  String get _consentCheckboxLabel {
    final privacyVersion = _legalVersion('privacy_policy');
    final consentVersion = _legalVersion('personal_data_consent');
    return appText(
      AppText.consentCheckboxLabel,
      args: {
        'privacyVersion': privacyVersion,
        'consentVersion': consentVersion,
      },
    );
  }

  Future<void> _loadLegalDocuments({bool showError = true}) async {
    if (_loadingLegalDocuments) {
      return;
    }

    if (mounted) {
      setState(() {
        _loadingLegalDocuments = true;
        if (showError) {
          _error = null;
        }
      });
    }

    try {
      final legalDocuments = await _client().getCurrentLegalDocuments();
      if (!mounted) return;
      setState(() {
        _legalDocuments = legalDocuments;
      });
    } catch (e) {
      if (showError && mounted) {
        setState(() {
          _error = userErrorText(e);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loadingLegalDocuments = false;
        });
      }
    }
  }

  Future<void> _openLegalDocumentsPage() async {
    if (_legalDocuments == null) {
      await _loadLegalDocuments();
    }
    if (!mounted || _legalDocuments == null) {
      return;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LegalDocumentsPage(
            documents: _legalDocuments!,
            apiBaseUrl: _apiController.text.trim()),
      ),
    );
  }

  void _startCountdown(DateTime? endsAt) {
    _countdownTimer = _countdownTicker.restart(
      currentTimer: _countdownTimer,
      endsAt: endsAt,
      isActive: () => mounted,
      onTick: (tick) {
        setState(() {
          _timeLeftLabel = tick.label;
          _isQuestionExpired = _sessionPhase != 'answering' || tick.isExpired;
        });
      },
    );
  }

  Future<void> _connectSocket(String sessionUuid) async {
    await _closeSocket();
    final token = _participantToken;
    if (token == null || token.isEmpty) return;
    final url = _client().sessionWebSocketUrl(sessionUuid);

    try {
      _socketSupervisor = LiveSocketSupervisor(
        url: url,
        authentication: {
          'event': 'auth',
          'access_type': 'participant',
          'token': token,
        },
        onMessage: _handleParticipantSocketEvent,
        onInvalidPayload: () => _appendEvent('Invalid socket payload.'),
        onTransportError: (_) {
          _appendEvent('Ошибка транспорта WebSocket.');
          _setSocketConnected(false);
        },
        onConnectionError: (error) {
          final code = error['code']?.toString();
          if (code == 'access_invalid' ||
              code == 'access_revoked' ||
              code == 'access_expired') {
            unawaited(_clearParticipantAccessIfInvalid(ApiException(
              statusCode: 401,
              message: 'Ролевой доступ недействителен.',
              body: '{}',
              code: code,
            )));
          }
          _appendEvent(
              'Соединение отклонено: ${code ?? 'неизвестная причина'}');
        },
        onStopped: (_, reason) {
          _appendEvent(
              'Повтор WebSocket прекращён: ${reason ?? 'соединение закрыто'}');
          _setSocketConnected(false);
        },
        opener: widget.socketOpener,
      );
      await _socketSupervisor!.start();
      _appendEvent(
          'WebSocket участника открыт, ожидается подтверждение доступа.');
    } catch (e) {
      _setSocketConnected(false);
      _appendEvent('Не удалось открыть WebSocket участника.');
    }
  }

  Future<void> _closeSocket() async {
    await _socketSupervisor?.stop();
    _socketSupervisor = null;
    _setSocketConnected(false);
  }

  void _startStatePolling(String sessionUuid) {
    _statePollingTimer?.cancel();
    _statePollingTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _syncSessionState(sessionUuid),
    );
  }

  Future<void> _syncSessionState(String sessionUuid) async {
    if (!mounted ||
        _joinPayload == null ||
        _sessionFinished ||
        _syncingSessionState) {
      return;
    }

    _syncingSessionState = true;
    try {
      final token = _participantToken;
      if (token == null || token.isEmpty) return;
      final participation = await _client().getParticipationState(
        sessionUuid,
        participantToken: token,
      );
      if (!mounted) return;
      _applySessionStatePayload(
        mapOrNull(participation['state']) ?? <String, dynamic>{},
        source: SessionStateSource.participantRead,
      );
    } on ApiException catch (e) {
      await _clearParticipantAccessIfInvalid(e);
      // WebSocket остаётся основным каналом, опрос — только страховка.
    } catch (_) {
      // Временная ошибка опроса не уничтожает сохранённый токен.
    } finally {
      _syncingSessionState = false;
    }
  }

  void _setSocketConnected(bool connected) {
    if (!mounted) return;
    setState(() {
      _socketConnected = connected;
    });
  }

  bool _applySessionStatePayload(
    Map<String, dynamic> payload, {
    required SessionStateSource source,
  }) {
    final reducer = _sessionStateReducer;
    if (reducer == null) return false;
    final reduction = _answerController?.applyState(payload, source: source) ??
        reducer.apply(payload, source: source);
    if (!reduction.accepted) return false;
    if (reduction.contextChanged) {
      _answerController?.cancelPending();
      _uncertainAnswer = null;
      _latestAnswerRequest = null;
    }

    final state = reduction.state;
    final status = state['status']?.toString() ?? _sessionStatus;
    final phase = state['phase']?.toString() ?? _sessionPhase;
    final isFinished = status == 'finished' || status == 'aborted';
    final isAnswerRevealed = state['is_answer_revealed'] == true;
    final answer = mapOrNull(state['answer']);
    final visibleHasAnswer =
        _answerController?.visibleHasAnswer ?? answer?['has_answer'] == true;
    final visibleChoiceId = _answerController?.visibleSelectedChoiceId ??
        answer?['selected_choice_id'] as int?;
    setState(() {
      _sessionStatus = status;
      _sessionPhase = phase;
      _sessionFinished = isFinished;
      _activeQuestion =
          isFinished ? null : mapOrNull(state['current_question']);
      _revealPayload = isAnswerRevealed ? mapOrNull(state['reveal']) : null;
      _questionAnswered = visibleHasAnswer;
      _selectedChoiceId = visibleChoiceId;
      _isQuestionExpired = phase != 'answering' || isAnswerRevealed;
      if (isFinished) {
        _finalLeaderboard =
            (state['leaderboard'] as List<dynamic>? ?? <dynamic>[]).toList();
      }
    });

    if (isFinished) {
      _countdownTimer?.cancel();
      _statePollingTimer?.cancel();
      setState(() {
        _timeLeftLabel = '--:--';
      });
    } else if (isAnswerRevealed) {
      _countdownTimer?.cancel();
      setState(() {
        _timeLeftLabel = '00:00';
      });
    } else {
      _startCountdown(parseDateTimeLocal(state['phase_ends_at']));
    }
    return true;
  }

  void _handleParticipantSocketEvent(Map<String, dynamic> message) {
    _setSocketConnected(true);
    final event = message['event']?.toString() ?? 'unknown';
    final payload = mapOrNull(message['payload']) ?? <String, dynamic>{};
    final accepted = _applySessionStatePayload(
      payload,
      source: SessionStateSource.participantWebsocket,
    );
    _appendEvent(accepted
        ? 'Событие: $event'
        : 'Отклонено несовместимое событие WebSocket.');
  }

  Future<void> _activateParticipation(
    Map<String, dynamic> payload,
    String sessionUuid,
  ) async {
    final incomingState = mapOrNull(payload['state']);
    if (incomingState == null) {
      throw StateError('Сервер не вернул состояние участия.');
    }
    var reducer = _sessionStateReducer;
    if (reducer == null || reducer.sessionUuid != sessionUuid) {
      reducer = SessionStateReducer(sessionUuid);
      _sessionStateReducer = reducer;
      _answerController = ParticipantAnswerController(reducer: reducer);
    }
    final reduction = _answerController!.applyState(
      incomingState,
      source: SessionStateSource.participantRead,
    );
    if (!reduction.accepted) {
      throw StateError(reduction.reason ?? 'Некорректное состояние участия.');
    }
    final state = reduction.state;
    final isAnswerRevealed = state['is_answer_revealed'] == true ||
        payload['is_answer_revealed'] == true;
    final currentQuestion = mapOrNull(state['current_question']) ??
        mapOrNull(payload['current_question']);
    final status = state['status']?.toString() ??
        payload['status']?.toString() ??
        payload['session_status']?.toString() ??
        'waiting';
    final phase =
        state['phase']?.toString() ?? payload['phase']?.toString() ?? 'lobby';

    final safePayload = Map<String, dynamic>.from(payload)
      ..remove('participant_token');
    setState(() {
      _joinPayload = safePayload;
      _sessionUuid = sessionUuid;
      _activeQuestion = currentQuestion;
      _revealPayload = isAnswerRevealed
          ? mapOrNull(state['reveal'] ?? payload['reveal'])
          : null;
      _finalLeaderboard =
          (state['leaderboard'] as List<dynamic>? ?? <dynamic>[]).toList();
      _sessionStatus = status;
      _sessionPhase = phase;
      _sessionFinished = status == 'finished' || status == 'aborted';
      _questionAnswered = _answerController!.visibleHasAnswer;
      _selectedChoiceId = _answerController!.visibleSelectedChoiceId;
      _isQuestionExpired = phase != 'answering' || isAnswerRevealed;
      _timeLeftLabel = isAnswerRevealed ? '00:00' : '--:--';
      _legalDocuments =
          mapOrNull(payload['legal_documents']) ?? _legalDocuments;
      _events.clear();
    });

    if (isAnswerRevealed) {
      _countdownTimer?.cancel();
    } else {
      _startCountdown(parseDateTimeLocal(
        state['phase_ends_at'] ??
            state['question_ends_at'] ??
            payload['question_ends_at'] ??
            payload['phase_ends_at'],
      ));
    }

    await _connectSocket(sessionUuid);
    _startStatePolling(sessionUuid);
  }

  Future<void> _persistPendingParticipation() async {
    final payload = _pendingJoinPayload;
    final token = _participantToken;
    final sessionUuid = _sessionUuid;
    if (payload == null || token == null || sessionUuid == null) return;

    if (!_participantTokenPersisted) {
      await _roleAccessStore.persist(
        role: RoleAccessKind.participant,
        sessionUuid: sessionUuid,
        apiBaseUrl: _apiController.text.trim(),
        token: token,
      );
      _participantTokenPersisted = true;
    }

    var combined = payload;
    if (mapOrNull(payload['state']) == null) {
      final restored = await _client().getParticipationState(
        sessionUuid,
        participantToken: token,
      );
      combined = <String, dynamic>{...payload, ...restored};
    }
    await _activateParticipation(combined, sessionUuid);
    _joinTokenFromLink = sessionUuid;
    _useJoinTokenFromLink = true;
    replaceParticipantJoinLocation(sessionUuid);
    _pendingJoinPayload = null;
  }

  Future<void> _join() async {
    if (_pendingJoinPayload != null) {
      setState(() {
        _loading = true;
        _error = null;
      });
      try {
        await _persistPendingParticipation();
      } catch (e) {
        if (mounted) {
          setState(() {
            _error = userErrorText(e);
          });
        }
      } finally {
        if (mounted) {
          setState(() {
            _loading = false;
          });
        }
      }
      return;
    }

    final validationError = _joinFormErrorText();
    if (validationError != null) {
      setState(() {
        _error = validationError;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      if (_joinPreview?['can_join'] == false) {
        throw StateError(
          _joinPreview?['closed_reason']?.toString() ??
              appText(AppText.participantSessionUnavailable),
        );
      }

      final joinToken = _activeJoinToken;
      final pin = _activePin;

      final payload = await _client().joinSession(
        pin: pin,
        joinToken: joinToken,
        phone: _phoneController.text.trim(),
        name: _nameController.text.trim(),
        consent: _consent,
      );
      final sessionUuid = payload['session_uuid']?.toString();
      final participantToken = payload['participant_token']?.toString();
      if (sessionUuid == null || sessionUuid.isEmpty) {
        throw StateError('Сервер не вернул UUID сессии.');
      }
      if (participantToken == null || participantToken.isEmpty) {
        throw StateError('Сервер не вернул токен участия.');
      }
      normalizeSessionUuid(sessionUuid);
      _participantToken = participantToken;
      _sessionUuid = sessionUuid;
      _participantTokenPersisted = false;
      _pendingJoinPayload = payload;
      await _persistPendingParticipation();
    } catch (e) {
      setState(() {
        final fallbackHint = _shouldShowManualPinFallback(e)
            ? appText(AppText.participantManualPinFallbackHint)
            : '';
        _error = '${userErrorText(e)}$fallbackHint';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _answer(int choiceId) async {
    if (_joinPayload == null ||
        _activeQuestion == null ||
        _sessionPhase != 'answering' ||
        _isQuestionExpired) {
      return;
    }
    if (_questionAnswered && _selectedChoiceId == choiceId) {
      return;
    }

    final hadAnswer = _questionAnswered;
    final reducer = _sessionStateReducer;
    final controller = _answerController;
    final context = reducer?.context;
    final sessionUuid = _sessionUuid;
    final participantToken = _participantToken;
    if (reducer == null ||
        controller == null ||
        context == null ||
        sessionUuid == null ||
        participantToken == null) {
      return;
    }
    final retained = _uncertainAnswer;
    final request = retained != null &&
            retained.choiceId == choiceId &&
            retained.questionId == _activeQuestion!['id'] &&
            reducer.matchesContext(retained.context)
        ? retained
        : ParticipantAnswerRequest(
            submissionId: newRequestId(),
            questionId: _activeQuestion!['id'] as int,
            choiceId: choiceId,
            context: context,
          );
    _uncertainAnswer = null;
    _latestAnswerRequest = request;
    setState(() {
      _error = null;
      _questionAnswered = false;
      _selectedChoiceId = choiceId;
    });
    try {
      final result = await controller.submit(
        request: request,
        send: (body, abortTrigger) => _client().submitAnswer(
          sessionUuid: sessionUuid,
          participantToken: participantToken,
          questionId: body['question_id'] as int,
          choiceId: body['choice_id'] as int,
          submissionId: body['submission_id'] as String,
          abortTrigger: abortTrigger,
        ),
        readState: () async {
          final participation = await _client().getParticipationState(
            sessionUuid,
            participantToken: participantToken,
          );
          final state = mapOrNull(participation['state']);
          if (state == null) {
            throw StateError('Сервер не вернул состояние участия.');
          }
          return state;
        },
      );
      if (!mounted || !identical(_latestAnswerRequest, request)) return;
      if (result.state?['schema_version'] == 2) {
        _applySessionStatePayload(
          result.state!,
          source: SessionStateSource.participantRead,
        );
      }
      switch (result.kind) {
        case ParticipantAnswerResultKind.submitted:
        case ParticipantAnswerResultKind.recoveredAfterNetwork:
          setState(() {
            _questionAnswered = controller.visibleHasAnswer;
            _selectedChoiceId = controller.visibleSelectedChoiceId;
          });
          _appendEvent(hadAnswer
              ? 'Выбор ответа изменён и зафиксирован.'
              : 'Ответ зафиксирован без раскрытия правильности.');
          break;
        case ParticipantAnswerResultKind.conflict:
          setState(() {
            _error = result.error == null
                ? 'Ответ конфликтует с текущим состоянием.'
                : userErrorText(result.error!);
          });
          break;
        case ParticipantAnswerResultKind.temporarilyFailed:
        case ParticipantAnswerResultKind.uncertain:
          _uncertainAnswer = request;
          setState(() {
            _error = result.kind == ParticipantAnswerResultKind.uncertain
                ? 'Результат ответа неизвестен. Повтор того же выбора сохранит исходный идентификатор.'
                : userErrorText(result.error!);
          });
          break;
        case ParticipantAnswerResultKind.cancelled:
          break;
      }
    } on ApiException catch (e) {
      await _clearParticipantAccessIfInvalid(e);
      if (!mounted) return;
      setState(() {
        _error = userErrorText(e);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = userErrorText(e);
        });
      }
    }
  }

  Widget _buildLiveSessionArea(BuildContext context) {
    return AppSectionCard(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.94),
      borderRadius: 28,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appText(AppText.participantLiveCardTitle),
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          if (_sessionFinished)
            ParticipantPodiumCard(
              leaderboard: _finalLeaderboard,
              currentSessionParticipantId:
                  asInt(_joinPayload?['session_participant_id'], -1),
            )
          else if (_sessionPhase == 'reading')
            ParticipantRoundMessage(
              icon: Icons.connected_tv_outlined,
              message: appText(AppText.participantLookAtDisplayMessage),
              color: const Color(0xFF005F73),
            )
          else if (_activeQuestion == null)
            ParticipantRoundMessage(
              icon: Icons.hourglass_top_outlined,
              message: appText(AppText.waitingForQuestionMessage),
              color: const Color(0xFF005F73),
            )
          else
            ParticipantQuestionCard(
              question: _activeQuestion!,
              onAnswer: _answer,
              questionLocked: _sessionPhase != 'answering' ||
                  _isQuestionExpired ||
                  _revealPayload != null,
              selectedChoiceId: _selectedChoiceId,
              timeLeftLabel: _timeLeftLabel,
              correctChoiceId: _correctChoiceId,
              answerRevealed: _revealPayload != null,
            ),
          if (_isQuestionExpired &&
              !_questionAnswered &&
              !_sessionFinished) ...[
            const SizedBox(height: 10),
            ParticipantRoundMessage(
              icon: Icons.timer_off_outlined,
              message: appText(AppText.timeOverMessage),
              color: Theme.of(context).colorScheme.error,
            ),
          ],
          if (_revealPayload != null && !_sessionFinished) ...[
            const SizedBox(height: 10),
            ParticipantRoundMessage(
              icon: Icons.check_circle_outline,
              message: appText(AppText.participantCorrectAnswerRevealed),
              color: const Color(0xFF26890C),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFF7F9FC), Color(0xFFE0F7FA)],
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 920,
                  minHeight: constraints.maxHeight.isFinite &&
                          constraints.maxHeight > 32
                      ? constraints.maxHeight - 32
                      : 0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ParticipantHero(
                      isLive: _joinPayload != null,
                      sessionStatus: _sessionStatus,
                      socketConnected: _socketConnected,
                      hasActiveQuestion: _activeQuestion != null &&
                          _sessionPhase == 'answering',
                      timeLeftLabel: _timeLeftLabel,
                    ),
                    const SizedBox(height: 16),
                    if (_joinPayload == null) ...[
                      ParticipantJoinConnectionCard(
                        apiController: _apiController,
                        pinController: _pinController,
                        useJoinTokenFromLink: _useJoinTokenFromLink,
                        joinTokenFromLink: _joinTokenFromLink,
                        loading: _loading,
                        loadingJoinPreview: _loadingJoinPreview,
                        joinPreview: _joinPreview,
                        onLoadJoinPreview: () => _loadJoinPreview(),
                        onUsePinInstead: () {
                          setState(() {
                            _useJoinTokenFromLink = false;
                            _joinPreview = null;
                          });
                        },
                        onUseJoinToken: () {
                          setState(() {
                            _useJoinTokenFromLink = true;
                            _joinPreview = null;
                          });
                          _loadJoinPreview(showError: false);
                        },
                      ),
                      const SizedBox(height: 14),
                      ParticipantProfileCard(
                        nameController: _nameController,
                        phoneController: _phoneController,
                        consent: _consent,
                        consentLabel: _consentCheckboxLabel,
                        loading: _loading,
                        loadingLegalDocuments: _loadingLegalDocuments,
                        error: _error,
                        onConsentChanged: (value) {
                          setState(() {
                            _consent = value;
                          });
                        },
                        onOpenLegalDocuments: _openLegalDocumentsPage,
                        onRefreshLegalDocuments: () => _loadLegalDocuments(),
                        onJoin: _join,
                      ),
                    ] else ...[
                      _buildLiveSessionArea(context),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
