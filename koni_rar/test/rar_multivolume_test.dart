// Web-runnable multi-volume RAR decoding. Real `rar 6.24 -v<size>` sets
// (RAR5 store, RAR5 compressed, RAR4 compressed), each volume inlined as
// base64 (no dart:io) so cross-volume reassembly runs on dart2js and
// dart2wasm. Volume 1 is opened; the rest are served through
// ArchiveReadOptions.nextVolume. Reading verifies CRC-32 (from the final
// segment's header) by default, so a decode that completes is byte-exact
// (also checked sha256-vs-unrar locally, store and compressed, both versions).
//
// Regenerate: `rar a -v1500b <name>.rar <files>` (add -ma4 for RAR4). The
// split file's header repeats per volume with splitBefore/splitAfter flags.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:test/test.dart';

// mv5: 3 volumes
final _mv5store = <Uint8List>[
  base64.decode(
    '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'
    'AAA=',
  ),
  base64.decode(
    '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'
    'AAA=',
  ),
  base64.decode(
    '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'
    'BAA=',
  ),
];

// mvA: 4 volumes
final _mv5comp = <Uint8List>[
  base64.decode(
    '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'
    'AA',
  ),
  base64.decode(
    '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'
    'AA',
  ),
  base64.decode(
    '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'
    'AA',
  ),
  base64.decode(
    'UmFyIRoHAQDUxeGIDAEFBwMDBgEBgICAAAJVz1wlAgsLyYUABMKNAaSDAtT2XgiABQEFdC50eH'
    'QKAxOJRlhqCHdMGSm+tlb4qqJdXmy9SFtMgrSk7cK/NeYby9mQvXbN1qdT5M4QJm5B28eesdpx'
    'agjUSIQztdRnkFwNVMPbUl6P7jSJ6NGfpzwIrmYEed/ZfXYGoVNbeTqqLOx0gstcUN8PrX9dQz'
    'SsaY2ZH/kOnmnsjb0XOrusNusuTn6vu/2cp3WYv3Q1Cc0mrpwSUYFjxTJiLiZSheS/e3Hqid4i'
    'B+27Xqsks1Ztywf/bt5hWBPdKCjdYld2YDL0+FXolYZk+WC6LNfvAe7uCEphXeFVOdqcffpJ2f'
    'oyVurvHVXItDXQHND0L8C7Oll6+zlST69Qz07HMGb59u1dHxvbaMadBNrjQj/a8ZBF4CTXV+ef'
    'Zlfc0Dterw2pHdNbb58m4HFH2SPTmyZUAQg3P0SxtaDpbnuW9RNXIU9vvPsdS4IUKjvKO5IuiP'
    'aTR5gfzVzpVE85tcArkvmeXHYRStDPZ4tF3DSImcCoLPqfamU9WT136dKvXuOYUnUrrhxGN3RL'
    'C9hbnMZdxiKnsX4or6Cx5nrwwIN7yM9jVw67e94X902yKE63aqYYvWrqOG/UsSTL0Cd9Z2y9ub'
    'z9asdTfD3bNrOm81zcpbFrYEzCjkurpajQx8va80+RC2FVCuqKC/Ou0dOu362WUgA1k/6DPQBa'
    'YLr3jGHkQq/dd2wpszAWwxm+bVL5fbqsrgl/elXFmnQPpH3lft8/XGZ/KP8pPqTkGbtPrW6Sul'
    '612jJ/nT38CadKnBHatmqGvx3ccRIHa+Zlv2fWfM6b5b+NLDtOyqrirAPf9ac6tC1/+H0gLmUv'
    '4FP1Q2nexU5M+yydMZdyH33IezIq9LRPtGfTGfR1t3tHt6yUkNQeX7UgGemRwlXFWK3WUiWAy4'
    'g+K3jamKMvR78oOFUWjGtQ6tfLHG/hQmvr6JkURqamEzeaL0VIq70uj+NbxA6WR7LqIqAEGfay'
    'i5PwJhkjBCcCAwuTAASTAKSDAuAbVEuAAAEJc21hbGwudHh0CgMT50FYaipXcA9zZWNvbmQgZm'
    'lsZSwgc21hbGwKHXdWUQMFBAA=',
  ),
];

// mvB: 4 volumes
final _mv4comp = <Uint8List>[
  base64.decode(
    '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'
    'AA',
  ),
  base64.decode(
    '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'
    'AA',
  ),
  base64.decode(
    'UmFyIRoHABl6cxEADQAAAAAAAADIJnQjkCoAigUAAMJGAAADhzaFMxS271wdNQUApIEAAHQudH'
    'h0APDAw0BfO1bP0nBAxCs1hGsmhmjXHwM10drh0wOSMwjvtG8tVKpC1Nj502v5VpP96TF+ILut'
    'oCmwo7/akNmdSklK5wRRAphbW6DpH1IbdnLxe/JinIpeF/zt9RWOlT0oSFaZPlVTRWThUHVwcI'
    'SSgncX6xxR/xCZe9GAJIoDVE7qScWMH414/u/2zZCiCqZZK0X7ZYYGjFqM3pRRXQVj1/+l+HPw'
    'i/sjH1pI2bMCE/eKk4ViIWCgZ0t375f8o7ajj61NqSiV1mUmxesrsQktIC75qlpZB19mnE1zH8'
    'rfyFtWWt8rDM6XXatCuSXTDC7Wq3/Wlt3vgJIEUvGtGz00fNmkIOmuop4Pzxae/Y19kTiHE1zu'
    '+CkL/Z1PArWtULruHJY+aXqT65JBgp2s89eU0EUxRDpDghg4MlKjQ0w4PBjPUNOEXSu9H4xSMr'
    'e0KZtcPDR8OQcH98VsQtJrMK8P5I5gFrShWY/5YzU7T3Dp2czoZU6XO0IYacOprkdX5mP+VEaV'
    'huc0svlqw2xX3OPzLqaWorFbisjyNgMtSJUgSxZFAYVbfArvns9nZmK8TCWCzMmbjyvGemlmdC'
    'pm+KXChAd06AZEOcq0m8+HWR5/wJOW7mRpgLdO0X3sB8zLfl8W3RKmtjN+l07avCbUPVLmzJD4'
    'r2YGMeUReMUkLs6dujBzzBglr/YmvOvRMeFdZeYrR+orYz2jSqCBqd+emW14a9O82TyvwpTXqs'
    '4Idrr6opK4UFt0Nc8aqqB/rRs+WEjowriFacBrWozwiYLWtXGcZHSkYpImsp9z1gE8fy7L42fa'
    'Xrq3ad5hazAI0ngBPzhU+bEG2BPPJ+9dFZJDWAxY01nrdOZGWTwkeCsubLCDYpvJdIp2eiBwwP'
    'VmubktVBGr8vMrIWtgkEoTA1oLG3uk+ZthsorbBIXfhduXrf7fwS4gh5OsE6yFmdHA0bWFDSbe'
    'DqcFTGnpby+Q7GuxjmCCUgt6Yxg9YPQFHynjphue163iMgu0UvvRK9Li07yBegkMHda2Fsg3Jq'
    'F+d4lvVu0mF2JiARnd0gq26W1XpOMM2jIDcwoHqCTGq6X/sZ0+jXctRCbs19XbwPMrwYjRlFvF'
    'yPCO1U8L7yMAcfpscmUEmfWgN0Zml0ztyXfza9N7xYUtaV0/wo/qxFV6mdBnlC31ST207aj3ms'
    'FvoNuNLoG1RhAAeuzq97CglaQ6xLoA/lnCvRNtKHRWqkJ9mnUvIc7Qa7Pja0MLNQcOhFnVI133'
    'HeRv4bjFKUgZjVC3LpFulVxj8w6CuMG7DAXx3j827g/GBTC7zxQblsozIZ1p009/faM90gFGsY'
    'WxQiF359GVGO06uNP7HSlakoBe/Xt4cBp1I0t0nNv0IOPUnr1lqVxaTZIMi3MABDy4clfUsvef'
    'VlElcI7sU5frLMnQUXMDhGylE24oK47kZ2ty4TI7XeKDDXYB2JQkR3B2l+btLtj8IzoMIWbWtq'
    'raNB0lICzn16bRyIQ6d3p3LGtbER7L5nSDgZ2tGmQLdh9awgGgsGVAIxd337LFpQdn0oLXmcNv'
    'H+PetUeF5b6R2v1GzMaZamnCbnWqZytfJHr6Iiey4LBrtTlqB/W0QpvrZW+KqSXm82VqQtJkE6'
    'Unbor81Zhu3syFa7ZstTqfJjCBM3IO1jzvHacWoI0JEIZ3PUZ5BcDVTD21Jej+40iejRn6c8CK'
    '5mAnnX2X12BoKmpvJ5qizsdILLXEG+H1r/PUM0rHLGzI/746eaeyNrRb1d1ht1lyb+r7rzOU7e'
    'Yr3Q1Cc0mrowSUZCxxTJiLiZSg/pXvbi1RO8CB+27Vqsks1Rtywf+XbzCsCe6USjbxK7sxDL0+'
    'Fn0SuGZPlguizV7wHs7ghCYZ7wqpztTj79JOv6MlTq706q5Fobpbew9AFACzrIGfAgAAAAAAAA'
    'AA',
  ),
  base64.decode(
    'UmFyIRoHABl6cxEADQAAAAAAAACBwHQhkCoA7wEAAMJGAAAD1PZeCBS271wdNQUApIEAAHQudH'
    'h0APDAw0CuwHND0L8C7Olb19m1JPz6hnp2OaGb37dq6PjW20Y06CbnjQj/a8ZAl6BJrq/PDptf'
    'c0Dterw0pHeWtt8+DchxR9kj05slqAIQbz9EsbWg6U57lPUTVyFPL4v2OpcEIKjrKO1Rckekmj'
    'wgfzVzpVE7za8ArgvmeXjsIpWhfZ4pF3hpAmcCoK/U+1Mp6snz36dKvXuOcKTzK64cRjZ0SwvY'
    'U5zFu4xFT2K8UV9BY7z14YEGt5Gexq4ddPe8K+6bVKEa3SqYYrWrmcNepYyTK0Cd9Z2t7c3f1q'
    'x1N+Hu0bV6bznm5S2LWwJmFHBdXS1Ehj5e1Zp8iFoKoK6ZQPjz2jp12/WyykAGsn/kM+QC5YLr'
    '3jEPIwq/Zd24U2ZgLkMZvm5pfL7dVa4JfjpVxRpwH0T7tft7+uMx4uX+Un1ByDN0n1qdJXS9c9'
    'oyXjy9+BNOlTgjtWzVC/Ds44hQOl8zLfr9Z8vTfM/xpYdp2VVcVQD3+NOdOha/+H0AXLS/kKfz'
    'Q2nexU5M+yye2LdyH23IejIs+lon2jP2xfo62z2j2tZKKGoPL9qQhnpkcJVxmxW6ykRwFuIPjO'
    '8bmYot6PfaDhmi0Y1qHVL5Y434UJr6+iZFEamphM3mitFSKu9Lo/jW8QOlkeS6iKgBQz7WUXk/'
    'P9Jc23QgkC4AEwAAABMAAAAD4BtUS5uz71wdMAkApIEAAHNtYWxsLnR4dADw/YUnc2Vjb25kIG'
    'ZpbGUsIHNtYWxsClIsew5AFAAy+vkFAwAAAAAAAAAA',
  ),
];

Future<ArchiveReader> _open(List<Uint8List> volumes, {int cutoff = 1 << 30}) =>
    const RarFormat().openReader(
      MemoryByteSource(volumes.first),
      ArchiveReadOptions(
        nextVolume:
            (v) async =>
                v <= volumes.length && v <= cutoff
                    ? MemoryByteSource(volumes[v - 1])
                    : null,
      ),
    );

Future<int> _read(ArchiveReader r, ArchiveEntry e) async =>
    (await r.openRead(e).toList()).fold<int>(0, (s, c) => s + c.length);

void main() {
  for (final s in [
    (name: 'RAR5 store', vols: _mv5store),
    (name: 'RAR5 compressed', vols: _mv5comp),
    (name: 'RAR4 compressed', vols: _mv4comp),
  ]) {
    group('multi-volume ${s.name}', () {
      test('reassembles and decodes every file (CRC-verified)', () async {
        final r = await _open(s.vols);
        final files = r.entries.where((e) => !e.isDirectory).toList();
        expect(files, isNotEmpty);
        for (final e in files) {
          expect(await _read(r, e), e.uncompressedSize);
        }
        await r.close();
      });

      test('reads files out of order', () async {
        final r = await _open(s.vols);
        final files = r.entries.where((e) => !e.isDirectory).toList();
        for (final e in files.reversed) {
          expect(await _read(r, e), e.uncompressedSize);
        }
        await r.close();
      });

      test('a missing continuation volume is a typed error', () async {
        // Serve only volume 1; a split file's data cannot complete.
        await expectLater(
          _open(s.vols, cutoff: 1),
          throwsA(isA<UnexpectedEofException>()),
        );
      });
    });
  }

  test('multi-volume without a resolver is a typed error', () async {
    await expectLater(
      const RarFormat().openReader(
        MemoryByteSource(_mv5store.first),
        const ArchiveReadOptions(),
      ),
      throwsA(isA<UnsupportedFeatureException>()),
    );
  });
}
