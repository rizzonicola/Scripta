import 'package:flutter/widgets.dart';

/// Stringhe (it/en/fr) delle funzioni desktop: menu contestuali e
/// scorciatoie. Tenute qui, e non negli .arb, per non richiedere la
/// rigenerazione di `flutter gen-l10n`; le voci già presenti in
/// [AppLocalizations] (nuova nota, elimina, ordina...) vengono riusate
/// direttamente dai chiamanti.
class DesktopStrings {
  final String _lang;
  const DesktopStrings._(this._lang);

  factory DesktopStrings.of(BuildContext context) {
    final code = Localizations.localeOf(context).languageCode;
    return DesktopStrings._(_table.containsKey(code) ? code : 'en');
  }

  String _t(String key) => _table[_lang]![key] ?? _table['en']![key] ?? key;

  String get pin => _t('pin');
  String get unpin => _t('unpin');
  String get moveTo => _t('moveTo');
  String get duplicate => _t('duplicate');
  String get exportMarkdown => _t('exportMarkdown');
  String get copySuffix => _t('copySuffix');
  String get moveFolder => _t('moveFolder');
  String get exportFolderZip => _t('exportFolderZip');
  String get exportAllZip => _t('exportAllZip');
  String get importNotes => _t('importNotes');
  String get newNoteHere => _t('newNoteHere');
  String get expand => _t('expand');
  String get collapse => _t('collapse');
  String get keyboardShortcuts => _t('keyboardShortcuts');
  String get close => _t('close');
  String get groupNotes => _t('groupNotes');
  String get groupNavigation => _t('groupNavigation');
  String get groupEditor => _t('groupEditor');
  String get groupApp => _t('groupApp');

  String command(String id) => _t('cmd.$id');

  static const Map<String, Map<String, String>> _table = {
    'it': {
      'pin': 'Fissa in alto',
      'unpin': 'Rimuovi dai fissati',
      'moveTo': 'Sposta in cartella...',
      'duplicate': 'Duplica',
      'exportMarkdown': 'Esporta come Markdown (.md)',
      'copySuffix': ' (copia)',
      'moveFolder': 'Sposta cartella...',
      'exportFolderZip': 'Esporta cartella come ZIP',
      'exportAllZip': 'Esporta tutte le note (ZIP)',
      'importNotes': 'Importa...',
      'newNoteHere': 'Nuova nota qui',
      'expand': 'Espandi',
      'collapse': 'Comprimi',
      'keyboardShortcuts': 'Scorciatoie da tastiera',
      'close': 'Chiudi',
      'groupNotes': 'Note e cartelle',
      'groupNavigation': 'Navigazione e ricerca',
      'groupEditor': 'Editor',
      'groupApp': 'Applicazione',
      'cmd.newNote': 'Nuova nota',
      'cmd.newFolder': 'Nuova cartella',
      'cmd.save': 'Salva e sincronizza',
      'cmd.findInNote': 'Cerca nella nota',
      'cmd.searchNotes': 'Cerca tra le note',
      'cmd.toggleMode': 'Alterna Modifica / Sola lettura',
      'cmd.focusMode': 'Modalità focus',
      'cmd.escape': 'Esci da focus / chiudi ricerca',
      'cmd.pinNote': 'Fissa / rimuovi nota fissata',
      'cmd.moveNote': 'Sposta nota in cartella',
      'cmd.exportNote': 'Esporta nota (.md)',
      'cmd.duplicateNote': 'Duplica nota',
      'cmd.deleteNote': 'Elimina nota',
      'cmd.nextNote': 'Nota successiva',
      'cmd.previousNote': 'Nota precedente',
      'cmd.settings': 'Impostazioni',
      'cmd.help': 'Mostra le scorciatoie',
      'cmd.bold': 'Grassetto',
      'cmd.italic': 'Corsivo',
      'cmd.link': 'Inserisci link',
      'cmd.heading1': 'Titolo 1',
      'cmd.heading2': 'Titolo 2',
      'cmd.heading3': 'Titolo 3',
    },
    'en': {
      'pin': 'Pin to top',
      'unpin': 'Unpin',
      'moveTo': 'Move to folder...',
      'duplicate': 'Duplicate',
      'exportMarkdown': 'Export as Markdown (.md)',
      'copySuffix': ' (copy)',
      'moveFolder': 'Move folder...',
      'exportFolderZip': 'Export folder as ZIP',
      'exportAllZip': 'Export all notes (ZIP)',
      'importNotes': 'Import...',
      'newNoteHere': 'New note here',
      'expand': 'Expand',
      'collapse': 'Collapse',
      'keyboardShortcuts': 'Keyboard shortcuts',
      'close': 'Close',
      'groupNotes': 'Notes & folders',
      'groupNavigation': 'Navigation & search',
      'groupEditor': 'Editor',
      'groupApp': 'Application',
      'cmd.newNote': 'New note',
      'cmd.newFolder': 'New folder',
      'cmd.save': 'Save & sync',
      'cmd.findInNote': 'Find in note',
      'cmd.searchNotes': 'Search notes',
      'cmd.toggleMode': 'Toggle Edit / Read-only',
      'cmd.focusMode': 'Focus mode',
      'cmd.escape': 'Exit focus / close search',
      'cmd.pinNote': 'Pin / unpin note',
      'cmd.moveNote': 'Move note to folder',
      'cmd.exportNote': 'Export note (.md)',
      'cmd.duplicateNote': 'Duplicate note',
      'cmd.deleteNote': 'Delete note',
      'cmd.nextNote': 'Next note',
      'cmd.previousNote': 'Previous note',
      'cmd.settings': 'Settings',
      'cmd.help': 'Show shortcuts',
      'cmd.bold': 'Bold',
      'cmd.italic': 'Italic',
      'cmd.link': 'Insert link',
      'cmd.heading1': 'Heading 1',
      'cmd.heading2': 'Heading 2',
      'cmd.heading3': 'Heading 3',
    },
    'fr': {
      'pin': 'Épingler en haut',
      'unpin': 'Désépingler',
      'moveTo': 'Déplacer vers un dossier...',
      'duplicate': 'Dupliquer',
      'exportMarkdown': 'Exporter en Markdown (.md)',
      'copySuffix': ' (copie)',
      'moveFolder': 'Déplacer le dossier...',
      'exportFolderZip': 'Exporter le dossier en ZIP',
      'exportAllZip': 'Exporter toutes les notes (ZIP)',
      'importNotes': 'Importer...',
      'newNoteHere': 'Nouvelle note ici',
      'expand': 'Développer',
      'collapse': 'Réduire',
      'keyboardShortcuts': 'Raccourcis clavier',
      'close': 'Fermer',
      'groupNotes': 'Notes et dossiers',
      'groupNavigation': 'Navigation et recherche',
      'groupEditor': 'Éditeur',
      'groupApp': 'Application',
      'cmd.newNote': 'Nouvelle note',
      'cmd.newFolder': 'Nouveau dossier',
      'cmd.save': 'Enregistrer et synchroniser',
      'cmd.findInNote': 'Rechercher dans la note',
      'cmd.searchNotes': 'Rechercher des notes',
      'cmd.toggleMode': 'Basculer Édition / Lecture seule',
      'cmd.focusMode': 'Mode focus',
      'cmd.escape': 'Quitter le focus / fermer la recherche',
      'cmd.pinNote': 'Épingler / désépingler la note',
      'cmd.moveNote': 'Déplacer la note vers un dossier',
      'cmd.exportNote': 'Exporter la note (.md)',
      'cmd.duplicateNote': 'Dupliquer la note',
      'cmd.deleteNote': 'Supprimer la note',
      'cmd.nextNote': 'Note suivante',
      'cmd.previousNote': 'Note précédente',
      'cmd.settings': 'Paramètres',
      'cmd.help': 'Afficher les raccourcis',
      'cmd.bold': 'Gras',
      'cmd.italic': 'Italique',
      'cmd.link': 'Insérer un lien',
      'cmd.heading1': 'Titre 1',
      'cmd.heading2': 'Titre 2',
      'cmd.heading3': 'Titre 3',
    },
  };
}
