import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:test/test.dart';

/// Platform-neutral reader tests (VM, dart2js, dart2wasm) over an embedded
/// compressed archive: `rar a -m3 tiny.rar hello.txt story.txt` (RAR 7.23).
/// Exercises the RAR5 Huffman + LZ decoder on every target.
const String _tinyRarBase64 =
    'UmFyIRoHAQAzkrXlCgEFBgAFAQGAgABMAUfGHwICjAAGjACkgwKlXQ1ebvdJOIAAAQloZWxs'
    'by50eHRoZWxsbywgcmFyIQrCzGXTHwICwQAGywCkgwKlXQ1eKGEdrIADAQlzdG9yeS50eHTE'
    'oD5FRUIvdAQ+7BX4AaYnxQRHRmKJrn/gUcyG7q/TO/hY+g3boauSRjdJjmHnv4SK3CzdlWgU'
    'jM76I1YQwmnpkB13VlEDBQQA';

Future<String> _read(ArchiveReader reader, ArchiveEntry entry) async {
  final chunks = await reader.openRead(entry).toList();
  return utf8.decode(chunks.expand<int>((c) => c).toList());
}

void main() {
  final bytes = base64.decode(_tinyRarBase64);

  test('decodes RAR5-compressed entries on every platform', () async {
    final reader = await const RarFormat().openReader(
      MemoryByteSource(Uint8List.fromList(bytes)),
      const ArchiveReadOptions(),
    );
    final byPath = {for (final e in reader.entries) e.path: e};
    expect(byPath.keys.toSet(), {'hello.txt', 'story.txt'});
    expect(await _read(reader, byPath['hello.txt']!), 'hello, rar!\n');
    expect(
      await _read(reader, byPath['story.txt']!),
      'the quick brown fox jumps over the lazy dog, '
      'over and over and over again.\n',
    );
    await reader.close();
  });

  test('detection accepts RAR5, rejects noise', () async {
    const format = RarFormat();
    expect(
      await format.matches(MemoryByteSource(Uint8List.fromList(bytes))),
      isTrue,
    );
    expect(
      await format.matches(
        MemoryByteSource(Uint8List.fromList(List.filled(16, 0x50))),
      ),
      isFalse,
    );
  });
}
