import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../core/app_config.dart';
import '../../core/countdown_ticker.dart';
import '../../core/live_event_log.dart';
import '../../core/live_socket_connection.dart';
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

class ParticipantPanel extends StatefulWidget {
  const ParticipantPanel({super.key});

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
  bool _consent = false;
  bool _loading = false;
  int _totalPoints = 0;
  int _lastAnswerPoints = 0;
  String? _error;
  String _sessionStatus = 'waiting';
  bool _questionAnswered = false;
  int? _selectedChoiceId;
  bool _sessionFinished = false;
  String _timeLeftLabel = '--:--';
  bool _isQuestionExpired = false;
  Map<String, dynamic>? _legalDocuments;
  bool _loadingLegalDocuments = false;
  Map<String, dynamic>? _joinPreview;
  bool _loadingJoinPreview = false;
  String? _joinTokenFromLink;
  bool _useJoinTokenFromLink = false;

  LiveSocketConnection? _socketConnection;
  bool _socketConnected = false;
  Timer? _countdownTimer;
  final _countdownTicker = const CountdownTicker();
  final _eventLog = const LiveEventLog();
  final List<String> _events = [];

  ApiClient _client() => ApiClient(_apiController.text.trim());

  String? get _activeJoinToken =>
      _useJoinTokenFromLink ? _joinTokenFromLink : null;

  String? get _activePin {
    if (_useJoinTokenFromLink) {
      return null;
    }
    final pin = _pinController.text.trim();
    return pin.isEmpty ? null : pin;
  }

  @override
  void initState() {
    super.initState();
    final initialJoinSource = ParticipantJoinSource.fromUri(Uri.base);
    _configureJoinSource(initialJoinSource);
    _loadLegalDocuments(showError: false);
    _loadJoinPreview(showError: initialJoinSource.hasJoinTarget);
  }

  void _configureJoinSource(ParticipantJoinSource joinSource) {
    final apiBaseUrl = joinSource.apiBaseUrl;
    if (apiBaseUrl != null) {
      _apiController.text = apiBaseUrl;
    }

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
          _isQuestionExpired = tick.isExpired;
        });
      },
    );
  }

  void _applyQuestionState(Map<String, dynamic>? question, dynamic endsAtRaw) {
    setState(() {
      _activeQuestion = question;
      _revealPayload = null;
      _questionAnswered = false;
      _selectedChoiceId = null;
      _isQuestionExpired = false;
    });
    _startCountdown(parseDateTimeLocal(endsAtRaw));
  }

  Future<void> _connectSocket(int sessionId) async {
    await _closeSocket();
    final url = _client().sessionWebSocketUrl(sessionId);

    try {
      _socketConnection = LiveSocketConnection.connect(
        url: url,
        isActive: () => mounted,
        onMessage: _handleParticipantSocketEvent,
        onInvalidPayload: () => _appendEvent('Invalid socket payload.'),
        onError: (error) {
          _appendEvent('Socket error: $error');
          _setSocketConnected(false);
        },
        onDone: () {
          _appendEvent('Socket disconnected.');
          _setSocketConnected(false);
        },
      );

      _setSocketConnected(true);
      _appendEvent('Connected to live session.');
    } catch (e) {
      _setSocketConnected(false);
      _appendEvent('Failed to connect socket: $e');
    }
  }

  Future<void> _closeSocket() async {
    await _socketConnection?.close();
    _socketConnection = null;
    _setSocketConnected(false);
  }

  void _setSocketConnected(bool connected) {
    if (!mounted) return;
    setState(() {
      _socketConnected = connected;
    });
  }

  void _handleParticipantSocketEvent(Map<String, dynamic> message) {
    final event = message['event']?.toString() ?? 'unknown';
    final payload = mapOrNull(message['payload']) ?? <String, dynamic>{};

    switch (event) {
      case 'session_state':
      case 'session_started':
        final incomingQuestion = mapOrNull(payload['current_question']);
        final incomingQuestionId = asInt(incomingQuestion?['id'], -1);
        final activeQuestionId = asInt(_activeQuestion?['id'], -2);
        final isAnswerRevealed = payload['is_answer_revealed'] == true;

        setState(() {
          _sessionStatus = payload['status']?.toString() ?? _sessionStatus;
          _sessionFinished = _sessionStatus == 'finished';
        });

        if (incomingQuestionId != activeQuestionId ||
            incomingQuestion == null) {
          _applyQuestionState(incomingQuestion, payload['question_ends_at']);
        } else {
          _startCountdown(parseDateTimeLocal(payload['question_ends_at']));
        }

        if (isAnswerRevealed && incomingQuestion != null) {
          _countdownTimer?.cancel();
          setState(() {
            _isQuestionExpired = true;
            _timeLeftLabel = '00:00';
          });
        }
        break;
      case 'question_started':
        setState(() {
          _sessionStatus = payload['status']?.toString() ?? 'live';
          _sessionFinished = false;
          _lastAnswerPoints = 0;
        });
        _applyQuestionState(
            mapOrNull(payload['question']), payload['question_ends_at']);
        break;
      case 'answer_revealed':
        _countdownTimer?.cancel();
        setState(() {
          _revealPayload = payload;
          _timeLeftLabel = '00:00';
          _isQuestionExpired = true;
        });
        break;
      case 'session_finished':
        _countdownTimer?.cancel();
        setState(() {
          _sessionStatus = 'finished';
          _sessionFinished = true;
          _activeQuestion = null;
          _timeLeftLabel = '--:--';
          _isQuestionExpired = false;
        });
        break;
      default:
        break;
    }

    _appendEvent('Event: $event');
  }

  Future<void> _join() async {
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

      final isAnswerRevealed = payload['is_answer_revealed'] == true;

      setState(() {
        _joinPayload = payload;
        _activeQuestion = mapOrNull(payload['current_question']);
        _revealPayload = null;
        _totalPoints = 0;
        _lastAnswerPoints = 0;
        _sessionStatus = payload['session_status']?.toString() ?? 'waiting';
        _sessionFinished = _sessionStatus == 'finished';
        _questionAnswered = false;
        _selectedChoiceId = null;
        _isQuestionExpired = isAnswerRevealed;
        _timeLeftLabel = isAnswerRevealed ? '00:00' : '--:--';
        _legalDocuments =
            mapOrNull(payload['legal_documents']) ?? _legalDocuments;
        _events.clear();
      });

      if (isAnswerRevealed) {
        _countdownTimer?.cancel();
      } else {
        _startCountdown(parseDateTimeLocal(payload['question_ends_at']));
      }

      await _connectSocket(payload['session_id'] as int);
    } catch (e) {
      setState(() {
        final fallbackHint = _useJoinTokenFromLink
            ? appText(AppText.participantManualPinFallbackHint)
            : '';
        _error = '${userErrorText(e)}$fallbackHint';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _answer(int choiceId) async {
    if (_joinPayload == null ||
        _activeQuestion == null ||
        _questionAnswered ||
        _isQuestionExpired) {
      return;
    }

    try {
      final response = await _client().submitAnswer(
        sessionParticipantId: _joinPayload!['session_participant_id'] as int,
        questionId: _activeQuestion!['id'] as int,
        choiceId: choiceId,
      );

      setState(() {
        _totalPoints = asInt(response['total_points'], _totalPoints);
        _lastAnswerPoints = asInt(response['score_points']);
        _questionAnswered = true;
        _selectedChoiceId = choiceId;
      });

      _appendEvent('Answer submitted (+$_lastAnswerPoints pts).');
    } catch (e) {
      setState(() {
        _error = userErrorText(e);
      });
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
          Text(appText(AppText.participantLastAnswer,
              args: {'points': _lastAnswerPoints})),
          const SizedBox(height: 14),
          if (_sessionFinished)
            ParticipantRoundMessage(
              icon: Icons.flag_circle_outlined,
              message: appText(AppText.sessionFinishedMessage),
              color: const Color(0xFF0A9396),
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
              questionLocked: _questionAnswered || _isQuestionExpired,
              selectedChoiceId: _selectedChoiceId,
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
          if (_revealPayload != null) ...[
            const SizedBox(height: 14),
            ParticipantRevealResultsCard(revealPayload: _revealPayload!),
          ],
          const SizedBox(height: 14),
          ParticipantLiveEventsCard(events: _events),
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
                      totalPoints: _totalPoints,
                      sessionStatus: _sessionStatus,
                      socketConnected: _socketConnected,
                      hasActiveQuestion: _activeQuestion != null,
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
