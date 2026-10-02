import '../../../core/database/notes_dao.dart';

enum NoteSortOrder {
  updatedDesc,
  updatedAsc,
  createdDesc,
  createdAsc,
  titleAsc,
  titleDesc,
  custom,
}

/// Modello di dominio di una nota, usato da UI e provider.
///
/// A differenza della generazione precedente, NON esiste più alcun concetto
/// di percorso (niente `relativePath`, niente `pendingOldRelativePath`): la
/// posizione di una nota è determinata unicamente da [folderId] (null =
/// nessuna cartella, la nota compare comunque in "Tutte le note"). Spostare
/// una nota tra cartelle è un semplice cambio di [folderId], propagato alla
/// sync come un normale aggiornamento con un nuovo `updated_at` — non più un
/// "vecchio percorso / nuovo percorso" da riconciliare lato server.
class NoteModel {
  final String id;
  final String title;
  final String content;
  final String? folderId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isFavorite;
  final bool isPinned;
  final int orderIndex;

  // Costruttore non `const`: i campi obbligatori (`createdAt`/`updatedAt`)
  // sono `DateTime`, che non ha un costruttore const, quindi un
  // `const NoteModel(...)` non sarebbe comunque mai stato invocabile nella
  // pratica. Serve inoltre un costruttore NON const perché sotto, il campo
  // `previewSnippet`, è un `late final` con inizializzatore: combinazione
  // non ammessa dal compilatore Dart con un costruttore `const`.
  NoteModel({
    required this.id,
    required this.title,
    required this.content,
    this.folderId,
    required this.createdAt,
    required this.updatedAt,
    this.isFavorite = false,
    this.isPinned = false,
    this.orderIndex = 0,
  });

  NoteModel copyWith({
    String? id,
    String? title,
    String? content,
    String? Function()? folderId,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isFavorite,
    bool? isPinned,
    int? orderIndex,
  }) {
    return NoteModel(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      folderId: folderId != null ? folderId() : this.folderId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isFavorite: isFavorite ?? this.isFavorite,
      isPinned: isPinned ?? this.isPinned,
      orderIndex: orderIndex ?? this.orderIndex,
    );
  }

  /// Numero di parole, calcolato UNA sola volta per istanza (la nota è
  /// immutabile). Prima era un getter ricalcolato (e chiamato due volte per
  /// ogni rebuild di `NoteCard`, anche via [readingTimeMinutes]) con
  /// `trim()` + `split(RegExp(...))`: una copia del testo e una stringa per
  /// ogni parola, a ogni battitura sulla nota aperta.
  late final int wordCount = _countWords();

  /// Una parola è una sequenza massimale di caratteri non-spazio: stesso
  /// risultato di `content.trim().split(RegExp(r'\s+'))`, in un solo passaggio
  /// sul testo e senza allocare nulla.
  int _countWords() {
    final text = content;
    var count = 0;
    var inWord = false;
    for (var i = 0; i < text.length; i++) {
      final isSpace = _isWhitespace(text.codeUnitAt(i));
      if (!isSpace && !inWord) count++;
      inWord = !isSpace;
    }
    return count;
  }

  /// Gli stessi caratteri riconosciuti da `\s` nelle RegExp.
  static bool _isWhitespace(int c) =>
      c == 0x20 ||
      (c >= 0x09 && c <= 0x0D) ||
      c == 0xA0 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200A) ||
      c == 0x2028 ||
      c == 0x2029 ||
      c == 0x202F ||
      c == 0x205F ||
      c == 0x3000 ||
      c == 0xFEFF;

  late final int readingTimeMinutes = (wordCount / 200).ceil().clamp(1, 999);

  /// Anteprima "pulita" (senza simboli di formattazione Markdown) mostrata
  /// nelle card della lista note.
  ///
  /// `late final` invece di un getter ricalcolato: [NoteModel] è
  /// immutabile (ogni modifica passa da [copyWith], che produce una nuova
  /// istanza), quindi le 5 passate di `RegExp.replaceAll` sul contenuto
  /// vengono eseguite al più una volta per istanza (alla prima lettura),
  /// invece che ad ogni singolo rebuild di `NoteCard` — che con liste note
  /// grandi può voler dire molte volte per la stessa identica istanza,
  /// senza alcun bisogno di ripetere il calcolo.
  late final String previewSnippet = _buildPreviewSnippet();

  // RegExp compilate una volta sola (erano ricreate a ogni calcolo).
  static final RegExp _headingMarks = RegExp(r'#+\s*');
  static final RegExp _emphasisMarks = RegExp(r'\*+');
  static final RegExp _codeMarks = RegExp(r'`+');
  static final RegExp _linkSyntax = RegExp(r'\[(.*?)\]\(.*?\)');
  static final RegExp _taskMarks = RegExp(r'- \[( |x)\]');

  /// Quanti caratteri iniziali del contenuto si ripuliscono per ricavare lo
  /// snippet. Lo snippet ne mostra al massimo 120: passare 5 RegExp su una
  /// nota da centinaia di KB (e rifarlo a ogni battitura, perché ogni
  /// modifica crea una nuova istanza) era il costo dominante dell'editing di
  /// note lunghe.
  static const int _snippetSourceChars = 4000;

  /// Se dal prefisso restano meno di questi caratteri "puliti" (inizio quasi
  /// tutto markup), il prefisso non basta e si ripulisce l'intero contenuto,
  /// come in origine.
  static const int _snippetMinCleanChars = 200;

  /// Rimuove i simboli di formattazione Markdown per un'anteprima leggibile.
  static String _stripMarkdown(String raw) => raw
      .replaceAll(_headingMarks, '')
      .replaceAll(_emphasisMarks, '')
      .replaceAll(_codeMarks, '')
      // NB: `replaceAll(.., r'$1')` inseriva il testo letterale "$1" (in Dart
      // la stringa di sostituzione non viene interpretata): serve un callback
      // per mostrare il testo del link.
      .replaceAllMapped(_linkSyntax, (m) => m[1] ?? '')
      .replaceAll(_taskMarks, '')
      .trim();

  String _buildPreviewSnippet() {
    final isLong = content.length > _snippetSourceChars;
    var cleaned = _stripMarkdown(isLong ? content.substring(0, _snippetSourceChars) : content);
    if (isLong && cleaned.length < _snippetMinCleanChars) {
      cleaned = _stripMarkdown(content);
    }
    if (cleaned.isEmpty) return 'Nessun testo aggiuntivo';
    return cleaned.length > 120 ? '${cleaned.substring(0, 120)}...' : cleaned;
  }

  /// Converte la riga grezza del database locale nel modello di dominio.
  factory NoteModel.fromRow(NoteRow row) {
    return NoteModel(
      id: row.id,
      title: row.title,
      content: row.content,
      folderId: row.folderId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt, isUtc: true).toLocal(),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt, isUtc: true).toLocal(),
      isFavorite: row.isFavorite,
      isPinned: row.isPinned,
      orderIndex: row.orderIndex,
    );
  }

  /// Converte verso la riga grezza da persistere. [deletedAt] resta a carico
  /// del chiamante (NotesNotifier), che lo valorizza solo per le operazioni
  /// di soft-delete: un NoteModel visibile in UI è per definizione sempre
  /// attivo, quindi il modello di dominio stesso non porta questo campo.
  NoteRow toRow({int? deletedAt}) {
    return NoteRow(
      id: id,
      title: title,
      content: content,
      folderId: folderId,
      isFavorite: isFavorite,
      isPinned: isPinned,
      orderIndex: orderIndex,
      createdAt: createdAt.toUtc().millisecondsSinceEpoch,
      updatedAt: updatedAt.toUtc().millisecondsSinceEpoch,
      deletedAt: deletedAt,
    );
  }
}
