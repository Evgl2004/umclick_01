import 'package:flutter/material.dart';

import '../../../l10n/app_strings.dart';
import '../../../shared/widgets/app_surfaces.dart';

class TeacherSessionSetupCard extends StatelessWidget {
  const TeacherSessionSetupCard({
    super.key,
    required this.loading,
    required this.isLoggedIn,
    required this.selectedQuizId,
    required this.onCreateSession,
  });

  final bool loading;
  final bool isLoggedIn;
  final int? selectedQuizId;
  final VoidCallback onCreateSession;

  @override
  Widget build(BuildContext context) {
    final canCreateSession = !loading && isLoggedIn && selectedQuizId != null;

    return AppSectionCard(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          final details = _SessionSetupDetails(selectedQuizId: selectedQuizId);
          final button = FilledButton.icon(
            onPressed: canCreateSession ? onCreateSession : null,
            icon: const Icon(Icons.playlist_add_check_circle_outlined),
            label: Text(appText(AppText.createSessionButton)),
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                details,
                const SizedBox(height: 14),
                button,
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: details),
              const SizedBox(width: 12),
              button,
            ],
          );
        },
      ),
    );
  }
}

class _SessionSetupDetails extends StatelessWidget {
  const _SessionSetupDetails({required this.selectedQuizId});

  final int? selectedQuizId;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: const Color(0xFFE0F7FA),
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(
            Icons.cast_for_education_outlined,
            color: Color(0xFF005F73),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                appText(AppText.teacherSessionSetupTitle),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(appText(AppText.teacherSessionSetupSubtitle)),
              const SizedBox(height: 8),
              Text(
                selectedQuizId == null
                    ? appText(AppText.selectQuizForSession)
                    : appText(AppText.sessionQuiz,
                        args: {'id': selectedQuizId}),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
