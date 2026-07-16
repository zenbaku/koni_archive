// RAR4 legacy unpack-version handling (R9). koni_rar decodes unpack versions 20
// and 26 (RAR 2.0/2.6, see rar2_web_test.dart) and 29 (RAR 2.9/3.x), plus
// version-agnostic store. Version 15 (RAR 1.5) has no clean-room reference and
// is rejected with a clear typed error, verified here with synthetic headers,
// since no tool authors v15 archives.
library;

import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:test/test.dart';

import 'src/rar4_builder.dart';

Future<ArchiveReader> _open(Uint8List bytes) => const RarFormat().openReader(
  MemoryByteSource(bytes),
  const ArchiveReadOptions(),
);

void main() {
  test('a STORE archive decodes at any unpack version', () async {
    for (final v in [15, 20, 26, 29]) {
      final bytes = buildRar4Store({
        'a.txt': 'legacy store $v',
      }, unpackVersion: v);
      final reader = await _open(bytes);
      final data = await reader.openRead(reader.entries.single).toList();
      expect(
        String.fromCharCodes(data.expand((c) => c)),
        'legacy store $v',
        reason: 'store v$v should decode',
      );
      await reader.close();
    }
  });

  test('a v15 (RAR 1.5) COMPRESSED entry is a clean typed error', () async {
    final bytes = buildRar4Store(
      {'a.txt': 'x' * 32},
      unpackVersion: 15,
      method: 0x33, // compressed level 3 (not store)
    );
    final reader = await _open(bytes);
    // Listing works; openRead reports the unsupported version synchronously,
    // like the other header-detected rejections.
    expect(reader.entries.single.path, 'a.txt');
    expect(
      () => reader.openRead(reader.entries.single),
      throwsA(
        isA<UnsupportedFeatureException>().having(
          (x) => x.toString(),
          'message',
          allOf(contains('unpack version'), contains('15')),
        ),
      ),
    );
    await reader.close();
  });

  test('a solid RAR 2.0 continuation is a clean typed error', () async {
    // The run's first file (solid flag clear) decodes via the non-solid path;
    // a solid *continuation* (v20) would misroute to the method-29 solid path,
    // so it is rejected cleanly instead. Real solid v20 archive:
    // fixtures/rar_static/rar2_solid.rar (fuzz pool).
    final bytes = buildRar4Store(
      {'first.txt': 'x' * 64, 'second.txt': 'y' * 64},
      unpackVersion: 20,
      method: 0x33,
      solid: true,
    );
    final reader = await _open(bytes);
    expect(reader.entries.map((e) => e.path), ['first.txt', 'second.txt']);
    await expectLater(
      reader.openRead(reader.entries[1]).toList(),
      throwsA(
        isA<UnsupportedFeatureException>().having(
          (x) => x.toString(),
          'message',
          contains('solid RAR 2.0'),
        ),
      ),
    );
    await reader.close();
  });

  test('a v29 COMPRESSED header is NOT rejected by the version gate', () async {
    // v29 routes to the method-29 decoder; here the body is not valid method-29,
    // so it fails as corruption, not as an unsupported version, proving the
    // gate keys on the version, not the method.
    final bytes = buildRar4Store(
      {'a.txt': 'x' * 32},
      unpackVersion: 29,
      method: 0x33,
    );
    final reader = await _open(bytes);
    await expectLater(
      reader.openRead(reader.entries.single).toList(),
      throwsA(isA<ArchiveException>()),
    );
    await reader.close();
  });
}
