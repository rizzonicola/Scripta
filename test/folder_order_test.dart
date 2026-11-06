import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/database/folders_dao.dart';
import 'package:scripta/core/database/notes_dao.dart';
import 'package:scripta/features/folders/models/folder_node.dart';
import 'package:scripta/features/folders/providers/folder_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/wait_until.dart';

/// Fake in-memory di [FoldersDao]: esercita [FolderNotifier] senza aprire un
/// database SQLite, e registra le scritture per verificare che il riordino
/// resti puramente locale (niente `updated_at`/`dirty`).
class _MemoryFoldersDao implements FoldersDao {
  final Map<String, FolderRow> rows = {};
  final List<Map<String, int>> orderWrites = [];
  final List<String> upsertedIds = [];

  @override
  Future<List<FolderRow>> getActive() async =>
      rows.values.where((r) => !r.isDeleted).toList()..sort((a, b) {
        final byOrder = a.orderIndex.compareTo(b.orderIndex);
        if (byOrder != 0) return byOrder;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

  @override
  Future<FolderRow?> getById(String id) async => rows[id];

  @override
  Future<void> upsert(FolderRow row) async {
    upsertedIds.add(row.id);
    rows[row.id] = row;
  }

  @override
  Future<void> setOrderIndexes(Map<String, int> indexes) async {
    orderWrites.add(Map.of(indexes));
    for (final entry in indexes.entries) {
      final row = rows[entry.key];
      if (row != null) rows[entry.key] = row.copyWith(orderIndex: entry.value);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _MemoryNotesDao implements NotesDao {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

final Provider<Ref> _refProvider = Provider<Ref>((ref) => ref);


FolderRow _row(
  String id,
  String name, {
  String? parentId,
  int orderIndex = 0,
}) => FolderRow(
  id: id,
  name: name,
  parentId: parentId,
  isExpanded: true,
  orderIndex: orderIndex,
  updatedAt: 1,
  deletedAt: null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('FolderNode.buildForest', () {
    test('senza ordine manuale resta alfabetico (case-insensitive)', () {
      final forest = FolderNode.buildForest([
        _row('b', 'beta'),
        _row('A', 'Alpha'),
        _row('c', 'gamma'),
      ]);

      expect(forest.map((n) => n.id), ['A', 'b', 'c']);
    });

    test('orderIndex > 0 viene prima dell’ordine alfabetico', () {
      final forest = FolderNode.buildForest([
        _row('a', 'Alpha'),
        _row('c', 'Gamma', orderIndex: 1),
        _row('b', 'Beta', orderIndex: 2),
      ]);

      expect(forest.map((n) => n.id), ['c', 'b', 'a']);
    });

    test('i figli sono ordinati con lo stesso criterio del loro genitore', () {
      final forest = FolderNode.buildForest([
        _row('root', 'Root'),
        _row('z', 'Zeta', parentId: 'root'),
        _row('m', 'Mu', parentId: 'root', orderIndex: 1),
      ]);

      expect(forest.single.children.map((n) => n.id), ['m', 'z']);
    });
  });

  group('FolderNotifier — riordino manuale', () {
    late ProviderContainer container;
    late _MemoryFoldersDao dao;
    late FolderNotifier folders;

    setUp(() async {
      dao = _MemoryFoldersDao();
      container = ProviderContainer();
      folders = FolderNotifier(
        container.read(_refProvider),
        foldersDao: dao,
        notesDao: _MemoryNotesDao(),
      );
      await waitUntil(() async => folders.initialLoadComplete);
    });

    tearDown(() async {
      await folders.flushPendingWrites();
      container.dispose();
    });

    test(
      'moveFolderRelative sposta prima/dopo e dentro, in modo persistente',
      () async {
        final alpha = folders.addFolder('Alpha');
        final beta = folders.addFolder('Beta');
        final gamma = folders.addFolder('Gamma');
        await folders.flushPendingWrites();

        expect(folders.state.rootFolders.map((n) => n.name), [
          'Alpha',
          'Beta',
          'Gamma',
        ]);

        // Gamma prima di Alpha -> ordine manuale 1-based.
        expect(
          folders.moveFolderRelative(
            gamma.id,
            alpha.id,
            FolderDropPosition.before,
          ),
          isTrue,
        );
        expect(folders.state.rootFolders.map((n) => n.name), [
          'Gamma',
          'Alpha',
          'Beta',
        ]);
        await folders.flushPendingWrites();
        expect(dao.rows[gamma.id]!.orderIndex, 1);
        expect(dao.rows[alpha.id]!.orderIndex, 2);
        expect(dao.rows[beta.id]!.orderIndex, 3);

        // Beta dentro Gamma.
        expect(
          folders.moveFolderRelative(
            beta.id,
            gamma.id,
            FolderDropPosition.inside,
          ),
          isTrue,
        );
        final gammaNode = folders.findNode(gamma.id)!;
        expect(gammaNode.children.map((n) => n.name), ['Beta']);
        expect(folders.state.rootFolders.map((n) => n.name), [
          'Gamma',
          'Alpha',
        ]);
        await folders.flushPendingWrites();
        expect(dao.rows[beta.id]!.parentId, gamma.id);
      },
    );

    test('dopo un riordino manuale le nuove cartelle vanno in fondo', () async {
      final alpha = folders.addFolder('Alpha');
      final beta = folders.addFolder('Beta');
      await folders.flushPendingWrites();

      folders.moveFolderRelative(beta.id, alpha.id, FolderDropPosition.before);
      await folders.flushPendingWrites();

      final delta = folders.addFolder('Delta');
      await folders.flushPendingWrites();

      expect(folders.state.rootFolders.map((n) => n.name), [
        'Beta',
        'Alpha',
        'Delta',
      ]);
      expect(dao.rows[delta.id]!.orderIndex, greaterThan(0));
    });

    test(
      'il rilascio sul bordo inferiore di una cartella espansa la rende prima figlia',
      () async {
        final parent = folders.addFolder('Parent');
        final child = folders.addFolder('Child', parentId: parent.id);
        final other = folders.addFolder('Other');
        await folders.flushPendingWrites();

        expect(
          folders.moveFolderRelative(
            other.id,
            parent.id,
            FolderDropPosition.after,
          ),
          isTrue,
        );

        final parentNode = folders.findNode(parent.id)!;
        expect(parentNode.children.map((n) => n.name), ['Other', 'Child']);
        expect(folders.state.rootFolders.map((n) => n.id), [parent.id]);
        expect(child.parentId, parent.id);
      },
    );

    test('rifiuta se stessa, i propri discendenti e i no-op', () async {
      final parent = folders.addFolder('Parent');
      final child = folders.addFolder('Child', parentId: parent.id);
      final sibling = folders.addFolder('Sibling');
      await folders.flushPendingWrites();

      expect(
        folders.moveFolderRelative(
          parent.id,
          parent.id,
          FolderDropPosition.inside,
        ),
        isFalse,
      );
      expect(
        folders.moveFolderRelative(
          parent.id,
          child.id,
          FolderDropPosition.inside,
        ),
        isFalse,
      );
      expect(folders.canMoveFolder(parent.id, child.id), isFalse);

      // Sposta Sibling dentro Parent, dopo Child.
      expect(
        folders.moveFolderRelative(
          sibling.id,
          child.id,
          FolderDropPosition.after,
        ),
        isTrue,
      );
      await folders.flushPendingWrites();
      expect(folders.findNode(parent.id)!.children.map((n) => n.name), [
        'Child',
        'Sibling',
      ]);

      // Stessa posizione: nessuna scrittura aggiuntiva.
      final writesBefore = dao.orderWrites.length;
      expect(
        folders.moveFolderRelative(
          sibling.id,
          child.id,
          FolderDropPosition.after,
        ),
        isFalse,
      );
      await folders.flushPendingWrites();
      expect(dao.orderWrites.length, writesBefore);
    });

    test('il solo riordino non riscrive updated_at né fa upsert', () async {
      final alpha = folders.addFolder('Alpha');
      final beta = folders.addFolder('Beta');
      await folders.flushPendingWrites();
      dao.upsertedIds.clear();

      final before = dao.rows[alpha.id]!.updatedAt;
      folders.moveFolderRelative(beta.id, alpha.id, FolderDropPosition.before);
      await folders.flushPendingWrites();

      expect(dao.upsertedIds, isEmpty);
      expect(dao.rows[alpha.id]!.updatedAt, before);
      expect(dao.rows[beta.id]!.orderIndex, 1);
    });
  });
}
