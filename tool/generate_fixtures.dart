// Generates committed test fixture archives using locally installed
// reference tools (zip, tar, 7zz, rar, gzip, …).
//
// Policy: fixtures are produced by reference tools on the
// owner's machine and committed; CI never needs the tools, only the committed
// archives. Each run records the version of every tool used in a
// `fixtures_manifest.json` next to the generated fixtures, so provenance is
// always reproducible.
//
// Usage:
//   dart run tool/generate_fixtures.dart [--only <set-id>,<set-id>]
//
// Fixture sets are registered in [fixtureSets]; each format milestone adds
// its own set (M2: tar, M3/M5: zip, M4: gzip, M8: 7z, M9/M10: rar, including
// the synthetic CBZ/CBR/CB7 fixtures with dummy page images).

import 'dart:async';
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
  XzFixtureSet(),
  Bzip2FixtureSet(),
  ZstdFixtureSet(),
  SevenZFixtureSet(),
  RarFixtureSet(),
];

/// RAR fixtures (M9/M10): RAR5 store/compressed/solid, encrypted, RAR4,
/// and a synthetic CBR comic. Uses the proprietary `rar` tool.
final class RarFixtureSet implements FixtureSet {
  @override
  String get id => 'rar';

  @override
  String get package => 'koni_rar';

  @override
  List<String> get requiredTools => ['rar'];

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

      file('hello.txt', 'hello, rar!\n'.codeUnits);
      file('empty.txt', const []);
      file(
        'nested/deep/data.bin',
        List.generate(100000, (i) => ((i * 7) ^ (i >> 3)) & 0xFF),
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
        '-t', '202001020304.05', ...all, '.', //
      ], cwd: root);

      Future<void> rarUp(
        String name,
        List<String> args,
        List<String> members,
      ) => TarFixtureSet._run('rar', [
        'a', '-y', '-r0', '-ol', ...args, '$out/$name', ...members, //
      ], cwd: root);

      const basicMembers = ['hello.txt', 'empty.txt', 'nested', '日本語'];
      await rarUp('store.rar', ['-m0'], basicMembers);
      await rarUp('normal.rar', ['-m3'], basicMembers);
      await rarUp('best_solid.rar', ['-m5', '-s'], basicMembers);
      // RAR5 file decryption (P3-4): store, compressed, and solid variants.
      await rarUp('encrypted.rar', ['-m0', '-psecret'], ['hello.txt']);
      await rarUp('encrypted_compressed.rar', [
        '-m3',
        '-psecret',
      ], basicMembers);
      await rarUp('encrypted_solid.rar', [
        '-m5',
        '-s',
        '-psecret',
      ], basicMembers);
      // Encrypted-header (-hp) archives: header decryption is a documented
      // deferral (doc/notes.md), so this stays a typed-error fixture.
      await rarUp('encrypted_headers.rar', ['-m0', '-hpsecret'], ['hello.txt']);
      // NOTE: the encrypted RAR4 fixtures (enc_rar4*.rar, P3-5) are NOT
      // generated here; rar 7.x removed -ma4 and cannot author v4. They
      // were authored once with rar 6.24 and committed as static fixtures
      // (see koni_rar/doc/notes.md). v4 *detection* is covered synthetically.
      await rarUp('synthetic_comic.cbr', ['-m3'], ['comic']);
    } finally {
      staging.deleteSync(recursive: true);
    }
  }
}

/// 7z fixtures (M8): codec/filter matrix, solid + non-solid blocks,
/// encrypted and deferred-codec archives, and a synthetic CB7 comic.
final class SevenZFixtureSet implements FixtureSet {
  @override
  String get id => 'sevenz';

  @override
  String get package => 'koni_sevenz';

  @override
  List<String> get requiredTools => ['7zz'];

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

      file('hello.txt', 'hello, 7z!\n'.codeUnits);
      file('empty.txt', const []);
      file(
        'nested/deep/data.bin',
        List.generate(100000, (i) => ((i * 7) ^ (i >> 3)) & 0xFF),
      );
      file('日本語/ページ001.txt', 'unicode page\n'.codeUnits);
      // Synthetic x86-ish payload so the BCJ filter has calls to convert.
      final code = <int>[];
      var seed = 12345;
      while (code.length < 50000) {
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
        if (seed % 7 == 0) {
          code.addAll([
            0xE8,
            seed & 0xFF,
            (seed >> 8) & 0xFF,
            (seed >> 16) & 0x0F,
            0x00,
          ]);
        } else {
          code.add(seed & 0xFF);
        }
      }
      file('program.bin', code);
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
        '-t', '202001020304.05', ...all, '.', //
      ], cwd: root);

      Future<void> sevenZip(
        String name,
        List<String> args,
        List<String> members,
      ) => TarFixtureSet._run('7zz', [
        'a', '-y', '-stl', // -stl: archive mtime from newest file
        ...args,
        '$out/$name',
        ...members,
      ], cwd: root);

      const basicMembers = ['hello.txt', 'empty.txt', 'nested', '日本語'];
      // Default (LZMA2, solid).
      await sevenZip('lzma2_solid.7z', ['-m0=LZMA2', '-ms=on'], basicMembers);
      await sevenZip('lzma2_nonsolid.7z', [
        '-m0=LZMA2',
        '-ms=off',
      ], basicMembers);
      await sevenZip('lzma1.7z', ['-m0=LZMA'], basicMembers);
      await sevenZip('copy.7z', ['-m0=Copy'], basicMembers);
      await sevenZip('deflate.7z', ['-m0=Deflate'], basicMembers);
      await sevenZip('bzip2.7z', ['-m0=BZip2'], basicMembers);
      await sevenZip(
        'bcj_lzma2.7z',
        [
          '-m0=BCJ', '-m1=LZMA2', //
        ],
        ['program.bin'],
      );
      await sevenZip(
        'delta_lzma2.7z',
        [
          '-m0=Delta:4', '-m1=LZMA2', //
        ],
        ['nested/deep/data.bin'],
      );
      // Deferred codecs -> typed errors.
      await sevenZip('ppmd.7z', ['-m0=PPMd'], ['hello.txt']);
      await sevenZip(
        'bcj2.7z',
        ['-m0=BCJ2', '-m1=LZMA2', '-m2=LZMA', '-m3=LZMA'],
        ['program.bin'],
      );
      // AES-256 decryption (P3-3). encrypted.7z = AES→LZMA2 single file;
      // encrypted_solid = AES→LZMA2 solid, multiple substreams;
      // encrypted_copy = AES over a Copy folder (the AES-only peel path);
      // encrypted_header(+_solid) = encrypted headers (password at open).
      await sevenZip('encrypted.7z', ['-psecret'], ['hello.txt']);
      await sevenZip('encrypted_solid.7z', [
        '-psecret',
        '-ms=on',
      ], basicMembers);
      await sevenZip(
        'encrypted_copy.7z',
        ['-psecret', '-mm=Copy'],
        ['hello.txt'],
      );
      await sevenZip(
        'encrypted_header.7z',
        ['-psecret', '-mhe=on'],
        ['hello.txt'],
      );
      await sevenZip('encrypted_header_solid.7z', [
        '-psecret',
        '-mhe=on',
        '-ms=on',
      ], basicMembers);
      // CB7 comic (solid LZMA2), the flagship shape.
      await TarFixtureSet._run('7zz', [
        'a',
        '-y',
        '-m0=LZMA2',
        '-ms=on',
        '$out/synthetic_comic.cb7',
        'comic',
      ], cwd: root);
    } finally {
      staging.deleteSync(recursive: true);
    }
  }
}

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

/// XZ fixtures: the four integrity checks (none/CRC32/CRC64/SHA-256), a delta
/// filter, an x86 BCJ filter, a multi-block file (`-T0 --block-size`), a
/// concatenation of two streams, and a layered `.tar.xz`. Plaintext sources are
/// copied alongside so the test can compare byte-for-byte. Uses `xz` (+ `tar`).
final class XzFixtureSet implements FixtureSet {
  @override
  String get id => 'xz';

  @override
  String get package => 'koni_xz';

  @override
  List<String> get requiredTools => ['xz', 'tar'];

  /// `Hello, xz world!\n` repeated (small, all-checks sample).
  static List<int> get _helloText => ('Hello, xz world!\n' * 4).codeUnits;

  /// Compressible natural-ish text, big enough to split into blocks.
  static List<int> get _proseText =>
      ('the quick brown fox jumps over the lazy dog. ' * 1000).codeUnits;

  /// A byte ramp: ideal for the delta filter.
  static List<int> get _ramp =>
      List<int>.generate(20000, (i) => (i * 7) & 0xFF);

  @override
  Future<void> generate(Directory outDir) async {
    final staging = Directory.systemTemp.createTempSync('koni_archive_fx');
    try {
      final root = staging.path;
      final out = outDir.absolute.path;

      File('$root/hello.txt').writeAsBytesSync(_helloText);
      File('$root/prose.bin').writeAsBytesSync(_proseText);
      File('$root/ramp.bin').writeAsBytesSync(_ramp);
      // Plaintext sources committed too, so the test compares against them.
      File('$root/hello.txt').copySync('$out/hello.txt');
      File('$root/prose.bin').copySync('$out/prose.bin');
      File('$root/ramp.bin').copySync('$out/ramp.bin');

      Future<void> xz(List<String> args, String src, String dst) async {
        await TarFixtureSet._run(
          'xz',
          ['-k', '-c', ...args, src],
          cwd: root,
          stdoutPath: '$out/$dst',
        );
      }

      // The four integrity checks over the same small text.
      await xz(['-C', 'crc64'], 'hello.txt', 'hello_crc64.xz');
      await xz(['-C', 'crc32'], 'hello.txt', 'hello_crc32.xz');
      await xz(['-C', 'sha256'], 'hello.txt', 'hello_sha256.xz');
      await xz(['-C', 'none'], 'hello.txt', 'hello_none.xz');

      // Delta filter (distance 1) + LZMA2, over the ramp.
      await xz(
        ['--delta=dist=1', '--lzma2=preset=6'],
        'ramp.bin',
        'ramp_delta.xz',
      );

      // x86 BCJ filter + LZMA2, over the prose.
      await xz(['--x86', '--lzma2=preset=6'], 'prose.bin', 'prose_bcj.xz');

      // A non-x86 BCJ (ARM): the reader must reject this with a typed error,
      // so it is a committed negative fixture.
      await xz(['--arm', '--lzma2=preset=6'], 'prose.bin', 'prose_arm.xz');

      // Multi-block: force >1 block with a small block size.
      await xz(
        ['-T0', '--block-size=16384'],
        'prose.bin',
        'prose_multiblock.xz',
      );

      // Multi-block *with* the x86 BCJ filter: proves the BCJ start offset
      // resets per block (each block is independent).
      await xz(
        ['--x86', '--lzma2=preset=6', '-T0', '--block-size=16384'],
        'prose.bin',
        'prose_bcj_multiblock.xz',
      );

      // A two-transform chain (delta then x86): exercises the reverse-apply
      // loop with more than one non-final filter.
      await xz(
        ['--delta=dist=1', '--x86', '--lzma2=preset=6'],
        'ramp.bin',
        'ramp_delta_x86.xz',
      );

      // Empty input: a zero-record index and a zero-block stream.
      File('$root/empty.bin').writeAsBytesSync(const <int>[]);
      await xz(const [], 'empty.bin', 'empty.xz');

      // Concatenation of two independent streams (decodes to hello.txt twice).
      File('$out/two_stream.xz').writeAsBytesSync([
        ...File('$out/hello_crc64.xz').readAsBytesSync(),
        ...File('$out/hello_crc32.xz').readAsBytesSync(),
      ]);

      // Layered .tar.xz (sniffs as the inner TAR).
      await TarFixtureSet._run('tar', [
        '-c',
        '--format',
        'ustar',
        '-f',
        'sample.tar',
        '--',
        'hello.txt',
        'prose.bin',
      ], cwd: root);
      await xz(['-6'], 'sample.tar', 'sample.tar.xz');
    } finally {
      staging.deleteSync(recursive: true);
    }
  }
}

/// BZip2 fixtures: a single-entry `.bz2` and a layered `.tar.bz2`, plus the
/// plaintext sources for byte-for-byte comparison. Uses `bzip2` (+ `tar`).
final class Bzip2FixtureSet implements FixtureSet {
  @override
  String get id => 'bzip2';

  @override
  String get package => 'koni_bzip2';

  @override
  List<String> get requiredTools => ['bzip2', 'tar'];

  static List<int> get _helloText => ('hello, bzip2!\n' * 4).codeUnits;

  static List<int> get _proseText =>
      ('the quick brown fox jumps over the lazy dog. ' * 2000).codeUnits;

  @override
  Future<void> generate(Directory outDir) async {
    final staging = Directory.systemTemp.createTempSync('koni_archive_fx');
    try {
      final root = staging.path;
      final out = outDir.absolute.path;

      File('$root/hello.txt').writeAsBytesSync(_helloText);
      File('$root/prose.bin').writeAsBytesSync(_proseText);
      File('$root/hello.txt').copySync('$out/hello.txt');
      File('$root/prose.bin').copySync('$out/prose.bin');

      Future<void> bz(String src, String dst) => TarFixtureSet._run(
        'bzip2',
        ['-9', '-c', src],
        cwd: root,
        stdoutPath: '$out/$dst',
      );

      await bz('hello.txt', 'hello.bz2');

      await TarFixtureSet._run('tar', [
        '-c',
        '--format',
        'ustar',
        '-f',
        'sample.tar',
        '--',
        'hello.txt',
        'prose.bin',
      ], cwd: root);
      await bz('sample.tar', 'sample.tar.bz2');
    } finally {
      staging.deleteSync(recursive: true);
    }
  }
}

/// Zstandard fixtures: a single-entry `.zst` and a layered `.tar.zst`, plus the
/// plaintext sources. Uses `zstd` (+ `tar`).
final class ZstdFixtureSet implements FixtureSet {
  @override
  String get id => 'zstd';

  @override
  String get package => 'koni_zstd';

  @override
  List<String> get requiredTools => ['zstd', 'tar'];

  static List<int> get _helloText => ('hello, zstd!\n' * 4).codeUnits;

  static List<int> get _proseText =>
      ('the quick brown fox jumps over the lazy dog. ' * 2000).codeUnits;

  @override
  Future<void> generate(Directory outDir) async {
    final staging = Directory.systemTemp.createTempSync('koni_archive_fx');
    try {
      final root = staging.path;
      final out = outDir.absolute.path;

      File('$root/hello.txt').writeAsBytesSync(_helloText);
      File('$root/prose.bin').writeAsBytesSync(_proseText);
      File('$root/hello.txt').copySync('$out/hello.txt');
      File('$root/prose.bin').copySync('$out/prose.bin');

      Future<void> zst(String src, String dst) => TarFixtureSet._run(
        'zstd',
        ['-q', '-19', '--check', '-c', src],
        cwd: root,
        stdoutPath: '$out/$dst',
      );

      await zst('hello.txt', 'hello.zst');

      await TarFixtureSet._run('tar', [
        '-c',
        '--format',
        'ustar',
        '-f',
        'sample.tar',
        '--',
        'hello.txt',
        'prose.bin',
      ], cwd: root);
      await zst('sample.tar', 'sample.tar.zst');
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
  List<String> get requiredTools => ['zip', '7zz'];

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
      // Traditional PKWARE ("zipcrypto"): the original stored fixture plus
      // a deflated multi-file one exercising the decrypt→inflate path.
      await zipUp('encrypted.zip', ['-0', '-P', 'secret'], ['hello.txt']);
      await zipUp(
        'encrypted_zipcrypto_deflate.zip',
        ['-9', '-P', 'secret'],
        ['hello.txt', 'nested/deep/data.bin'],
      );

      // WinZip AES (method 99): Info-ZIP zip(1) cannot author these, so
      // 7zz does. It writes AE-2 (HMAC-authenticated, CRC field zeroed);
      // the AE-1 CRC-verify branch is covered by an in-test byte patch.
      Future<void> sevenZipAes(
        String name,
        List<String> args,
        List<String> members,
      ) => TarFixtureSet._run('7zz', [
        'a', '-y', '-tzip', '-psecret', //
        ...args,
        '$out/$name',
        ...members,
      ], cwd: root);
      await sevenZipAes(
        'encrypted_aes256.zip',
        ['-mem=AES256'],
        ['hello.txt', 'nested/deep/data.bin'],
      );
      await sevenZipAes('encrypted_aes128.zip', ['-mem=AES128'], ['hello.txt']);
      await sevenZipAes(
        'encrypted_aes256_stored.zip',
        ['-mm=Copy', '-mem=AES256'],
        ['hello.txt'],
      );
      // A bzip2-compressed (method 12) ZIP; Info-ZIP `zip` here isn't built
      // with bzip2, so 7zz authors it.
      await TarFixtureSet._run('7zz', [
        'a', '-y', '-tzip', '-mm=BZip2', //
        '$out/bzip2.zip',
        'hello.txt',
        'nested/deep/data.bin',
      ], cwd: root);
      const comicMembers = [
        'comic/',
        'comic/ComicInfo.xml',
        'comic/page001.png',
        'comic/page002.png',
        'comic/page003.png',
      ];
      await zipUp('synthetic_comic.cbz', ['-0'], comicMembers);
      await zipUp('synthetic_comic_deflated.cbz', ['-9'], comicMembers);

      // Archive comment pushes the EOCD away from EOF.
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

      // The canonical 22-byte empty archive (spec-defined EOCD only;
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
    String? stdoutPath,
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
    if (stdoutPath != null) {
      final sink = File(stdoutPath).openWrite();
      await process.stdout.pipe(sink);
    } else {
      await process.stdout.drain<void>();
    }
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
  'xz': ['xz', '--version'],
  'bzip2': ['bzip2', '--help'],
  'zstd': ['zstd', '--version'],
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
      // Timeout guard: a Gatekeeper-blocked binary hangs at exec forever.
      final probe = await Process.run(
        cmd.first,
        cmd.skip(1).toList(),
      ).timeout(const Duration(seconds: 30));
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
    } on TimeoutException {
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
