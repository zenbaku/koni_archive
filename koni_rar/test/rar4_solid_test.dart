// Web-runnable solid RAR4 decoding. A real `rar 6.24 -ma4 -m3 -s` archive
// of five text files that share a vocabulary, so later files reference earlier
// ones through the shared solid window, inlined as base64 (no dart:io) so the
// cross-file LZSS decode runs on dart2js and dart2wasm, not just the VM.
// Reading verifies CRC-32 by default, so a decode that completes is byte-exact
// (also checked sha256-vs-unrar locally). The same archive lives in
// test/fixtures/rar_static/solid_rar4.rar for the fuzz smoke test.
//
// Regenerate: `rar a -ma4 -m3 -s solid_rar4.rar <files>` (rar 6.24; rar 7.x
// cannot author v4). See doc/notes.md.
library;

import 'dart:convert';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:test/test.dart';

final _solid = base64.decode(
  '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'
  'HaFlovwAEWEQP8TEPXsAQAcA',
);

Future<ArchiveReader> _open() => const RarFormat().openReader(
  MemoryByteSource(_solid),
  const ArchiveReadOptions(),
);

Future<int> _read(ArchiveReader r, ArchiveEntry e) async =>
    (await r.openRead(e).toList()).fold<int>(0, (s, c) => s + c.length);

void main() {
  test('solid RAR4: all files decode in order (CRC-verified)', () async {
    final r = await _open();
    final files = r.entries.where((e) => !e.isDirectory).toList();
    expect(files, hasLength(5));
    for (final e in files) {
      expect(await _read(r, e), e.uncompressedSize);
    }
    await r.close();
  });

  test('solid RAR4: out-of-order and repeat reads rebuild the run', () async {
    final r = await _open();
    final files = r.entries.where((e) => !e.isDirectory).toList();
    // Last, first, middle, last again (repeat), then all forward.
    final order = [4, 0, 2, 4, 0, 1, 2, 3, 4];
    for (final i in order) {
      expect(await _read(r, files[i]), files[i].uncompressedSize);
    }
    await r.close();
  });

  test('solid RAR4: content is stable across read orders', () async {
    final r = await _open();
    final files = r.entries.where((e) => !e.isDirectory).toList();
    final forward = <String>[
      for (final e in files)
        utf8.decode(
          (await r.openRead(e).toList()).expand<int>((c) => c).toList(),
        ),
    ];
    // Re-read in reverse; each file must yield identical bytes.
    for (var i = files.length - 1; i >= 0; i--) {
      final again = utf8.decode(
        (await r.openRead(files[i]).toList()).expand<int>((c) => c).toList(),
      );
      expect(again, forward[i]);
    }
    await r.close();
  });
}
