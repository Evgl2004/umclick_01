import 'app_language.dart';

enum AppText {
  appTitle,
  teacherTab,
  participantTab,
  apiBaseUrlLabel,
  teacherApiBaseUrlHelper,
  participantApiBaseUrlHelper,
  teacherAuthTitle,
  usernameLabel,
  passwordLabel,
  emailOptionalLabel,
  signupCodeOptionalLabel,
  signupCodeHelper,
  registerButton,
  loginButton,
  teacherProfileButton,
  logoutButton,
  restoringTeacherSession,
  loggedInTeacher,
  notAuthenticated,
  refreshTokenStored,
  quizBuilderTitle,
  quizDraftMode,
  quizEditMode,
  untitledQuiz,
  untitledQuizLong,
  noQuizzesYet,
  loadButton,
  saveNewQuizButton,
  saveQuizChangesButton,
  newDraftButton,
  refreshQuizzesButton,
  deleteSelectedButton,
  quizTitleLabel,
  quizDescriptionOptionalLabel,
  questionNumber,
  removeQuestionTooltip,
  questionTextLabel,
  timeLimitSecLabel,
  timeLimitHelper,
  choiceNumber,
  removeChoiceTooltip,
  addChoiceButton,
  addQuestionButton,
  selectQuizForSession,
  sessionQuiz,
  createSessionButton,
  statusValue,
  participantsCount,
  webSocketState,
  webSocketConnected,
  webSocketDisconnected,
  currentQuestion,
  timeLeft,
  answersReceived,
  joinUrl,
  startButton,
  nextQuestionButton,
  revealAnswersButton,
  finishButton,
  leaderboardButton,
  exportCsvButton,
  exportUrlSnack,
  revealResultsTitle,
  totalAnswers,
  pointsAwarded,
  revealedBy,
  choiceStats,
  liveEventsTitle,
  noEventsYet,
  joinLinkDetected,
  joinTokenLabel,
  refreshPreviewButton,
  usePinInsteadButton,
  sessionPinLabel,
  sessionPinHelper,
  previewSessionButton,
  useJoinTokenButton,
  participantNameLabel,
  participantPhoneLabel,
  participantPhoneHelper,
  legalDocumentsButton,
  refreshLegalDocsButton,
  joinSessionButton,
  participantPoints,
  participantLastAnswer,
  sessionFinishedMessage,
  waitingForQuestionMessage,
  timeOverMessage,
  consentCheckboxLabel,
  privacyConsentTitle,
  currentLegalVersionsTitle,
  privacyVersionLabel,
  privacyUrlLabel,
  personalDataConsentVersionLabel,
  personalDataConsentUrlLabel,
  legalContactLabel,
  legalConsentNotice,
  privacyPolicyTitle,
  personalDataConsentTitle,
  privacyPolicyDescription,
  personalDataConsentDescription,
  privacyDataCollectedTitle,
  privacyDataCollectedBody,
  privacyPurposeTitle,
  privacyPurposeBody,
  privacyLegalBasisTitle,
  privacyLegalBasisBody,
  privacyRetentionTitle,
  privacyRetentionBody,
  privacySharingTitle,
  privacySharingBody,
  privacyRightsTitle,
  privacyRightsBody,
  consentScopeTitle,
  consentScopeBody,
  consentActionsTitle,
  consentActionsBody,
  consentPurposeTitle,
  consentPurposeBody,
  consentPeriodTitle,
  consentPeriodBody,
  consentWithdrawalTitle,
  consentWithdrawalBody,
  consentConfirmationTitle,
  consentConfirmationBody,
  legalMetadataRefreshError,
  publicLegalVersionLabel,
  publicLegalUrlLabel,
  publicLegalContactLabel,
  openPrivacyPolicyButton,
  openConsentButton,
  openAppButton,
  retryButton,
  questionTimeLimitLabel,
  answerLockedMessage,
}

class LocalizedString {
  const LocalizedString({
    required this.ru,
    required this.en,
  });

  final String ru;
  final String en;
}

const _strings = <AppText, LocalizedString>{
  AppText.appTitle: LocalizedString(ru: 'umclick MVP', en: 'umclick MVP'),
  AppText.teacherTab: LocalizedString(ru: 'Преподаватель', en: 'Teacher'),
  AppText.participantTab: LocalizedString(ru: 'Участник', en: 'Participant'),
  AppText.apiBaseUrlLabel: LocalizedString(ru: 'Адрес API', en: 'API base URL'),
  AppText.teacherApiBaseUrlHelper: LocalizedString(
    ru: 'Обычно менять не нужно. Используется для запросов к backend.',
    en: 'Usually does not need changes. Used for backend API requests.',
  ),
  AppText.participantApiBaseUrlHelper: LocalizedString(
    ru: 'Адрес backend. В обычном сценарии уже заполнен из ссылки.',
    en: 'Backend URL. Usually already provided by the join link.',
  ),
  AppText.teacherAuthTitle: LocalizedString(ru: 'Вход преподавателя', en: 'Teacher Auth'),
  AppText.usernameLabel: LocalizedString(ru: 'Логин', en: 'Username'),
  AppText.passwordLabel: LocalizedString(ru: 'Пароль', en: 'Password'),
  AppText.emailOptionalLabel: LocalizedString(ru: 'Email (необязательно)', en: 'Email (optional)'),
  AppText.signupCodeOptionalLabel: LocalizedString(
    ru: 'Код регистрации (необязательно)',
    en: 'Signup code (optional)',
  ),
  AppText.signupCodeHelper: LocalizedString(
    ru: 'Если в .env задан TEACHER_SIGNUP_CODE, без него регистрация закрыта.',
    en: 'Required only when TEACHER_SIGNUP_CODE is configured in .env.',
  ),
  AppText.registerButton: LocalizedString(ru: 'Зарегистрироваться', en: 'Register'),
  AppText.loginButton: LocalizedString(ru: 'Войти', en: 'Login'),
  AppText.teacherProfileButton: LocalizedString(ru: 'Профиль', en: 'Who am I'),
  AppText.logoutButton: LocalizedString(ru: 'Выйти', en: 'Logout'),
  AppText.restoringTeacherSession: LocalizedString(
    ru: 'Восстанавливаем сессию преподавателя...',
    en: 'Restoring saved teacher session...',
  ),
  AppText.loggedInTeacher: LocalizedString(ru: 'Вход выполнен{suffix}', en: 'Logged in{suffix}'),
  AppText.notAuthenticated: LocalizedString(ru: 'Не авторизован', en: 'Not authenticated'),
  AppText.refreshTokenStored: LocalizedString(
    ru: 'Refresh token сохранен локально в этом браузере.',
    en: 'Refresh token is stored locally for this browser profile.',
  ),
  AppText.quizBuilderTitle: LocalizedString(ru: 'Конструктор викторины', en: 'Quiz Builder'),
  AppText.quizDraftMode: LocalizedString(ru: 'Режим: новая викторина', en: 'Mode: new quiz draft'),
  AppText.quizEditMode: LocalizedString(
    ru: 'Режим: редактирование викторины #{id}',
    en: 'Mode: editing quiz #{id}',
  ),
  AppText.untitledQuiz: LocalizedString(ru: 'Без названия', en: 'Untitled'),
  AppText.untitledQuizLong: LocalizedString(ru: 'Викторина без названия', en: 'Untitled quiz'),
  AppText.noQuizzesYet: LocalizedString(ru: 'Викторин пока нет', en: 'No quizzes yet'),
  AppText.loadButton: LocalizedString(ru: 'Загрузить', en: 'Load'),
  AppText.saveNewQuizButton: LocalizedString(ru: 'Сохранить новую', en: 'Save new quiz'),
  AppText.saveQuizChangesButton: LocalizedString(ru: 'Сохранить изменения', en: 'Save changes'),
  AppText.newDraftButton: LocalizedString(ru: 'Новый черновик', en: 'New draft'),
  AppText.refreshQuizzesButton: LocalizedString(ru: 'Обновить список', en: 'Refresh quizzes'),
  AppText.deleteSelectedButton: LocalizedString(ru: 'Удалить выбранную', en: 'Delete selected'),
  AppText.quizTitleLabel: LocalizedString(ru: 'Название викторины', en: 'Quiz title'),
  AppText.quizDescriptionOptionalLabel: LocalizedString(
    ru: 'Описание (необязательно)',
    en: 'Description (optional)',
  ),
  AppText.questionNumber: LocalizedString(ru: 'Вопрос {number}', en: 'Question {number}'),
  AppText.removeQuestionTooltip: LocalizedString(ru: 'Удалить вопрос', en: 'Remove question'),
  AppText.questionTextLabel: LocalizedString(ru: 'Текст вопроса', en: 'Question text'),
  AppText.timeLimitSecLabel: LocalizedString(ru: 'Лимит времени (сек)', en: 'Time limit (sec)'),
  AppText.timeLimitHelper: LocalizedString(
    ru: 'Участник должен ответить до окончания таймера.',
    en: 'Participant must answer before the timer expires.',
  ),
  AppText.choiceNumber: LocalizedString(ru: 'Вариант {number}', en: 'Choice {number}'),
  AppText.removeChoiceTooltip: LocalizedString(ru: 'Удалить вариант', en: 'Remove choice'),
  AppText.addChoiceButton: LocalizedString(ru: 'Добавить вариант', en: 'Add choice'),
  AppText.addQuestionButton: LocalizedString(ru: 'Добавить вопрос', en: 'Add question'),
  AppText.selectQuizForSession: LocalizedString(
    ru: 'Выберите викторину, чтобы создать live-сессию.',
    en: 'Select a quiz in builder to create a live session.',
  ),
  AppText.sessionQuiz: LocalizedString(ru: 'Викторина сессии: #{id}', en: 'Session quiz: #{id}'),
  AppText.createSessionButton: LocalizedString(ru: 'Создать сессию', en: 'Create session'),
  AppText.statusValue: LocalizedString(ru: 'Статус: {status}', en: 'Status: {status}'),
  AppText.participantsCount: LocalizedString(ru: 'Участники: {count}', en: 'Participants: {count}'),
  AppText.webSocketState: LocalizedString(ru: 'WebSocket: {state}', en: 'WebSocket: {state}'),
  AppText.webSocketConnected: LocalizedString(ru: 'подключен', en: 'connected'),
  AppText.webSocketDisconnected: LocalizedString(ru: 'отключен', en: 'disconnected'),
  AppText.currentQuestion: LocalizedString(ru: 'Текущий вопрос: {text}', en: 'Current question: {text}'),
  AppText.timeLeft: LocalizedString(ru: 'Осталось времени: {time}', en: 'Time left: {time}'),
  AppText.answersReceived: LocalizedString(ru: 'Получено ответов: {count}', en: 'Answers received: {count}'),
  AppText.joinUrl: LocalizedString(ru: 'Ссылка для участников: {url}', en: 'Join URL: {url}'),
  AppText.startButton: LocalizedString(ru: 'Старт', en: 'Start'),
  AppText.nextQuestionButton: LocalizedString(ru: 'Следующий вопрос', en: 'Next question'),
  AppText.revealAnswersButton: LocalizedString(ru: 'Показать ответы', en: 'Reveal answers'),
  AppText.finishButton: LocalizedString(ru: 'Завершить', en: 'Finish'),
  AppText.leaderboardButton: LocalizedString(ru: 'Рейтинг', en: 'Leaderboard'),
  AppText.exportCsvButton: LocalizedString(ru: 'Экспорт CSV', en: 'Export CSV'),
  AppText.exportUrlSnack: LocalizedString(ru: 'Ссылка экспорта: {url}', en: 'Export URL: {url}'),
  AppText.revealResultsTitle: LocalizedString(ru: 'Результаты раунда', en: 'Round results'),
  AppText.totalAnswers: LocalizedString(ru: 'Всего ответов: {count}', en: 'Total answers: {count}'),
  AppText.pointsAwarded: LocalizedString(ru: 'Начислено очков: {points}', en: 'Points awarded: {points}'),
  AppText.revealedBy: LocalizedString(ru: 'Раскрыто: {value}', en: 'Revealed by: {value}'),
  AppText.choiceStats: LocalizedString(
    ru: 'Голоса: {votes} | Очки: {points}',
    en: 'Votes: {votes} | Pts: {points}',
  ),
  AppText.liveEventsTitle: LocalizedString(ru: 'События', en: 'Live events'),
  AppText.noEventsYet: LocalizedString(ru: 'Событий пока нет.', en: 'No events yet.'),
  AppText.joinLinkDetected: LocalizedString(
    ru: 'Обнаружена ссылка входа. PIN вводить не нужно.',
    en: 'Join link detected. Session PIN is not required.',
  ),
  AppText.joinTokenLabel: LocalizedString(ru: 'Токен: {token}', en: 'Token: {token}'),
  AppText.refreshPreviewButton: LocalizedString(ru: 'Обновить предпросмотр', en: 'Refresh preview'),
  AppText.usePinInsteadButton: LocalizedString(ru: 'Ввести PIN вручную', en: 'Use PIN instead'),
  AppText.sessionPinLabel: LocalizedString(ru: 'PIN сессии', en: 'Session PIN'),
  AppText.sessionPinHelper: LocalizedString(
    ru: '6 цифр с экрана преподавателя. По QR-ссылке PIN не нужен.',
    en: '6 digits from teacher screen. QR links do not require PIN.',
  ),
  AppText.previewSessionButton: LocalizedString(ru: 'Предпросмотр сессии', en: 'Preview session'),
  AppText.useJoinTokenButton: LocalizedString(
    ru: 'Использовать токен из ссылки',
    en: 'Use token from join link',
  ),
  AppText.participantNameLabel: LocalizedString(ru: 'Имя', en: 'Name'),
  AppText.participantPhoneLabel: LocalizedString(ru: 'Телефон', en: 'Phone'),
  AppText.participantPhoneHelper: LocalizedString(
    ru: 'Используется для быстрой регистрации и выгрузки результатов.',
    en: 'Used for quick registration and result export.',
  ),
  AppText.legalDocumentsButton: LocalizedString(ru: 'Документы и согласие', en: 'Privacy & consent'),
  AppText.refreshLegalDocsButton: LocalizedString(ru: 'Обновить документы', en: 'Refresh legal docs'),
  AppText.joinSessionButton: LocalizedString(ru: 'Войти в сессию', en: 'Join session'),
  AppText.participantPoints: LocalizedString(ru: 'Очки: {points}', en: 'Points: {points}'),
  AppText.participantLastAnswer: LocalizedString(ru: 'Последний ответ: +{points}', en: 'Last answer: +{points} pts'),
  AppText.sessionFinishedMessage: LocalizedString(
    ru: 'Сессия завершена. Спасибо за участие!',
    en: 'Session finished. Thanks for playing!',
  ),
  AppText.waitingForQuestionMessage: LocalizedString(
    ru: 'Ждём, когда преподаватель запустит следующий вопрос...',
    en: 'Waiting for teacher to start the next question...',
  ),
  AppText.timeOverMessage: LocalizedString(
    ru: 'Время вышло. Ждите результаты и следующий вопрос.',
    en: 'Time is over. Wait for results and the next question.',
  ),
  AppText.consentCheckboxLabel: LocalizedString(
    ru: 'Согласен(на) на обработку персональных данных и принимаю политику конфиденциальности '
        '(политика v{privacyVersion}, согласие v{consentVersion})',
    en: 'I consent to personal data processing and privacy policy '
        '(privacy v{privacyVersion}, consent v{consentVersion})',
  ),
  AppText.privacyConsentTitle: LocalizedString(ru: 'Документы и согласие', en: 'Privacy & Consent'),
  AppText.currentLegalVersionsTitle: LocalizedString(
    ru: 'Актуальные версии документов',
    en: 'Current legal versions',
  ),
  AppText.privacyVersionLabel: LocalizedString(
    ru: 'Версия политики: {version}',
    en: 'Privacy policy version: {version}',
  ),
  AppText.privacyUrlLabel: LocalizedString(
    ru: 'URL политики: {url}',
    en: 'Privacy policy URL: {url}',
  ),
  AppText.personalDataConsentVersionLabel: LocalizedString(
    ru: 'Версия согласия: {version}',
    en: 'Personal data consent version: {version}',
  ),
  AppText.personalDataConsentUrlLabel: LocalizedString(
    ru: 'URL согласия: {url}',
    en: 'Consent URL: {url}',
  ),
  AppText.legalContactLabel: LocalizedString(ru: 'Контакт: {email}', en: 'Contact: {email}'),
  AppText.legalConsentNotice: LocalizedString(
    ru: 'Перед входом в викторину участник подтверждает согласие на обработку персональных данных '
        'и принимает политику конфиденциальности. Эти версии сохраняются вместе с согласием.',
    en: 'Before joining a quiz, participant agrees to personal data processing '
        'and acknowledges the privacy policy. Versions above are saved with consent.',
  ),
  AppText.privacyPolicyTitle: LocalizedString(ru: 'Политика конфиденциальности', en: 'Privacy Policy'),
  AppText.personalDataConsentTitle: LocalizedString(
    ru: 'Согласие на обработку персональных данных',
    en: 'Personal Data Processing Consent',
  ),
  AppText.privacyPolicyDescription: LocalizedString(
    ru: 'Как umclick собирает, хранит и использует данные участников.',
    en: 'How umclick collects, stores, and uses participant data.',
  ),
  AppText.personalDataConsentDescription: LocalizedString(
    ru: 'Условия согласия на сбор и обработку персональных данных в umclick.',
    en: 'Rules of consent for collecting and processing personal data in umclick.',
  ),
  AppText.privacyDataCollectedTitle: LocalizedString(
    ru: '1. Какие данные мы собираем',
    en: '1. Data We Collect',
  ),
  AppText.privacyDataCollectedBody: LocalizedString(
    ru: 'Мы собираем телефон участника, отображаемое имя, сведения об участии в сессии, '
        'историю ответов и технические журналы, необходимые для надежной работы сервиса.',
    en: 'We collect participant phone number, display name, session participation metadata, '
        'answer history, and technical logs required for reliability and abuse prevention.',
  ),
  AppText.privacyPurposeTitle: LocalizedString(
    ru: '2. Для чего обрабатываются данные',
    en: '2. Why We Process Data',
  ),
  AppText.privacyPurposeBody: LocalizedString(
    ru: 'Данные используются для регистрации участников, проведения live-викторин, расчета очков, '
        'формирования рейтинга и выгрузки результатов преподавателю.',
    en: 'Data is used to register participants, run live quiz sessions, calculate scores, '
        'build leaderboards, and export results to teachers after each session.',
  ),
  AppText.privacyLegalBasisTitle: LocalizedString(
    ru: '3. Правовое основание',
    en: '3. Legal Basis',
  ),
  AppText.privacyLegalBasisBody: LocalizedString(
    ru: 'Обработка выполняется на основании явного согласия участника, принятого перед входом в сессию.',
    en: 'Processing is based on explicit participant consent accepted before joining a quiz session.',
  ),
  AppText.privacyRetentionTitle: LocalizedString(
    ru: '4. Хранение',
    en: '4. Storage and Retention',
  ),
  AppText.privacyRetentionBody: LocalizedString(
    ru: 'Данные хранятся в базах сервиса только в течение срока, необходимого для работы продукта, '
        'разрешения спорных ситуаций и соблюдения обязательств.',
    en: 'Data is stored in service databases and retained only for the period required to deliver '
        'the service, resolve disputes, and satisfy legal obligations.',
  ),
  AppText.privacySharingTitle: LocalizedString(
    ru: '5. Доступ и передача',
    en: '5. Sharing and Access',
  ),
  AppText.privacySharingBody: LocalizedString(
    ru: 'Данные доступны авторизованному преподавателю конкретной сессии и техническим операторам, '
        'которые обеспечивают хостинг и поддержку.',
    en: 'Data is available to authorized teacher accounts of the specific session and to technical '
        'operators responsible for hosting and support under confidentiality duties.',
  ),
  AppText.privacyRightsTitle: LocalizedString(
    ru: '6. Права участника',
    en: '6. Participant Rights',
  ),
  AppText.privacyRightsBody: LocalizedString(
    ru: 'Участник может запросить доступ, исправление, ограничение, удаление данных или отзыв '
        'согласия через контактный email на этой странице.',
    en: 'Participants may request access, correction, restriction, deletion, or withdrawal of consent '
        'by contacting the legal email listed on this page.',
  ),
  AppText.consentScopeTitle: LocalizedString(ru: '1. Объем согласия', en: '1. Scope of Consent'),
  AppText.consentScopeBody: LocalizedString(
    ru: 'Входя в сессию, участник соглашается на обработку телефона, имени, ответов, очков и времени участия.',
    en: 'By joining a session, participant consents to processing of phone number, name, '
        'quiz answers, score values, and participation timestamps.',
  ),
  AppText.consentActionsTitle: LocalizedString(ru: '2. Действия с данными', en: '2. Processing Actions'),
  AppText.consentActionsBody: LocalizedString(
    ru: 'Согласие включает сбор, запись, систематизацию, хранение, обновление, извлечение, '
        'передачу авторизованному преподавателю и удаление после срока хранения.',
    en: 'Consent covers collection, recording, systematization, storage, updating, extraction, '
        'transfer to authorized teacher accounts, and deletion after retention period.',
  ),
  AppText.consentPurposeTitle: LocalizedString(ru: '3. Цель обработки', en: '3. Purpose of Processing'),
  AppText.consentPurposeBody: LocalizedString(
    ru: 'Обработка нужна для входа участника, прохождения викторины, расчета очков, показа рейтинга и экспорта отчета преподавателю.',
    en: 'Processing is required for participant authorization, quiz gameplay, score calculation, '
        'leaderboard display, and teacher report export.',
  ),
  AppText.consentPeriodTitle: LocalizedString(ru: '4. Срок действия', en: '4. Consent Period'),
  AppText.consentPeriodBody: LocalizedString(
    ru: 'Согласие действует с момента принятия до отзыва или до достижения целей обработки.',
    en: 'Consent is valid from the moment of acceptance and remains active until withdrawal '
        'or until processing purposes are fully achieved.',
  ),
  AppText.consentWithdrawalTitle: LocalizedString(ru: '5. Отзыв согласия', en: '5. Withdrawal Procedure'),
  AppText.consentWithdrawalBody: LocalizedString(
    ru: 'Участник может отозвать согласие через юридический контакт. Отзыв может ограничить дальнейшее участие в викторинах.',
    en: 'Participant can withdraw consent by contacting legal support. Withdrawal may limit ability '
        'to continue using quiz participation features.',
  ),
  AppText.consentConfirmationTitle: LocalizedString(ru: '6. Подтверждение', en: '6. Confirmation'),
  AppText.consentConfirmationBody: LocalizedString(
    ru: 'Продолжая регистрацию, участник подтверждает, что прочитал и принял этот текст согласия '
        'и связанную версию политики конфиденциальности.',
    en: 'Continuing with registration confirms that participant has read and accepted this consent '
        'text and related privacy policy version.',
  ),
  AppText.legalMetadataRefreshError: LocalizedString(
    ru: 'Не удалось обновить юридические данные: {error}',
    en: 'Failed to refresh legal metadata: {error}',
  ),
  AppText.publicLegalVersionLabel: LocalizedString(ru: 'Версия: {version}', en: 'Version: {version}'),
  AppText.publicLegalUrlLabel: LocalizedString(ru: 'Публичный URL: {url}', en: 'Public URL: {url}'),
  AppText.publicLegalContactLabel: LocalizedString(
    ru: 'Юридический контакт: {email}',
    en: 'Legal contact: {email}',
  ),
  AppText.openPrivacyPolicyButton: LocalizedString(ru: 'Открыть политику', en: 'Open privacy policy'),
  AppText.openConsentButton: LocalizedString(ru: 'Открыть согласие', en: 'Open consent form'),
  AppText.openAppButton: LocalizedString(ru: 'Открыть приложение', en: 'Open app'),
  AppText.retryButton: LocalizedString(ru: 'Повторить', en: 'Retry'),
  AppText.questionTimeLimitLabel: LocalizedString(
    ru: 'Лимит времени: {seconds} сек',
    en: 'Time limit: {seconds} sec',
  ),
  AppText.answerLockedMessage: LocalizedString(
    ru: 'Ответ зафиксирован. Ждём обновления от преподавателя.',
    en: 'Answer locked. Waiting for teacher update.',
  ),
};

String appText(AppText key, {Map<String, Object?> args = const {}}) {
  final text = _strings[key];
  if (text == null) {
    return key.name;
  }
  var result = uiText(ru: text.ru, en: text.en);
  for (final entry in args.entries) {
    result = result.replaceAll('{${entry.key}}', entry.value?.toString() ?? '');
  }
  return result;
}
