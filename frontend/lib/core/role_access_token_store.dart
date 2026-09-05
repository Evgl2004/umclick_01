import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';
import 'session_uuid.dart';

enum RoleAccessKind {
  participant('participant'),
  display('display');

  const RoleAccessKind(this.storageName);

  final String storageName;
}

class StoredRoleAccess {
  const StoredRoleAccess({
    required this.token,
    required this.apiBaseUrl,
    this.grantId,
  });

  final String token;
  final String apiBaseUrl;
  final String? grantId;
}

class RoleAccessTokenStore {
  const RoleAccessTokenStore();

  static const _prefix = 'umclick_role_access_v1';

  Future<void> persist({
    required RoleAccessKind role,
    required String sessionUuid,
    required String apiBaseUrl,
    required String token,
    String? grantId,
  }) async {
    final uuid = normalizeSessionUuid(sessionUuid);
    final origin = trustedApiOrigin(apiBaseUrl);
    final normalizedGrantId =
        role == RoleAccessKind.display ? _normalizeGrantId(grantId) : null;
    if (token.isEmpty) {
      throw const FormatException('Пустой ролевой токен нельзя сохранить.');
    }

    final prefs = await SharedPreferences.getInstance();
    final tokenKey = _tokenKey(
      role,
      uuid,
      origin,
      grantId: normalizedGrantId,
    );
    final tokenSaved = await prefs.setString(
      tokenKey,
      token,
    );
    if (!tokenSaved) {
      throw StateError('Не удалось сохранить ролевой токен локально.');
    }

    final locatorSaved = await prefs.setString(
      _locatorKey(role, uuid),
      role == RoleAccessKind.display
          ? jsonEncode({'origin': origin, 'grant_id': normalizedGrantId})
          : origin,
    );
    if (!locatorSaved) {
      await prefs.remove(tokenKey);
      throw StateError('Не удалось сохранить область ролевого токена.');
    }
  }

  Future<StoredRoleAccess?> restoreForSession({
    required RoleAccessKind role,
    required String sessionUuid,
  }) async {
    final uuid = normalizeSessionUuid(sessionUuid);
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final locator = prefs.getString(_locatorKey(role, uuid));
    if (locator == null || locator.isEmpty) return null;

    String origin;
    String? grantId;
    if (role == RoleAccessKind.display) {
      try {
        final decoded = jsonDecode(locator);
        if (decoded is! Map<String, dynamic>) return null;
        origin = decoded['origin']?.toString() ?? '';
        grantId = _normalizeGrantId(decoded['grant_id']?.toString());
      } on FormatException {
        return null;
      }
    } else {
      origin = locator;
    }
    if (origin.isEmpty) return null;
    final token = prefs.getString(
      _tokenKey(role, uuid, origin, grantId: grantId),
    );
    if (token == null || token.isEmpty) return null;
    return StoredRoleAccess(
      token: token,
      apiBaseUrl: '$origin/api',
      grantId: grantId,
    );
  }

  Future<void> clear({
    required RoleAccessKind role,
    required String sessionUuid,
    required String apiBaseUrl,
    String? grantId,
  }) async {
    final uuid = normalizeSessionUuid(sessionUuid);
    final origin = trustedApiOrigin(apiBaseUrl);
    final normalizedGrantId =
        role == RoleAccessKind.display ? _normalizeGrantId(grantId) : null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await prefs.remove(
      _tokenKey(role, uuid, origin, grantId: normalizedGrantId),
    );
    if (role != RoleAccessKind.display &&
        prefs.getString(_locatorKey(role, uuid)) == origin) {
      await prefs.remove(_locatorKey(role, uuid));
    }
  }

  String _tokenKey(
    RoleAccessKind role,
    String uuid,
    String origin, {
    String? grantId,
  }) {
    final encodedOrigin = base64Url.encode(utf8.encode(origin));
    final grantScope = grantId == null ? '' : '.$grantId';
    return '$_prefix.token.${role.storageName}.$uuid.$encodedOrigin$grantScope';
  }

  String _locatorKey(RoleAccessKind role, String uuid) {
    return '$_prefix.origin.${role.storageName}.$uuid';
  }

  String _normalizeGrantId(String? value) {
    if (value == null) {
      throw const FormatException('Не указан UUID выдачи доступа к показу.');
    }
    try {
      return normalizeSessionUuid(value);
    } on FormatException {
      throw const FormatException('Некорректный UUID выдачи доступа к показу.');
    }
  }
}

String trustedApiOrigin(String apiBaseUrl, [Uri? currentUri]) {
  final raw = apiBaseUrl.trim();
  final parsed = Uri.tryParse(raw);
  if (parsed != null &&
      (parsed.scheme == 'http' || parsed.scheme == 'https') &&
      parsed.host.isNotEmpty &&
      parsed.userInfo.isEmpty) {
    return parsed.origin;
  }

  if (raw.startsWith('/')) {
    final browserUri = currentUri ?? Uri.base;
    if ((browserUri.scheme == 'http' || browserUri.scheme == 'https') &&
        browserUri.host.isNotEmpty &&
        browserUri.userInfo.isEmpty) {
      return browserUri.origin;
    }
    return Uri.parse(localDevApiBaseUrl).origin;
  }

  throw const FormatException('Некорректный доверенный адрес API.');
}
