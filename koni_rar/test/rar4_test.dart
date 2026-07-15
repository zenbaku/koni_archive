import 'dart:convert';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:test/test.dart';

import 'src/rar4_builder.dart';

/// The RAR4 container + store path, exercised on every platform without a
/// committed v4 fixture (rar 7.x only authors v5). Method-29 decoding is
/// verified by the conformance suite against the real corpus (local only).
Future<String> _read(ArchiveReader reader, ArchiveEntry entry) async {
  final chunks = await reader.openRead(entry).toList();
  return utf8.decode(chunks.expand<int>((c) => c).toList());
}

void main() {
  test('parses a hand-built RAR4 store archive on every platform', () async {
    final bytes = buildRar4Store({
      'hello.txt': 'hello, rar4!\n',
      'dir/note.md': 'a second stored entry',
    });
    final reader = await const RarFormat().openReader(
      MemoryByteSource(bytes),
      const ArchiveReadOptions(),
    );
    expect(reader.entries.map((e) => e.path), ['hello.txt', 'dir/note.md']);
    final byPath = {for (final e in reader.entries) e.path: e};
    expect(byPath['hello.txt']!.uncompressedSize, 13);
    expect(byPath['hello.txt']!.crc32, isNotNull);
    expect(await _read(reader, byPath['hello.txt']!), 'hello, rar4!\n');
    expect(
      await _read(reader, byPath['dir/note.md']!),
      'a second stored entry',
    );
    await reader.close();
  });

  test('detects the RAR4 signature', () async {
    final bytes = buildRar4Store({'a.txt': 'x'});
    expect(await const RarFormat().matches(MemoryByteSource(bytes)), isTrue);
  });

  test('a stored entry with a corrupted CRC-32 errors the stream', () async {
    final bytes = buildRar4Store({'a.txt': 'content'});
    // 'content' (7 bytes) is stored just before the 7-byte ENDARC block;
    // flip a byte inside it so the streamed CRC-32 diverges from the one
    // recorded in the header.
    bytes[bytes.length - 7 - 4] ^= 0xFF;
    final reader = await const RarFormat().openReader(
      MemoryByteSource(bytes),
      const ArchiveReadOptions(),
    );
    await expectLater(
      reader.openRead(reader.entries.single).toList(),
      throwsA(isA<ChecksumMismatchException>()),
    );
  });
}
