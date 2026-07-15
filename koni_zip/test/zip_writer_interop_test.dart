@TestOn('vm')
@Tags(['interop'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_zip/koni_zip.dart';
import 'package:test/test.dart';

/// Interop is the definition of done (per doc/writing.md): the reference
/// `unzip` must validate and extract what we wrote, byte-for-byte — the real
/// check that our deflate stream, data descriptors, and central directory
/// are standard. Skipped (marked) when `unzip` is absent.
void main() {
  final unzip = _find('unzip', ['-v']);

  Future<Uint8List> build(ArchiveWriteOptions options) async {
    final sink = BytesBuilderSink();
    final writer = const ZipWriteFormat().openWriter(sink, options);
    await writer.addEntry(
      ArchiveEntrySpec(path: 'dir', type: ArchiveEntryType.directory),
    );
    await writer.addBytes(
      ArchiveEntrySpec(path: 'hello.txt'),
      Uint8List.fromList(utf8.encode('hello, zip writer!\n')),
    );
    await writer.addBytes(
      ArchiveEntrySpec(path: 'dir/data.txt'),
      Uint8List.fromList(utf8.encode('deflate me ' * 400)),
    );
    await writer.addBytes(
      ArchiveEntrySpec(path: 'raw.bin', compression: ArchiveCompression.stored),
      Uint8List.fromList(List.generate(4000, (i) => (i * 13 + 5) & 0xFF)),
    );
    await writer.addBytes(
      ArchiveEntrySpec(path: '日本語/ページ.txt'),
      Uint8List.fromList(utf8.encode('unicode page\n')),
    );
    await writer.close();
    await sink.close();
    return sink.takeBytes();
  }

  test('unzip -t validates a koni_zip archive (deflate + stored)', () async {
    if (unzip == null) {
      markTestSkipped('no `unzip` on PATH; interop check skipped');
      return;
    }
    final archive = await build(const ArchiveWriteOptions());
    final dir = Directory.systemTemp.createTempSync('koni_zip_interop');
    try {
      final path = '${dir.path}/out.zip';
      File(path).writeAsBytesSync(archive);
      final test = await Process.run(
        unzip,
        ['-t', path],
        stdoutEncoding: latin1,
        stderrEncoding: latin1,
      );
      expect(
        test.exitCode,
        0,
        reason: 'unzip -t failed: ${test.stdout}\n${test.stderr}',
      );
      expect(test.stdout, contains('No errors detected'));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('unzip validates a ZIP64 archive (>0xFFFF entries)', () async {
    if (unzip == null) {
      markTestSkipped('no `unzip` on PATH; interop check skipped');
      return;
    }
    // >0xFFFF entries forces the ZIP64 end-of-central-directory record and
    // locator: the plain EOCD carries 0xFFFF sentinel counts and unzip must
    // consult EOCD64 to find the real central directory. Self-round-trip
    // (zip_writer_test.dart) can't catch a shared reader/writer misreading of
    // the ZIP64 layout — only an external tool can.
    final sink = BytesBuilderSink();
    final writer = const ZipWriteFormat().openWriter(
      sink,
      const ArchiveWriteOptions(compression: ArchiveCompression.stored),
    );
    for (var i = 0; i < 70000; i++) {
      await writer.addBytes(ArchiveEntrySpec(path: 'e$i'), Uint8List(0));
    }
    await writer.close();
    await sink.close();
    final archive = sink.takeBytes();

    final dir = Directory.systemTemp.createTempSync('koni_zip_zip64');
    try {
      final path = '${dir.path}/big.zip';
      File(path).writeAsBytesSync(archive);
      final test = await Process.run(
        unzip,
        ['-t', path],
        stdoutEncoding: latin1,
        stderrEncoding: latin1,
      );
      expect(
        test.exitCode,
        0,
        reason: 'unzip -t failed: ${test.stdout}\n${test.stderr}',
      );
      expect(test.stdout, contains('No errors detected'));
      // unzip tests every entry it finds; seeing the last one proves it read
      // the full central directory *through* the ZIP64 records — a reader that
      // stalled at the 0xFFFF sentinel would stop ~65534 entries in.
      expect(test.stdout, contains('e69999'));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('unzip extracts our entries byte-for-byte', () async {
    if (unzip == null) {
      markTestSkipped('no `unzip` on PATH; interop check skipped');
      return;
    }
    final expected = <String, Uint8List>{
      'hello.txt': Uint8List.fromList(utf8.encode('hello, zip writer!\n')),
      'dir/data.txt': Uint8List.fromList(utf8.encode('deflate me ' * 400)),
      'raw.bin': Uint8List.fromList(
        List.generate(4000, (i) => (i * 13 + 5) & 0xFF),
      ),
      '日本語/ページ.txt': Uint8List.fromList(utf8.encode('unicode page\n')),
    };
    final archive = await build(const ArchiveWriteOptions());
    final dir = Directory.systemTemp.createTempSync('koni_zip_extract');
    try {
      final path = '${dir.path}/out.zip';
      File(path).writeAsBytesSync(archive);
      final out = Directory('${dir.path}/x')..createSync();
      final result = await Process.run(
        unzip,
        ['-o', path, '-d', out.path],
        stdoutEncoding: latin1,
        stderrEncoding: latin1,
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      for (final MapEntry(key: p, value: content) in expected.entries) {
        final file = File('${out.path}/$p');
        expect(file.existsSync(), isTrue, reason: 'missing $p');
        expect(file.readAsBytesSync(), content, reason: 'content of $p');
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  // WinZip AES (AE-2) is the real proof of the encrypted layout: the salt,
  // verifier, CTR keystream, and HMAC tag must be exactly what a standard
  // extractor expects. Info-ZIP `unzip` only does traditional zipcrypto, so
  // the AES check uses `7zz`, which supports WinZip AES; skipped if absent.
  test('7zz decrypts our AES-256 archive byte-for-byte', () async {
    final sevenZip = _find('7zz', ['--help']);
    if (sevenZip == null) {
      markTestSkipped('no `7zz` on PATH; AES interop check skipped');
      return;
    }
    const password = 'corr3ct h0rse';
    final expected = <String, Uint8List>{
      'secret.txt': Uint8List.fromList(utf8.encode('top secret\n')),
      'dir/notes.txt': Uint8List.fromList(utf8.encode('classified ' * 300)),
      'raw.bin': Uint8List.fromList(
        List.generate(4000, (i) => (i * 29 + 3) & 0xFF),
      ),
    };
    final sink = BytesBuilderSink();
    final writer = const ZipWriteFormat().openWriter(
      sink,
      const ArchiveWriteOptions(password: password),
    );
    await writer.addBytes(
      ArchiveEntrySpec(path: 'secret.txt'),
      expected['secret.txt']!,
    );
    await writer.addBytes(
      ArchiveEntrySpec(path: 'dir/notes.txt'),
      expected['dir/notes.txt']!,
    );
    await writer.addBytes(
      ArchiveEntrySpec(path: 'raw.bin', compression: ArchiveCompression.stored),
      expected['raw.bin']!,
    );
    await writer.close();
    await sink.close();
    final archive = sink.takeBytes();

    final dir = Directory.systemTemp.createTempSync('koni_zip_aes');
    try {
      final path = '${dir.path}/enc.zip';
      File(path).writeAsBytesSync(archive);

      // A wrong password must be rejected (proves the verifier/HMAC bind to
      // the key), then the right one extracts byte-for-byte.
      final wrong = await Process.run(
        sevenZip,
        ['t', '-p-nope-', path],
        stdoutEncoding: latin1,
        stderrEncoding: latin1,
      );
      expect(
        wrong.exitCode,
        isNot(0),
        reason: '7zz accepted a wrong password: ${wrong.stdout}',
      );

      final out = Directory('${dir.path}/x')..createSync();
      final result = await Process.run(
        sevenZip,
        ['x', '-y', '-p$password', '-o${out.path}', path],
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
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}

String? _find(String name, List<String> probeArgs) {
  for (final candidate in [
    '/opt/homebrew/bin/$name',
    '/usr/local/bin/$name',
    '/usr/bin/$name',
    '/bin/$name',
    name,
  ]) {
    try {
      Process.runSync(candidate, probeArgs);
      return candidate;
    } on ProcessException {
      continue;
    }
  }
  return null;
}
