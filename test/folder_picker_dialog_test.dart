import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/features/folders/presentation/folder_picker_dialog.dart';

// La radice è sempre mostrata dal selettore, ma normalmente sceglierla quando
// è già la posizione attuale è un no-op. L'importazione di una cartella usa
// [FolderPickerDialog.allowCurrentSelection] perché non ha una posizione
// "attuale": la radice evidenziata è solo il valore predefinito.

Future<void> _openPicker(
  WidgetTester tester, {
  required String? currentFolderId,
  required bool allowCurrentSelection,
  required ValueChanged<String?> onSelected,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => FolderPickerDialog(
                title: 'Scegli',
                rootIcon: Icons.folder_special_outlined,
                rootLabel: 'Tutte le note',
                emptyLabel: 'Nessuna cartella',
                cancelLabel: 'Annulla',
                destinations: const [],
                currentFolderId: currentFolderId,
                allowCurrentSelection: allowCurrentSelection,
                onSelected: onSelected,
              ),
            ),
            child: const Text('Apri'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Apri'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('la radice attuale è un no-op senza allowCurrentSelection', (
    tester,
  ) async {
    var called = false;
    await _openPicker(
      tester,
      currentFolderId: null,
      allowCurrentSelection: false,
      onSelected: (_) => called = true,
    );

    await tester.tap(find.text('Tutte le note'));
    await tester.pumpAndSettle();

    expect(called, isFalse);
    expect(find.text('Scegli'), findsNothing);
  });

  testWidgets('allowCurrentSelection rende confermabile la radice', (
    tester,
  ) async {
    var called = false;
    String? selected;
    await _openPicker(
      tester,
      currentFolderId: null,
      allowCurrentSelection: true,
      onSelected: (folderId) {
        called = true;
        selected = folderId;
      },
    );

    await tester.tap(find.text('Tutte le note'));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(selected, isNull);
    expect(find.text('Scegli'), findsNothing);
  });
}
