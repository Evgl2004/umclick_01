import 'package:flutter/material.dart';

import '../../../l10n/app_strings.dart';
import '../../../shared/widgets/app_surfaces.dart';

class ParticipantProfileCard extends StatelessWidget {
  const ParticipantProfileCard({
    super.key,
    required this.nameController,
    required this.phoneController,
    required this.consent,
    required this.consentLabel,
    required this.loading,
    required this.loadingLegalDocuments,
    required this.error,
    required this.onConsentChanged,
    required this.onOpenLegalDocuments,
    required this.onRefreshLegalDocuments,
    required this.onJoin,
  });

  final TextEditingController nameController;
  final TextEditingController phoneController;
  final bool consent;
  final String consentLabel;
  final bool loading;
  final bool loadingLegalDocuments;
  final String? error;
  final ValueChanged<bool> onConsentChanged;
  final VoidCallback onOpenLegalDocuments;
  final VoidCallback onRefreshLegalDocuments;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.94),
      borderRadius: 28,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appText(AppText.participantProfileCardTitle),
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 14),
          TextField(
            controller: nameController,
            decoration: InputDecoration(
              labelText: appText(AppText.participantNameLabel),
              prefixIcon: const Icon(Icons.badge_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: phoneController,
            decoration: InputDecoration(
              labelText: appText(AppText.participantPhoneLabel),
              helperText: appText(AppText.participantPhoneHelper),
              prefixIcon: const Icon(Icons.phone_outlined),
            ),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            value: consent,
            onChanged: (value) => onConsentChanged(value ?? false),
            title: Text(consentLabel),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: (loading || loadingLegalDocuments)
                    ? null
                    : onOpenLegalDocuments,
                icon: const Icon(Icons.policy_outlined),
                label: Text(appText(AppText.legalDocumentsButton)),
              ),
              OutlinedButton.icon(
                onPressed: (loading || loadingLegalDocuments)
                    ? null
                    : onRefreshLegalDocuments,
                icon: const Icon(Icons.refresh),
                label: Text(appText(AppText.refreshLegalDocsButton)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: loading ? null : onJoin,
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(appText(AppText.joinSessionButton)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
                textStyle: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
