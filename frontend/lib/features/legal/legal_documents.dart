import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../core/app_config.dart';
import '../../core/value_utils.dart';
import '../../l10n/app_strings.dart';

enum PublicLegalDocumentType {
  privacyPolicy,
  personalDataConsent,
}

class LegalDocumentsPage extends StatelessWidget {
  const LegalDocumentsPage({
    super.key,
    required this.documents,
    required this.apiBaseUrl,
  });

  final Map<String, dynamic> documents;
  final String apiBaseUrl;

  String _version(String key) {
    final section = mapOrNull(documents[key]);
    final version = section?['version']?.toString() ?? '';
    return version.isEmpty ? 'n/a' : version;
  }

  String _url(String key) {
    final section = mapOrNull(documents[key]);
    return section?['url']?.toString() ?? '-';
  }

  @override
  Widget build(BuildContext context) {
    final privacyVersion = _version('privacy_policy');
    final consentVersion = _version('personal_data_consent');
    final contactEmail = documents['contact_email']?.toString() ?? '-';

    return Scaffold(
      appBar: AppBar(title: Text(appText(AppText.privacyConsentTitle))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(appText(AppText.currentLegalVersionsTitle), style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(appText(AppText.privacyVersionLabel, args: {'version': privacyVersion})),
                  SelectableText(appText(AppText.privacyUrlLabel, args: {'url': _url('privacy_policy')})),
                  const SizedBox(height: 6),
                  Text(appText(AppText.personalDataConsentVersionLabel, args: {'version': consentVersion})),
                  SelectableText(appText(AppText.personalDataConsentUrlLabel, args: {'url': _url('personal_data_consent')})),
                  const SizedBox(height: 6),
                  SelectableText(appText(AppText.legalContactLabel, args: {'email': contactEmail})),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                appText(AppText.legalConsentNotice),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => PublicLegalDocumentPage(
                        documentType: PublicLegalDocumentType.privacyPolicy,
                        initialDocuments: documents,
                        apiBaseUrl: apiBaseUrl,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.policy_outlined),
                label: Text(appText(AppText.openPrivacyPolicyButton)),
              ),
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => PublicLegalDocumentPage(
                        documentType: PublicLegalDocumentType.personalDataConsent,
                        initialDocuments: documents,
                        apiBaseUrl: apiBaseUrl,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.gpp_maybe_outlined),
                label: Text(appText(AppText.openConsentButton)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class PublicLegalDocumentPage extends StatefulWidget {
  const PublicLegalDocumentPage({
    super.key,
    required this.documentType,
    this.initialDocuments,
    this.apiBaseUrl = defaultApiBaseUrl,
    this.appHomeBuilder,
  });

  final PublicLegalDocumentType documentType;
  final Map<String, dynamic>? initialDocuments;
  final String apiBaseUrl;
  final WidgetBuilder? appHomeBuilder;

  @override
  State<PublicLegalDocumentPage> createState() => _PublicLegalDocumentPageState();
}

class _PublicLegalDocumentPageState extends State<PublicLegalDocumentPage> {
  Map<String, dynamic>? _documents;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _documents = widget.initialDocuments;
    if (_documents == null) {
      _loadLegalDocuments();
    }
  }

  String get _documentKey {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return 'privacy_policy';
    }
    return 'personal_data_consent';
  }

  String get _fallbackVersion {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return defaultPrivacyPolicyVersion;
    }
    return defaultPersonalDataConsentVersion;
  }

  String get _title {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return appText(AppText.privacyPolicyTitle);
    }
    return appText(AppText.personalDataConsentTitle);
  }

  String get _shortDescription {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return appText(AppText.privacyPolicyDescription);
    }
    return appText(AppText.personalDataConsentDescription);
  }

  String get _fallbackPublicUrl {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return '/legal/privacy';
    }
    return '/legal/consent';
  }

  String get _version {
    final section = mapOrNull(_documents?[_documentKey]);
    final version = section?['version']?.toString().trim() ?? '';
    return version.isEmpty ? _fallbackVersion : version;
  }

  String get _documentUrl {
    final section = mapOrNull(_documents?[_documentKey]);
    final url = section?['url']?.toString().trim() ?? '';
    return url.isEmpty ? _fallbackPublicUrl : url;
  }

  String get _contactEmail {
    final email = _documents?['contact_email']?.toString().trim() ?? '';
    return email.isEmpty ? 'privacy@umclick.local' : email;
  }

  List<MapEntry<String, String>> get _sections {
    if (widget.documentType == PublicLegalDocumentType.privacyPolicy) {
      return [
        MapEntry(appText(AppText.privacyDataCollectedTitle), appText(AppText.privacyDataCollectedBody)),
        MapEntry(appText(AppText.privacyPurposeTitle), appText(AppText.privacyPurposeBody)),
        MapEntry(appText(AppText.privacyLegalBasisTitle), appText(AppText.privacyLegalBasisBody)),
        MapEntry(appText(AppText.privacyRetentionTitle), appText(AppText.privacyRetentionBody)),
        MapEntry(appText(AppText.privacySharingTitle), appText(AppText.privacySharingBody)),
        MapEntry(appText(AppText.privacyRightsTitle), appText(AppText.privacyRightsBody)),
      ];
    }

    return [
      MapEntry(appText(AppText.consentScopeTitle), appText(AppText.consentScopeBody)),
      MapEntry(appText(AppText.consentActionsTitle), appText(AppText.consentActionsBody)),
      MapEntry(appText(AppText.consentPurposeTitle), appText(AppText.consentPurposeBody)),
      MapEntry(appText(AppText.consentPeriodTitle), appText(AppText.consentPeriodBody)),
      MapEntry(appText(AppText.consentWithdrawalTitle), appText(AppText.consentWithdrawalBody)),
      MapEntry(appText(AppText.consentConfirmationTitle), appText(AppText.consentConfirmationBody)),
    ];
  }

  Future<void> _loadLegalDocuments() async {
    if (_loading) {
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final docs = await ApiClient(widget.apiBaseUrl).getCurrentLegalDocuments();
      if (!mounted) return;
      setState(() {
        _documents = docs;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          TextButton.icon(
            onPressed: () {
              final appHomeBuilder = widget.appHomeBuilder;
              if (appHomeBuilder == null) {
                Navigator.of(context).popUntil((route) => route.isFirst);
                return;
              }

              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: appHomeBuilder),
                (route) => false,
              );
            },
            icon: const Icon(Icons.home_outlined),
            label: Text(appText(AppText.openAppButton)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_loading) const SizedBox(height: 12),
          if (_error != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(appText(AppText.legalMetadataRefreshError, args: {'error': _error})),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _loadLegalDocuments,
                      icon: const Icon(Icons.refresh),
                      label: Text(appText(AppText.retryButton)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_shortDescription, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(appText(AppText.publicLegalVersionLabel, args: {'version': _version})),
                  SelectableText(appText(AppText.publicLegalUrlLabel, args: {'url': _documentUrl})),
                  SelectableText(appText(AppText.publicLegalContactLabel, args: {'email': _contactEmail})),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          ..._sections.map((section) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(section.key, style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 6),
                      Text(section.value),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
