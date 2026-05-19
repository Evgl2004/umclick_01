import 'dart:convert';

import '../api/api_client.dart';
import '../l10n/app_strings.dart';

String userErrorText(Object error) {
  if (error is ApiException) {
    return _apiExceptionText(error);
  }
  if (error is FormatException) {
    return _formatExceptionText(error);
  }
  if (error is StateError) {
    return _rawErrorText(error.message);
  }
  return _rawErrorText(error.toString());
}

String _apiExceptionText(ApiException error) {
  if (error.message == 'Failed to join session') {
    final validationText = _joinValidationText(error);
    if (validationText != null) {
      return validationText;
    }
  }

  return switch (error.message) {
    'Failed to register teacher' => appText(AppText.apiRegisterTeacherFailed),
    'Failed to login' => appText(AppText.apiLoginFailed),
    'Failed to refresh token' => appText(AppText.apiRefreshTokenFailed),
    'Failed to get profile' => appText(AppText.apiGetProfileFailed),
    'Failed to load quizzes' => appText(AppText.apiLoadQuizzesFailed),
    'Failed to create quiz' => appText(AppText.apiCreateQuizFailed),
    'Failed to update quiz' => appText(AppText.apiUpdateQuizFailed),
    'Failed to delete quiz' => appText(AppText.apiDeleteQuizFailed),
    'Failed to create session' => appText(AppText.apiCreateSessionFailed),
    'Failed to fetch session details' =>
      appText(AppText.apiFetchSessionDetailsFailed),
    'Failed to start session' => appText(AppText.apiStartSessionFailed),
    'Failed to finish session' => appText(AppText.apiFinishSessionFailed),
    'Failed to load next question' => appText(AppText.apiNextQuestionFailed),
    'Failed to reveal answers' => appText(AppText.apiRevealAnswersFailed),
    'Failed to load leaderboard' => appText(AppText.apiLoadLeaderboardFailed),
    'Failed to export session results' =>
      appText(AppText.apiExportSessionFailed),
    'Failed to load legal documents' => appText(AppText.apiLoadLegalFailed),
    'Failed to load session preview' => appText(AppText.apiLoadPreviewFailed),
    'Failed to join session' => appText(AppText.apiJoinSessionFailed),
    'Failed to submit answer' => appText(AppText.apiSubmitAnswerFailed),
    _ => _rawErrorText(error.message),
  };
}

String? _joinValidationText(ApiException error) {
  if (error.statusCode != 400) {
    return null;
  }

  final body = _decodeErrorBody(error.body);
  if (body == null) {
    return null;
  }

  if (_hasFieldError(body, 'name')) {
    return appText(AppText.participantNameRequiredError);
  }
  if (_hasFieldError(body, 'phone')) {
    return appText(AppText.participantPhoneRequiredError);
  }
  if (_hasFieldError(body, 'consent')) {
    return appText(AppText.participantConsentRequiredError);
  }

  return null;
}

Map<String, dynamic>? _decodeErrorBody(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
  } on FormatException {
    return null;
  }
  return null;
}

bool _hasFieldError(Map<String, dynamic> body, String field) {
  final value = body[field];
  if (value == null) {
    return false;
  }
  if (value is List) {
    return value.isNotEmpty;
  }
  if (value is Map) {
    return value.isNotEmpty;
  }
  return value.toString().trim().isNotEmpty;
}

String _formatExceptionText(FormatException error) {
  final message = error.message;
  final questionTextMatch =
      RegExp(r'^Question (\d+) text is required\.$').firstMatch(message);
  if (questionTextMatch != null) {
    return appText(
      AppText.quizValidationQuestionTextRequired,
      args: {'questionNumber': questionTextMatch.group(1)},
    );
  }

  final timeLimitMatch = RegExp(
    r'^Question (\d+) time limit must be between 5 and 180 seconds\.$',
  ).firstMatch(message);
  if (timeLimitMatch != null) {
    return appText(
      AppText.quizValidationQuestionTimeLimit,
      args: {'questionNumber': timeLimitMatch.group(1)},
    );
  }

  final twoChoicesMatch = RegExp(
    r'^Question (\d+) must have at least two non-empty choices\.$',
  ).firstMatch(message);
  if (twoChoicesMatch != null) {
    return appText(
      AppText.quizValidationTwoChoices,
      args: {'questionNumber': twoChoicesMatch.group(1)},
    );
  }

  final oneCorrectMatch = RegExp(
    r'^Question (\d+) must have exactly one correct choice\.$',
  ).firstMatch(message);
  if (oneCorrectMatch != null) {
    return appText(
      AppText.quizValidationOneCorrectChoice,
      args: {'questionNumber': oneCorrectMatch.group(1)},
    );
  }

  return _rawErrorText(message);
}

String _rawErrorText(String message) {
  return switch (message) {
    'Quiz title is required.' => appText(AppText.quizValidationTitleRequired),
    'Add at least one question.' => appText(AppText.quizValidationAddQuestion),
    'Login required for teacher API.' =>
      appText(AppText.teacherLoginRequiredError),
    'Session expired. Please login again.' =>
      appText(AppText.sessionExpiredLoginAgainError),
    'Enter a PIN or open a tokenized join link first.' =>
      appText(AppText.participantJoinTargetRequired),
    'Session is not available for joining.' =>
      appText(AppText.participantSessionUnavailable),
    _ => message,
  };
}
