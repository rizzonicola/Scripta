import 'package:flutter/material.dart';

import '../../../core/l10n/app_localizations.dart';

/// Metadati mostrati in fondo alla lettura. Esistono tutti insieme o non
/// esistono: il chiamante costruisce il value object solo quando la nota li
/// ha davvero, così la vista non deve coordinare tre nullable indipendenti.
class ReadingMetadata {
  const ReadingMetadata({
    required this.wordCount,
    required this.readingTimeMinutes,
    required this.updatedAt,
  });

  final int wordCount;
  final int readingTimeMinutes;
  final DateTime updatedAt;

  @override
  bool operator ==(Object other) =>
      other is ReadingMetadata &&
      other.wordCount == wordCount &&
      other.readingTimeMinutes == readingTimeMinutes &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(wordCount, readingTimeMinutes, updatedAt);
}

/// Footer della vista di lettura: conteggio parole, tempo di lettura e data
/// dell'ultima modifica. È un elemento normale della lista (non un overlay),
/// quindi non copre il testo e scorre via con la nota.
class ReadingMetaFooter extends StatelessWidget {
  const ReadingMetaFooter({super.key, required this.metadata});

  final ReadingMetadata metadata;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final localizations = MaterialLocalizations.of(context);
    final date = localizations.formatMediumDate(metadata.updatedAt.toLocal());
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(
            color: theme.colorScheme.outline.withValues(alpha: 0.25),
            thickness: 1,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              Text(
                l10n.noteStats(metadata.wordCount, metadata.readingTimeMinutes),
                style: theme.textTheme.labelSmall?.copyWith(color: muted),
              ),
              Text(
                l10n.updatedOn(date),
                style: theme.textTheme.labelSmall?.copyWith(color: muted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
