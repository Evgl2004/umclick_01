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
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.96),
        borderRadius: 28,
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
      padding: const EdgeInsets.all(14),
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.96),
      borderRadius: 30,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
          final intro = const _TeacherAuthIntroPanel();
          final form = _TeacherAuthForm(
            usernameController: usernameController,
            passwordController: passwordController,
            emailController: emailController,
            signupCodeController: signupCodeController,
            loading: loading,
            restoringSession: restoringSession,
            onRegister: onRegister,
            onLogin: onLogin,
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                intro,
                const SizedBox(height: 14),
                form,
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Expanded(flex: 4, child: _TeacherAuthIntroPanel()),
              const SizedBox(width: 16),
              Expanded(flex: 5, child: form),
            ],
          );
        },
      ),
    );
  }
}

class _TeacherAuthIntroPanel extends StatelessWidget {
  const _TeacherAuthIntroPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF073B3A), Color(0xFF0A9396), Color(0xFFFFB703)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppStatusChip(
            icon: Icons.login_rounded,
            label: appText(AppText.teacherFlowAuthTitle),
            background: Colors.white.withValues(alpha: 0.18),
            foreground: Colors.white,
          ),
          const SizedBox(height: 20),
          Text(
            appText(AppText.teacherAuthTitle),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  height: 1.05,
                ),
          ),
          const SizedBox(height: 10),
          Text(
            appText(AppText.teacherFlowAuthBody),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 15,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _TeacherAuthForm extends StatelessWidget {
  const _TeacherAuthForm({
    required this.usernameController,
    required this.passwordController,
    required this.emailController,
    required this.signupCodeController,
    required this.loading,
    required this.restoringSession,
    required this.onRegister,
    required this.onLogin,
  });

  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final TextEditingController emailController;
  final TextEditingController signupCodeController;
  final bool loading;
  final bool restoringSession;
  final VoidCallback onRegister;
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.lock_open_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  appText(AppText.notAuthenticated),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: usernameController,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.person_outline_rounded),
              labelText: appText(AppText.usernameLabel),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: passwordController,
            obscureText: true,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.password_rounded),
              labelText: appText(AppText.passwordLabel),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: emailController,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.alternate_email_rounded),
              labelText: appText(AppText.emailOptionalLabel),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: signupCodeController,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.key_rounded),
              labelText: appText(AppText.signupCodeOptionalLabel),
              helperText: appText(AppText.signupCodeHelper),
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: loading ? null : onRegister,
                icon: const Icon(Icons.person_add_alt_1_rounded),
                label: Text(appText(AppText.registerButton)),
              ),
              FilledButton.tonalIcon(
                onPressed: loading ? null : onLogin,
                icon: const Icon(Icons.login_rounded),
                label: Text(appText(AppText.loginButton)),
              ),
            ],
          ),
          if (restoringSession) ...[
            const SizedBox(height: 10),
            Text(appText(AppText.restoringTeacherSession)),
          ],
        ],
      ),
    );
  }
}
