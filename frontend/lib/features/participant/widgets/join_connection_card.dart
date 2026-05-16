import 'package:flutter/material.dart';

import '../../../core/value_utils.dart';
import '../../../l10n/app_strings.dart';
import '../../../shared/widgets/app_surfaces.dart';

class ParticipantJoinConnectionCard extends StatelessWidget {
  const ParticipantJoinConnectionCard({
    super.key,
    required this.apiController,
    required this.pinController,
    required this.useJoinTokenFromLink,
    required this.joinTokenFromLink,
    required this.loading,
    required this.loadingJoinPreview,
    required this.joinPreview,
    required this.onLoadJoinPreview,
    required this.onUsePinInstead,
    required this.onUseJoinToken,
  });

  final TextEditingController apiController;
  final TextEditingController pinController;
  final bool useJoinTokenFromLink;
  final String? joinTokenFromLink;
  final bool loading;
  final bool loadingJoinPreview;
  final Map<String, dynamic>? joinPreview;
  final VoidCallback onLoadJoinPreview;
  final VoidCallback onUsePinInstead;
  final VoidCallback onUseJoinToken;

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.94),
      borderRadius: 28,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appText(AppText.participantJoinCardTitle),
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 14),
          TextField(
            controller: apiController,
            decoration: InputDecoration(
              labelText: appText(AppText.apiBaseUrlLabel),
              helperText: appText(AppText.participantApiBaseUrlHelper),
            ),
          ),
          const SizedBox(height: 14),
          if (useJoinTokenFromLink && joinTokenFromLink != null)
            _JoinTokenNotice(
              joinToken: joinTokenFromLink!,
              loading: loading,
              loadingJoinPreview: loadingJoinPreview,
              onLoadJoinPreview: onLoadJoinPreview,
              onUsePinInstead: onUsePinInstead,
            )
          else
            _PinJoinForm(
              pinController: pinController,
              joinTokenFromLink: joinTokenFromLink,
              loading: loading,
              loadingJoinPreview: loadingJoinPreview,
              onLoadJoinPreview: onLoadJoinPreview,
              onUseJoinToken: onUseJoinToken,
            ),
          if (loadingJoinPreview || joinPreview != null) ...[
            const SizedBox(height: 14),
            _JoinPreviewCard(
              loadingJoinPreview: loadingJoinPreview,
              preview: joinPreview,
            ),
          ],
        ],
      ),
    );
  }
}

class _JoinTokenNotice extends StatelessWidget {
  const _JoinTokenNotice({
    required this.joinToken,
    required this.loading,
    required this.loadingJoinPreview,
    required this.onLoadJoinPreview,
    required this.onUsePinInstead,
  });

  final String joinToken;
  final bool loading;
  final bool loadingJoinPreview;
  final VoidCallback onLoadJoinPreview;
  final VoidCallback onUsePinInstead;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFE0F7FA),
        borderRadius: BorderRadius.circular(20),
        border:
            Border.all(color: const Color(0xFF0A9396).withValues(alpha: 0.32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.link, color: Color(0xFF005F73)),
              const SizedBox(width: 8),
              Expanded(child: Text(appText(AppText.joinLinkDetected))),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
              appText(AppText.joinTokenLabel, args: {'token': joinToken})),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed:
                    (loading || loadingJoinPreview) ? null : onLoadJoinPreview,
                icon: const Icon(Icons.refresh),
                label: Text(appText(AppText.refreshPreviewButton)),
              ),
              OutlinedButton.icon(
                onPressed: loading ? null : onUsePinInstead,
                icon: const Icon(Icons.pin_outlined),
                label: Text(appText(AppText.usePinInsteadButton)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PinJoinForm extends StatelessWidget {
  const _PinJoinForm({
    required this.pinController,
    required this.joinTokenFromLink,
    required this.loading,
    required this.loadingJoinPreview,
    required this.onLoadJoinPreview,
    required this.onUseJoinToken,
  });

  final TextEditingController pinController;
  final String? joinTokenFromLink;
  final bool loading;
  final bool loadingJoinPreview;
  final VoidCallback onLoadJoinPreview;
  final VoidCallback onUseJoinToken;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: pinController,
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w900),
          decoration: InputDecoration(
            labelText: appText(AppText.sessionPinLabel),
            helperText: appText(AppText.sessionPinHelper),
            prefixIcon: const Icon(Icons.pin_outlined),
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.tonalIcon(
                onPressed:
                    (loading || loadingJoinPreview) ? null : onLoadJoinPreview,
                icon: const Icon(Icons.visibility_outlined),
                label: Text(appText(AppText.previewSessionButton)),
              ),
              if (joinTokenFromLink != null)
                TextButton.icon(
                  onPressed: loading ? null : onUseJoinToken,
                  icon: const Icon(Icons.link),
                  label: Text(appText(AppText.useJoinTokenButton)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _JoinPreviewCard extends StatelessWidget {
  const _JoinPreviewCard({
    required this.loadingJoinPreview,
    required this.preview,
  });

  final bool loadingJoinPreview;
  final Map<String, dynamic>? preview;

  @override
  Widget build(BuildContext context) {
    final preview = this.preview;
    if (loadingJoinPreview && preview == null) {
      return const LinearProgressIndicator();
    }
    if (preview == null) {
      return const SizedBox.shrink();
    }

    final quiz = mapOrNull(preview['quiz']) ?? <String, dynamic>{};
    final title =
        quiz['title']?.toString() ?? appText(AppText.untitledQuizLong);
    final description = quiz['description']?.toString() ?? '';
    final statusLabel = preview['session_status']?.toString() ?? 'unknown';
    final participantsCount = asInt(preview['participants_count']);
    final canJoin = preview['can_join'] != false;
    final closedReason = preview['closed_reason']?.toString() ?? '';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: canJoin
            ? const Color(0xFFFFF4D6)
            : Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: canJoin
              ? const Color(0xFFFFB703).withValues(alpha: 0.42)
              : Theme.of(context).colorScheme.error,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(canJoin ? Icons.fact_check_outlined : Icons.lock_outline),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(description),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AppStatusChip(
                icon: Icons.flag_outlined,
                label:
                    appText(AppText.statusValue, args: {'status': statusLabel}),
                background: Colors.white.withValues(alpha: 0.66),
                foreground: const Color(0xFF023047),
              ),
              AppStatusChip(
                icon: Icons.group_outlined,
                label: appText(AppText.participantsCount,
                    args: {'count': participantsCount}),
                background: Colors.white.withValues(alpha: 0.66),
                foreground: const Color(0xFF023047),
              ),
            ],
          ),
          if (!canJoin && closedReason.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(closedReason,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (loadingJoinPreview) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }
}
