import 'package:flutter_riverpod/legacy.dart';

/// Cartella attualmente selezionata (null = "Tutte le note").
///
/// Vive fuori da `folderProvider` perché è il punto di incontro tra cartelle e
/// note: entrambi i moduli la leggono, nessuno dei due la possiede. Tenerla qui
/// evita che `notes_provider` debba importare `folder_provider` solo per
/// conoscere la selezione.
final selectedFolderScopeProvider = StateProvider<String?>((ref) => null);
