import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/core/services/export_archive.dart';
import 'package:scripta/core/services/import_parser.dart';

/// Verifica che [mapZipEntryPath] traduca [entry] in [folders] + [fileName].
void _expectZip(String entry, List<String> folders, String fileName) {
  final location = mapZipEntryPath(entry);
  expect(location, isNotNull, reason: 'la voce "$entry" non doveva essere ignorata');
  expect(location!.folders, folders, reason: 'cartelle di "$entry"');
  expect(location.fileName, fileName, reason: 'nome file di "$entry"');
}

void main() {
  group('mapZipEntryPath: radice e Non_Catalogate', () {
    test('le note di Non_Catalogate tornano alla radice (nessuna cartella)', () {
      _expectZip('$uncatalogedFolderName/A.md', const [], 'A.md');
      _expectZip('Non_Catalogate/1 - Nome Nota.md', const [], '1 - Nome Nota.md');
    });

    test('il confronto ignora maiuscole e spazi ai bordi', () {
      _expectZip('non_catalogate/A.md', const [], 'A.md');
      _expectZip('NON_CATALOGATE/A.md', const [], 'A.md');
      _expectZip(' Non_Catalogate /A.md', const [], 'A.md');
    });

    test('una cartella vera resta una cartella, a ogni profondità', () {
      _expectZip('Reale/C.md', const ['Reale'], 'C.md');
      _expectZip('A/B/C/Nota.md', const ['A', 'B', 'C'], 'Nota.md');
      _expectZip('2 - Progetti/1 - Nota.md', const ['2 - Progetti'], '1 - Nota.md');
    });

    test('solo il livello più alto è il contenitore dell\'esportazione', () {
      _expectZip('Lavoro/Non_Catalogate/x.md', const ['Lavoro', 'Non_Catalogate'], 'x.md');
      _expectZip('Non_Catalogate/Sotto/x.md', const ['Non_Catalogate', 'Sotto'], 'x.md');
    });

    test('un nome solo simile non è il contenitore', () {
      _expectZip('Non_Catalogate2/A.md', const ['Non_Catalogate2'], 'A.md');
      _expectZip('Non Catalogate/A.md', const ['Non Catalogate'], 'A.md');
      _expectZip('Catalogate/A.md', const ['Catalogate'], 'A.md');
    });

    test('isUncatalogedFolderName usa la stessa costante dell\'esportazione', () {
      expect(isUncatalogedFolderName(uncatalogedFolderName), isTrue);
      expect(isUncatalogedFolderName('Lavoro'), isFalse);
      expect(isUncatalogedFolderName(''), isFalse);
    });
  });

  group('mapZipEntryPath: piattaforme', () {
    test('separatori Windows (\\) equivalgono a /', () {
      _expectZip(r'Lavoro\Sub\n.md', const ['Lavoro', 'Sub'], 'n.md');
      _expectZip(r'Non_Catalogate\A.md', const [], 'A.md');
      _expectZip(r'Lavoro/Sub\n.md', const ['Lavoro', 'Sub'], 'n.md');
    });

    test('"./" iniziale, "." e separatori doppi sono ininfluenti', () {
      _expectZip('./Lavoro//Sub/./n.md', const ['Lavoro', 'Sub'], 'n.md');
      _expectZip('./Non_Catalogate/A.md', const [], 'A.md');
    });

    test('voci fuori dalla gerarchia (path traversal, assoluti, unità) ignorate', () {
      for (final entry in [
        '../evil.md',
        'a/../../evil.md',
        'a/..\\evil.md',
        '/etc/evil.md',
        'C:/evil.md',
        r'C:\evil.md',
        r'\\server\share\evil.md',
      ]) {
        expect(mapZipEntryPath(entry), isNull, reason: entry);
      }
    });

    test('il rumore degli ZIP di macOS non diventa note né cartelle', () {
      expect(mapZipEntryPath('__MACOSX/Lavoro/._A.md'), isNull);
      expect(mapZipEntryPath('__MACOSX/A.md'), isNull);
      expect(mapZipEntryPath('__macosx/A.md'), isNull);
      expect(mapZipEntryPath('Lavoro/._A.md'), isNull);
      // Un file nascosto "normale" non è rumore.
      _expectZip('Lavoro/.nascosta.md', const ['Lavoro'], '.nascosta.md');
    });

    test('ciò che non è una nota viene ignorato', () {
      expect(mapZipEntryPath('Lavoro/immagine.png'), isNull);
      expect(mapZipEntryPath('Lavoro/relazione.pdf'), isNull);
      expect(mapZipEntryPath('Lavoro/.DS_Store'), isNull);
      expect(mapZipEntryPath('Lavoro/'), isNull);
      expect(mapZipEntryPath(''), isNull);
    });

    test('le estensioni importabili non distinguono le maiuscole', () {
      _expectZip('a/B.MD', const ['a'], 'B.MD');
      _expectZip('a/B.markdown', const ['a'], 'B.markdown');
      _expectZip('a/B.TXT', const ['a'], 'B.TXT');
    });
  });

  group('mapFileSystemPath (segmenti nativi, cartella scelta dall\'utente)', () {
    test('stessa mappatura dello ZIP', () {
      final root = mapFileSystemPath(const ['Non_Catalogate', 'A.md']);
      expect(root!.folders, isEmpty);
      expect(root.fileName, 'A.md');

      final nested = mapFileSystemPath(const ['Lavoro', 'Sub', 'n.md']);
      expect(nested!.folders, ['Lavoro', 'Sub']);

      final top = mapFileSystemPath(const ['n.md']);
      expect(top!.folders, isEmpty);
    });

    test('un "\\" in un nome di file non è un separatore: qui è già stato spezzato', () {
      final location = mapFileSystemPath(const ['Lavoro', r'a\b.md']);
      expect(location!.folders, ['Lavoro']);
      expect(location.fileName, r'a\b.md');
    });

    test('scarta traversal, rumore macOS, file non-nota e liste vuote', () {
      expect(mapFileSystemPath(const ['..', 'x.md']), isNull);
      expect(mapFileSystemPath(const ['__MACOSX', 'x.md']), isNull);
      expect(mapFileSystemPath(const ['Lavoro', '._x.md']), isNull);
      expect(mapFileSystemPath(const ['Lavoro', 'x.pdf']), isNull);
      expect(mapFileSystemPath(const ['Lavoro']), isNull);
      expect(mapFileSystemPath(const <String>[]), isNull);
    });
  });

  group('mapFilePath: convenzioni di percorso di ogni piattaforma', () {
    // Il contesto è iniettabile: le regole di Windows e di POSIX si verificano
    // entrambe su qualunque sistema, senza dover avere quel sistema.
    test('Windows: separatore "\\", unità e Non_Catalogate alla radice', () {
      final bucket = mapFilePath(
        r'C:\Utenti\io\Backup\Non_Catalogate\1 - Nome Nota.md',
        rootPath: r'C:\Utenti\io\Backup',
        context: p.windows,
      );
      expect(bucket!.folders, isEmpty);
      expect(bucket.fileName, '1 - Nome Nota.md');

      final nested = mapFilePath(
        r'C:\Utenti\io\Backup\Lavoro\Sub\n.md',
        rootPath: r'C:\Utenti\io\Backup',
        context: p.windows,
      );
      expect(nested!.folders, ['Lavoro', 'Sub']);

      final top = mapFilePath(
        r'C:\Utenti\io\Backup\n.md',
        rootPath: r'C:\Utenti\io\Backup',
        context: p.windows,
      );
      expect(top!.folders, isEmpty);
    });

    test('Windows: cartella di rete (UNC) e radice con separatore finale', () {
      final unc = mapFilePath(
        r'\\server\share\Backup\Non_Catalogate\A.md',
        rootPath: r'\\server\share\Backup',
        context: p.windows,
      );
      expect(unc!.folders, isEmpty);
      expect(unc.fileName, 'A.md');

      final trailing = mapFilePath(
        r'C:\Backup\Lavoro\n.md',
        rootPath: r'C:\Backup\',
        context: p.windows,
      );
      expect(trailing!.folders, ['Lavoro']);
    });

    test('POSIX (Linux, macOS, Android, iOS): "/" separa, "\\" è un carattere', () {
      final bucket = mapFilePath(
        '/home/io/Backup/Non_Catalogate/A.md',
        rootPath: '/home/io/Backup',
        context: p.posix,
      );
      expect(bucket!.folders, isEmpty);

      final backslash = mapFilePath(
        '/home/io/Backup/Lavoro/a\\b.md',
        rootPath: '/home/io/Backup',
        context: p.posix,
      );
      expect(backslash!.folders, ['Lavoro']);
      expect(backslash.fileName, 'a\\b.md');

      final trailing = mapFilePath(
        '/home/io/Backup/Lavoro/n.md',
        rootPath: '/home/io/Backup/',
        context: p.posix,
      );
      expect(trailing!.folders, ['Lavoro']);
    });

    test('percorsi con spazi, accenti e prefissi numerici restano intatti', () {
      final windows = mapFilePath(
        r'C:\Mie note\2 - Città\42 - Perché.md',
        rootPath: r'C:\Mie note',
        context: p.windows,
      );
      expect(windows!.folders, ['2 - Città']);
      expect(windows.fileName, '42 - Perché.md');

      final posix = mapFilePath(
        '/Users/io/Mie note/2 - Città/42 - Perché.md',
        rootPath: '/Users/io/Mie note',
        context: p.posix,
      );
      expect(posix!.folders, ['2 - Città']);
      expect(posix.fileName, '42 - Perché.md');
    });

    test('senza contesto usa quello della piattaforma che esegue i test', () {
      final root = p.join(p.separator == '/' ? '/tmp' : r'C:\tmp', 'Backup');
      final location = mapFilePath(
        p.join(root, 'Non_Catalogate', 'A.md'),
        rootPath: root,
      );
      expect(location!.folders, isEmpty);
      expect(location.fileName, 'A.md');
    });

    test('un file fuori dalla cartella scelta non entra nella gerarchia', () {
      expect(
        mapFilePath('/home/io/Altro/n.md', rootPath: '/home/io/Backup', context: p.posix),
        isNull,
      );
    });
  });

  group('parseNoteFile: titoli con prefisso numerico', () {
    const numericTitles = [
      '1 - Nome Nota',
      '01. Introduzione',
      '2024-01-05 Riunione',
      '10 cose da fare',
      '3',
      '007',
      '1.2.3 Versione',
      '42 - Città',
    ];
    const bodies = [
      'corpo',
      '',
      '# Titolo interno\n\ncorpo',
      'prima riga\n# non è un titolo',
      '\n\ntesto dopo righe vuote',
    ];

    test('esporta → importa: titolo e testo tornano identici (file reali di Scripta)', () {
      for (final title in numericTitles) {
        for (final body in bodies) {
          // Esattamente ciò che scrive `buildNotesZip`.
          final exported = noteMarkdownContent(title, body);
          final fileName = '${sanitizeFileName(title)}.md';

          final parsed = parseNoteFile(exported, fileName);

          expect(parsed.title, title,
              reason: 'titolo di "$title" con testo ${body.codeUnits.length} car.');
          expect(parsed.content, body, reason: 'testo di "$title"');
        }
      }
    });

    test('regressione: "# Nome Nota" nel testo non cancella il "1 - " del titolo', () {
      final parsed = parseNoteFile('# Nome Nota\n\ncorpo', '1 - Nome Nota.md');

      expect(parsed.title, '1 - Nome Nota');
      // L'intestazione è testo della nota: non va persa.
      expect(parsed.content, '# Nome Nota\n\ncorpo');
    });

    test('qualunque forma di prefisso numerico sopravvive a un H1 senza prefisso', () {
      for (final prefix in ['1 - ', '01. ', '2024-01-05 ', '3) ', '007 ', '10_']) {
        final fileName = '${prefix}Nome Nota.md';
        final parsed = parseNoteFile('# Nome Nota\n\ncorpo', fileName);
        expect(parsed.title, '${prefix}Nome Nota', reason: fileName);
      }
    });

    test('un H1 con altro testo non sostituisce mai un titolo numerato', () {
      final parsed = parseNoteFile('# Capitolo uno\n\ncorpo', '2 - Seconda.md');
      expect(parsed.title, '2 - Seconda');
      expect(parsed.content, '# Capitolo uno\n\ncorpo');
    });

    test('un H1 che contiene il prefisso (eco del titolo) viene riconosciuto', () {
      final parsed = parseNoteFile('# 1 - Nome Nota\n\ncorpo', '1 - Nome Nota.md');
      expect(parsed.title, '1 - Nome Nota');
      expect(parsed.content, 'corpo');
    });
  });

  group('parseNoteFile: regole sul titolo', () {
    test('senza H1 il titolo è il nome del file e il testo resta invariato', () {
      final parsed = parseNoteFile('solo testo\nsecondo rigo', '1 - Nome Nota.md');
      expect(parsed.title, '1 - Nome Nota');
      expect(parsed.content, 'solo testo\nsecondo rigo');
    });

    test('"#Titolo" senza spazio non è un titolo di primo livello', () {
      final parsed = parseNoteFile('#Titolo\ncorpo', 'Altro.md');
      expect(parsed.title, 'Altro');
      expect(parsed.content, '#Titolo\ncorpo');
    });

    test('un H2 non è un titolo di primo livello', () {
      final parsed = parseNoteFile('## Sezione\ncorpo', 'Altro.md');
      expect(parsed.title, 'Altro');
      expect(parsed.content, '## Sezione\ncorpo');
    });

    test('l\'eco del titolo conserva i caratteri illegali nei nomi di file', () {
      const title = 'Capitolo 1/2: "Intro"';
      final exported = noteMarkdownContent(title, 'corpo');
      final fileName = '${sanitizeFileName(title)}.md'; // Capitolo 1_2_ _Intro_.md

      final parsed = parseNoteFile(exported, fileName);

      expect(parsed.title, title);
      expect(parsed.content, 'corpo');
    });

    test('il suffisso " (n)" delle collisioni non altera il titolo', () {
      for (final fileName in ['Riunione (2).md', 'riunione (3).md', 'Riunione (12).md']) {
        final parsed = parseNoteFile('# Riunione\n\nx', fileName);
        expect(parsed.title, 'Riunione', reason: fileName);
        expect(parsed.content, 'x', reason: fileName);
      }
    });

    test('una parentesi che non è un contatore fa parte del titolo', () {
      final parsed = parseNoteFile('# Riunione\n\nx', 'Riunione (bozza).md');
      expect(parsed.title, 'Riunione (bozza)');
      expect(parsed.content, '# Riunione\n\nx');
    });

    test('il confronto con il nome del file ignora le maiuscole', () {
      final parsed = parseNoteFile('# Riunione\n\nx', 'riunione.md');
      expect(parsed.title, 'Riunione');
      expect(parsed.content, 'x');
    });

    test('nome segnaposto (nota senza titolo): vale l\'H1', () {
      for (final fileName in [
        'Nota_ab12cd.md',
        'Nota_AB12CD.md',
        'Nota_ab12cd (2).md',
        'Nota_senza_titolo.md',
        'untitled.md',
        'Untitled.md',
      ]) {
        final parsed = parseNoteFile('# Titolo vero\n\ncorpo', fileName);
        expect(parsed.title, 'Titolo vero', reason: fileName);
        expect(parsed.content, 'corpo', reason: fileName);
      }
    });

    test('un titolo utente simile a un segnaposto non lo è', () {
      for (final fileName in ['Nota_1.md', 'Nota_10.md', 'Nota_abc.md', 'Nota_ab12cdef.md']) {
        final parsed = parseNoteFile('# Altro\n\ncorpo', fileName);
        expect(parsed.title, fileName.replaceAll('.md', ''), reason: fileName);
        expect(parsed.content, '# Altro\n\ncorpo', reason: fileName);
      }
    });

    test('estensioni .txt e .markdown (anche maiuscole) escono dal titolo', () {
      expect(parseNoteFile('x', 'Appunti.txt').title, 'Appunti');
      expect(parseNoteFile('x', 'Doc.MARKDOWN').title, 'Doc');
      expect(parseNoteFile('x', 'Lista.1.md').title, 'Lista.1');
      expect(parseNoteFile('x', 'Appunti.md.md').title, 'Appunti.md');
    });

    test('nome file vuoto → titolo di ripiego', () {
      expect(parseNoteFile('x', '.md').title, 'Nota importata');
      expect(parseNoteFile('x', '   .txt').title, 'Nota importata');
    });
  });

  group('parseNoteFile: corpo e formati', () {
    test('righe vuote prima dell\'H1 e una sola riga vuota dopo vengono assorbite', () {
      final parsed = parseNoteFile('\n\n# Titolo\n\ncorpo', 'Titolo.md');
      expect(parsed.title, 'Titolo');
      expect(parsed.content, 'corpo');
    });

    test('dopo l\'H1 si assorbe UNA sola riga vuota: le altre sono del testo', () {
      final parsed = parseNoteFile('# T\n\n\ncorpo', 'T.md');
      expect(parsed.content, '\ncorpo');
    });

    test('H1 rientrato', () {
      final parsed = parseNoteFile('  # Titolo\ncorpo', 'Titolo.md');
      expect(parsed.title, 'Titolo');
      expect(parsed.content, 'corpo');
    });

    test('file con il solo H1', () {
      final parsed = parseNoteFile('# Titolo', 'Titolo.md');
      expect(parsed.title, 'Titolo');
      expect(parsed.content, '');
    });

    test('H1 vuoto: titolo dal nome del file, riga assorbita', () {
      final parsed = parseNoteFile('# \n\ncorpo', 'Nota.md');
      expect(parsed.title, 'Nota');
      expect(parsed.content, 'corpo');
    });

    test('BOM UTF-8 e CRLF (Blocco Note di Windows) vengono normalizzati', () {
      final parsed = parseNoteFile('\uFEFF# Titolo\r\n\r\ncorpo\r\nseconda', 'Titolo.md');
      expect(parsed.title, 'Titolo');
      expect(parsed.content, 'corpo\nseconda');
    });

    test('BOM e CRLF anche senza H1', () {
      final parsed = parseNoteFile('\uFEFFa\r\nb\rc', 'N.md');
      expect(parsed.title, 'N');
      expect(parsed.content, 'a\nb\nc');
    });

    test('normalizeImportedText non tocca testo già pulito', () {
      expect(normalizeImportedText('a\nb'), 'a\nb');
      expect(normalizeImportedText(''), '');
    });
  });
}
