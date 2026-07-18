// Web-runnable xz decoding: small fixtures inlined as base64 (no dart:io) so
// the VLI arithmetic, the two-lane CRC-64 verify, LZMA2, and the delta / x86
// BCJ filters run on dart2js and dart2wasm, not only the VM. Run with:
//   dart test test/xz_web_test.dart -p chrome
//   dart test test/xz_web_test.dart -p chrome -c dart2wasm
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_xz/koni_xz.dart';
import 'package:test/test.dart';

// Deterministic plaintexts, matching tool/generate_fixtures.dart's XzFixtureSet.
Uint8List get _hello =>
    Uint8List.fromList(('Hello, xz world!\n' * 4).codeUnits);
Uint8List get _prose => Uint8List.fromList(
  ('the quick brown fox jumps over the lazy dog. ' * 1000).codeUnits,
);
Uint8List get _ramp =>
    Uint8List.fromList(List<int>.generate(20000, (i) => (i * 7) & 0xFF));

const _fixtures = <String, String>{
  'hello_crc64':
      '/Td6WFoAAATm1rRGBMAgRCEBFgAAAAAAAAAAAAm2DGTgAEMAGF0AJBlJmG8WAo0Ij1+Uqknhw24'
      'vkI66CAAAAEeeWu/tJRggAAE8RF1JxCIftvN9AQAAAAAEWVo=',
  'hello_crc32':
      '/Td6WFoAAAFpIt42BMAgRCEBFgAAAAAAAAAAAAm2DGTgAEMAGF0AJBlJmG8WAo0Ij1+Uqknhw24'
      'vkI66CAAAAB/Frv8AAThEWYyoRpBCmQ0BAAAAAAFZWg==',
  'hello_sha256':
      '/Td6WFoAAArh+wyhBMAgRCEBFgAAAAAAAAAAAAm2DGTgAEMAGF0AJBlJmG8WAo0Ij1+Uqknhw24'
      'vkI66CAAAAISQdL2hWlawKg8g6RVpenLduhgBqZl8Ou1PZkQm0bwWAAFURPKo4I8Ym0uaAQAAAA'
      'AKWVo=',
  'hello_none':
      '/Td6WFoAAAD/EtlBBMAgRCEBFgAAAAAAAAAAAAm2DGTgAEMAGF0AJBlJmG8WAo0Ij1+Uqknhw24'
      'vkI66CAAAAAABNERVwx3qBnKeegEAAAAAAFla',
  'ramp_delta':
      '/Td6WFoAAATm1rRGBMFDoJwBAwEAIQEWAAAAAIbX4DLgTh8AO10AAAJMEf/XOzYrLe+EMXM/XY3'
      'eiKlEGfOOrSgJQ8FVvZLXiBUhEa4OuoEtimNFA6z4K3GiE08tdkQZAAAAACAiJeodtolBAAFfoJw'
      'BAABCxf64scRn+wIAAAAABFla',
  'prose_bcj':
      '/Td6WFoAAATm1rRGBMF7yN8CBAAhARYAAAAAAFmDNd7gr8cAc10AOhoIznbH5enWBzTD0Q6/zlX'
      'hqr3g5I+YAd2N5QdUnmUlXyc6an6000kDic7UfTz/mt42HKwRZeLK+ymJJn8DiT0hMwSrSIwO2p4'
      'FEQ7nMvSp+A3e0YY2mFkqaDbhRJtycLb5FU+swgUCN4yL3H+YjeEAAAAAZOAZvkX3O/oAAZcByN8'
      'CAPANTPmxxGf7AgAAAAAEWVo=',
  'prose_multiblock':
      '/Td6WFoAAATm1rRGA8BqgIABIQEWAAAAF9XcfOA//wBiXQA6GgjOdsfl6dYHNMPRDr/OVeGqveDk'
      'j5gB3Y3lB1SeZSVfJzpqfrTTSQOJztR9PP+a3jYcrBFl4sr7KYkmfwOJPSEzBKtIjA7angURDuc'
      'y9Kn4Dd7RhjaYWSpoNuD1qhCvAAAAAIArc5T+/BbcA8BogIABIQEWAAAAKgUpeOA//wBgXQA4nUl'
      'VqZl4LbriMS2g66zKIIgKbc8UVZbxhUrrk2dsWfVIIGqS8uTgzDEqzYRVkA49baoEFwIESU1TDXX'
      'zxa3b3HxR6O4txPGB5ZpCwcEkbHY0Og3OJEPsBKi7hnxvnAAAU8bY9CNyYeEDwGPIXyEBFgAAAAAJ'
      'RB1V4C/HAFtdADWICEdj/F522VUXQEGyLEOE/maC/I8C7EyLB9YuKaLlEla0hp3+ElcAnqxgKdHs'
      'rSo9pfEGv+X+4+ksZUoQkeG6THpwS7cd76Gdj8FDv6x9wCKb+nJZwihSkAAAACU1g0G8v214AAOCA'
      'YCAAYABgIABe8hfABKUMaWsJz4tBAAAAAAEWVo=',
  'two_stream':
      '/Td6WFoAAATm1rRGBMAgRCEBFgAAAAAAAAAAAAm2DGTgAEMAGF0AJBlJmG8WAo0Ij1+Uqknhw24'
      'vkI66CAAAAEeeWu/tJRggAAE8RF1JxCIftvN9AQAAAAAEWVr9N3pYWgAAAWki3jYEwCBEIQEWAAAA'
      'AAAAAAAACbYMZOAAQwAYXQAkGUmYbxYCjQiPX5SqSeHDbi+QjroIAAAAH8Wu/wABOERZjKhGkEKZ'
      'DQEAAAAAAVla',
};

Uint8List _bytes(String name) => base64.decode(_fixtures[name]!);

Future<Uint8List> _decode(String name) async {
  final reader = await const XzFormat().openReader(
    MemoryByteSource(_bytes(name)),
    const ArchiveReadOptions(),
  );
  final b = BytesBuilder(copy: false);
  await for (final chunk in reader.openRead(reader.entries.single)) {
    b.add(chunk);
  }
  await reader.close();
  return b.takeBytes();
}

void main() {
  test('crc64 / crc32 / sha256 / none decode on this platform', () async {
    for (final name in [
      'hello_crc64',
      'hello_crc32',
      'hello_sha256',
      'hello_none',
    ]) {
      expect(await _decode(name), _hello, reason: name);
    }
  });

  test('delta filter decodes', () async {
    expect(await _decode('ramp_delta'), _ramp);
  });

  test('x86 BCJ filter decodes', () async {
    expect(await _decode('prose_bcj'), _prose);
  });

  test('multi-block stream decodes', () async {
    expect(await _decode('prose_multiblock'), _prose);
  });

  test('concatenated streams decode', () async {
    expect(
      await _decode('two_stream'),
      Uint8List.fromList([..._hello, ..._hello]),
    );
  });

  test('a corrupted CRC-64 check is caught on this platform', () async {
    // Flip the final byte (inside the last stream's index/footer region is
    // risky; instead flip a compressed byte) — any corruption must stay typed.
    final bytes = Uint8List.fromList(_bytes('hello_crc64'));
    bytes[35] ^= 0xFF;
    final reader = await const XzFormat().openReader(
      MemoryByteSource(bytes),
      const ArchiveReadOptions(),
    );
    await expectLater(
      reader.openRead(reader.entries.single).toList(),
      throwsA(isA<CorruptArchiveException>()),
    );
    await reader.close();
  });
}
