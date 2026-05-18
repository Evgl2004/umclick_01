const localDevApiBaseUrl = 'http://localhost:8000/api';
const sameOriginApiBaseUrl = '/api';
const defaultPrivacyPolicyVersion = '2026-03';
const defaultPersonalDataConsentVersion = '2026-03';

const prefsAccessTokenKey = 'umclick_teacher_access_token';
const prefsRefreshTokenKey = 'umclick_teacher_refresh_token';
const prefsApiBaseUrlKey = 'umclick_api_base_url';
const prefsUsernameKey = 'umclick_teacher_username';

String get defaultApiBaseUrl => resolveDefaultApiBaseUrl();

String resolveDefaultApiBaseUrl([Uri? currentUri]) {
  final uri = currentUri ?? Uri.base;
  final isLocalFlutterDevServer =
      (uri.host == 'localhost' || uri.host == '127.0.0.1') && uri.port == 3000;

  if (isLocalFlutterDevServer ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return localDevApiBaseUrl;
  }

  return sameOriginApiBaseUrl;
}
