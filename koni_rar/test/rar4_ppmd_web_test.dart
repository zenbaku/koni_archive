// Web-runnable RAR4 PPMd (variant H "text compression") decoding. Real v4
// PPMd fixtures (authored with rar 6.24; rar 7.x cannot author v4) inlined as
// base64 so the range decoder's 32-bit arithmetic and the context model run on
// dart2js and dart2wasm, not just the VM. Reading verifies CRC-32 by default,
// so a decode that completes is byte-exact (also checked vs unrar locally).
// The same archives live in test/fixtures/rar_static/ for the fuzz smoke test.
//
// Regenerate: `rar a -ma4 -m5 -mc16:1t+ ppmd_rar4.rar ppmd_in.txt`,
// `rar a -ma4 -m5 -mc32:1t+ ppmd_rar4_runs.rar stress_runs.txt`,
// `rar a -ma4 -m5 -mct+ -s solid_ppmd.rar s1.txt s2.txt s3.txt` (rar 6.24).
// See doc/notes.md.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:test/test.dart';

// rar 6.24 -ma4 -m5 -mc16:1t+ over repeated sentences (18771 bytes). Trips the
// PPMd LZ escape (code 4) and rescale/glue in a 1 MB model.
final _ppmd = base64.decode(
  'UmFyIRoHAM+QcwAADQAAAAAAAAC2F3QgkDAArQEAAFNJAAAD7+S535IE8FwdNQsApIEAAHBwbWRf'
  'aW4udHh0APADwzPvAP9UFjuLTfjUq2kXNZKU/ODS4qaw+S18CEUQNndH5A2tM/rVwdUAVXugu5x1'
  'UOn+RV44I+uXnmkIWqK05OmX1uIPzlbKafkTf7DbZVIeOYd5TI6/okvMMqK2N6B8gq3sfMQI/HYf'
  'UiOOD/rZ9NtpwWQOrl0d8Cgjcc5q6Cq3DbfdROrsVbAAsShBq06l34OG8fOSkqBy1XyzSFDZ3Uhk'
  'rEWOQYb6ISGXHSN1aS941FKfPwp5EWogm3Mu44AJwmKgMZryuGMeZPGHfioph5OzueeBOpIfN2Bu'
  'eszRBjSHfMeOr/DQKWndtTlEPvoiwTBGk2dHKGorPgvuyLbTkQt5sG6z9U/rJdYotNUU2JlqfbMi'
  '17Sr5NZvpy4/RDaF1clgz5NT8lNMP52+Png7hwrvKeNN8u82t4LflNkx1a4ZYjHJ0s9TGLyO4W80'
  'nl9L/LXw/2xpCPlSAPRtTC+Sgz8JXNTIsJSz/etjHRrTzKYik+BLPIZYQnbjT69TPS5eRWI+NwQQ'
  '/FRJ7pJkSg1wdqVk6Flk9n9sGDsxOmR9+6VYhA6YCGQAAL+IZ/ap/9TEPXsAQAcA',
);

// rar 6.24 -ma4 -m5 -mc32:1t+ over 324600 bytes of long repeated runs. Trips
// the PPMd distance-1 (code 5) and distance (code 4) escapes heavily.
// (libarchive 3.7.4's own RAR reader fails this stream; unrar and this decoder
// both decode it.)
final _ppmdRuns = base64.decode(
  'UmFyIRoHAM+QcwAADQAAAAAAAACa6XRgkDQAyQIAAPjzBAADFMw5OXS971wdNQ8ApIEAAHN0cmVz'
  'c19ydW5zLnR4dACwHkJ9AL+IX9rp/79iEDAAEj/oDAAISOl4DNIMB2E6QXhLs26fUgrayidAuucL'
  'ZIpicfu4AAquAAJt/AQlVwACc/4CEquAAUN/AQlVwADsP4CEquAAeH/AQlVwAE7f4CEQ9AD/eIWJ'
  'hIW//eec/8xMR2SCQvSlmRFpJKDEDkpOawlA8D2cw6RC/Bsi98Z576y0CKtybizKinmDx4SdSxyM'
  'CbmSb531cUo6nTR6Rpd57Vy97OKQVCBjJIn7yFna+Ecmr22PzPNL+73eypm4TlOFPvu0ek1ePXvt'
  '7oj+cw+U74PcXhN/D6ImkQyA1cSwFxV/H8EvR5NQPuLbKWu2MGbzK3uHJmQyy21CXPdZMQ8px16i'
  'j31f0n90LnQ/crKHI80eQKCNn78NuT+8BI+s8s49P2zHyNXrBrCemxQcyLwtLX5FPJBqOTNIUPYc'
  'I04Jrds0KbIS0aPKN7SO49/UcbaZ/4LdRWJJyxwtA4g43ulofvb3FIYmVGK2MQZNspd0u+SFcXfj'
  'AfZ2AZcSBLf6UA/32bxsm2Xbv16tpw0elZb92Hl9oyLSMNb9ieNg9xzKTeaJJSHw+0At+ODqq/8l'
  'NmBqb+rnKoacIBxjtTCypgTalxUy7q8pyVnWzQZ8PlweJJ5s22cNFShFBKDnFCHU2fe6j5qi62rc'
  'I8Fs/8Y2nj9bIAqTahhrug1BqjAv0dgqD22SwBh+SFUE2myYnTnVPWKMWG5oxfqrihrPT4iAEcRb'
  'bgefJBS6YPx3NpS1VsB1jIcz3f45OQLzCAVx00assPNwXItvhYgxOoy7+MUYsAlRc+6NyT/jq8YN'
  'zB9qHTVZ2AA6WHAObu4n1nbFyMTXjeGJnRVWMg5kipHBr8K9pqcGIdiUCqfZZ307dI30WpV8ZnD6'
  'F2x1GPyoQM2BNKAnVfT6k27N22fgivgZSgEbZ4L2SZAkqlIAAL+IZ/ap/9TEPXsAQAcA',
);

// rar 6.24 -ma4 -m5 -mct+ -s over three text files. A solid PPMd run: the whole
// run shares one PPMd model and escape symbol across its files, each of which is
// its own block ending with an escape-code-2 marker (see doc/notes.md).
final _solidPpmd = base64.decode(
  'UmFyIRoHADvQcwgADQAAAAAAAABId3SAkCsARwAAAPwIAAADA1kt4vS971wdNQYApIEAAHMxLnR4'
  'dADwWsKW5xj/ZgVX+EfWL9RSifot8EW2HX+66rwBEVJ4HXmnHBj7+f9fqGi2CLX0Tttt9IRHY51i'
  'wOytijdukkU73TQAAL+IZ/ap/9ThX3SQkCsAOgAAACILAAADvJF7uvS971wdNQYApIEAAHMyLnR4'
  'dADwg8iWh5woLgVlY696ye/Y1EoQhvKpnvQRADoFHCeljzP//1jki+LwJ56aeBBV5AXmRzWbHAAA'
  'v4hn9qn/1FuZdJCQKwA9AAAAVAsAAANdooEI9L3vXB01BgCkgQAAczMudHh0APB6zpaH599X19Bd'
  '7/76XBdjr+aUyN2Ro3hNvL9cilVdMq2Pon9HmAmszvB/VjB0b/50AAAaRxvmAAC/iGf2qf/UxD17'
  'AEAHAA==',
);

Future<List<Uint8List>> _readAll(Uint8List archive) async {
  final reader = await const RarFormat().openReader(
    MemoryByteSource(archive),
    const ArchiveReadOptions(),
  );
  final out = <Uint8List>[];
  try {
    for (final entry in reader.entries) {
      final chunks = await reader.openRead(entry).toList();
      final bytes = Uint8List(entry.uncompressedSize);
      var o = 0;
      for (final c in chunks) {
        bytes.setRange(o, o + c.length, c);
        o += c.length;
      }
      out.add(bytes);
    }
  } finally {
    await reader.close();
  }
  return out;
}

void main() {
  test('PPMd fixture decodes (CRC-verified) on this platform', () async {
    final data = (await _readAll(_ppmd)).single;
    expect(data.length, 18771);
    expect(utf8.decode(data), startsWith('The archive format stores'));
  });

  test(
    'PPMd code-4/code-5 (LZ escapes) fixture decodes on this platform',
    () async {
      final data = (await _readAll(_ppmdRuns)).single;
      expect(data.length, 324600);
      expect(data[0], 'x'.codeUnitAt(0));
    },
  );

  test(
    'solid PPMd: every file decodes (CRC-verified) on this platform',
    () async {
      final reader = await const RarFormat().openReader(
        MemoryByteSource(_solidPpmd),
        const ArchiveReadOptions(),
      );
      expect(reader.entries.map((e) => e.path), ['s1.txt', 's2.txt', 's3.txt']);
      // Every member decodes — the shared model + escape carry across files, and
      // each file's slice is CRC-checked. Read out of order to also exercise the
      // whole-run decode + per-file cache.
      for (final i in [2, 0, 1]) {
        final e = reader.entries[i];
        final chunks = await reader.openRead(e).toList();
        expect(chunks.fold<int>(0, (s, c) => s + c.length), e.uncompressedSize);
      }
      await reader.close();
    },
  );
}
