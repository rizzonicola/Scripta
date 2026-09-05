import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../../../core/constants/app_constants.dart';
import '../models/note_model.dart';
import '../../folders/providers/folder_provider.dart';

class NotesState {
  final List<NoteModel> notes;
  final String searchQuery;
  final String? activeNoteId;
  final NoteSortOrder sortOrder;

  const NotesState({
    this.notes = const [],
    this.searchQuery = '',
    this.activeNoteId,
    this.sortOrder = NoteSortOrder.updatedDesc,
  });

  NotesState copyWith({
    List<NoteModel>? notes,
    String? searchQuery,
    String? Function()? activeNoteId,
    NoteSortOrder? sortOrder,
  }) {
    return NotesState(
      notes: notes ?? this.notes,
      searchQuery: searchQuery ?? this.searchQuery,
      activeNoteId: activeNoteId != null ? activeNoteId() : this.activeNoteId,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}

class NotesNotifier extends StateNotifier<NotesState> {
  static const String _prefKey = 'scripta_notes_list';
  static const String _legacyPrefKey = 'inkflow_notes_list';
  static const String _tombstonesKey = 'scripta_deleted_notes_tombstones';
  final _uuid = const Uuid();
  List<Map<String, dynamic>> _tombstones = [];
  Timer? _saveDebounceTimer;

  NotesNotifier() : super(const NotesState()) {
    _loadFromPrefs();
  }

  @override
  void dispose() {
    flushPendingSaves();
    super.dispose();
  }

  void flushPendingSaves() {
    if (_saveDebounceTimer != null) {
      _saveDebounceTimer!.cancel();
      _saveDebounceTimer = null;
      _saveToPrefs();
    }
  }

  void _debouncedSaveToPrefs() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _saveToPrefs();
    });
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    var rawJson = prefs.getString(_prefKey);
    rawJson ??= prefs.getString(_legacyPrefKey);

    final rawTombstones = prefs.getString(_tombstonesKey);
    if (rawTombstones != null && rawTombstones.isNotEmpty) {
      try {
        final List<dynamic> decoded = json.decode(rawTombstones);
        _tombstones = decoded.cast<Map<String, dynamic>>();
      } catch (_) {}
    }

    final sortStr = prefs.getString(AppConstants.prefSortMode);
    NoteSortOrder sortOrder = NoteSortOrder.updatedDesc;
    if (sortStr != null) {
      for (final val in NoteSortOrder.values) {
        if (val.name == sortStr) {
          sortOrder = val;
          break;
        }
      }
    }

    if (rawJson != null && rawJson.isNotEmpty) {
      try {
        final List<dynamic> decoded = json.decode(rawJson);
        var notes = decoded
            .map((item) => NoteModel.fromMap(item as Map<String, dynamic>))
            .toList();

        notes = _sortNotes(notes, sortOrder);

        state = state.copyWith(
          notes: notes,
          activeNoteId: () => notes.isNotEmpty ? notes.first.id : null,
          sortOrder: sortOrder,
        );
        return;
      } catch (_) {}
    }

    // Default sample note for Scripta
    final now = DateTime.now();
    final sampleNote = NoteModel(
      id: _uuid.v4(),
      title: 'Benvenuto in Scripta ✒️',
      content: '''# Benvenuto in Scripta ✒️

**Scripta** è un'app di note *Minimal, Markdown-First* pensata per eliminare ogni distrazione e liberare il tuo flusso creativo.

---

### ✨ Caratteristiche Principali

- [x] **Dual Mode**: Passa fluidamente tra modalità *Edit* e *Read-Only*
- [x] **Blocchi di Codice Potenziati**: Evidenziazione sintassi, selezione fluida e pulsante di copia in alto a destra
- [x] **Focus Mode**: Scrittura e lettura immersiva a schermo intero
- [x] **Toolbar Intelligente**: Formatta all'istante senza ricordare la sintassi
- [x] **Albero Cartelle & Riordino**: Organizzazione gerarchica con ordinamento per data, alfabetico o personalizzato (drag & drop)
- [x] **Temi Ricchi**: Scegli tra Dark Teal, OLED Black, Nord, Midnight e altri

---

### 📊 Tabelle Markdown

| Scorciatoia | Funzione | Risultato |
| :--- | :--- | :--- |
| `Ctrl + B` | Grassetto | **Testo evidenziato** |
| `Ctrl + I` | Corsivo | *Testo enfatico* |
| `F11` | Focus Mode | Schermo intero pulito |

---

### 💻 Blocchi di Codice con Evidenziazione e Copia Rapida

```dart
void main() {
  final app = ScriptaApp();
  app.startWritingWithPassion();
}
```

```json
{
  "name": "Scripta",
  "theme": "dark_teal",
  "markdown_first": true
}
```

> "La semplicità è la suprema sofisticazione."
> — *Leonardo da Vinci*

Sentiti libero di modificare questa nota o di crearne di nuove dall'elenco a sinistra!
''',
      createdAt: now,
      updatedAt: now,
      isPinned: true,
      isFavorite: true,
      orderIndex: 0,
    );

    state = state.copyWith(
      notes: [sampleNote],
      activeNoteId: () => sampleNote.id,
      sortOrder: sortOrder,
    );
    _saveToPrefs();
  }

  static List<NoteModel> _sortNotes(List<NoteModel> list, NoteSortOrder order) {
    final sorted = List<NoteModel>.from(list);
    sorted.sort((a, b) {
      if (order != NoteSortOrder.custom) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      }

      switch (order) {
        case NoteSortOrder.updatedDesc:
          return b.updatedAt.compareTo(a.updatedAt);
        case NoteSortOrder.updatedAsc:
          return a.updatedAt.compareTo(b.updatedAt);
        case NoteSortOrder.createdDesc:
          return b.createdAt.compareTo(a.createdAt);
        case NoteSortOrder.createdAsc:
          return a.createdAt.compareTo(b.createdAt);
        case NoteSortOrder.titleAsc:
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case NoteSortOrder.titleDesc:
          return b.title.toLowerCase().compareTo(a.title.toLowerCase());
        case NoteSortOrder.custom:
          return a.orderIndex.compareTo(b.orderIndex);
      }
    });
    return sorted;
  }

  Future<void> _saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final rawJson = json.encode(state.notes.map((n) => n.toMap()).toList());
    await prefs.setString(_prefKey, rawJson);
  }

  NoteModel? get activeNote {
    if (state.activeNoteId == null) return null;
    try {
      return state.notes.firstWhere((n) => n.id == state.activeNoteId);
    } catch (_) {
      return state.notes.isNotEmpty ? state.notes.first : null;
    }
  }

  void selectNote(String? id) {
    if (state.activeNoteId != id) {
      flushPendingSaves();
      final sorted = _sortNotes(state.notes, state.sortOrder);
      state = state.copyWith(notes: sorted, activeNoteId: () => id);
    }
  }

  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  Future<void> setSortOrder(NoteSortOrder order) async {
    flushPendingSaves();
    final sorted = _sortNotes(state.notes, order);
    state = state.copyWith(notes: sorted, sortOrder: order);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefSortMode, order.name);
  }

  void reorderNotes(int oldIndex, int newIndex) {
    flushPendingSaves();
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }

    final updated = List<NoteModel>.from(state.notes);
    final item = updated.removeAt(oldIndex);
    updated.insert(newIndex, item);

    // Update orderIndex
    final reindexed = <NoteModel>[];
    for (int i = 0; i < updated.length; i++) {
      reindexed.add(updated[i].copyWith(orderIndex: i));
    }

    state = state.copyWith(
      notes: reindexed,
      sortOrder: NoteSortOrder.custom,
    );
    _saveToPrefs();
  }

  NoteModel createNote({String? folderId}) {
    flushPendingSaves();
    final now = DateTime.now();
    final newNote = NoteModel(
      id: _uuid.v4(),
      title: '',
      content: '',
      folderId: folderId,
      createdAt: now,
      updatedAt: now,
      orderIndex: 0,
    );

    // If custom order, push other indexes by 1
    final updated = [
      newNote,
      ...state.notes.map((n) => n.copyWith(orderIndex: n.orderIndex + 1)),
    ];

    state = state.copyWith(
      notes: _sortNotes(updated, state.sortOrder),
      activeNoteId: () => newNote.id,
    );
    _saveToPrefs();
    return newNote;
  }

  void updateNote(String id, {String? title, String? content}) {
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index == -1) return;

    final existing = state.notes[index];
    final updatedNote = existing.copyWith(
      title: title ?? existing.title,
      content: content ?? existing.content,
      updatedAt: DateTime.now(),
    );

    final updatedList = List<NoteModel>.from(state.notes);
    updatedList[index] = updatedNote;

    state = state.copyWith(
      notes: updatedList,
    );
    _debouncedSaveToPrefs();
  }

  void moveNote(String id, String? targetFolderId) {
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index == -1) return;

    final existing = state.notes[index];
    final updatedNote = existing.copyWith(
      folderId: () => targetFolderId,
      updatedAt: DateTime.now(),
    );

    final updatedList = List<NoteModel>.from(state.notes);
    updatedList[index] = updatedNote;

    state = state.copyWith(
      notes: _sortNotes(updatedList, state.sortOrder),
    );
    _saveToPrefs();
  }

  static String sanitizeFileName(String name) {
    final sanitized = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return sanitized.isEmpty ? 'nota' : sanitized;
  }

  void deleteNote(String id) {
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index != -1) {
      final note = state.notes[index];
      final relPath = note.relativePath ?? '${sanitizeFileName(note.title)}.md';
      _tombstones.add({
        'relative_path': relPath,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      _saveTombstones();
    }

    final updatedList = state.notes.where((n) => n.id != id).toList();
    String? nextActiveId;
    if (state.activeNoteId == id) {
      nextActiveId = updatedList.isNotEmpty ? updatedList.first.id : null;
    } else {
      nextActiveId = state.activeNoteId;
    }

    state = state.copyWith(
      notes: updatedList,
      activeNoteId: () => nextActiveId,
    );
    _saveToPrefs();
  }

  List<Map<String, dynamic>> get tombstones => List.unmodifiable(_tombstones);

  Future<void> purgeTombstones(List<String> paths) async {
    _tombstones.removeWhere((t) => paths.contains(t['relative_path']));
    await _saveTombstones();
  }

  Future<void> _saveTombstones() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tombstonesKey, json.encode(_tombstones));
  }

  void updateNoteRelativePath(String noteId, String relativePath) {
    final index = state.notes.indexWhere((n) => n.id == noteId);
    if (index == -1) return;
    final updatedList = List<NoteModel>.from(state.notes);
    updatedList[index] =
        updatedList[index].copyWith(relativePath: () => relativePath);
    state = state.copyWith(notes: updatedList);
    _saveToPrefs();
  }

  void applyServerNote({
    required String relativePath,
    required String content,
    required DateTime updatedAt,
    required bool deleted,
    String? folderId,
  }) {
    if (deleted) {
      final index = state.notes.indexWhere(
        (n) =>
            n.relativePath == relativePath ||
            (n.relativePath == null &&
                relativePath.endsWith('/${sanitizeFileName(n.title)}.md')),
      );
      if (index != -1) {
        final id = state.notes[index].id;
        final updatedList = state.notes.where((n) => n.id != id).toList();
        String? nextActiveId = state.activeNoteId;
        if (state.activeNoteId == id) {
          nextActiveId = updatedList.isNotEmpty ? updatedList.first.id : null;
        }
        state = state.copyWith(
          notes: updatedList,
          activeNoteId: () => nextActiveId,
        );
        _saveToPrefs();
      }
      return;
    }

    // Extract title from filename (strip .md)
    final filename = relativePath.split('/').last;
    final titleFromFilename = filename.endsWith('.md')
        ? filename.substring(0, filename.length - 3).replaceAll('_', ' ')
        : filename;

    final index = state.notes.indexWhere(
      (n) =>
          n.relativePath == relativePath ||
          (n.relativePath == null &&
              n.title.toLowerCase() == titleFromFilename.toLowerCase()),
    );

    if (index != -1) {
      final existing = state.notes[index];
      final newTitle = (existing.title.trim().isEmpty || existing.title.startsWith('nota_'))
          ? (titleFromFilename.isEmpty ? 'Nota' : titleFromFilename)
          : existing.title;

      final updated = existing.copyWith(
        title: newTitle,
        content: content,
        updatedAt: updatedAt,
        relativePath: () => relativePath,
      );
      final updatedList = List<NoteModel>.from(state.notes);
      updatedList[index] = updated;
      state = state.copyWith(notes: _sortNotes(updatedList, state.sortOrder));
      _saveToPrefs();
    } else {
      // Create new note from server
      final newNote = NoteModel(
        id: _uuid.v4(),
        title: titleFromFilename.isEmpty ? 'Nota' : titleFromFilename,
        content: content,
        folderId: folderId,
        createdAt: updatedAt,
        updatedAt: updatedAt,
        relativePath: relativePath,
        orderIndex: 0,
      );
      final updatedList = [newNote, ...state.notes];
      state = state.copyWith(notes: _sortNotes(updatedList, state.sortOrder));
      _saveToPrefs();
    }
  }

  void togglePin(String id) {
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index == -1) return;

    final existing = state.notes[index];
    final updatedNote = existing.copyWith(isPinned: !existing.isPinned);

    final updatedList = List<NoteModel>.from(state.notes);
    updatedList[index] = updatedNote;

    state = state.copyWith(
      notes: _sortNotes(updatedList, state.sortOrder),
    );
    _saveToPrefs();
  }

  void toggleFavorite(String id) {
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index == -1) return;

    final existing = state.notes[index];
    final updatedList = List<NoteModel>.from(state.notes);
    updatedList[index] = existing.copyWith(isFavorite: !existing.isFavorite);

    state = state.copyWith(notes: updatedList);
    _saveToPrefs();
  }
}

final notesProvider = StateNotifierProvider<NotesNotifier, NotesState>((ref) {
  return NotesNotifier();
});

/// Provider for the currently active note
final activeNoteProvider = Provider<NoteModel?>((ref) {
  final activeNoteId = ref.watch(notesProvider.select((s) => s.activeNoteId));
  if (activeNoteId == null) return null;
  final notes = ref.watch(notesProvider.select((s) => s.notes));
  try {
    return notes.firstWhere((n) => n.id == activeNoteId);
  } catch (_) {
    return notes.isNotEmpty ? notes.first : null;
  }
});

/// Provider for filtered notes based on folder and search query
final filteredNotesProvider = Provider<List<NoteModel>>((ref) {
  final notes = ref.watch(notesProvider.select((s) => s.notes));
  final selectedFolderId = ref.watch(folderProvider.select((s) => s.selectedFolderId));
  final searchQuery = ref.watch(notesProvider.select((s) => s.searchQuery));

  var filtered = notes;

  // Filter by selected folder if any
  if (selectedFolderId != null) {
    filtered = filtered
        .where((n) => n.folderId == selectedFolderId)
        .toList();
  }

  // Filter by search query
  if (searchQuery.trim().isNotEmpty) {
    final q = searchQuery.toLowerCase().trim();
    filtered = filtered.where((n) {
      return n.title.toLowerCase().contains(q) ||
          n.content.toLowerCase().contains(q);
    }).toList();
  }

  return filtered;
});
