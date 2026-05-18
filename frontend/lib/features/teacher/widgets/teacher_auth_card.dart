import 'package:flutter/material.dart';

import '../../../l10n/app_strings.dart';
import '../../../shared/widgets/app_surfaces.dart';

class TeacherAuthCard extends StatelessWidget {
  const TeacherAuthCard({
    super.key,
    required this.usernameController,
    required this.passwordController,
    required this.emailController,
    required this.signupCodeController,
    required this.loading,
    required this.restoringSession,
    required this.isLoggedIn,
    required this.hasRefreshToken,
    required this.teacher,
    required this.onRegister,
    required this.onLogin,
    required this.onLoadProfile,
    required this.onLogout,
  });

  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final TextEditingController emailController;
  final TextEditingController signupCodeController;
  final bool loading;
  final bool restoringSession;
  final bool isLoggedIn;
  final bool hasRefreshToken;
  final Map<String, dynamic>? teacher;
  final VoidCallback onRegister;
  final VoidCallback onLogin;
  final VoidCallback onLoadProfile;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    if (isLoggedIn) {
      return AppSectionCard(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 620;
            final summary = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  appText(AppText.teacherAuthTitle),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  appText(
                    AppText.loggedInTeacher,
                    args: {
                      'suffix':
                          teacher != null ? ': ${teacher!['username']}' : '',
                    },
                  ),
                ),
                if (hasRefreshToken) Text(appText(AppText.refreshTokenStored)),
              ],
            );
            final actions = Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton(
                  onPressed: loading ? null : onLoadProfile,
                  child: Text(appText(AppText.teacherProfileButton)),
                ),
                OutlinedButton(
                  onPressed: loading ? null : onLogout,
                  child: Text(appText(AppText.logoutButton)),
                ),
              ],
            );

            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  summary,
                  const SizedBox(height: 14),
                  actions,
                ],
              );
            }

            return Row(
              children: [
                Expanded(child: summary),
                const SizedBox(width: 16),
                actions,
              ],
            );
          },
        ),
      );
    }

    return AppSectionCard(
      child: Padding(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              appText(AppText.teacherAuthTitle),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: usernameController,
              decoration: InputDecoration(
                labelText: appText(AppText.usernameLabel),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: appText(AppText.passwordLabel),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: emailController,
              decoration: InputDecoration(
                labelText: appText(AppText.emailOptionalLabel),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: signupCodeController,
              decoration: InputDecoration(
                labelText: appText(AppText.signupCodeOptionalLabel),
                helperText: appText(AppText.signupCodeHelper),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton(
                  onPressed: loading ? null : onRegister,
                  child: Text(appText(AppText.registerButton)),
                ),
                FilledButton.tonal(
                  onPressed: loading ? null : onLogin,
                  child: Text(appText(AppText.loginButton)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (restoringSession)
              Text(appText(AppText.restoringTeacherSession)),
            Text(
              appText(AppText.notAuthenticated),
            ),
          ],
        ),
      ),
    );
  }
}
