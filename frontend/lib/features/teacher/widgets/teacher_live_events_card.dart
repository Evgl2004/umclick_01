import 'package:flutter/material.dart';

import '../../../l10n/app_strings.dart';
import '../../../shared/widgets/app_surfaces.dart';

class TeacherLiveEventsCard extends StatelessWidget {
  const TeacherLiveEventsCard({
    super.key,
    required this.events,
  });

  final List<String> events;

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            appText(AppText.liveEventsTitle),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (events.isEmpty)
            Text(appText(AppText.noEventsYet))
          else
            ...events.map((event) => Text(event)),
        ],
      ),
    );
  }
}
