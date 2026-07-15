// Generates committed test fixture archives using locally installed
// reference tools (zip, tar, 7zz, rar, gzip, …).
//
// Policy (PROMPT_V1.md §11): fixtures are produced by reference tools on the
// owner's machine and committed; CI never needs the tools, only the committed
// archives. Each run records the version of every tool used in a
// `fixtures_manifest.json` next to the generated fixtures, so provenance is
// always reproducible.
//
// Usage:
//   dart run tool/generate_fixtures.dart [--only <set-id>,<set-id>]
//
// Fixture sets are registered in [fixtureSets]; each format milestone adds
// its own set (M2: tar, M3/M5: zip, M4: gzip, M8: 7z, M9/M10: rar — including
// the synthetic CBZ/CBR/CB7 fixtures with dummy page images).

import 'dart:convert';
import 'dart:io';

/// A group of fixture archives generated together for one package.
abstract class FixtureSet {
  /// Stable identifier, used with `--only` (e.g. `tar`, `zip`).
  String get id;

  /// Package directory (relative to the workspace root) the fixtures land in,
  /// under `<package>/test/fixtures/`.
  String get package;

  /// Reference tools this set needs on PATH (e.g. `['tar', 'gzip']`).
  List<String> get requiredTools;

  /// Generates the fixture archives into [outDir] (already created, empty).
  Future<void> generate(Directory outDir);
}

/// Registered fixture sets; format milestones append their sets here. The
/// harness (tool detection, version manifest, output layout) is fixed from
/// M0 so every set records provenance the same way.
final List<FixtureSet> fixtureSets = [
  TarFixtureSet(),
  ZipFixtureSet(),
  GzipFixtureSet(),
];

/// GZIP fixtures (M4): named, anonymous, and multi-member .gz files.
final class GzipFixtureSet implements FixtureSet {
  @override
  String get id => 'gzip';

  @override
  String get package => 'koni_gzip';

  @override
  List<String> get requiredTools => ['gzip'];

  @override
  Future<void> generate(Directory outDir) async {
    final staging = Directory.systemTemp.createTempSync('koni_archive_fx');
    try {
      final root = staging.path;
      final out = outDir.absolute.path;

      File('$root/hello.txt').writeAsBytesSync('hello, gzip!\n'.codeUnits);
      File(
        '$root/second.txt',
      ).writeAsBytesSync('second member content\n'.codeUnits);
      File('$root/data.bin').writeAsBytesSync(
        List.generate(100000, (i) => (i * 7 + i ~/ 1000) & 0xFF),
      );
      await TarFixtureSet._run('touch', [
        '-t',
        '202001020304.05',
        'hello.txt',
        'second.txt',
        'data.bin',
      ], cwd: root);

      // -k keep, -9 best; FNAME + MTIME recorded by default.
      await TarFixtureSet._run('gzip', ['-9', '-k', 'hello.txt'], cwd: root);
      File('$root/hello.txt.gz').copySync('$out/hello.txt.gz');

      // -n: no name, no mtime.
      await TarFixtureSet._run('gzip', [
        '-9',
        '-k',
        '-n',
        'data.bin',
      ], cwd: root);
      File('$root/data.bin.gz').copySync('$out/anonymous.gz');

      // Multi-member: concatenation of two members (RFC 1952 §2.2).
      await TarFixtureSet._run('gzip', ['-9', '-k', 'second.txt'], cwd: root);
      File('$out/multi_member.gz').writeAsBytesSync([
        ...File('$root/hello.txt.gz').readAsBytesSync(),
        ...File('$root/second.txt.gz').readAsBytesSync(),
      ]);

      // Layered .tar.gz (M6): tarball whose decompressed head sniffs as TAR.
      await TarFixtureSet._run('tar', [
        '-c',
        '--format',
        'ustar',
        '-f',
        'tarball.tar',
        '--',
        'hello.txt',
        'second.txt',
        'data.bin',
      ], cwd: root);
      await TarFixtureSet._run('touch', [
        '-t',
        '202001020304.05',
        'tarball.tar',
      ], cwd: root);
      await TarFixtureSet._run('gzip', ['-9', '-k', 'tarball.tar'], cwd: root);
      File('$root/tarball.tar.gz').copySync('$out/tarball.tar.gz');
    } finally {
      staging.deleteSync(recursive: true);
    }
  }
}

/// ZIP fixtures (M3/M5): stored + deflated archives, comments, encrypted
/// entries, self-extracting prefixes, unicode names, and a synthetic CBZ
/// comic with dummy page images.
final class ZipFixtureSet implements FixtureSet {
  @override
  String get id => 'zip';

  @override
  String get package => 'koni_zip';

  @override
  List<String> get requiredTools => ['zip'];

  @override
  Future<void> generate(Directory outDir) async {
    final staging = Directory.systemTemp.createTempSync('koni_archive_fx');
    try {
      final root = staging.path;
      final out = outDir.absolute.path;

      void file(String rel, List<int> bytes) {
        File('$root/$rel')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes);
      }

      file('hello.txt', 'hello, zip!\n'.codeUnits);
      file('empty.txt', const []);
      file(
        'nested/deep/data.bin',
        List.generate(2600, (i) => (i * 7 + 3) & 0xFF),
      );
      file('日本語/ページ001.txt', 'unicode page\n'.codeUnits);
      for (var i = 1; i <= 3; i++) {
        file('comic/page00$i.png', TarFixtureSet._dummyPng(i));
      }
      file(
        'comic/ComicInfo.xml',
        '<ComicInfo><Series>Synthetic</Series></ComicInfo>\n'.codeUnits,
      );

      await TarFixtureSet._run('chmod', ['-R', 'u=rwX,go=rX', '.'], cwd: root);
      final all =
          staging
              .listSync(recursive: true)
              .map((e) => e.path.substring(root.length + 1))
              .toList();
      await TarFixtureSet._run('touch', [
        '-h',
        '-t',
        '202001020304.05',
        ...all,
        '.',
      ], cwd: root);

      Future<void> zipUp(
        String name,
        List<String> args,
        List<String> members,
      ) => TarFixtureSet._run('zip', [
        '-X', // strip platform extras where possible; -0/-9 come via args
        ...args,
        '$out/$name',
        '--',
        ...members,
      ], cwd: root);

      const basicMembers = [
        'hello.txt',
        'empty.txt',
        'nested/',
        'nested/deep/',
        'nested/deep/data.bin',
        '日本語/',
        '日本語/ページ001.txt',
      ];
      await zipUp('stored_basic.zip', ['-0'], basicMembers);
      await zipUp('zip64.zip', ['-0', '-fz'], basicMembers);
      await zipUp('deflated.zip', ['-9'], basicMembers);
      await zipUp('encrypted.zip', ['-0', '-P', 'secret'], ['hello.txt']);
      const comicMembers = [
        'comic/',
        'comic/ComicInfo.xml',
        'comic/page001.png',
        'comic/page002.png',
        'comic/page003.png',
      ];
      await zipUp('synthetic_comic.cbz', ['-0'], comicMembers);
      await zipUp('synthetic_comic_deflated.cbz', ['-9'], comicMembers);

      // Archive comment pushes the EOCD away from EOF (§5).
      await TarFixtureSet._run(
        'zip',
        ['-X', '-0', '-z', '$out/comment.zip', 'hello.txt'],
        cwd: root,
        stdin: 'a comment pushing the EOCD forward\n',
      );

      // Self-extracting-style prefix: junk before the ZIP; offsets keep
      // pointing at the original positions (reader must compute the delta).
      final prefixed = File('$out/prefixed.zip');
      prefixed.writeAsBytesSync([
        ...List.filled(4096, 0x2A), // 4 KiB of '*' stub
        ...File('$out/stored_basic.zip').readAsBytesSync(),
      ]);

      // The canonical 22-byte empty archive (spec-defined EOCD only —
      // Info-ZIP zip(1) refuses to create archives with no members).
      File(
        '$out/empty.zip',
      ).writeAsBytesSync([0x50, 0x4B, 0x05, 0x06, ...List.filled(18, 0)]);
    } finally {
      staging.deleteSync(recursive: true);
    }
  }
}

/// TAR fixtures (M2): ustar/pax/gnu/v7 archives, long + unicode names,
/// symlinks/hardlinks/fifo, duplicates, an empty archive, and a synthetic
/// CBT comic with dummy page images.
final class TarFixtureSet implements FixtureSet {
  @override
  String get id => 'tar';

  @override
  String get package => 'koni_tar';

  @override
  List<String> get requiredTools => ['tar'];

  /// UTC everywhere so `touch -t` timestamps are machine-independent:
  /// 2020-01-02T03:04:05Z = epoch 1577934245 (asserted by tests).
  static const Map<String, String> _env = {
    'TZ': 'UTC',
    'LC_ALL': 'en_US.UTF-8',
    'LANG': 'en_US.UTF-8',
  };

  static final String _longName = '${'L' * 160}.txt';
  static final String _longTarget = 'T' * 150;

  @override
  Future<void> generate(Directory outDir) async {
    final staging = Directory.systemTemp.createTempSync('koni_archive_fx');
    try {
      final root = staging.path;

      // ---- source tree -------------------------------------------------
      void file(String rel, List<int> bytes) {
        File('$root/$rel')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes);
      }

      file('hello.txt', 'hello, tar!\n'.codeUnits);
      file('empty.txt', const []);
      file(
        'nested/deep/data.bin',
        List.generate(2600, (i) => (i * 7 + 3) & 0xFF),
      );
      file('日本語/ページ001.txt', 'unicode page\n'.codeUnits);
      file(_longName, 'long name content\n'.codeUnits);
      Link('$root/link.txt').createSync('hello.txt');
      Link('$root/longlink.txt').createSync(_longTarget);
      await _run('ln', ['hello.txt', 'hard.txt'], cwd: root);
      await _run('mkfifo', ['pipe.fifo'], cwd: root);
      for (var i = 1; i <= 3; i++) {
        file('comic/page00$i.png', _dummyPng(i));
      }
      file(
        'comic/ComicInfo.xml',
        '<ComicInfo><Series>Synthetic</Series></ComicInfo>\n'.codeUnits,
      );

      await _run('chmod', ['-R', 'u=rwX,go=rX', '.'], cwd: root);
      // Deterministic mtimes (TZ=UTC): 202001020304.05.
      final all =
          staging
              .listSync(recursive: true)
              .map((e) => e.path.substring(root.length + 1))
              .toList();
      await _run('touch', [
        '-h',
        '-t',
        '202001020304.05',
        ...all,
        '.',
      ], cwd: root);

      // ---- archives -----------------------------------------------------
      Future<void> tarUp(String name, String format, List<String> members) =>
          _run('tar', [
            '-c',
            '-n', // no auto-recursion: member order is fully explicit
            '--format', format,
            '-f', '${outDir.absolute.path}/$name',
            '--', ...members,
          ], cwd: root);

      const basicMembers = [
        'hello.txt',
        'empty.txt',
        'nested',
        'nested/deep',
        'nested/deep/data.bin',
        '日本語',
        '日本語/ページ001.txt',
        'link.txt',
        'hard.txt',
      ];
      await tarUp('basic_ustar.tar', 'ustar', basicMembers);
      await tarUp('long_paths_pax.tar', 'pax', [
        'hello.txt',
        _longName,
        'longlink.txt',
        '日本語/ページ001.txt',
      ]);
      await tarUp('long_paths_gnu.tar', 'gnutar', [
        'hello.txt',
        _longName,
        'longlink.txt',
      ]);
      await tarUp('v7.tar', 'v7', ['hello.txt', 'empty.txt']);
      await tarUp('special_types.tar', 'pax', ['pipe.fifo', 'hello.txt']);
      await tarUp('synthetic_comic.cbt', 'ustar', [
        'comic',
        'comic/ComicInfo.xml',
        'comic/page001.png',
        'comic/page002.png',
        'comic/page003.png',
      ]);

      // Duplicate path: create, then append the same member again.
      await tarUp('duplicate.tar', 'ustar', ['hello.txt']);
      await _run('tar', [
        '-r',
        '--format',
        'ustar',
        '-f',
        '${outDir.absolute.path}/duplicate.tar',
        'hello.txt',
      ], cwd: root);

      // Empty archive (just end-of-archive blocks).
      await _run('tar', [
        '-c',
        '-f',
        '${outDir.absolute.path}/empty.tar',
        '-T',
        '/dev/null',
      ], cwd: root);
    } finally {
      staging.deleteSync(recursive: true);
    }
  }

  /// Deterministic dummy "page image": PNG signature + patterned filler.
  /// Archive tests treat content as opaque bytes; no image decoder is
  /// involved.
  static List<int> _dummyPng(int seed) => [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    ...List.generate(1024, (i) => (i * seed + 17) & 0xFF),
  ];

  static Future<void> _run(
    String exe,
    List<String> args, {
    String? cwd,
    String? stdin,
  }) async {
    final process = await Process.start(
      exe,
      args,
      workingDirectory: cwd,
      environment: _env,
    );
    if (stdin != null) process.stdin.write(stdin);
    await process.stdin.close();
    final stderrText = await process.stderr.transform(utf8.decoder).join();
    await process.stdout.drain<void>();
    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw ProcessException(
        exe,
        args,
        'exit $exitCode: $stderrText',
        exitCode,
      );
    }
  }
}

/// Reference tools this script knows how to version-stamp.
const Map<String, List<String>> _versionCommands = {
  'zip': ['zip', '-v'],
  'unzip': ['unzip', '-v'],
  'tar': ['tar', '--version'],
  'gzip': ['gzip', '--version'],
  '7zz': ['7zz'],
  'rar': ['rar'],
};

Future<void> main(List<String> args) async {
  final only = _parseOnly(args);
  final tools = await _detectTools();

  stdout.writeln('Reference tools:');
  for (final MapEntry(key: name, value: version) in tools.entries) {
    stdout.writeln('  $name: ${version ?? 'NOT AVAILABLE'}');
  }

  final selected =
      fixtureSets.where((s) => only == null || only.contains(s.id)).toList();
  if (fixtureSets.isEmpty) {
    stdout.writeln(
      '\nNo fixture sets are registered yet (M0 scaffolding); '
      'format milestones add them. Nothing to generate.',
    );
    return;
  }
  if (selected.isEmpty) {
    stderr.writeln(
      '\nNo fixture set matches --only=${only!.join(',')}. '
      'Known sets: ${fixtureSets.map((s) => s.id).join(', ')}',
    );
    exitCode = 1;
    return;
  }

  for (final set in selected) {
    final missing = set.requiredTools.where((t) => tools[t] == null).toList();
    if (missing.isNotEmpty) {
      stderr.writeln(
        'SKIP ${set.id}: missing reference tool(s): ${missing.join(', ')}',
      );
      exitCode = 1;
      continue;
    }
    final outDir = Directory('${set.package}/test/fixtures/${set.id}');
    if (outDir.existsSync()) outDir.deleteSync(recursive: true);
    outDir.createSync(recursive: true);
    stdout.writeln('\nGenerating fixture set "${set.id}" -> ${outDir.path}');
    await set.generate(outDir);
    _writeManifest(outDir, set, tools);
  }
}

Set<String>? _parseOnly(List<String> args) {
  final i = args.indexOf('--only');
  if (i >= 0 && i + 1 < args.length) return args[i + 1].split(',').toSet();
  return null;
}

Future<Map<String, String?>> _detectTools() async {
  final result = <String, String?>{};
  for (final MapEntry(key: name, value: cmd) in _versionCommands.entries) {
    try {
      final probe = await Process.run(cmd.first, cmd.skip(1).toList());
      final lines = '${probe.stdout}\n${probe.stderr}'
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty);
      // First line that looks like it carries a version number (e.g. `zip -v`
      // prints a copyright banner before "This is Zip 3.0 ...").
      result[name] = lines.firstWhere(
        (l) => RegExp(r'\d+\.\d+').hasMatch(l),
        orElse: () => lines.first,
      );
    } on ProcessException {
      result[name] = null;
    }
  }
  return result;
}

void _writeManifest(
  Directory outDir,
  FixtureSet set,
  Map<String, String?> tools,
) {
  final files =
      outDir
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.substring(outDir.path.length + 1))
          .where((p) => p != 'fixtures_manifest.json')
          .toList()
        ..sort();
  final manifest = {
    'schema': 1,
    'set': set.id,
    'tools': {for (final t in set.requiredTools) t: tools[t]},
    'files': files,
  };
  File('${outDir.path}/fixtures_manifest.json').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
  );
}
