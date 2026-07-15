@TestOn('vm')
@Tags(['interop'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_sevenz/koni_sevenz.dart';
import 'package:test/test.dart';

/// Interop is the definition of done (per doc/writing-scope.md): the
/// reference `7zz` must validate and extract what we wrote, byte-for-byte —
/// the check that our container (signature header, pack/unpack info,
/// per-folder CRCs, FilesInfo) and our Deflate/Copy folders are standard.
/// Skipped (marked) when `7zz` is absent, so public CI stays green.
void main() {
  final sevenZip = _find('7zz');

  Future<Uint8List> build(ArchiveWriteOptions options) async {
    final sink = BytesBuilderSink();
    final writer = const SevenZWriteFormat().openWriter(sink, options);
    await writer.addEntry(
      ArchiveEntrySpec(path: 'dir', type: ArchiveEntryType.directory),
    );
    await writer.addBytes(
      ArchiveEntrySpec(path: 'hello.txt'),
      Uint8List.fromList(utf8.encode('hello, 7z writer!\n')),
    );
    await writer.addBytes(
      ArchiveEntrySpec(path: 'dir/data.txt'),
      Uint8List.fromList(utf8.encode('deflate me ' * 400)),
    );
    await writer.addBytes(
      ArchiveEntrySpec(path: 'raw.bin', compression: ArchiveCompression.stored),
      Uint8List.fromList(List.generate(4000, (i) => (i * 13 + 5) & 0xFF)),
    );
    await writer.addBytes(ArchiveEntrySpec(path: 'empty.txt'), Uint8List(0));
    await writer.addBytes(
      ArchiveEntrySpec(path: '日本語/ページ.txt'),
      Uint8List.fromList(utf8.encode('unicode page\n')),
    );
    await writer.addEntry(
      ArchiveEntrySpec(
        path: 'latest',
        type: ArchiveEntryType.symlink,
        linkTarget: 'dir/data.txt',
      ),
    );
    await writer.close();
    await sink.close();
    return sink.takeBytes();
  }

  test('7zz t validates a koni_sevenz archive (lzma2 default + copy)', () async {
    if (sevenZip == null) {
      markTestSkipped('no `7zz` on PATH; interop check skipped');
      return;
    }
    final archive = await build(const ArchiveWriteOptions());
    final dir = Directory.systemTemp.createTempSync('koni_7z_interop');
    try {
      final path = '${dir.path}/out.7z';
      File(path).writeAsBytesSync(archive);
      final result = await Process.run(
        sevenZip,
        ['t', path],
        stdoutEncoding: latin1,
        stderrEncoding: latin1,
      );
      expect(
        result.exitCode,
        0,
        reason: '7zz t failed: ${result.stdout}\n${result.stderr}',
      );
      expect(result.stdout, contains('Everything is Ok'));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('7zz validates a many-entry archive (multi-byte 7z numbers)', () async {
    if (sevenZip == null) {
      markTestSkipped('no `7zz` on PATH; interop check skipped');
      return;
    }
    // Self-round-trip can't validate our `number()` encoder: the reader's
    // `readSevenZipNumber` is its exact inverse, so a systematic bug cancels
    // out. ~300 entries push numFolders/numFiles and the pack-size list into
    // multi-byte 7z numbers, verified by the reference tool.
    final sink = BytesBuilderSink();
    final writer = const SevenZWriteFormat().openWriter(
      sink,
      const ArchiveWriteOptions(),
    );
    for (var i = 0; i < 300; i++) {
      await writer.addBytes(
        ArchiveEntrySpec(path: 'e$i.txt'),
        Uint8List.fromList(utf8.encode('entry number $i\n')),
      );
    }
    await writer.close();
    await sink.close();

    final dir = Directory.systemTemp.createTempSync('koni_7z_many');
    try {
      final path = '${dir.path}/many.7z';
      File(path).writeAsBytesSync(sink.takeBytes());
      final result = await Process.run(
        sevenZip,
        ['t', path],
        stdoutEncoding: latin1,
        stderrEncoding: latin1,
      );
      expect(
        result.exitCode,
        0,
        reason: '7zz t failed: ${result.stdout}\n${result.stderr}',
      );
      expect(result.stdout, contains('Everything is Ok'));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('7zz extracts our entries byte-for-byte', () async {
    if (sevenZip == null) {
      markTestSkipped('no `7zz` on PATH; interop check skipped');
      return;
    }
    final expected = <String, Uint8List>{
      'hello.txt': Uint8List.fromList(utf8.encode('hello, 7z writer!\n')),
      'dir/data.txt': Uint8List.fromList(utf8.encode('deflate me ' * 400)),
      'raw.bin': Uint8List.fromList(
        List.generate(4000, (i) => (i * 13 + 5) & 0xFF),
      ),
      'empty.txt': Uint8List(0),
      '日本語/ページ.txt': Uint8List.fromList(utf8.encode('unicode page\n')),
    };
    final archive = await build(const ArchiveWriteOptions());
    final dir = Directory.systemTemp.createTempSync('koni_7z_extract');
    try {
      final path = '${dir.path}/out.7z';
      File(path).writeAsBytesSync(archive);
      final out = Directory('${dir.path}/x')..createSync();
      final result = await Process.run(
        sevenZip,
        ['x', path, '-o${out.path}', '-y', '-snl'], // -snl: restore symlinks
        stdoutEncoding: latin1,
        stderrEncoding: latin1,
      );
      expect(
        result.exitCode,
        0,
        reason: '7zz x failed: ${result.stdout}\n${result.stderr}',
      );
      for (final MapEntry(key: p, value: content) in expected.entries) {
        final file = File('${out.path}/$p');
        expect(file.existsSync(), isTrue, reason: 'missing $p');
        expect(file.readAsBytesSync(), content, reason: 'content of $p');
      }
      // The directory entry must extract as a directory.
      expect(Directory('${out.path}/dir').existsSync(), isTrue);
      // The symlink must be restored as a link to its target.
      final link = Link('${out.path}/latest');
      expect(link.existsSync(), isTrue, reason: 'symlink not restored');
      expect(link.targetSync(), 'dir/data.txt');
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('7zz extracts every coder, incl. multi-chunk + fallback LZMA2', () async {
    if (sevenZip == null) {
      markTestSkipped('no `7zz` on PATH; interop check skipped');
      return;
    }
    final random = Random(17);
    // > 2 MiB compressible: several full-size LZMA2 chunks. Noise segments
    // force uncompressed-chunk fallbacks and state resets mid-stream.
    final big = BytesBuilder(copy: false);
    for (var i = 0; i < 8; i++) {
      big.add(utf8.encode('panel $i of a very repetitive comic page. ' * 8000));
      big.add(List.generate(40000, (_) => random.nextInt(256)));
    }
    final expected = <String, (ArchiveCompression?, Uint8List)>{
      'big.dat': (null, big.takeBytes()), // lzma2 default
      'classic.bin': (
        ArchiveCompression.lzma,
        Uint8List.fromList(utf8.encode('lzma1 folder ' * 5000)),
      ),
      'flate.txt': (
        ArchiveCompression.deflate,
        Uint8List.fromList(utf8.encode('deflate folder ' * 2000)),
      ),
      'stored.raw': (
        ArchiveCompression.stored,
        Uint8List.fromList(List.generate(5000, (i) => (i * 31) & 0xFF)),
      ),
    };

    final sink = BytesBuilderSink();
    final writer = const SevenZWriteFormat().openWriter(
      sink,
      const ArchiveWriteOptions(),
    );
    for (final MapEntry(key: path, value: (method, content))
        in expected.entries) {
      await writer.addBytes(
        ArchiveEntrySpec(path: path, compression: method),
        content,
      );
    }
    await writer.close();
    await sink.close();

    final dir = Directory.systemTemp.createTempSync('koni_7z_coders');
    try {
      final path = '${dir.path}/coders.7z';
      File(path).writeAsBytesSync(sink.takeBytes());
      final out = Directory('${dir.path}/x')..createSync();
      final result = await Process.run(
        sevenZip,
        ['x', path, '-o${out.path}', '-y'],
        stdoutEncoding: latin1,
        stderrEncoding: latin1,
      );
      expect(
        result.exitCode,
        0,
        reason: '7zz x failed: ${result.stdout}\n${result.stderr}',
      );
      for (final MapEntry(key: p, value: (_, content)) in expected.entries) {
        expect(
          File('${out.path}/$p').readAsBytesSync(),
          content,
          reason: 'content of $p',
        );
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}

String? _find(String name) {
  for (final candidate in [
    '/opt/homebrew/bin/$name',
    '/usr/local/bin/$name',
    '/usr/bin/$name',
    name,
  ]) {
    try {
      final r = Process.runSync(candidate, ['--help']);
      if (r.exitCode == 0 || r.exitCode == 1) return candidate;
    } on ProcessException {
      continue;
    }
  }
  return null;
}
