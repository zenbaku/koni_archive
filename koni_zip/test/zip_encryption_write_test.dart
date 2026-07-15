import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_zip/koni_zip.dart';
import 'package:test/test.dart';

/// Write-side WinZip AES (AE-2) encryption (Phase 4): the writer's output
/// must round-trip through our own reader with the password, reject the
/// wrong password, and refuse to open without one. Interop with `unzip -P`
/// lives in `zip_writer_interop_test.dart` (VM-only).

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// A deterministic "random" byte source so an encrypted archive is
/// reproducible in tests (salt = 0x00,0x01,0x02,…). Never use outside tests.
Uint8List _countingBytes(int length) =>
    Uint8List.fromList(List.generate(length, (i) => i & 0xFF));

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
          ? const ZipWriteFormat().openWriter(sink, options)
          : ZipWriter(
            const ZipWriteFormat(),
            sink,
            options,
            randomBytes: randomBytes,
          );
  await build(writer);
  await writer.close();
  await sink.close();
  return sink.takeBytes();
}

Future<Map<String, Uint8List>> readAll(
  Uint8List archive, {
  String? password,
}) async {
  final reader = await const ZipFormat().openReader(
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
  const password = 'sésame-🔒-42';

  group('round-trips through the reader with the password', () {
    test('deflate entries (default) decrypt byte-for-byte', () async {
      final big = Uint8List.fromList(utf8.encode('koni archive! ' * 500));
      final archive = await writeEncrypted((w) async {
        await w.addBytes(ArchiveEntrySpec(path: 'hello.txt'), _bytes('hi\n'));
        await w.addBytes(ArchiveEntrySpec(path: 'nested/deep/data.txt'), big);
      }, password: password);

      final files = await readAll(archive, password: password);
      expect(utf8.decode(files['hello.txt']!), 'hi\n');
      expect(files['nested/deep/data.txt'], big);
    });

    test('stored entries decrypt byte-for-byte', () async {
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
      final files = await readAll(archive, password: password);
      expect(files['raw.bin'], data);
    });

    test(
      'an empty file is encrypted (envelope only) and reads back empty',
      () async {
        final archive = await writeEncrypted((w) async {
          await w.addBytes(ArchiveEntrySpec(path: 'empty.txt'), Uint8List(0));
        }, password: password);
        final files = await readAll(archive, password: password);
        expect(files['empty.txt'], isEmpty);
      },
    );

    test(
      'unicode names and a directory survive; the dir stays plaintext',
      () async {
        final archive = await writeEncrypted((w) async {
          await w.addEntry(
            ArchiveEntrySpec(path: '章', type: ArchiveEntryType.directory),
          );
          await w.addBytes(
            ArchiveEntrySpec(path: '章/ページ.txt'),
            _bytes('unicode page\n'),
          );
        }, password: password);

        final reader = await const ZipFormat().openReader(
          MemoryByteSource(archive),
          const ArchiveReadOptions(password: password),
        );
        final dir = reader.entries.firstWhere((e) => e.path == '章');
        final file = reader.entries.firstWhere((e) => e.path == '章/ページ.txt');
        expect(dir.isEncrypted, isFalse, reason: 'directories carry no data');
        expect(file.isEncrypted, isTrue);
        final files = await readAll(archive, password: password);
        expect(utf8.decode(files['章/ページ.txt']!), 'unicode page\n');
      },
    );

    test(
      'the reader flags entries encrypted and hides the AES envelope size',
      () async {
        final plain = _bytes('exactly these bytes');
        final archive = await writeEncrypted((w) async {
          await w.addBytes(
            ArchiveEntrySpec(
              path: 'a.txt',
              compression: ArchiveCompression.stored,
            ),
            plain,
          );
        }, password: password);
        final reader = await const ZipFormat().openReader(
          MemoryByteSource(archive),
          const ArchiveReadOptions(password: password),
        );
        final entry = reader.entries.single;
        expect(entry.isEncrypted, isTrue);
        expect(entry.uncompressedSize, plain.length);
        // Stored + AES-256: the recorded compressed size is plaintext + the
        // 16-byte salt + 2-byte verifier + 10-byte MAC = +28.
        expect(entry.compressedSize, plain.length + 28);
      },
    );
  });

  group('password enforcement', () {
    test('a wrong password is rejected by the AES verifier', () async {
      final archive = await writeEncrypted((w) async {
        await w.addBytes(ArchiveEntrySpec(path: 'a.txt'), _bytes('secret\n'));
      }, password: password);
      final reader = await const ZipFormat().openReader(
        MemoryByteSource(archive),
        const ArchiveReadOptions(password: 'wrong'),
      );
      expect(
        () => reader.openRead(reader.entries.single).toList(),
        throwsA(isA<InvalidPasswordException>()),
      );
    });

    test('opening an encrypted entry with no password throws', () async {
      final archive = await writeEncrypted((w) async {
        await w.addBytes(ArchiveEntrySpec(path: 'a.txt'), _bytes('secret\n'));
      }, password: password);
      final reader = await const ZipFormat().openReader(
        MemoryByteSource(archive),
        const ArchiveReadOptions(),
      );
      expect(
        () => reader.openRead(reader.entries.single).toList(),
        throwsA(isA<EncryptedArchiveException>()),
      );
    });
  });

  test('a fixed salt makes the ciphertext reproducible', () async {
    Future<Uint8List> once() => writeEncrypted(
      (w) async {
        await w.addBytes(
          ArchiveEntrySpec(
            path: 'a.txt',
            compression: ArchiveCompression.stored,
          ),
          _bytes('determinism\n'),
        );
      },
      password: password,
      randomBytes: _countingBytes,
    );
    expect(await once(), await once());
  });
}
