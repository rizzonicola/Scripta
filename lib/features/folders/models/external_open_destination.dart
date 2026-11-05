/// Destinazione scelta per una voce esterna (file o cartella).
///
/// [folderId] serve ad aprire un FILE dentro una cartella esistente, mentre
/// [pathSegments] serve all'importazione di una CARTELLA, che deve ricreare
/// l'albero per nome sotto la destinazione. Radice = entrambi vuoti.
class ExternalOpenDestination {
  const ExternalOpenDestination({
    this.folderId,
    this.pathSegments = const <String>[],
  });

  final String? folderId;
  final List<String> pathSegments;
}
