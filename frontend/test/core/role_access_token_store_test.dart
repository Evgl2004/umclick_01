import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:umclick_frontend/core/role_access_token_store.dart';

void main() {
  const uuid = '123e4567-e89b-42d3-a456-426614174000';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('stores tokens in distinct role and trusted-origin scopes', () async {
    const store = RoleAccessTokenStore();
    await store.persist(
      role: RoleAccessKind.participant,
      sessionUuid: uuid,
      apiBaseUrl: 'https://one.example/api',
      token: 'participant-secret',
    );
    await store.persist(
      role: RoleAccessKind.display,
      sessionUuid: uuid,
      apiBaseUrl: 'https://two.example/api',
      token: 'display-secret',
      grantId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    );

    final participant = await store.restoreForSession(
      role: RoleAccessKind.participant,
      sessionUuid: uuid,
    );
    final display = await store.restoreForSession(
      role: RoleAccessKind.display,
      sessionUuid: uuid,
    );
    final keys = (await SharedPreferences.getInstance()).getKeys();

    expect(participant?.token, 'participant-secret');
    expect(participant?.apiBaseUrl, 'https://one.example/api');
    expect(display?.token, 'display-secret');
    expect(display?.apiBaseUrl, 'https://two.example/api');
    expect(display?.grantId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    expect(keys.every((key) => !key.contains('secret')), isTrue);
  });

  test('clears only the exact role, session and origin scope', () async {
    const store = RoleAccessTokenStore();
    await store.persist(
      role: RoleAccessKind.participant,
      sessionUuid: uuid,
      apiBaseUrl: 'https://one.example/api',
      token: 'participant-secret',
    );
    await store.persist(
      role: RoleAccessKind.display,
      sessionUuid: uuid,
      apiBaseUrl: 'https://two.example/api',
      token: 'display-secret',
      grantId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    );

    await store.clear(
      role: RoleAccessKind.participant,
      sessionUuid: uuid,
      apiBaseUrl: 'https://one.example/api',
    );

    expect(
      await store.restoreForSession(
        role: RoleAccessKind.participant,
        sessionUuid: uuid,
      ),
      isNull,
    );
    expect(
      (await store.restoreForSession(
        role: RoleAccessKind.display,
        sessionUuid: uuid,
      ))
          ?.token,
      'display-secret',
    );
  });

  test('ignores URL paths when deriving the trusted origin', () {
    expect(
      trustedApiOrigin('https://example.test/untrusted/path?x=1'),
      'https://example.test',
    );
    expect(
      trustedApiOrigin('/api', Uri.parse('https://app.example/join?api=bad')),
      'https://app.example',
    );
  });

  test('late clear of an old display grant cannot remove a newer grant',
      () async {
    const oldWindow = RoleAccessTokenStore();
    const newWindow = RoleAccessTokenStore();
    const oldGrant = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const newGrant = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

    await oldWindow.persist(
      role: RoleAccessKind.display,
      sessionUuid: uuid,
      apiBaseUrl: 'https://display.example/api',
      token: 'old-display-token',
      grantId: oldGrant,
    );
    final openedOld = await oldWindow.restoreForSession(
      role: RoleAccessKind.display,
      sessionUuid: uuid,
    );
    expect(openedOld?.grantId, oldGrant);

    await newWindow.persist(
      role: RoleAccessKind.display,
      sessionUuid: uuid,
      apiBaseUrl: 'https://display.example/api',
      token: 'new-display-token',
      grantId: newGrant,
    );
    await oldWindow.clear(
      role: RoleAccessKind.display,
      sessionUuid: uuid,
      apiBaseUrl: 'https://display.example/api',
      grantId: oldGrant,
    );
    await oldWindow.clear(
      role: RoleAccessKind.display,
      sessionUuid: uuid,
      apiBaseUrl: 'https://display.example/api',
      grantId: oldGrant,
    );

    final stillCurrent = await oldWindow.restoreForSession(
      role: RoleAccessKind.display,
      sessionUuid: uuid,
    );
    expect(stillCurrent?.grantId, newGrant);
    expect(stillCurrent?.token, 'new-display-token');

    await newWindow.clear(
      role: RoleAccessKind.display,
      sessionUuid: uuid,
      apiBaseUrl: 'https://display.example/api',
      grantId: newGrant,
    );
    expect(
      await oldWindow.restoreForSession(
        role: RoleAccessKind.display,
        sessionUuid: uuid,
      ),
      isNull,
    );
  });
}
