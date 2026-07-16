// Web-runnable RAR4 PPMd (variant H "text compression") decoding. Real v4
// PPMd fixtures (authored with rar 6.24; rar 7.x cannot author v4) inlined as
// base64 so the range decoder's 32-bit arithmetic and the context model run on
// dart2js and dart2wasm, not just the VM. Reading verifies CRC-32 by default,
// so a decode that completes is byte-exact (also checked vs unrar locally).
// The same archives live in test/fixtures/rar_static/ for the fuzz smoke test.
//
// Regenerate: `rar a -ma4 -m5 -mc16:1t+ ppmd_rar4.rar ppmd_in.txt`,
// `rar a -ma4 -m5 -mc32:1t+ ppmd_rar4_runs.rar stress_runs.txt`,
// `rar a -ma4 -m5 -mct+ -s solid_ppmd.rar s1.txt s2.txt s3.txt`, and
// `rar a -ma4 -m5 -mc:1t ppmd_switch.rar switch.dat` where switch.dat is >~60 KB
// of natural-ish text then a repetitive binary block then a short text tail (so
// `-mct` auto-mode switches PPMd->LZSS mid-file). All rar 6.24. See doc/notes.md.
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

// rar 6.24 -ma4 -m5 -mc:1t over ~62 KB of text (PPMd) followed by a repetitive
// binary block (general/LZSS) and a short text tail: RAR's -mct auto-mode switches
// compression method mid-file, so decoding crosses a PPMd->method-29 (LZSS) block
// boundary (PPMd escape code 0 -> an LZSS table block). Exercises R8.
final _ppmdSwitch = base64.decode(
  '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'
  'BcTvnLZRRM1jBqVLTbM3hsPOfUDEPXsAQAcA',
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
    'PPMd->method-29 mid-file block switch decodes on this platform',
    () async {
      // The file starts in PPMd (text), then RAR's -mct auto-mode switches to
      // method-29 (LZSS) mid-file. Decoding crosses the boundary via the shared
      // bit-reader; CRC-32 verify (on by default) makes a completing decode
      // byte-exact; also checked vs unrar locally.
      final data = (await _readAll(_ppmdSwitch)).single;
      expect(data.length, 73589);
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
      // Every member decodes; the shared model + escape carry across files, and
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
