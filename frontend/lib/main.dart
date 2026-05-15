import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api/api_client.dart';
import 'core/app_config.dart';
import 'core/value_utils.dart';
import 'features/teacher/teacher_panel.dart';
import 'l10n/app_language.dart';
import 'l10n/app_strings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await appLanguage.load();
  runApp(const UmclickApp());
}

enum UmclickEntryPoint {
  home,
  legalPrivacy,
  legalConsent,
}

enum PublicLegalDocumentType {
  privacyPolicy,
  personalDataConsent,
}

String _normalizePath(String path) {
  if (path.isEmpty) return '/';
  final trimmed = path.replaceAll(RegExp(r'/+$'), '');
  return trimmed.isEmpty ? '/' : trimmed;
}

UmclickEntryPoint resolveEntryPoint(Uri uri) {
  final normalizedPath = _normalizePath(uri.path.toLowerCase());
  switch (normalizedPath) {
    case '/legal/privacy':
      return UmclickEntryPoint.legalPrivacy;
    case '/legal/consent':
      return UmclickEntryPoint.legalConsent;
    default:
      return UmclickEntryPoint.home;
  }
}

int resolveInitialHomeTab(Uri uri) {
  final normalizedPath = _normalizePath(uri.path.toLowerCase());
  if (normalizedPath == '/join') {
    return 1;
  }
  return 0;
}

String resolvePublicLegalApiBase(Uri uri) {
  final apiFromQuery = uri.queryParameters['api']?.trim() ?? '';
  if (apiFromQuery.isNotEmpty) {
    return apiFromQuery;
  }
  return defaultApiBaseUrl;
}

class UmclickApp extends StatelessWidget {
  const UmclickApp({super.key});

  Widget _buildHomeForEntryPoint() {
    final uri = Uri.base;
    final entryPoint = resolveEntryPoint(uri);
    final publicApiBase = resolvePublicLegalApiBase(uri);

    switch (entryPoint) {
      case UmclickEntryPoint.legalPrivacy:
        return PublicLegalDocumentPage(
          documentType: PublicLegalDocumentType.privacyPolicy,
          apiBaseUrl: publicApiBase,
        );
      case UmclickEntryPoint.legalConsent:
        return PublicLegalDocumentPage(
          documentType: PublicLegalDocumentType.personalDataConsent,
          apiBaseUrl: publicApiBase,
        );
      case UmclickEntryPoint.home:
        return HomePage(initialIndex: resolveInitialHomeTab(uri));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UiLanguage>(
      valueListenable: appLanguage,
      builder: (context, _, __) {
        return MaterialApp(
          title: 'umclick',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0E7C7B)),
            useMaterial3: true,
            tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 350)),
          ),
          home: _buildHomeForEntryPoint(),
        );
      },
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, 1).toInt();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [const TeacherPanel(), const ParticipantPanel()];

    return Scaffold(
      appBar: AppBar(
        title: Text(appText(AppText.appTitle)),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: LanguageSwitcher()),
          ),
        ],
      ),
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.school),
            label: appText(AppText.teacherTab),
          ),
          NavigationDestination(
            icon: const Icon(Icons.group),
            label: appText(AppText.participantTab),
          ),
        ],
        onDestinationSelected: (value) {
          setState(() {
            _index = value;
          });
        },
      ),
    );
  }
}

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

  WebSocketChannel? _socket;
  StreamSubscription? _socketSubscription;
  bool _socketConnected = false;
  Timer? _countdownTimer;
  final List<String> _events = [];

  ApiClient _client() => ApiClient(_apiController.text.trim());

  String? get _activeJoinToken => _useJoinTokenFromLink ? _joinTokenFromLink : null;

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
    _configureJoinSourceFromUrl();
    _loadLegalDocuments(showError: false);
    _loadJoinPreview(showError: _joinTokenFromLink != null || _activePin != null);
  }

  void _configureJoinSourceFromUrl() {
    final apiBaseFromUrl = Uri.base.queryParameters['api']?.trim() ?? '';
    if (apiBaseFromUrl.isNotEmpty) {
      _apiController.text = apiBaseFromUrl;
    }

    final tokenFromUrl = Uri.base.queryParameters['token']?.trim() ?? '';
    if (tokenFromUrl.isNotEmpty) {
      _joinTokenFromLink = tokenFromUrl;
      _useJoinTokenFromLink = true;
      return;
    }

    final pinFromUrl = Uri.base.queryParameters['pin']?.trim() ?? '';
    if (pinFromUrl.isNotEmpty) {
      _pinController.text = pinFromUrl;
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
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _events.insert(0, '[$timestamp] $text');
      if (_events.length > 25) {
        _events.removeRange(25, _events.length);
      }
    });
  }

  Future<void> _loadJoinPreview({bool showError = true}) async {
    if (_loadingJoinPreview) {
      return;
    }

    final joinToken = _activeJoinToken;
    final pin = _activePin;
    if ((joinToken == null || joinToken.isEmpty) && (pin == null || pin.isEmpty)) {
      if (showError) {
        setState(() {
          _error = 'Enter a PIN or open a tokenized join link first.';
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
        _legalDocuments = mapOrNull(preview['legal_documents']) ?? _legalDocuments;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _joinPreview = null;
        if (showError) {
          _error = e.toString();
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
          _error = e.toString();
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
        builder: (_) => LegalDocumentsPage(documents: _legalDocuments!, apiBaseUrl: _apiController.text.trim()),
      ),
    );
  }

  void _startCountdown(DateTime? endsAt) {
    _countdownTimer?.cancel();
    if (endsAt == null) {
      setState(() {
        _timeLeftLabel = '--:--';
        _isQuestionExpired = false;
      });
      return;
    }

    void tick() {
      final remaining = endsAt.difference(DateTime.now());
      if (remaining.inMilliseconds <= 0) {
        _countdownTimer?.cancel();
        if (!mounted) return;
        setState(() {
          _timeLeftLabel = '00:00';
          _isQuestionExpired = true;
        });
        return;
      }

      if (!mounted) return;
      setState(() {
        _timeLeftLabel = formatRemaining(remaining);
        _isQuestionExpired = false;
      });
    }

    tick();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
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
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _socket = channel;
      _socketSubscription = channel.stream.listen(
        (raw) {
          try {
            final decoded = jsonDecode(raw as String);
            final message = mapOrNull(decoded);
            if (message == null) return;
            _handleParticipantSocketEvent(message);
          } catch (_) {
            _appendEvent('Invalid socket payload.');
          }
        },
        onError: (error) {
          _appendEvent('Socket error: $error');
          setState(() {
            _socketConnected = false;
          });
        },
        onDone: () {
          _appendEvent('Socket disconnected.');
          setState(() {
            _socketConnected = false;
          });
        },
      );

      setState(() {
        _socketConnected = true;
      });
      _appendEvent('Connected to live session.');
    } catch (e) {
      setState(() {
        _socketConnected = false;
      });
      _appendEvent('Failed to connect socket: $e');
    }
  }

  Future<void> _closeSocket() async {
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    await _socket?.sink.close();
    _socket = null;
    if (mounted) {
      setState(() {
        _socketConnected = false;
      });
    }
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

        if (incomingQuestionId != activeQuestionId || incomingQuestion == null) {
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
        _applyQuestionState(mapOrNull(payload['question']), payload['question_ends_at']);
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
          _joinPreview?['closed_reason']?.toString() ?? 'Session is not available for joining.',
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
        _legalDocuments = mapOrNull(payload['legal_documents']) ?? _legalDocuments;
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
            ? '\nYou can switch to manual PIN input if this link is outdated.'
            : '';
        _error = '${e.toString()}$fallbackHint';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _answer(int choiceId) async {
    if (_joinPayload == null || _activeQuestion == null || _questionAnswered || _isQuestionExpired) {
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
        _error = e.toString();
      });
    }
  }

  Widget _buildJoinPreviewCard() {
    final preview = _joinPreview;
    if (_loadingJoinPreview && preview == null) {
      return const LinearProgressIndicator();
    }
    if (preview == null) {
      return const SizedBox.shrink();
    }

    final quiz = mapOrNull(preview['quiz']) ?? <String, dynamic>{};
    final title = quiz['title']?.toString() ?? appText(AppText.untitledQuizLong);
    final description = quiz['description']?.toString() ?? '';
    final statusLabel = preview['session_status']?.toString() ?? 'unknown';
    final participantsCount = asInt(preview['participants_count']);
    final canJoin = preview['can_join'] != false;
    final closedReason = preview['closed_reason']?.toString() ?? '';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: canJoin ? const Color(0xFFFFF4D6) : Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: canJoin ? const Color(0xFFFFB703).withOpacity(0.42) : Theme.of(context).colorScheme.error,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(canJoin ? Icons.fact_check_outlined : Icons.lock_outline),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(description),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildStatusChip(
                icon: Icons.flag_outlined,
                label: appText(AppText.statusValue, args: {'status': statusLabel}),
                background: Colors.white.withOpacity(0.66),
                foreground: const Color(0xFF023047),
              ),
              _buildStatusChip(
                icon: Icons.group_outlined,
                label: appText(AppText.participantsCount, args: {'count': participantsCount}),
                background: Colors.white.withOpacity(0.66),
                foreground: const Color(0xFF023047),
              ),
            ],
          ),
          if (!canJoin && closedReason.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(closedReason, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (_loadingJoinPreview) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }

  Widget _buildParticipantCard(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(18),
  }) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surface.withOpacity(0.94),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: padding,
        child: child,
      ),
    );
  }

  Widget _buildStatusChip({
    required IconData icon,
    required String label,
    required Color background,
    required Color foreground,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: foreground, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _buildParticipantHero(BuildContext context) {
    final isLive = _joinPayload != null;
    final statusText = appText(AppText.statusValue, args: {'status': _sessionStatus});
    final socketText = appText(
      AppText.webSocketState,
      args: {
        'state': _socketConnected ? appText(AppText.webSocketConnected) : appText(AppText.webSocketDisconnected),
      },
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF023047), Color(0xFF0A9396), Color(0xFFFFB703)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF023047).withOpacity(0.22),
            blurRadius: 28,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStatusChip(
            icon: isLive ? Icons.bolt : Icons.qr_code_2,
            label: isLive ? appText(AppText.participantHeroLiveBadge) : appText(AppText.participantHeroJoinBadge),
            background: Colors.white.withOpacity(0.18),
            foreground: Colors.white,
          ),
          const SizedBox(height: 18),
          Text(
            isLive ? appText(AppText.participantHeroLiveTitle) : appText(AppText.participantHeroJoinTitle),
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            isLive ? appText(AppText.participantHeroLiveSubtitle) : appText(AppText.participantHeroJoinSubtitle),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white.withOpacity(0.9),
                  height: 1.35,
                ),
          ),
          if (isLive) ...[
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _buildStatusChip(
                  icon: Icons.emoji_events_outlined,
                  label: appText(AppText.participantPoints, args: {'points': _totalPoints}),
                  background: Colors.white,
                  foreground: const Color(0xFF023047),
                ),
                _buildStatusChip(
                  icon: Icons.flag_outlined,
                  label: statusText,
                  background: Colors.white.withOpacity(0.18),
                  foreground: Colors.white,
                ),
                _buildStatusChip(
                  icon: _socketConnected ? Icons.wifi : Icons.wifi_off,
                  label: socketText,
                  background: Colors.white.withOpacity(0.18),
                  foreground: Colors.white,
                ),
                if (_activeQuestion != null)
                  _buildStatusChip(
                    icon: Icons.timer_outlined,
                    label: appText(AppText.timeLeft, args: {'time': _timeLeftLabel}),
                    background: Colors.white.withOpacity(0.18),
                    foreground: Colors.white,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildJoinConnectionCard(BuildContext context) {
    return _buildParticipantCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appText(AppText.participantJoinCardTitle), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 14),
          TextField(
            controller: _apiController,
            decoration: InputDecoration(
              labelText: appText(AppText.apiBaseUrlLabel),
              helperText: appText(AppText.participantApiBaseUrlHelper),
            ),
          ),
          const SizedBox(height: 14),
          if (_useJoinTokenFromLink && _joinTokenFromLink != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFE0F7FA),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF0A9396).withOpacity(0.32)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.link, color: Color(0xFF005F73)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(appText(AppText.joinLinkDetected))),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SelectableText(appText(AppText.joinTokenLabel, args: {'token': _joinTokenFromLink})),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      OutlinedButton.icon(
                        onPressed: (_loading || _loadingJoinPreview) ? null : () => _loadJoinPreview(),
                        icon: const Icon(Icons.refresh),
                        label: Text(appText(AppText.refreshPreviewButton)),
                      ),
                      OutlinedButton.icon(
                        onPressed: _loading
                            ? null
                            : () {
                                setState(() {
                                  _useJoinTokenFromLink = false;
                                  _joinPreview = null;
                                });
                              },
                        icon: const Icon(Icons.pin_outlined),
                        label: Text(appText(AppText.usePinInsteadButton)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ] else ...[
            TextField(
              controller: _pinController,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
              decoration: InputDecoration(
                labelText: appText(AppText.sessionPinLabel),
                helperText: appText(AppText.sessionPinHelper),
                prefixIcon: const Icon(Icons.pin_outlined),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.tonalIcon(
                  onPressed: (_loading || _loadingJoinPreview) ? null : () => _loadJoinPreview(),
                  icon: const Icon(Icons.visibility_outlined),
                  label: Text(appText(AppText.previewSessionButton)),
                ),
                if (_joinTokenFromLink != null)
                  TextButton.icon(
                    onPressed: _loading
                        ? null
                        : () {
                            setState(() {
                              _useJoinTokenFromLink = true;
                              _joinPreview = null;
                            });
                            _loadJoinPreview(showError: false);
                          },
                    icon: const Icon(Icons.link),
                    label: Text(appText(AppText.useJoinTokenButton)),
                  ),
              ],
            ),
          ],
          if (_loadingJoinPreview || _joinPreview != null) ...[
            const SizedBox(height: 14),
            _buildJoinPreviewCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildParticipantProfileCard(BuildContext context) {
    return _buildParticipantCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appText(AppText.participantProfileCardTitle), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 14),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: appText(AppText.participantNameLabel),
              prefixIcon: const Icon(Icons.badge_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phoneController,
            decoration: InputDecoration(
              labelText: appText(AppText.participantPhoneLabel),
              helperText: appText(AppText.participantPhoneHelper),
              prefixIcon: const Icon(Icons.phone_outlined),
            ),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            value: _consent,
            onChanged: (value) {
              setState(() {
                _consent = value ?? false;
              });
            },
            title: Text(_consentCheckboxLabel),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: (_loading || _loadingLegalDocuments) ? null : _openLegalDocumentsPage,
                icon: const Icon(Icons.policy_outlined),
                label: Text(appText(AppText.legalDocumentsButton)),
              ),
              OutlinedButton.icon(
                onPressed: (_loading || _loadingLegalDocuments) ? null : () => _loadLegalDocuments(),
                icon: const Icon(Icons.refresh),
                label: Text(appText(AppText.refreshLegalDocsButton)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _loading ? null : _join,
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(appText(AppText.joinSessionButton)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
                textStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }

  Widget _buildLiveSessionArea(BuildContext context) {
    return _buildParticipantCard(
      context,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appText(AppText.participantLiveCardTitle), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          Text(appText(AppText.participantLastAnswer, args: {'points': _lastAnswerPoints})),
          const SizedBox(height: 14),
          if (_sessionFinished)
            _buildRoundMessage(
              context,
              icon: Icons.flag_circle_outlined,
              message: appText(AppText.sessionFinishedMessage),
              color: const Color(0xFF0A9396),
            )
          else if (_activeQuestion == null)
            _buildRoundMessage(
              context,
              icon: Icons.hourglass_top_outlined,
              message: appText(AppText.waitingForQuestionMessage),
              color: const Color(0xFF005F73),
            )
          else
            _QuestionCard(
              question: _activeQuestion!,
              onAnswer: _answer,
              questionLocked: _questionAnswered || _isQuestionExpired,
              selectedChoiceId: _selectedChoiceId,
            ),
          if (_isQuestionExpired && !_questionAnswered && !_sessionFinished) ...[
            const SizedBox(height: 10),
            _buildRoundMessage(
              context,
              icon: Icons.timer_off_outlined,
              message: appText(AppText.timeOverMessage),
              color: Theme.of(context).colorScheme.error,
            ),
          ],
          if (_revealPayload != null) ...[
            const SizedBox(height: 14),
            _buildRevealResultsCard(context),
          ],
          const SizedBox(height: 14),
          _buildLiveEventsCard(context),
        ],
      ),
    );
  }

  Widget _buildRoundMessage(
    BuildContext context, {
    required IconData icon,
    required String message,
    required Color color,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.11),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: color.withOpacity(0.24)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }

  Widget _buildRevealResultsCard(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.55),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appText(AppText.revealResultsTitle), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(appText(AppText.totalAnswers, args: {'count': _revealPayload!['total_answers'] ?? 0})),
          Text(appText(AppText.pointsAwarded, args: {'points': _revealPayload!['total_points_awarded'] ?? 0})),
          Text(appText(AppText.revealedBy, args: {'value': _revealPayload!['revealed_by'] ?? 'teacher'})),
          const SizedBox(height: 8),
          ...((_revealPayload!['choices'] as List<dynamic>? ?? <dynamic>[]).map((rawChoice) {
            final choice = mapOrNull(rawChoice) ?? <String, dynamic>{};
            final isCorrect = choice['is_correct'] == true;
            return ListTile(
              dense: true,
              leading: Icon(isCorrect ? Icons.check_circle : Icons.circle_outlined),
              title: Text('${choice['text']}'),
              trailing: Text(appText(
                AppText.choiceStats,
                args: {
                  'votes': choice['answers_count'] ?? 0,
                  'points': choice['points_awarded'] ?? 0,
                },
              )),
            );
          })),
        ],
      ),
    );
  }

  Widget _buildLiveEventsCard(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.35),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appText(AppText.liveEventsTitle), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_events.isEmpty)
            Text(appText(AppText.noEventsYet))
          else
            ..._events.map((event) => Text(event)),
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
                  minHeight: constraints.maxHeight.isFinite && constraints.maxHeight > 32
                      ? constraints.maxHeight - 32
                      : 0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildParticipantHero(context),
                    const SizedBox(height: 16),
                    if (_joinPayload == null) ...[
                      _buildJoinConnectionCard(context),
                      const SizedBox(height: 14),
                      _buildParticipantProfileCard(context),
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

class LegalDocumentsPage extends StatelessWidget {
  const LegalDocumentsPage({
    super.key,
    required this.documents,
    required this.apiBaseUrl,
  });

  final Map<String, dynamic> documents;
  final String apiBaseUrl;

  String _version(String key) {
    final section = mapOrNull(documents[key]);
    final version = section?['version']?.toString() ?? '';
    return version.isEmpty ? 'n/a' : version;
  }

  String _url(String key) {
    final section = mapOrNull(documents[key]);
    return section?['url']?.toString() ?? '-';
  }

  @override
  Widget build(BuildContext context) {
    final privacyVersion = _version('privacy_policy');
    final consentVersion = _version('personal_data_consent');
    final contactEmail = documents['contact_email']?.toString() ?? '-';

    return Scaffold(
      appBar: AppBar(title: Text(appText(AppText.privacyConsentTitle))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(appText(AppText.currentLegalVersionsTitle), style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(appText(AppText.privacyVersionLabel, args: {'version': privacyVersion})),
                  SelectableText(appText(AppText.privacyUrlLabel, args: {'url': _url('privacy_policy')})),
                  const SizedBox(height: 6),
                  Text(appText(AppText.personalDataConsentVersionLabel, args: {'version': consentVersion})),
                  SelectableText(appText(AppText.personalDataConsentUrlLabel, args: {'url': _url('personal_data_consent')})),
                  const SizedBox(height: 6),
                  SelectableText(appText(AppText.legalContactLabel, args: {'email': contactEmail})),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                appText(AppText.legalConsentNotice),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => PublicLegalDocumentPage(
                        documentType: PublicLegalDocumentType.privacyPolicy,
                        initialDocuments: documents,
                        apiBaseUrl: apiBaseUrl,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.policy_outlined),
                label: Text(appText(AppText.openPrivacyPolicyButton)),
              ),
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => PublicLegalDocumentPage(
                        documentType: PublicLegalDocumentType.personalDataConsent,
                        initialDocuments: documents,
                        apiBaseUrl: apiBaseUrl,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.gpp_maybe_outlined),
                label: Text(appText(AppText.openConsentButton)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class PublicLegalDocumentPage extends StatefulWidget {
  const PublicLegalDocumentPage({
    super.key,
    required this.documentType,
    this.initialDocuments,
    this.apiBaseUrl = defaultApiBaseUrl,
  });

  final PublicLegalDocumentType documentType;
  final Map<String, dynamic>? initialDocuments;
  final String apiBaseUrl;

  @override
  State<PublicLegalDocumentPage> createState() => _PublicLegalDocumentPageState();
}

class _PublicLegalDocumentPageState extends State<PublicLegalDocumentPage> {
  Map<String, dynamic>? _documents;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _documents = widget.initialDocuments;
    if (_documents == null) {
      _loadLegalDocuments();
    }
  }

  String get _documentKey {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return 'privacy_policy';
    }
    return 'personal_data_consent';
  }

  String get _fallbackVersion {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return defaultPrivacyPolicyVersion;
    }
    return defaultPersonalDataConsentVersion;
  }

  String get _title {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return appText(AppText.privacyPolicyTitle);
    }
    return appText(AppText.personalDataConsentTitle);
  }

  String get _shortDescription {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return appText(AppText.privacyPolicyDescription);
    }
    return appText(AppText.personalDataConsentDescription);
  }

  String get _fallbackPublicUrl {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return '/legal/privacy';
    }
    return '/legal/consent';
  }

  String get _version {
    final section = mapOrNull(_documents?[_documentKey]);
    final version = section?['version']?.toString().trim() ?? '';
    return version.isEmpty ? _fallbackVersion : version;
  }

  String get _documentUrl {
    final section = mapOrNull(_documents?[_documentKey]);
    final url = section?['url']?.toString().trim() ?? '';
    return url.isEmpty ? _fallbackPublicUrl : url;
  }

  String get _contactEmail {
    final email = _documents?['contact_email']?.toString().trim() ?? '';
    return email.isEmpty ? 'privacy@umclick.local' : email;
  }

  List<MapEntry<String, String>> get _sections {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return [
        MapEntry(appText(AppText.privacyDataCollectedTitle), appText(AppText.privacyDataCollectedBody)),
        MapEntry(appText(AppText.privacyPurposeTitle), appText(AppText.privacyPurposeBody)),
        MapEntry(appText(AppText.privacyLegalBasisTitle), appText(AppText.privacyLegalBasisBody)),
        MapEntry(appText(AppText.privacyRetentionTitle), appText(AppText.privacyRetentionBody)),
        MapEntry(appText(AppText.privacySharingTitle), appText(AppText.privacySharingBody)),
        MapEntry(appText(AppText.privacyRightsTitle), appText(AppText.privacyRightsBody)),
      ];
    }

    return [
      MapEntry(appText(AppText.consentScopeTitle), appText(AppText.consentScopeBody)),
      MapEntry(appText(AppText.consentActionsTitle), appText(AppText.consentActionsBody)),
      MapEntry(appText(AppText.consentPurposeTitle), appText(AppText.consentPurposeBody)),
      MapEntry(appText(AppText.consentPeriodTitle), appText(AppText.consentPeriodBody)),
      MapEntry(appText(AppText.consentWithdrawalTitle), appText(AppText.consentWithdrawalBody)),
      MapEntry(appText(AppText.consentConfirmationTitle), appText(AppText.consentConfirmationBody)),
    ];
  }

  Future<void> _loadLegalDocuments() async {
    if (_loading) {
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final docs = await ApiClient(widget.apiBaseUrl).getCurrentLegalDocuments();
      if (!mounted) return;
      setState(() {
        _documents = docs;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const HomePage()),
                (route) => false,
              );
            },
            icon: const Icon(Icons.home_outlined),
            label: Text(appText(AppText.openAppButton)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_loading) const SizedBox(height: 12),
          if (_error != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(appText(AppText.legalMetadataRefreshError, args: {'error': _error})),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _loadLegalDocuments,
                      icon: const Icon(Icons.refresh),
                      label: Text(appText(AppText.retryButton)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_shortDescription, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(appText(AppText.publicLegalVersionLabel, args: {'version': _version})),
                  SelectableText(appText(AppText.publicLegalUrlLabel, args: {'url': _documentUrl})),
                  SelectableText(appText(AppText.publicLegalContactLabel, args: {'email': _contactEmail})),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          ..._sections.map((section) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(section.key, style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 6),
                      Text(section.value),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    required this.onAnswer,
    required this.questionLocked,
    required this.selectedChoiceId,
  });

  final Map<String, dynamic> question;
  final ValueChanged<int> onAnswer;
  final bool questionLocked;
  final int? selectedChoiceId;

  static const _answerColors = [
    Color(0xFFE21B3C),
    Color(0xFF1368CE),
    Color(0xFFD89E00),
    Color(0xFF26890C),
  ];

  static const _answerIcons = [
    Icons.change_history,
    Icons.diamond_outlined,
    Icons.circle_outlined,
    Icons.square_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final choices = (question['choices'] as List<dynamic>? ?? <dynamic>[]).toList()
      ..sort((a, b) {
        final aMap = mapOrNull(a) ?? <String, dynamic>{};
        final bMap = mapOrNull(b) ?? <String, dynamic>{};
        return asInt(aMap['order']).compareTo(asInt(bMap['order']));
      });

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF111827), Color(0xFF023047)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF111827).withOpacity(0.22),
            blurRadius: 26,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    appText(AppText.questionTimeLimitLabel, args: {'seconds': question['time_limit_sec'] ?? '-'}),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                ),
                if (questionLocked)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      appText(AppText.answerLockedMessage),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              '${question['text']}',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    height: 1.15,
                  ),
            ),
            const SizedBox(height: 18),
            LayoutBuilder(
              builder: (context, constraints) {
                final useTwoColumns = constraints.maxWidth >= 680;
                final itemWidth = useTwoColumns ? (constraints.maxWidth - 12) / 2 : constraints.maxWidth;

                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: choices.asMap().entries.map((entry) {
                    final choiceIndex = entry.key;
                    final rawChoice = entry.value;
                    final choice = mapOrNull(rawChoice) ?? <String, dynamic>{};
                    final choiceId = asInt(choice['id'], -1);
                    final isSelected = selectedChoiceId == choiceId;
                    final color = _answerColors[choiceIndex % _answerColors.length];
                    final icon = _answerIcons[choiceIndex % _answerIcons.length];

                    return SizedBox(
                      width: itemWidth,
                      child: _buildAnswerTile(
                        context,
                        color: color,
                        icon: icon,
                        label: '${choice['text']}',
                        isSelected: isSelected,
                        isDimmed: questionLocked && !isSelected,
                        onTap: questionLocked ? null : () => onAnswer(choiceId),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnswerTile(
    BuildContext context, {
    required Color color,
    required IconData icon,
    required String label,
    required bool isSelected,
    required bool isDimmed,
    required VoidCallback? onTap,
  }) {
    final radius = BorderRadius.circular(24);

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: isDimmed ? 0.58 : 1,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            minHeight: 88,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: color,
              borderRadius: radius,
              border: Border.all(
                color: isSelected ? Colors.white : Colors.white.withOpacity(0.18),
                width: isSelected ? 4 : 1,
              ),
              boxShadow: [
                if (isSelected)
                  BoxShadow(
                    color: Colors.white.withOpacity(0.28),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          height: 1.2,
                        ),
                  ),
                ),
                if (isSelected) ...[
                  const SizedBox(width: 10),
                  const Icon(Icons.check_circle, color: Colors.white),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
