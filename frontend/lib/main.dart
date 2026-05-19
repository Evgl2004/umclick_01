import 'package:flutter/material.dart';

import 'core/app_config.dart';
import 'features/display/display_session_page.dart';
import 'features/legal/legal_documents.dart';
import 'features/participant/participant_panel.dart';
import 'features/teacher/teacher_panel.dart';
import 'l10n/app_language.dart';
import 'l10n/app_strings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await appLanguage.load();
  runApp(const UmclickApp());
}

enum UmclickEntryPoint {
  home,
  display,
  legalPrivacy,
  legalConsent,
}

String _normalizePath(String path) {
  if (path.isEmpty) return '/';
  final trimmed = path.replaceAll(RegExp(r'/+$'), '');
  return trimmed.isEmpty ? '/' : trimmed;
}

UmclickEntryPoint resolveEntryPoint(Uri uri) {
  final normalizedPath = _normalizePath(uri.path.toLowerCase());
  switch (normalizedPath) {
    case '/display':
      return UmclickEntryPoint.display;
    case '/legal/privacy':
      return UmclickEntryPoint.legalPrivacy;
    case '/legal/consent':
      return UmclickEntryPoint.legalConsent;
    default:
      return UmclickEntryPoint.home;
  }
}

int resolveInitialHomeTab(Uri uri) {
  final normalizedPath = _normalizePath(uri.path.toLowerCase());
  if (normalizedPath == '/join') {
    return 1;
  }
  return 0;
}

String resolvePublicLegalApiBase(Uri uri) {
  final apiFromQuery = uri.queryParameters['api']?.trim() ?? '';
  if (apiFromQuery.isNotEmpty) {
    return apiFromQuery;
  }
  return defaultApiBaseUrl;
}

class UmclickApp extends StatelessWidget {
  const UmclickApp({super.key});

  Widget _buildHomeForEntryPoint() {
    final uri = Uri.base;
    final entryPoint = resolveEntryPoint(uri);
    final publicApiBase = resolvePublicLegalApiBase(uri);

    switch (entryPoint) {
      case UmclickEntryPoint.legalPrivacy:
        return PublicLegalDocumentPage(
          documentType: PublicLegalDocumentType.privacyPolicy,
          apiBaseUrl: publicApiBase,
          appHomeBuilder: (_) => const HomePage(),
        );
      case UmclickEntryPoint.legalConsent:
        return PublicLegalDocumentPage(
          documentType: PublicLegalDocumentType.personalDataConsent,
          apiBaseUrl: publicApiBase,
          appHomeBuilder: (_) => const HomePage(),
        );
      case UmclickEntryPoint.display:
        return const DisplaySessionPage();
      case UmclickEntryPoint.home:
        return HomePage(initialIndex: resolveInitialHomeTab(uri));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UiLanguage>(
      valueListenable: appLanguage,
      builder: (context, _, __) {
        return MaterialApp(
          title: 'umclick',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme:
                ColorScheme.fromSeed(seedColor: const Color(0xFF0E7C7B)),
            useMaterial3: true,
            tooltipTheme: const TooltipThemeData(
                waitDuration: Duration(milliseconds: 350)),
          ),
          home: _buildHomeForEntryPoint(),
        );
      },
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, 1).toInt();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [const TeacherPanel(), const ParticipantPanel()];

    return Scaffold(
      appBar: AppBar(
        title: const _AppTitleWithBuildLabel(),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: LanguageSwitcher()),
          ),
        ],
      ),
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.school),
            label: appText(AppText.teacherTab),
          ),
          NavigationDestination(
            icon: const Icon(Icons.group),
            label: appText(AppText.participantTab),
          ),
        ],
        onDestinationSelected: (value) {
          setState(() {
            _index = value;
          });
        },
      ),
    );
  }
}

class _AppTitleWithBuildLabel extends StatelessWidget {
  const _AppTitleWithBuildLabel();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      children: [
        Text(appText(AppText.appTitle)),
        Tooltip(
          message: 'Build: $buildLabel',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              buildLabel,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ),
        ),
      ],
    );
  }
}
