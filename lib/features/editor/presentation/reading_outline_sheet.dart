import 'package:flutter/material.dart';

import '../../../core/l10n/app_localizations.dart';

/// Voce dell'indice della vista di lettura.
class ReadingOutlineEntry {
  const ReadingOutlineEntry({
    required this.title,
    required this.level,
    required this.documentId,
  });

  final String title;
  final int level;

  /// Identificativo stabile del blocco: la vista lo risolve nella posizione
  /// corrente della lista, che può cambiare tra una build e l'altra.
  final String documentId;
}

/// Foglio dell'indice: elenco dei titoli con rientro proporzionale al livello
/// Markdown. Toccando una voce il foglio restituisce la voce scelta alla
/// route chiamante, che si occupa dello scroll.
class ReadingOutlineSheet extends StatelessWidget {
  const ReadingOutlineSheet({super.key, required this.entries});

  final List<ReadingOutlineEntry> entries;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                l10n.readingOutline,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.only(
                      left: 20.0 + (entry.level - 1).clamp(0, 5) * 14,
                      right: 20,
                    ),
                    title: Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    onTap: () => Navigator.of(context).pop(entry),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
