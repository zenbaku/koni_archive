// Generates per-archive conformance manifests from the owner-provided
// real-world corpus.
//
// The corpus contains copyrighted archives and is NEVER committed. This
// script runs on the owner's machine, lists and hashes each archive's
// contents with *reference tools* (unzip, tar, 7zz, unrar, never
// koni_archive itself, so the manifests are independent ground truth), and
// writes JSON manifests into koni_archive/test/conformance/manifests/, which
// ARE committed. The conformance runner then decodes the corpus with
// koni_archive and checks it against these manifests.
//
// Usage:
//   dart run tool/generate_conformance_manifests.dart [--corpus <dir>]
//
// The corpus directory defaults to the KONI_ARCHIVE_CORPUS_DIR environment
// variable. Manifest schema: see
// koni_archive/test/conformance/manifests/README.md.
//
// Extractors are registered in [extractors]; each format milestone adds the
// one for its format (zip/cbz at M5, tar/cbt at M2, 7z/cb7 at M8, rar/cbr at
// M9/M10); a manifest is only useful once the runner can decode that format.

import 'dart:convert';
import 'dart:io';

/// Produces manifest data for one archive format using a reference tool.
abstract class ReferenceExtractor {
  /// Archive file extensions this extractor handles, lowercase, with dot
  /// (e.g. `['.zip', '.cbz']`).
  List<String> get extensions;

  /// Writes the manifest for [archive] to [manifestFile].
  Future<void> writeManifest(File archive, File manifestFile);
}

/// Registered reference extractors; format milestones append theirs.
final List<ReferenceExtractor> extractors = [
  ZipReferenceExtractor(),
  RarReferenceExtractor(),
];

/// ZIP/CBZ manifests via CPython's `zipfile` module: an independent
/// reference implementation, never koni_archive itself.
final class ZipReferenceExtractor implements ReferenceExtractor {
  @override
  List<String> get extensions => const ['.zip', '.cbz'];

  static const String _python = r'''
import zipfile, hashlib, json, sys, os
path = sys.argv[1]
z = zipfile.ZipFile(path)
entries = []
for info in z.infolist():
    if info.is_dir():
        continue
    data = z.read(info)
    entries.append({
        'path': info.filename,
        'sizeBytes': len(data),
        'crc32': format(info.CRC & 0xFFFFFFFF, '08x'),
        'sha256': hashlib.sha256(data).hexdigest(),
    })
raw = open(path, 'rb').read()
print(json.dumps({
    'schema': 1,
    'archive': {
        'fileName': os.path.basename(path),
        'sizeBytes': len(raw),
        'sha256': hashlib.sha256(raw).hexdigest(),
        'format': 'zip',
    },
    'tool': {'name': 'cpython-zipfile', 'version': sys.version.split()[0]},
    'entries': entries,
}, indent=1, ensure_ascii=False))
''';

  @override
  Future<void> writeManifest(File archive, File manifestFile) async {
    final result = await Process.run('python3', [
      '-c',
      _python,
      archive.path,
    ], stdoutEncoding: utf8);
    if (result.exitCode != 0) {
      throw ProcessException(
        'python3',
        ['-c', '<zip manifest script>', archive.path],
        'exit ${result.exitCode}: ${result.stderr}',
        result.exitCode,
      );
    }
    manifestFile.writeAsStringSync(result.stdout as String);
  }
}

/// RAR/CBR manifests via `unrar` (an independent reference tool).
/// Delegates to Python for extraction + hashing, mirroring the ZIP path.
final class RarReferenceExtractor implements ReferenceExtractor {
  @override
  List<String> get extensions => const ['.rar', '.cbr'];

  static const String _python = r'''
import subprocess, hashlib, json, sys, os, re
path = sys.argv[1]
listing = subprocess.run(['unrar', 'lt', path], capture_output=True, text=True)
entries = []
name = size = crc = typ = None
def flush():
    global name, size, crc, typ
    if typ == 'File' and name is not None:
        data = subprocess.run(['unrar', 'p', '-inul', path, name],
                              capture_output=True).stdout
        entries.append({
            'path': name,
            'sizeBytes': size if size is not None else len(data),
            'crc32': crc,
            'sha256': hashlib.sha256(data).hexdigest(),
        })
    name = size = crc = typ = None
for line in listing.stdout.splitlines():
    t = line.strip()
    if t.startswith('Name: '):
        flush()
        name = t[6:]
    elif t.startswith('Size: '): size = int(t[6:].strip() or 0)
    elif t.startswith('CRC32: '): crc = t[7:].strip().lower().rjust(8, '0')
    elif t.startswith('Type: '): typ = t[6:].strip()
flush()
raw = open(path, 'rb').read()
ver = subprocess.run(['unrar'], capture_output=True, text=True).stdout.splitlines()[0].strip()
print(json.dumps({
    'schema': 1,
    'archive': {
        'fileName': os.path.basename(path),
        'sizeBytes': len(raw),
        'sha256': hashlib.sha256(raw).hexdigest(),
        'format': 'rar',
    },
    'tool': {'name': 'unrar', 'version': ver},
    'entries': entries,
}, indent=1, ensure_ascii=False))
''';

  @override
  Future<void> writeManifest(File archive, File manifestFile) async {
    final result = await Process.run('python3', [
      '-c',
      _python,
      archive.path,
    ], stdoutEncoding: utf8);
    if (result.exitCode != 0) {
      throw ProcessException(
        'python3',
        ['-c', '<rar manifest script>', archive.path],
        'exit ${result.exitCode}: ${result.stderr}',
        result.exitCode,
      );
    }
    manifestFile.writeAsStringSync(result.stdout as String);
  }
}

const String _corpusEnvVar = 'KONI_ARCHIVE_CORPUS_DIR';
const String _manifestsDir = 'koni_archive/test/conformance/manifests';

Future<void> main(List<String> args) async {
  final corpusPath = _corpusArg(args) ?? Platform.environment[_corpusEnvVar];
  if (corpusPath == null || corpusPath.isEmpty) {
    stderr.writeln(
      'No corpus directory: pass --corpus <dir> or set $_corpusEnvVar.',
    );
    exitCode = 64; // EX_USAGE
    return;
  }
  final corpus = Directory(corpusPath);
  if (!corpus.existsSync()) {
    stderr.writeln('Corpus directory does not exist: $corpusPath');
    exitCode = 66; // EX_NOINPUT
    return;
  }

  final archives =
      corpus
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => _extension(f.path).isNotEmpty)
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  stdout.writeln('Corpus: $corpusPath (${archives.length} archive(s) found)');

  if (extractors.isEmpty) {
    stdout.writeln(
      'No reference extractors are registered yet (M0 scaffolding); '
      'format milestones add them. No manifests written.',
    );
    return;
  }

  var written = 0;
  for (final archive in archives) {
    final ext = _extension(archive.path);
    final extractor =
        extractors.where((e) => e.extensions.contains(ext)).firstOrNull;
    if (extractor == null) {
      stdout.writeln('  skip (no extractor for $ext): ${archive.path}');
      continue;
    }
    final manifestFile = File('$_manifestsDir/${_manifestName(archive)}.json');
    manifestFile.parent.createSync(recursive: true);
    await extractor.writeManifest(archive, manifestFile);
    stdout.writeln('  wrote ${manifestFile.path}');
    written++;
  }
  stdout.writeln('Wrote $written manifest(s) to $_manifestsDir.');
}

String? _corpusArg(List<String> args) {
  final i = args.indexOf('--corpus');
  return (i >= 0 && i + 1 < args.length) ? args[i + 1] : null;
}

/// Known archive extensions, lowercase (compound `.tar.gz` checked first).
const List<String> _knownExtensions = [
  '.tar.gz', '.tgz', '.tar', '.cbt', // tar family
  '.zip', '.cbz', // zip family
  '.gz', // bare gzip
  '.7z', '.cb7', // 7z family
  '.rar', '.cbr', // rar family
];

String _extension(String path) {
  final lower = path.toLowerCase();
  for (final ext in _knownExtensions) {
    if (lower.endsWith(ext)) return ext;
  }
  return '';
}

/// Manifest file name: archive basename, sanitized for portability.
String _manifestName(File archive) {
  final base = archive.uri.pathSegments.last;
  return base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}
