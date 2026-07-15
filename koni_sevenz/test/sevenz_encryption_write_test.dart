import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_sevenz/koni_sevenz.dart';
import 'package:test/test.dart';

/// Write-side 7z AES-256 encryption (Phase 4): each entry becomes a
/// `compressor → AES` folder chain. The output must round-trip through our
/// own reader with the password and reject a wrong one. Interop with `7zz`
/// lives in `sevenz_writer_interop_test.dart` (VM-only).

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// Deterministic IV source so an encrypted archive is reproducible in tests.
Uint8List _countingBytes(int length) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 7 + 1) & 0xFF));

Future<Uint8List> writeEncrypted(
  Future<void> Function(ArchiveWriter writer) build, {
  required String password,
  ArchiveCompression? compression,
  Uint8List Function(int)? randomBytes,
}) async {
  final sink = BytesBuilderSink();
  final options = ArchiveWriteOptions(
    password: password,
    compression: compression,
  );
  final writer =
      randomBytes == null
          ? const SevenZWriteFormat().openWriter(sink, options)
          : SevenZWriter(
            const SevenZWriteFormat(),
            sink,
            options,
            randomBytes: randomBytes,
          );
  await build(writer);
  await writer.close();
  await sink.close();
  return sink.takeBytes();
}

Future<Map<String, Uint8List>> readFiles(
  Uint8List archive, {
  String? password,
}) async {
  final reader = await SevenZReader.parse(
    const SevenZFormat(),
    MemoryByteSource(archive),
    ArchiveReadOptions(password: password),
  );
  final result = <String, Uint8List>{};
  for (final entry in reader.entries) {
    if (entry.type == ArchiveEntryType.file) {
      final chunks = await reader.openRead(entry).toList();
      result[entry.path] = Uint8List.fromList(
        chunks.expand<int>((c) => c).toList(),
      );
    }
  }
  return result;
}

void main() {
  const password = 'sésame-🔒-7z';

  group('round-trips through the reader with the password', () {
    test('lzma2 (default) entries decrypt byte-for-byte', () async {
      final big = Uint8List.fromList(utf8.encode('koni sevenz! ' * 500));
      final archive = await writeEncrypted((w) async {
        await w.addBytes(ArchiveEntrySpec(path: 'hello.txt'), _bytes('hi\n'));
        await w.addBytes(ArchiveEntrySpec(path: 'nested/deep/data.txt'), big);
      }, password: password);

      final files = await readFiles(archive, password: password);
      expect(utf8.decode(files['hello.txt']!), 'hi\n');
      expect(files['nested/deep/data.txt'], big);
    });

    test('copy (stored) entries decrypt byte-for-byte', () async {
      final data = Uint8List.fromList(
        List.generate(3000, (i) => (i * 7) & 0xFF),
      );
      final archive = await writeEncrypted(
        (w) async {
          await w.addBytes(ArchiveEntrySpec(path: 'raw.bin'), data);
        },
        password: password,
        compression: ArchiveCompression.stored,
      );
      final files = await readFiles(archive, password: password);
      expect(files['raw.bin'], data);
    });

    test('lzma entries decrypt byte-for-byte', () async {
      final data = Uint8List.fromList(utf8.encode('repeat ' * 800));
      final archive = await writeEncrypted(
        (w) async {
          await w.addBytes(ArchiveEntrySpec(path: 'a.txt'), data);
        },
        password: password,
        compression: ArchiveCompression.lzma,
      );
      final files = await readFiles(archive, password: password);
      expect(files['a.txt'], data);
    });

    test(
      'content whose compressed size is a 16-byte multiple needs no padding',
      () async {
        // Exercises the _padTo16 aligned branch: some payload will land on a
        // block boundary; whatever it is, the round-trip must be exact.
        for (final n in [1, 15, 16, 17, 32, 33, 255]) {
          final data = Uint8List.fromList(List.generate(n, (i) => i & 0xFF));
          final archive = await writeEncrypted((w) async {
            await w.addBytes(
              ArchiveEntrySpec(
                path: 'f.bin',
                compression: ArchiveCompression.stored,
              ),
              data,
            );
          }, password: password);
          final files = await readFiles(archive, password: password);
          expect(files['f.bin'], data, reason: 'n=$n');
        }
      },
    );

    test('mixed entries, dirs, and empty files in one archive', () async {
      // The writer reports a file entry as encrypted; a directory (no folder)
      // is never encrypted.
      late ArchiveEntry pageEntry;
      late ArchiveEntry dirEntry;
      final archive = await writeEncrypted((w) async {
        dirEntry = await w.addEntry(
          ArchiveEntrySpec(path: 'dir', type: ArchiveEntryType.directory),
        );
        pageEntry = await w.addBytes(
          ArchiveEntrySpec(path: 'dir/page.txt'),
          _bytes('encrypted page\n'),
        );
        await w.addBytes(ArchiveEntrySpec(path: 'empty.txt'), Uint8List(0));
        await w.addBytes(
          ArchiveEntrySpec(path: '日本語/ページ.txt'),
          _bytes('unicode\n'),
        );
      }, password: password);
      expect(pageEntry.isEncrypted, isTrue);
      expect(dirEntry.isEncrypted, isFalse);

      final files = await readFiles(archive, password: password);
      expect(utf8.decode(files['dir/page.txt']!), 'encrypted page\n');
      expect(files['empty.txt'], isEmpty);
      expect(utf8.decode(files['日本語/ページ.txt']!), 'unicode\n');
    });
  });

  group('password enforcement', () {
    test('opening an encrypted entry with no password throws', () async {
      final archive = await writeEncrypted((w) async {
        await w.addBytes(ArchiveEntrySpec(path: 'a.txt'), _bytes('secret\n'));
      }, password: password);
      final reader = await SevenZReader.parse(
        const SevenZFormat(),
        MemoryByteSource(archive),
        const ArchiveReadOptions(),
      );
      expect(
        () => reader.openRead(reader.entries.single).toList(),
        throwsA(isA<EncryptedArchiveException>()),
      );
    });

    test(
      'a wrong password surfaces as corrupt data (7z has no verifier)',
      () async {
        // 7z stores no password check value, so a wrong key yields garbage that
        // fails a downstream invariant (CRC mismatch or bad LZMA data). Either
        // way it must be a typed ArchiveException, never silent wrong bytes.
        final data = Uint8List.fromList(utf8.encode('the real content ' * 50));
        final archive = await writeEncrypted((w) async {
          await w.addBytes(ArchiveEntrySpec(path: 'a.txt'), data);
        }, password: password);
        final reader = await SevenZReader.parse(
          const SevenZFormat(),
          MemoryByteSource(archive),
          const ArchiveReadOptions(password: 'wrong-password'),
        );
        expect(
          () => reader.openRead(reader.entries.single).toList(),
          throwsA(isA<ArchiveException>()),
        );
      },
    );
  });

  test('a fixed IV makes the ciphertext reproducible', () async {
    Future<Uint8List> once() => writeEncrypted(
      (w) async {
        await w.addBytes(
          ArchiveEntrySpec(
            path: 'a.txt',
            compression: ArchiveCompression.stored,
          ),
          _bytes('determinism in 7z\n'),
        );
      },
      password: password,
      randomBytes: _countingBytes,
    );
    expect(await once(), await once());
  });
}
