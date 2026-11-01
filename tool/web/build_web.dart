// Build Web/PWA di Scripta.
//
// Uso:
//   dart run tool/web/build_web.dart [--flutter <path>] [--base-href /]
//
// Esegue `flutter build web` con Wasm + fallback dart2js, senza il service
// worker generato da Flutter, poi inietta nel service worker personalizzato
// (web/scripta_sw.js) l'id della build e l'elenco esatto degli asset da
// precaricare. L'output pronto per Cloudflare Pages è build/web.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final options = _parseArguments(arguments);
  final root = _findProjectRoot();
  final flutter = options['flutter'] ??
      Platform.environment['FLUTTER_BIN'] ??
      'flutter';
  final baseHref = options['base-href'] ?? '/';
  final buildId = options['build-id'] ?? _defaultBuildId();

  stdout.writeln('Scripta Web build');
  stdout.writeln('  progetto: ${root.path}');
  stdout.writeln('  flutter:  $flutter');
  stdout.writeln('  base:     $baseHref');
  stdout.writeln('  build id: $buildId');

  final exitCode = await _runFlutterBuild(
    root: root,
    flutter: flutter,
    baseHref: baseHref,
  );
  if (exitCode != 0) {
    stderr.writeln('flutter build web fallita (exit $exitCode).');
    exit(exitCode);
  }

  final buildDir = Directory(p.join(root.path, 'build', 'web'));
  if (!File(p.join(buildDir.path, 'index.html')).existsSync()) {
    stderr.writeln('Build incompleta: manca ${p.join(buildDir.path, 'index.html')}.');
    exit(1);
  }

  // Flutter genera un service worker vuoto anche con --pwa-strategy=none:
  // non deve restare nel deploy per non confondere browser e manutenzione.
  final flutterSw = File(p.join(buildDir.path, 'flutter_service_worker.js'));
  if (flutterSw.existsSync()) {
    flutterSw.deleteSync();
  }

  // Flutter può non copiare i file che iniziano con "_": _headers è
  // indispensabile su Cloudflare Pages, quindi lo copiamo esplicitamente.
  final headers = File(p.join(root.path, 'web', '_headers'));
  if (headers.existsSync()) {
    headers.copySync(p.join(buildDir.path, '_headers'));
  }

  final precache = _collectPrecacheFiles(buildDir);
  if (precache.isEmpty) {
    stderr.writeln('Nessun asset da precaricare: build web vuota?');
    exit(1);
  }

  final encodedPrecache = [
    for (final path in precache) _encodePath(path),
  ];

  final swFile = File(p.join(buildDir.path, 'scripta_sw.js'));
  if (!swFile.existsSync()) {
    stderr.writeln('Manca ${swFile.path}: web/scripta_sw.js non è stato copiato.');
    exit(1);
  }

  var sw = await swFile.readAsString();
  const idMarker = "const BUILD_ID = '__SCRIPT_BUILD_ID__';";
  const precacheMarker = 'const PRECACHE = /* __SCRIPT_PRECACHE__ */ [];';
  if (!sw.contains(idMarker) || !sw.contains(precacheMarker)) {
    stderr.writeln(
      'web/scripta_sw.js non contiene i marker attesi '
      '(BUILD_ID / PRECACHE).',
    );
    exit(1);
  }

  sw = sw.replaceFirst(
    idMarker,
    "const BUILD_ID = '${_escapeSingleQuoted(buildId)}';",
  );
  sw = sw.replaceFirst(
    precacheMarker,
    'const PRECACHE = ${jsonEncode(encodedPrecache)};',
  );
  await swFile.writeAsString(sw);

  final totalBytes = precache.fold<int>(
    0,
    (sum, path) => sum + File(p.join(buildDir.path, path)).lengthSync(),
  );
  stdout.writeln(
    'Precache: ${precache.length} file, '
    '${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MiB.',
  );
  stdout.writeln('Output: ${buildDir.path}');
}

Future<int> _runFlutterBuild({
  required Directory root,
  required String flutter,
  required String baseHref,
}) async {
  final process = await Process.start(
    flutter,
    <String>[
      'build',
      'web',
      '--release',
      '--wasm',
      '--no-web-resources-cdn',
      '--pwa-strategy=none',
      '--base-href',
      baseHref,
    ],
    workingDirectory: root.path,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
  );
  return process.exitCode;
}

/// Asset da precaricare: tutto ciò che serve all'app offline, esclusi
/// sorgenti di debug, mappe, simboli e file di servizio.
List<String> _collectPrecacheFiles(Directory buildDir) {
  final result = <String>[];
  for (final entity in buildDir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final relative = p
        .relative(entity.path, from: buildDir.path)
        .replaceAll(r'\', '/');
    if (_isExcluded(relative)) continue;
    result.add(relative);
  }
  result.sort();
  return result;
}

bool _isExcluded(String path) {
  if (path == 'scripta_sw.js') return true;
  if (path == 'flutter_service_worker.js') return true;
  if (path == '_headers' || path == '_redirects') return true;
  if (path.startsWith('.')) return true;
  if (path.endsWith('.map')) return true;
  if (path.endsWith('.symbols')) return true;
  if (path.endsWith('.dSYM')) return true;
  return false;
}

String _encodePath(String path) {
  return path.split('/').map(Uri.encodeComponent).join('/');
}

String _escapeSingleQuoted(String value) {
  return value
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll('\r', '')
      .replaceAll('\n', r'\n');
}

String _defaultBuildId() {
  final commit = Platform.environment['CF_PAGES_COMMIT_SHA'];
  final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;
  if (commit != null && commit.isNotEmpty) {
    final short = commit.length > 12 ? commit.substring(0, 12) : commit;
    return '$short-$timestamp';
  }
  return 'local-$timestamp';
}

Map<String, String> _parseArguments(List<String> arguments) {
  final result = <String, String>{};
  for (var i = 0; i < arguments.length; i++) {
    final arg = arguments[i];
    if (!arg.startsWith('--')) {
      _usage('Argomento non riconosciuto: $arg');
    }
    final eq = arg.indexOf('=');
    if (eq > 0) {
      result[arg.substring(2, eq)] = arg.substring(eq + 1);
      continue;
    }
    final key = arg.substring(2);
    if (i + 1 >= arguments.length) {
      _usage('Manca il valore per --$key');
    }
    result[key] = arguments[++i];
  }
  const known = {'flutter', 'base-href', 'build-id'};
  for (final key in result.keys) {
    if (!known.contains(key)) _usage('Opzione sconosciuta: --$key');
  }
  return result;
}

Never _usage(String message) {
  stderr.writeln(message);
  stderr.writeln(
    'Uso: dart run tool/web/build_web.dart '
    '[--flutter <path>] [--base-href /] [--build-id <id>]',
  );
  exit(64);
}

Directory _findProjectRoot() {
  var dir = Directory.current;
  while (true) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(dir.path, 'web')).existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      stderr.writeln(
        'Impossibile trovare la root del progetto (pubspec.yaml + web/).',
      );
      exit(1);
    }
    dir = parent;
  }
}
