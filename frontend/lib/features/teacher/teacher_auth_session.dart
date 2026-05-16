import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_config.dart';

class TeacherAuthSession {
  const TeacherAuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.apiBaseUrl,
    required this.username,
  });

  final String? accessToken;
  final String? refreshToken;
  final String? apiBaseUrl;
  final String? username;

  bool get hasAccessToken => accessToken != null && accessToken!.isNotEmpty;
}

class TeacherAuthSessionStore {
  const TeacherAuthSessionStore();

  Future<TeacherAuthSession> restore() async {
    final prefs = await SharedPreferences.getInstance();
    return TeacherAuthSession(
      accessToken: prefs.getString(prefsAccessTokenKey),
      refreshToken: prefs.getString(prefsRefreshTokenKey),
      apiBaseUrl: prefs.getString(prefsApiBaseUrlKey),
      username: prefs.getString(prefsUsernameKey),
    );
  }

  Future<void> persist({
    required String? accessToken,
    required String? refreshToken,
    required String apiBaseUrl,
    required String username,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await _setOrRemove(prefs, prefsAccessTokenKey, accessToken);
    await _setOrRemove(prefs, prefsRefreshTokenKey, refreshToken);

    if (apiBaseUrl.isNotEmpty) {
      await prefs.setString(prefsApiBaseUrlKey, apiBaseUrl);
    }
    if (username.isNotEmpty) {
      await prefs.setString(prefsUsernameKey, username);
    }
  }

  Future<void> clearTokens() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(prefsAccessTokenKey);
    await prefs.remove(prefsRefreshTokenKey);
  }

  Future<void> _setOrRemove(
    SharedPreferences prefs,
    String key,
    String? value,
  ) async {
    if (value != null && value.isNotEmpty) {
      await prefs.setString(key, value);
      return;
    }

    await prefs.remove(key);
  }
}
