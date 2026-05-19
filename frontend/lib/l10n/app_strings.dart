import 'app_language.dart';

enum AppText {
  appTitle,
  teacherTab,
  participantTab,
  apiBaseUrlLabel,
  teacherApiBaseUrlHelper,
  participantApiBaseUrlHelper,
  teacherAuthTitle,
  teacherHeroBadge,
  teacherHeroTitle,
  teacherHeroSubtitle,
  teacherWorkspaceTitle,
  teacherWorkspaceSubtitle,
  teacherAdvancedSettingsTitle,
  teacherAdvancedSettingsSubtitle,
  teacherFlowAuthTitle,
  teacherFlowAuthBody,
  teacherFlowQuizTitle,
  teacherFlowQuizBody,
  teacherFlowLaunchTitle,
  teacherFlowLaunchBody,
  teacherLockedTitle,
  teacherLockedBody,
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
  teacherSessionSetupTitle,
  teacherSessionSetupSubtitle,
  teacherLivePanelTitle,
  teacherQrCodeTitle,
  teacherRoundControlsTitle,
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
  exportDownloadedSnack,
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
  participantHeroJoinBadge,
  participantHeroJoinTitle,
  participantHeroJoinSubtitle,
  participantHeroLiveBadge,
  participantHeroLiveTitle,
  participantHeroLiveSubtitle,
  participantJoinCardTitle,
  participantProfileCardTitle,
  participantLiveCardTitle,
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
  participantTimeLeftBadge,
  sessionFinishedMessage,
  participantFinalPodiumTitle,
  participantFinalPodiumSubtitle,
  participantYourFinalResult,
  participantFinalRank,
  participantCorrectAnswers,
  participantRoundLeaderboardTitle,
  participantNoLeaderboardYet,
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
  quizRequiresOneQuestionSnack,
  questionRequiresTwoChoicesSnack,
  teacherRegisteredSnack,
  teacherLoginRequiredError,
  sessionExpiredLoginAgainError,
  quizCreatedNextStepSnack,
  quizUpdatedSnack,
  deleteQuizDialogTitle,
  deleteQuizDialogBody,
  cancelButton,
  deleteButton,
  leaderboardTitle,
  leaderboardNoResults,
  leaderboardCloseButton,
  leaderboardStats,
  quizValidationTitleRequired,
  quizValidationAddQuestion,
  quizValidationQuestionTextRequired,
  quizValidationQuestionTimeLimit,
  quizValidationTwoChoices,
  quizValidationOneCorrectChoice,
  participantJoinTargetRequired,
  participantNameRequiredError,
  participantPhoneRequiredError,
  participantConsentRequiredError,
  participantManualPinFallbackHint,
  participantSessionUnavailable,
  apiRegisterTeacherFailed,
  apiLoginFailed,
  apiRefreshTokenFailed,
  apiGetProfileFailed,
  apiLoadQuizzesFailed,
  apiCreateQuizFailed,
  apiUpdateQuizFailed,
  apiDeleteQuizFailed,
  apiCreateSessionFailed,
  apiFetchSessionDetailsFailed,
  apiStartSessionFailed,
  apiFinishSessionFailed,
  apiNextQuestionFailed,
  apiRevealAnswersFailed,
  apiLoadLeaderboardFailed,
  apiExportSessionFailed,
  apiLoadLegalFailed,
  apiLoadPreviewFailed,
  apiJoinSessionFailed,
  apiSubmitAnswerFailed,
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
  AppText.teacherAuthTitle:
      LocalizedString(ru: 'Вход преподавателя', en: 'Teacher Auth'),
  AppText.teacherHeroBadge:
      LocalizedString(ru: 'Панель ведущего', en: 'Host workspace'),
  AppText.teacherHeroTitle: LocalizedString(
    ru: 'Создайте викторину и запустите игру для аудитории',
    en: 'Create a quiz and host a live game',
  ),
  AppText.teacherHeroSubtitle: LocalizedString(
    ru: 'Сначала войдите как преподаватель. После входа откроется рабочий сценарий: викторина, запуск live-сессии, QR/PIN и экспорт результатов.',
    en: 'Sign in as a teacher first. After login, the workspace opens: quiz builder, live launch, QR/PIN, and result export.',
  ),
  AppText.teacherWorkspaceTitle: LocalizedString(
      ru: 'Рабочий кабинет преподавателя', en: 'Teacher workspace'),
  AppText.teacherWorkspaceSubtitle: LocalizedString(
    ru: 'Идите по шагам слева направо: подготовьте вопросы, создайте комнату, проведите раунд и выгрузите CSV.',
    en: 'Follow the flow left to right: prepare questions, create a room, host the round, and export CSV.',
  ),
  AppText.teacherAdvancedSettingsTitle:
      LocalizedString(ru: 'Технические настройки', en: 'Technical settings'),
  AppText.teacherAdvancedSettingsSubtitle: LocalizedString(
    ru: 'Обычно не открывать. Здесь можно поменять адрес API для разработки или диагностики.',
    en: 'Usually keep closed. Use this only to change API URL for development or diagnostics.',
  ),
  AppText.teacherFlowAuthTitle:
      LocalizedString(ru: '1. Вход', en: '1. Sign in'),
  AppText.teacherFlowAuthBody: LocalizedString(
    ru: 'Зарегистрируйтесь или войдите по выданному коду преподавателя.',
    en: 'Register or sign in with the teacher code.',
  ),
  AppText.teacherFlowQuizTitle:
      LocalizedString(ru: '2. Викторина', en: '2. Quiz'),
  AppText.teacherFlowQuizBody: LocalizedString(
    ru: 'Создайте вопросы, варианты и отметьте правильные ответы.',
    en: 'Create questions, choices, and mark correct answers.',
  ),
  AppText.teacherFlowLaunchTitle:
      LocalizedString(ru: '3. Запуск', en: '3. Launch'),
  AppText.teacherFlowLaunchBody: LocalizedString(
    ru: 'Создайте live-сессию, покажите QR/PIN и управляйте раундом.',
    en: 'Create a live session, share QR/PIN, and control the round.',
  ),
  AppText.teacherLockedTitle: LocalizedString(
      ru: 'Рабочий кабинет откроется после входа',
      en: 'Workspace unlocks after sign in'),
  AppText.teacherLockedBody: LocalizedString(
    ru: 'Так проверяющий не попадает сразу в конструктор и видит понятную точку старта.',
    en: 'This keeps reviewers out of the builder until they have a clear starting point.',
  ),
  AppText.usernameLabel: LocalizedString(ru: 'Логин', en: 'Username'),
  AppText.passwordLabel: LocalizedString(ru: 'Пароль', en: 'Password'),
  AppText.emailOptionalLabel:
      LocalizedString(ru: 'Email (необязательно)', en: 'Email (optional)'),
  AppText.signupCodeOptionalLabel: LocalizedString(
    ru: 'Код регистрации (необязательно)',
    en: 'Signup code (optional)',
  ),
  AppText.signupCodeHelper: LocalizedString(
    ru: 'Если в .env задан TEACHER_SIGNUP_CODE, без него регистрация закрыта.',
    en: 'Required only when TEACHER_SIGNUP_CODE is configured in .env.',
  ),
  AppText.registerButton:
      LocalizedString(ru: 'Зарегистрироваться', en: 'Register'),
  AppText.loginButton: LocalizedString(ru: 'Войти', en: 'Login'),
  AppText.teacherProfileButton: LocalizedString(ru: 'Профиль', en: 'Who am I'),
  AppText.logoutButton: LocalizedString(ru: 'Выйти', en: 'Logout'),
  AppText.restoringTeacherSession: LocalizedString(
    ru: 'Восстанавливаем сессию преподавателя...',
    en: 'Restoring saved teacher session...',
  ),
  AppText.loggedInTeacher:
      LocalizedString(ru: 'Вход выполнен{suffix}', en: 'Logged in{suffix}'),
  AppText.notAuthenticated:
      LocalizedString(ru: 'Не авторизован', en: 'Not authenticated'),
  AppText.refreshTokenStored: LocalizedString(
    ru: 'Refresh token сохранен локально в этом браузере.',
    en: 'Refresh token is stored locally for this browser profile.',
  ),
  AppText.quizBuilderTitle:
      LocalizedString(ru: 'Конструктор викторины', en: 'Quiz Builder'),
  AppText.quizDraftMode:
      LocalizedString(ru: 'Режим: новая викторина', en: 'Mode: new quiz draft'),
  AppText.quizEditMode: LocalizedString(
    ru: 'Режим: редактирование викторины #{id}',
    en: 'Mode: editing quiz #{id}',
  ),
  AppText.untitledQuiz: LocalizedString(ru: 'Без названия', en: 'Untitled'),
  AppText.untitledQuizLong:
      LocalizedString(ru: 'Викторина без названия', en: 'Untitled quiz'),
  AppText.noQuizzesYet:
      LocalizedString(ru: 'Викторин пока нет', en: 'No quizzes yet'),
  AppText.loadButton: LocalizedString(ru: 'Загрузить', en: 'Load'),
  AppText.saveNewQuizButton:
      LocalizedString(ru: 'Сохранить новую', en: 'Save new quiz'),
  AppText.saveQuizChangesButton:
      LocalizedString(ru: 'Сохранить изменения', en: 'Save changes'),
  AppText.newDraftButton:
      LocalizedString(ru: 'Новый черновик', en: 'New draft'),
  AppText.refreshQuizzesButton:
      LocalizedString(ru: 'Обновить список', en: 'Refresh quizzes'),
  AppText.deleteSelectedButton:
      LocalizedString(ru: 'Удалить выбранную', en: 'Delete selected'),
  AppText.quizTitleLabel:
      LocalizedString(ru: 'Название викторины', en: 'Quiz title'),
  AppText.quizDescriptionOptionalLabel: LocalizedString(
    ru: 'Описание (необязательно)',
    en: 'Description (optional)',
  ),
  AppText.questionNumber:
      LocalizedString(ru: 'Вопрос {number}', en: 'Question {number}'),
  AppText.removeQuestionTooltip:
      LocalizedString(ru: 'Удалить вопрос', en: 'Remove question'),
  AppText.questionTextLabel:
      LocalizedString(ru: 'Текст вопроса', en: 'Question text'),
  AppText.timeLimitSecLabel:
      LocalizedString(ru: 'Лимит времени (сек)', en: 'Time limit (sec)'),
  AppText.timeLimitHelper: LocalizedString(
    ru: 'Участник должен ответить до окончания таймера.',
    en: 'Participant must answer before the timer expires.',
  ),
  AppText.choiceNumber:
      LocalizedString(ru: 'Вариант {number}', en: 'Choice {number}'),
  AppText.removeChoiceTooltip:
      LocalizedString(ru: 'Удалить вариант', en: 'Remove choice'),
  AppText.addChoiceButton:
      LocalizedString(ru: 'Добавить вариант', en: 'Add choice'),
  AppText.addQuestionButton:
      LocalizedString(ru: 'Добавить вопрос', en: 'Add question'),
  AppText.selectQuizForSession: LocalizedString(
    ru: 'Выберите викторину, чтобы создать live-сессию.',
    en: 'Select a quiz in builder to create a live session.',
  ),
  AppText.sessionQuiz:
      LocalizedString(ru: 'Викторина сессии: #{id}', en: 'Session quiz: #{id}'),
  AppText.teacherSessionSetupTitle: LocalizedString(
    ru: 'Live-сессия',
    en: 'Live session',
  ),
  AppText.teacherSessionSetupSubtitle: LocalizedString(
    ru: 'Выберите викторину и создайте комнату для участников.',
    en: 'Select a quiz and create a room for participants.',
  ),
  AppText.teacherLivePanelTitle: LocalizedString(
    ru: 'Панель ведущего',
    en: 'Host panel',
  ),
  AppText.teacherQrCodeTitle: LocalizedString(
    ru: 'QR для подключения',
    en: 'Join QR code',
  ),
  AppText.teacherRoundControlsTitle: LocalizedString(
    ru: 'Управление раундом',
    en: 'Round controls',
  ),
  AppText.createSessionButton:
      LocalizedString(ru: 'Создать сессию', en: 'Create session'),
  AppText.statusValue:
      LocalizedString(ru: 'Статус: {status}', en: 'Status: {status}'),
  AppText.participantsCount:
      LocalizedString(ru: 'Участники: {count}', en: 'Participants: {count}'),
  AppText.webSocketState:
      LocalizedString(ru: 'WebSocket: {state}', en: 'WebSocket: {state}'),
  AppText.webSocketConnected: LocalizedString(ru: 'подключен', en: 'connected'),
  AppText.webSocketDisconnected:
      LocalizedString(ru: 'отключен', en: 'disconnected'),
  AppText.currentQuestion: LocalizedString(
      ru: 'Текущий вопрос: {text}', en: 'Current question: {text}'),
  AppText.timeLeft:
      LocalizedString(ru: 'Осталось времени: {time}', en: 'Time left: {time}'),
  AppText.answersReceived: LocalizedString(
      ru: 'Получено ответов: {count}', en: 'Answers received: {count}'),
  AppText.joinUrl: LocalizedString(
      ru: 'Ссылка для участников: {url}', en: 'Join URL: {url}'),
  AppText.startButton: LocalizedString(ru: 'Старт', en: 'Start'),
  AppText.nextQuestionButton:
      LocalizedString(ru: 'Следующий вопрос', en: 'Next question'),
  AppText.revealAnswersButton:
      LocalizedString(ru: 'Показать ответы', en: 'Reveal answers'),
  AppText.finishButton: LocalizedString(ru: 'Завершить', en: 'Finish'),
  AppText.leaderboardButton: LocalizedString(ru: 'Рейтинг', en: 'Leaderboard'),
  AppText.exportCsvButton: LocalizedString(ru: 'Экспорт CSV', en: 'Export CSV'),
  AppText.exportUrlSnack:
      LocalizedString(ru: 'Ссылка экспорта: {url}', en: 'Export URL: {url}'),
  AppText.exportDownloadedSnack: LocalizedString(
    ru: 'CSV-файл с результатами скачан.',
    en: 'CSV results file downloaded.',
  ),
  AppText.revealResultsTitle:
      LocalizedString(ru: 'Результаты раунда', en: 'Round results'),
  AppText.totalAnswers: LocalizedString(
      ru: 'Всего ответов: {count}', en: 'Total answers: {count}'),
  AppText.pointsAwarded: LocalizedString(
      ru: 'Начислено очков: {points}', en: 'Points awarded: {points}'),
  AppText.revealedBy:
      LocalizedString(ru: 'Раскрыто: {value}', en: 'Revealed by: {value}'),
  AppText.choiceStats: LocalizedString(
    ru: 'Голоса: {votes} | Очки: {points}',
    en: 'Votes: {votes} | Pts: {points}',
  ),
  AppText.liveEventsTitle: LocalizedString(ru: 'События', en: 'Live events'),
  AppText.noEventsYet:
      LocalizedString(ru: 'Событий пока нет.', en: 'No events yet.'),
  AppText.joinLinkDetected: LocalizedString(
    ru: 'Обнаружена ссылка входа. PIN вводить не нужно.',
    en: 'Join link detected. Session PIN is not required.',
  ),
  AppText.joinTokenLabel:
      LocalizedString(ru: 'Токен: {token}', en: 'Token: {token}'),
  AppText.refreshPreviewButton:
      LocalizedString(ru: 'Обновить предпросмотр', en: 'Refresh preview'),
  AppText.usePinInsteadButton:
      LocalizedString(ru: 'Ввести PIN вручную', en: 'Use PIN instead'),
  AppText.participantHeroJoinBadge:
      LocalizedString(ru: 'Игровой вход', en: 'Game join'),
  AppText.participantHeroJoinTitle:
      LocalizedString(ru: 'Готовимся к квизу', en: 'Get ready to play'),
  AppText.participantHeroJoinSubtitle: LocalizedString(
    ru: 'Введите PIN с экрана преподавателя или откройте QR-ссылку, чтобы попасть в live-сессию.',
    en: 'Enter the PIN from the teacher screen or open the QR link to join the live session.',
  ),
  AppText.participantHeroLiveBadge:
      LocalizedString(ru: 'Live-игра', en: 'Live game'),
  AppText.participantHeroLiveTitle:
      LocalizedString(ru: 'Вы в игре', en: 'You are in'),
  AppText.participantHeroLiveSubtitle: LocalizedString(
    ru: 'Следите за вопросом, отвечайте быстро и ждите раскрытия результатов преподавателем.',
    en: 'Follow the question, answer quickly, and wait for the teacher to reveal results.',
  ),
  AppText.participantJoinCardTitle: LocalizedString(
    ru: 'Подключение к сессии',
    en: 'Session connection',
  ),
  AppText.participantProfileCardTitle: LocalizedString(
    ru: 'Быстрая регистрация',
    en: 'Quick registration',
  ),
  AppText.participantLiveCardTitle:
      LocalizedString(ru: 'Игровой раунд', en: 'Game round'),
  AppText.sessionPinLabel: LocalizedString(ru: 'PIN сессии', en: 'Session PIN'),
  AppText.sessionPinHelper: LocalizedString(
    ru: '6 цифр с экрана преподавателя. По QR-ссылке PIN не нужен.',
    en: '6 digits from teacher screen. QR links do not require PIN.',
  ),
  AppText.previewSessionButton:
      LocalizedString(ru: 'Предпросмотр сессии', en: 'Preview session'),
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
  AppText.legalDocumentsButton:
      LocalizedString(ru: 'Документы и согласие', en: 'Privacy & consent'),
  AppText.refreshLegalDocsButton:
      LocalizedString(ru: 'Обновить документы', en: 'Refresh legal docs'),
  AppText.joinSessionButton:
      LocalizedString(ru: 'Войти в сессию', en: 'Join session'),
  AppText.participantPoints:
      LocalizedString(ru: 'Очки: {points}', en: 'Points: {points}'),
  AppText.participantLastAnswer: LocalizedString(
      ru: 'Последний ответ: +{points}', en: 'Last answer: +{points} pts'),
  AppText.participantTimeLeftBadge:
      LocalizedString(ru: 'Осталось: {time}', en: 'Left: {time}'),
  AppText.sessionFinishedMessage: LocalizedString(
    ru: 'Сессия завершена. Спасибо за участие!',
    en: 'Session finished. Thanks for playing!',
  ),
  AppText.participantFinalPodiumTitle:
      LocalizedString(ru: 'Финальный подиум', en: 'Final podium'),
  AppText.participantFinalPodiumSubtitle: LocalizedString(
    ru: 'Игра завершена. Вот итоговые места и ваш результат.',
    en: 'Game finished. Here are the final places and your result.',
  ),
  AppText.participantYourFinalResult: LocalizedString(
    ru: 'Ваш результат: {points} очков',
    en: 'Your result: {points} pts',
  ),
  AppText.participantFinalRank:
      LocalizedString(ru: 'Место #{rank}', en: 'Rank #{rank}'),
  AppText.participantCorrectAnswers: LocalizedString(
    ru: 'Верных ответов: {count}',
    en: 'Correct answers: {count}',
  ),
  AppText.participantRoundLeaderboardTitle: LocalizedString(
      ru: 'Рейтинг после вопроса', en: 'Leaderboard after question'),
  AppText.participantNoLeaderboardYet: LocalizedString(
    ru: 'Рейтинг появится после первых ответов.',
    en: 'Leaderboard appears after the first answers.',
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
  AppText.privacyConsentTitle:
      LocalizedString(ru: 'Документы и согласие', en: 'Privacy & Consent'),
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
  AppText.legalContactLabel:
      LocalizedString(ru: 'Контакт: {email}', en: 'Contact: {email}'),
  AppText.legalConsentNotice: LocalizedString(
    ru: 'Перед входом в викторину участник подтверждает согласие на обработку персональных данных '
        'и принимает политику конфиденциальности. Эти версии сохраняются вместе с согласием.',
    en: 'Before joining a quiz, participant agrees to personal data processing '
        'and acknowledges the privacy policy. Versions above are saved with consent.',
  ),
  AppText.privacyPolicyTitle:
      LocalizedString(ru: 'Политика конфиденциальности', en: 'Privacy Policy'),
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
  AppText.consentScopeTitle:
      LocalizedString(ru: '1. Объем согласия', en: '1. Scope of Consent'),
  AppText.consentScopeBody: LocalizedString(
    ru: 'Входя в сессию, участник соглашается на обработку телефона, имени, ответов, очков и времени участия.',
    en: 'By joining a session, participant consents to processing of phone number, name, '
        'quiz answers, score values, and participation timestamps.',
  ),
  AppText.consentActionsTitle:
      LocalizedString(ru: '2. Действия с данными', en: '2. Processing Actions'),
  AppText.consentActionsBody: LocalizedString(
    ru: 'Согласие включает сбор, запись, систематизацию, хранение, обновление, извлечение, '
        'передачу авторизованному преподавателю и удаление после срока хранения.',
    en: 'Consent covers collection, recording, systematization, storage, updating, extraction, '
        'transfer to authorized teacher accounts, and deletion after retention period.',
  ),
  AppText.consentPurposeTitle:
      LocalizedString(ru: '3. Цель обработки', en: '3. Purpose of Processing'),
  AppText.consentPurposeBody: LocalizedString(
    ru: 'Обработка нужна для входа участника, прохождения викторины, расчета очков, показа рейтинга и экспорта отчета преподавателю.',
    en: 'Processing is required for participant authorization, quiz gameplay, score calculation, '
        'leaderboard display, and teacher report export.',
  ),
  AppText.consentPeriodTitle:
      LocalizedString(ru: '4. Срок действия', en: '4. Consent Period'),
  AppText.consentPeriodBody: LocalizedString(
    ru: 'Согласие действует с момента принятия до отзыва или до достижения целей обработки.',
    en: 'Consent is valid from the moment of acceptance and remains active until withdrawal '
        'or until processing purposes are fully achieved.',
  ),
  AppText.consentWithdrawalTitle:
      LocalizedString(ru: '5. Отзыв согласия', en: '5. Withdrawal Procedure'),
  AppText.consentWithdrawalBody: LocalizedString(
    ru: 'Участник может отозвать согласие через юридический контакт. Отзыв может ограничить дальнейшее участие в викторинах.',
    en: 'Participant can withdraw consent by contacting legal support. Withdrawal may limit ability '
        'to continue using quiz participation features.',
  ),
  AppText.consentConfirmationTitle:
      LocalizedString(ru: '6. Подтверждение', en: '6. Confirmation'),
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
  AppText.publicLegalVersionLabel:
      LocalizedString(ru: 'Версия: {version}', en: 'Version: {version}'),
  AppText.publicLegalUrlLabel:
      LocalizedString(ru: 'Публичный URL: {url}', en: 'Public URL: {url}'),
  AppText.publicLegalContactLabel: LocalizedString(
    ru: 'Юридический контакт: {email}',
    en: 'Legal contact: {email}',
  ),
  AppText.openPrivacyPolicyButton:
      LocalizedString(ru: 'Открыть политику', en: 'Open privacy policy'),
  AppText.openConsentButton:
      LocalizedString(ru: 'Открыть согласие', en: 'Open consent form'),
  AppText.openAppButton:
      LocalizedString(ru: 'Открыть приложение', en: 'Open app'),
  AppText.retryButton: LocalizedString(ru: 'Повторить', en: 'Retry'),
  AppText.questionTimeLimitLabel: LocalizedString(
    ru: 'Лимит времени: {seconds} сек',
    en: 'Time limit: {seconds} sec',
  ),
  AppText.answerLockedMessage: LocalizedString(
    ru: 'Ответ зафиксирован. Ждём обновления от преподавателя.',
    en: 'Answer locked. Waiting for teacher update.',
  ),
  AppText.quizRequiresOneQuestionSnack: LocalizedString(
    ru: 'В викторине должен остаться хотя бы один вопрос.',
    en: 'Quiz must contain at least one question.',
  ),
  AppText.questionRequiresTwoChoicesSnack: LocalizedString(
    ru: 'В вопросе должно остаться минимум два варианта ответа.',
    en: 'Each question needs at least two answer choices.',
  ),
  AppText.teacherRegisteredSnack: LocalizedString(
    ru: 'Преподаватель зарегистрирован. Теперь войдите.',
    en: 'Teacher registered. Now login.',
  ),
  AppText.teacherLoginRequiredError: LocalizedString(
    ru: 'Сначала войдите как преподаватель.',
    en: 'Login required for teacher API.',
  ),
  AppText.sessionExpiredLoginAgainError: LocalizedString(
    ru: 'Сессия истекла. Войдите снова.',
    en: 'Session expired. Please login again.',
  ),
  AppText.quizCreatedNextStepSnack: LocalizedString(
    ru: 'Викторина сохранена. Следующий шаг: в блоке «Live-сессия» нажмите «Создать сессию».',
    en: 'Quiz saved. Next step: use the Live session block and press Create session.',
  ),
  AppText.quizUpdatedSnack: LocalizedString(
    ru: 'Викторина обновлена. Можно создавать или продолжать live-сессию.',
    en: 'Quiz updated. You can create or continue a live session.',
  ),
  AppText.deleteQuizDialogTitle:
      LocalizedString(ru: 'Удалить викторину?', en: 'Delete quiz?'),
  AppText.deleteQuizDialogBody: LocalizedString(
    ru: 'Удалить «{title}» без возможности восстановления?',
    en: 'Delete "{title}" permanently? This action cannot be undone.',
  ),
  AppText.cancelButton: LocalizedString(ru: 'Отмена', en: 'Cancel'),
  AppText.deleteButton: LocalizedString(ru: 'Удалить', en: 'Delete'),
  AppText.leaderboardTitle: LocalizedString(ru: 'Рейтинг', en: 'Leaderboard'),
  AppText.leaderboardNoResults: LocalizedString(
    ru: 'Результатов пока нет.',
    en: 'No results yet.',
  ),
  AppText.leaderboardCloseButton: LocalizedString(ru: 'Закрыть', en: 'Close'),
  AppText.leaderboardStats: LocalizedString(
    ru: 'Очки: {points} | Верных: {correct}',
    en: 'Pts: {points} | Correct: {correct}',
  ),
  AppText.quizValidationTitleRequired: LocalizedString(
    ru: 'Укажите название викторины.',
    en: 'Quiz title is required.',
  ),
  AppText.quizValidationAddQuestion: LocalizedString(
    ru: 'Добавьте хотя бы один вопрос.',
    en: 'Add at least one question.',
  ),
  AppText.quizValidationQuestionTextRequired: LocalizedString(
    ru: 'Заполните текст вопроса {questionNumber}.',
    en: 'Question {questionNumber} text is required.',
  ),
  AppText.quizValidationQuestionTimeLimit: LocalizedString(
    ru: 'В вопросе {questionNumber} лимит времени должен быть от 5 до 180 секунд.',
    en: 'Question {questionNumber} time limit must be between 5 and 180 seconds.',
  ),
  AppText.quizValidationTwoChoices: LocalizedString(
    ru: 'В вопросе {questionNumber} должно быть минимум два непустых варианта ответа.',
    en: 'Question {questionNumber} must have at least two non-empty choices.',
  ),
  AppText.quizValidationOneCorrectChoice: LocalizedString(
    ru: 'В вопросе {questionNumber} должен быть ровно один правильный ответ.',
    en: 'Question {questionNumber} must have exactly one correct choice.',
  ),
  AppText.participantJoinTargetRequired: LocalizedString(
    ru: 'Введите PIN или откройте QR-ссылку для подключения.',
    en: 'Enter a PIN or open a tokenized join link first.',
  ),
  AppText.participantNameRequiredError: LocalizedString(
    ru: 'Введите имя участника.',
    en: 'Enter participant name.',
  ),
  AppText.participantPhoneRequiredError: LocalizedString(
    ru: 'Введите телефон участника.',
    en: 'Enter participant phone.',
  ),
  AppText.participantConsentRequiredError: LocalizedString(
    ru: 'Подтвердите согласие на обработку персональных данных.',
    en: 'Confirm personal data consent.',
  ),
  AppText.participantManualPinFallbackHint: LocalizedString(
    ru: '\nЕсли QR-ссылка устарела, переключитесь на ручной ввод PIN.',
    en: '\nYou can switch to manual PIN input if this link is outdated.',
  ),
  AppText.participantSessionUnavailable: LocalizedString(
    ru: 'Сессия сейчас недоступна для подключения.',
    en: 'Session is not available for joining.',
  ),
  AppText.apiRegisterTeacherFailed: LocalizedString(
    ru: 'Не удалось зарегистрировать преподавателя.',
    en: 'Failed to register teacher.',
  ),
  AppText.apiLoginFailed:
      LocalizedString(ru: 'Не удалось войти.', en: 'Failed to login.'),
  AppText.apiRefreshTokenFailed: LocalizedString(
    ru: 'Не удалось обновить сессию входа.',
    en: 'Failed to refresh token.',
  ),
  AppText.apiGetProfileFailed: LocalizedString(
    ru: 'Не удалось загрузить профиль.',
    en: 'Failed to get profile.',
  ),
  AppText.apiLoadQuizzesFailed: LocalizedString(
    ru: 'Не удалось загрузить список викторин.',
    en: 'Failed to load quizzes.',
  ),
  AppText.apiCreateQuizFailed: LocalizedString(
    ru: 'Не удалось создать викторину.',
    en: 'Failed to create quiz.',
  ),
  AppText.apiUpdateQuizFailed: LocalizedString(
    ru: 'Не удалось обновить викторину.',
    en: 'Failed to update quiz.',
  ),
  AppText.apiDeleteQuizFailed: LocalizedString(
    ru: 'Не удалось удалить викторину.',
    en: 'Failed to delete quiz.',
  ),
  AppText.apiCreateSessionFailed: LocalizedString(
    ru: 'Не удалось создать live-сессию.',
    en: 'Failed to create session.',
  ),
  AppText.apiFetchSessionDetailsFailed: LocalizedString(
    ru: 'Не удалось загрузить детали live-сессии.',
    en: 'Failed to fetch session details.',
  ),
  AppText.apiStartSessionFailed: LocalizedString(
    ru: 'Не удалось запустить live-сессию.',
    en: 'Failed to start session.',
  ),
  AppText.apiFinishSessionFailed: LocalizedString(
    ru: 'Не удалось завершить live-сессию.',
    en: 'Failed to finish session.',
  ),
  AppText.apiNextQuestionFailed: LocalizedString(
    ru: 'Не удалось открыть следующий вопрос.',
    en: 'Failed to load next question.',
  ),
  AppText.apiRevealAnswersFailed: LocalizedString(
    ru: 'Не удалось показать ответы.',
    en: 'Failed to reveal answers.',
  ),
  AppText.apiLoadLeaderboardFailed: LocalizedString(
    ru: 'Не удалось загрузить рейтинг.',
    en: 'Failed to load leaderboard.',
  ),
  AppText.apiExportSessionFailed: LocalizedString(
    ru: 'Не удалось выгрузить результаты сессии.',
    en: 'Failed to export session results.',
  ),
  AppText.apiLoadLegalFailed: LocalizedString(
    ru: 'Не удалось загрузить юридические документы.',
    en: 'Failed to load legal documents.',
  ),
  AppText.apiLoadPreviewFailed: LocalizedString(
    ru: 'Не удалось загрузить предпросмотр сессии.',
    en: 'Failed to load session preview.',
  ),
  AppText.apiJoinSessionFailed: LocalizedString(
    ru: 'Не удалось войти в сессию.',
    en: 'Failed to join session.',
  ),
  AppText.apiSubmitAnswerFailed: LocalizedString(
    ru: 'Не удалось отправить ответ.',
    en: 'Failed to submit answer.',
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
