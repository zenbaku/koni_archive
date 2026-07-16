# koni_rar — implementation notes

Decisions made where the format is undocumented, matched against `rar`/
`unrar` output (§13.3). Provenance: see `doc/rar-provenance.md` (clean-room
policy, owner-approved) and `doc/references.md` (BSD/libarchive attribution).

## Scope (M9 + M10)

RAR5 (`Rar!\x1A\x07\x01\x00`): store and compressed methods 1–5, solid
and non-solid, with delta / x86 (E8/E8E9) / ARM filters.

RAR4 (`Rar!\x1A\x07\x00`, M10): the v1.5 container + store and the
method-29 (v2.9/v3+) LZSS+Huffman codec, **solid and non-solid**, including
the **RarVM standard filters** (see `rar4_filters.dart`). This is what the
real-world CBR corpus uses (`-m0` store, `-m3`/`-m5` method-29, and the
delta filter on 37 pages of one volume). **PPMd variant H** ("text
compression", `-mct`) is also decoded — see the PPMd section below. **Solid PPMd runs** decode too (see the PPMd section). The
following RAR4 features stay **typed errors**: *custom* (non-standard) VM
filter programs (license-bounded — the only reference is GPL unrar), and a
mid-file PPMd→method-29 block switch (implementation-scoped — the BSD
`rardecode` reader shows the path, but the PPMd↔LZSS loop hand-off is
unimplemented).
File encryption (`-p`) is supported on both
versions and RAR5 header encryption (`-hp`) reads with a password (see
below). **Multi-volume sets read** (both versions) when the caller supplies
the other volumes via `ArchiveReadOptions.nextVolume` (see below). RAR4
`-hp` stays a typed error (§15).

## Container

Base blocks: `CRC32, varint(headerSize), headerType, flags, [extraSize],
[dataSize], body, extra`. File headers carry flags, unpacked size,
attributes, optional mtime/CRC, compression info (method, version, solid,
dict shift), host OS, and a UTF-8 name. Extra records (encryption at 0x01,
redirect/symlink target at 0x05) sit at the header tail. Service headers
(metadata) are parsed and skipped. RAR5 stores version 0 meaning "5.0";
the reader normalizes to 50.

## RAR5 decompressor

An LZ77 scheme with Huffman-coded literals (NC=306), a 4-slot distance
cache, length/distance slot codes, and a 20-symbol bit-length table used to
build the others. Bit order is MSB-first. Blocks carry a 1-byte flags +
checksum + 1–3-byte size header; the Huffman tables (when present) are RLE-
encoded nibbles followed by table-code entries.

The output buffer *is* the LZ window and must be a power of two (indices
mask with `& (size-1)`). Non-solid files allocate a window big enough to
hold the whole file without wrapping (so every byte survives until read
out). Solid runs share one decoder across the run and extract each file's
region right after decoding it, before the window wraps — random access to
a late file decodes the run once; a backward jump rebuilds from the run
start. Files/runs are capped at 1 GiB (§7).

## Filters

Delta (per-channel byte prediction), x86 E8/E8E9 (relative→absolute call/
jump rewrite), and ARM BL are applied in place over the file's output after
decompression. The x86 filter uses a fixed 16 MiB file-size modulus, per
the format.

## Metadata

Names are UTF-8, decoded permissively (U+FFFD on bad bytes — fuzz-hardened,
§7). mtime is unix-seconds UTC. Unix-host attributes carry the st_mode
(low 12 bits exposed as posixMode); a REDIR record makes the entry a
symlink with the target as metadata. CRC-32 is verified by default.


## RAR4 method-29 decompressor (M10)

`rar4_decoder.dart`: LZSS with four canonical Huffman codes (main 299,
offset 60, low-offset 17, length 28) built from a 20-symbol precode, a
4-entry repeated-offset cache, and short/long match forms. The bitstream
is MSB-first and continuous across the file (in-band `256` markers start
new table blocks, not sub-headers). Codes assign in RAR's `create_code`
order (length, then symbol); the decoder uses a flat lookup table sized to
the longest code (≤15 bits). The length/offset base tables are the
standard v29 tables. As with RAR5, the output buffer is the power-of-two
LZ window. Symbol 257 reads a RarVM filter (see below); a PPMd block (the
block-type bit set) hands off to the PPMd decoder (see the PPMd section).

The MSB-first bit reader and the canonical Huffman decoder live in
`rar_bits.dart` (`Bits`/`Huffman`), shared with the v20 decoder below.

## RAR 2.0 / 2.6 decompressor — R9

`rar20_decoder.dart` (`Rar20Decoder`): older `.rar` archives declare unpack
version 20 (RAR 2.0) or 26 (RAR 2.6) — a different LZSS+Huffman scheme from v29.
v26 routes to the same decoder (`rardecode` maps `case 20, 26` together) but is
**untested** — DOS RAR 2.50 authors only v20, so there is no v26 fixture.
The container preserves the raw unpack-version byte as
`Rar5FileHeader.unpackVersion` (distinct from the `version` family marker, so
RAR4/RAR5 decoder dispatch is untouched); the reader routes v20/v26 compressed
files here, v29 to `rar4_decoder.dart`, and store (version-agnostic) straight
through.

Each block starts with an *audio* bit and a *keep-table* bit, then a code-length
table read via a 19-symbol pre-code (delta nibbles; 16 = repeat, 17/18 = zero
runs — no 0xF escape, unlike v29). A non-audio block builds three Huffman codes
(main 298, offset 48, length 28) and decodes: symbols <256 are literals, 256
reuses the previous offset+length, 257–260 take a length with an offset from the
4-entry history, 261–268 are short offsets, 269 ends the block, and 270+ are
normal matches (length index + a separate offset symbol). The LZ base tables are
the standard RAR tables (shared with v29, first 48 offset slots). Structure
adapted from the BSD `rardecode` (`decode20.go`/`decode20_lz.go`); byte-exact vs
`unrar` on VM/dart2js/dart2wasm (`test/rar2_web_test.dart`).

Fixtures can't be authored by any modern tool (rar ≥3 writes v29; rar 2.x is a
32-bit i386 binary Rosetta 2 can't run) — they were made with **DOS RAR 2.50**
under **DOSBox** (see `rar_static/README.md`), with `unrar` as the oracle.

**Typed errors (reference-bounded):** the **multimedia/audio** block mode — the
BSD `rardecode`'s audio predictor mis-decodes it (verified: `rardecode` itself
fails the audio fixture's CRC against `unrar`), so no correct permissive
reference exists; and **unpack version 15** (RAR 1.5), which `rardecode` rejects
outright (`ErrUnsupportedDecoder`) and libarchive never implemented. Only the GPL
unrar has either — the same license boundary as the custom RarVM interpreter.

A **solid** v20 run is also a typed error on continuation files: the run's first
file (a non-solid header) decodes via the normal path, but a continuation would
misroute to the method-29 solid path, so it is rejected cleanly. Full solid-v20
decode is deferred (doubly rare: vintage + solid; `rar_static/rar2_solid.rar` is
the fixture).

## RAR4 RarVM standard filters

`rar4_filters.dart`: RAR's method-29 compressor auto-applies a small set of
*standard* filters (post-decode transforms). Each is a fixed VM program the
decoder recognizes by fingerprint — program length + CRC-32, split into two
comparisons to avoid a 64-bit literal on dart2js — and runs natively, exactly
as libarchive's `execute_filter` does. Supported kinds: **delta**, **x86
E8**, **x86 E8/E9**, **RGB** (24-bit image), **audio**. A symbol-257 record
is read inline from the main bitstream (`read_filter`: flags byte + length +
code buffer), parsed (`parse_filter`: filter index, block start/length, VM
registers, and — for a new program — the bytecode, XOR-checked and
fingerprinted), and scheduled. Because this decoder decodes a whole file into
the window first, filters are applied as a post-pass over the file's disjoint
forward regions (the window holds *raw* LZ output; matches during decode copy
raw→raw, so post-hoc filtering is correct). A **custom** (non-standard) VM
program has no pure-Dart interpreter here and is a documented deferral — the
only interpreter reference is GPL unrar, so this boundary is license-bounded,
not difficulty-bounded (`doc/rar-provenance.md`).

Verification (see `test/rar4_filters_test.dart` + the fixtures below):
delta, E8, RGB, and audio each decode **byte-exact** against genuine rar 6.24
output on VM + dart2js + dart2wasm, and the corpus conformance now decodes all
of Twin Spica (37 delta-filtered pages) to unrar's sha256 with zero deferrals.
E8/E9 shares the E8 code path (only the E8 fingerprint was triggerable to
author a fixture); chained filters over the *same* region are handled but rely
on the reader's default CRC-32 verify as their backstop (a wrong result throws
`ChecksumMismatchException`, never silent corruption) rather than a dedicated
fixture. The delta arithmetic matches RAR5's `_delta`; the E8/E9 arithmetic
mirrors RAR5's `_e8e9`.

## RAR4 PPMd (variant H) — R5

RAR's "text compression" (`-mct`) is **PPMd variant H** — Dmitry Shkarin's
PPMII, the same variant 7-Zip carries. `rar4_ppmd.dart` is a clean-room port
of the **public-domain** Ppmd7 codec (Igor Pavlov 2010, from the LZMA SDK, as
vendored by libarchive's `archive_ppmd7.c`): a unit sub-allocator, a
suffix-linked context tree, SEE (secondary escape estimation), and
`Ppmd7_DecodeSymbol`. The C code addresses model nodes as 32-bit offsets into
a byte pool (`Base`), and the `CPpmd7_Context`/`CPpmd_State` structs alias (a
one-symbol context overlays its state on `SummFreq`+`Stats`) — the port keeps
that representation exactly (a `Uint8List` pool read through a little-endian
`ByteData`), because the free-list/glue logic and the aliasing depend on it.
All range-coder arithmetic is masked to 32 bits so dart2js (doubles, exact
only to 2^53) matches the VM and native C.

The **RAR range decoder** (`PpmdRarRangeDecoder`) is RAR's variant, not
7-Zip's: no leading zero byte on init, `Bottom = 0x8000`, and `Decode`/
`DecodeBit` work in `Low`/`Range` space. A PPMd block header (parsed in
`rar4_decoder.dart` `_parsePpmdBlock`, following libarchive's `parse_codes`)
is a 7-bit flags field, an optional memory byte (flag `0x20` → MB), and an
optional escape byte (flag `0x40`); `0x20` set allocates a fresh model of the
given order, `0x20` clear reuses the model, re-initialising only the range
decoder. Decoding follows libarchive's escape-char dispatch: a non-escape
symbol is a literal; an escape introduces a control code — `0` a new table
block, `2` end-of-data, `4`/`5` LZ matches (distance from three PPMd symbols +
2, or distance 1), and the `3` (RarVM filter) case stays a typed error. The
model's own `PpmdError` and any out-of-range access on corrupt state both map
to a typed `FormatException` (never an untyped crash) — fuzz-verified over
100k+ mutated iterations.

Reference / provenance: the model is public-domain Ppmd7; the RAR glue is
libarchive's BSD `rar.c`. **No unrar or GPL source was consulted** (`rar.c`
carries PPMd via the same public-domain codec). Verified byte-exact against
`unrar`/CRC-32 across a battery from 82 B to 2.6 MB, order 2–63, memory
1–8 MB, on VM + dart2js + dart2wasm (`test/rar4_ppmd_web_test.dart`,
`rar_static/ppmd_rar4*.rar`). The manga corpus never triggers PPMd (RAR picks
it for text, and comics are images), so these authored fixtures are the only
ground truth. Notably libarchive 3.7.4 *fails* the `ppmd_rar4_runs` stream
(`Internal error extracting RAR file`) where this decoder and `unrar` succeed.

**Benchmark (§13.2):** PPMd never appears in the manga corpus (RAR picks it for
text, comics are images), so there is no page-flip / random-access bench like
M8/M10. The hot path is instead measured synthetically as sequential decode
throughput: ~5.5 MB/s uncompressed on a 2.6 MB order-63 / 1 MB-memory stream,
~2.4 MB/s on a 600 KB order-16 / 8 MB stream (Dart VM, warm). PPMd is
inherently a per-symbol context model, so this is expected to be much slower
than method-29's LZSS — decode speed, not compression, is the trade the format
makes.

**Branch coverage:** the committed fixtures exercise literals, rescale/glue,
model restart, the code-4/code-5 LZ escapes, and (via `solid_ppmd.rar`) the
code-2 end-of-file marker and cross-file model/escape carry-over. The remaining
shipped branches — code-0 (mid-file block switch), code-3 (PPMd-embedded
filter), and the `default` escape-as-literal case — are **not** reachable from a
committed fixture (`-mct+` never emits filters, and rar keeps one block per file
for normal content, even at 2.6 MB). code-0→LZSS was confirmed to fire (and
throw its typed error) during bring-up on an `-mct` auto-mode stream
(uncommitted for size); code-0→PPMd and code-3/default are 1–3-line mirrors of
`rardecode`/libarchive dispatch, verified by inspection.

**Solid PPMd** decodes whole (`decompressSolidPpmdFile` per member, sharing one
model/escape/window across the run; `rar_reader.dart` `_decodeSolidPpmdRun`).
Each solid file is its own PPMd block ending with an escape-code-2 marker whose
symbols update the shared model — so the run is decoded to that marker, not to a
byte count, and the marker is consumed to keep the model in sync for the next
file. The RAR-block escape symbol carries across files (flag 0x40 sets it,
otherwise it persists — a continuation inherits the first block's escape).
libarchive supports no solid RAR at all, so the solid *control flow* was adapted
from the BSD Go `rardecode` reader; the model stays the public-domain Ppmd7.
Verified byte-exact vs unrar/CRC on 2–5-file runs, a 1-byte member, and
2×730 KB members, on VM/dart2js/dart2wasm (`solid_ppmd.rar`, and larger runs
verified locally).

**Still a typed error** (reference-bounded, not difficulty-bounded): a *mid-file*
PPMd→method-29(LZSS) block switch (escape code `0` selecting an LZSS block).
`rardecode` handles it by resuming the shared Huffman bit-reader where the range
decoder's read-ahead left off; wiring that PPMd↔LZSS hand-off into this decoder's
loop is unimplemented, so it stays an `UnsupportedFeatureException`. A code-0 to
another *PPMd* block is handled (the model carries over). This case needs `-mct`
auto-mode over content that alternates text and non-text; normal PPMd content
(even a single 2.6 MB file) never emits it.

## RAR4 solid runs

A solid run shares compression state across files. Unlike RAR5 (which
rebuilds Huffman tables per file and only shares the window), RAR4 keeps the
**tables, the repeated-offset cache, and the window** across the run: only
the run's first compressed file carries a table block; every later file's
packed data is its own byte-aligned bitstream that reuses the existing
tables. `Rar4Decoder.decompressFile` takes `parseTable:` — true for the first
compressed file (or any non-solid file), false for continuations — and the
reader (`_decodeSolidRar4`) drives one decoder across the run, picking
`parseTable: !decoder.hasTables` so a stored-file prefix still lets the first
*compressed* file build the tables. The window is sized to hold the whole run
without wrapping, so each file's output is a direct slice, cached for repeat
or out-of-order reads (an out-of-order read rebuilds the run from its start).
`hasTables` checks **all four** codes so a `_parseCodes` that threw part-way
on mutated input is never mistaken for a usable table set, and a mid-run
decode error drops the shared decoder so the next read rebuilds cleanly
(both hardened via the fuzz pool, which seeds `rar_static/solid_rar4.rar`).
Verified byte-exact (sha256) against `unrar` on a five-file run whose files
cross-reference each other, on VM + dart2js + dart2wasm
(`test/rar4_solid_test.dart`). Reference: none — libarchive's `rar.c`
explicitly bails on solid RAR ("RAR solid archive support unavailable"); this
follows the RAR3 format's continuous-state model, verified empirically.

## RAR4 container (M10)

`rar4_container.dart`: v1.5 base blocks (`crc16, type, flags, size`,
optional 4-byte add-size), MAIN/FILE/ENDARC headers. File data follows its
header; the walk advances by `headerSize + packSize`. Method 0x30 → store,
0x31–0x35 → 1–5. Names are UTF-8 (the RAR4 Unicode name-compression scheme
past a NUL is not decoded — the ASCII/UTF-8 prefix is used; documented
lossiness, rare for CBRs). DOS timestamps → UTC.

## Multi-volume (RAR4 + RAR5)

A multi-volume set is one archive split across `name.part1.rar`,
`name.part2.rar`, … (or `name.rar`, `name.r00`, …). Each volume is itself a
complete RAR archive (signature + main header + blocks + end); the main
header carries a *volume* flag (RAR5 archive-flag bit 0, RAR4 `MHD_VOLUME`
`0x0001`). A file whose data crosses a volume boundary has its **header
repeated in every volume it spans**, flagged `splitBefore` / `splitAfter`
(RAR5 bits `0x08`/`0x10`; RAR4 file-flag bits `0x01`/`0x02`); `unpackedSize`
is the full size in every occurrence, but `dataSize` is only that volume's
slice, and the **authoritative full-file CRC lives on the final segment**
(`splitAfter == false`) — earlier occurrences carry only their slice's CRC.

The reader logic is format-agnostic (`_parseMultiVolume`, `_VolumeSegment`
in `rar_reader.dart`): volume 1 is the source passed to `openReader`; the
rest come from `ArchiveReadOptions.nextVolume(n)` (called with 2, 3, … until
it returns null). It walks every volume, merges each split file's headers
into one logical entry whose packed data is the segments **concatenated**
across volumes, and decodes that whole with the ordinary single-file path —
which works for store *and* compressed because the packed stream is split at
byte boundaries (verified byte-exact vs `unrar`, both, both versions). A
missing continuation volume → `UnexpectedEofException`; a multi-volume
archive opened without a resolver → `UnsupportedFeatureException`. The reader
does not close volumes it obtains this way (the caller owns them). Solid +
multi-volume is not specifically exercised.

## Testing

**CI coverage caveat:** rar 7.x cannot author v4 fixtures. The committed
`rar_static/filter_*.rar` archives (authored with rar 6.24, see below) now
give CI a real, cross-platform regression guard for the method-29 decoder
**and** the standard filters — decoded byte-exact with the default CRC-32
verify on VM + dart2js + dart2wasm (`rar4_filters_test.dart`). The broader
method-29 corpus (solid runs, the full method-3/5 stream space) is still
only exercised by the owner's *local* (gitignored) CBR corpus via the
conformance runner — byte-identical to `unrar` across ~360 real pages,
where a wrong byte throws `ChecksumMismatchException`. Other CI coverage on
every platform: the RAR4 container + store path (a hand-built archive in
`rar4_test.dart`), and both the container and the `filter_*.rar` fixtures
under fuzz (seeded from `rar_static/` into `fuzz_smoke_test.dart`).
## Encryption (P3-4)

RAR5 **file** encryption (`rar -p`) is supported: AES-256-CBC, the
iterated-HMAC-SHA256 KDF, the password-check value, and hash-key-tweaked
CRCs — all in `rar_crypto.dart`, clean-room per `rar-provenance.md` and
pinned byte-exact against `rar`-authored fixtures (store, compressed,
solid). See `../../doc/encryption-scope.md`.

**RAR5 header encryption (`rar -hp`) IS supported** (`ArchiveReadOptions.
password`; wrong password → `InvalidPasswordException`, no password →
`EncryptedArchiveException`). It is decrypted inline during the header walk
in `rar5_container.dart`:

- The `HEAD_CRYPT` block (type 4, plaintext) carries version, flags,
  `lg2Count`, a 16-byte salt, and (flag bit 0) an 8-byte password-check +
  4-byte SHA-256 checksum — same shape as a file encryption record but **no
  IV**. Its salt derives the *block key* (the same HMAC-SHA256 KDF as `-p`);
  the check value verifies the password up front.
- **Each following header block** is `[16-byte IV in the clear][AES-256-CBC
  header, zero-padded to a 16-byte boundary]` — a *fresh IV per block*, not
  one continuous stream. `_readHeaderBytes` reads the IV, peek-decrypts the
  first block to read `CRC + headerSize`, then decrypts `⌈headerSize/16⌉·16`
  bytes; the block occupies `16 + padded` bytes. The end-of-archive block is
  encrypted too, so the walk decrypts it to see type 5 and stop.
- **File data is NOT block-key encrypted** — the block key covers headers
  only. Data stays encrypted solely by the file's own type-0x01 record
  (per-file salt/key/IV) exactly as under `-p`, so it is read from the raw
  source and decrypted by the existing `_decryptRar5` path. (An earlier
  P3-4 note guessed the data was *doubly* encrypted inside a single-CBC
  tail; that was wrong — the framing is per-block-header, and data lives
  outside the header layer.)
- The tweaked CRC uses the file record's **"use MAC" flag (bit 1)**, which
  `-hp` sets *without* the per-file password-check flag (bit 0). The two are
  independent; the CRC tweak keys off bit 1 (`Rar5EncryptionInfo.useMac`),
  the per-file check off bit 0.

Reverse-engineered against `rar 7.x`-authored fixtures and cross-checked
against the Go `rardecode` block framing (BSD; see `doc/references.md`);
libarchive's `rar5.c` has no crypto and could not serve here.

**RAR4 file** encryption (`rar -ma4 -p`, P3-5) IS supported: AES-128-CBC
with the bespoke RAR3 SHA-1 KDF (`0x40000` rounds absorbing
`passwordUtf16le ‖ salt ‖ counter24le`, one IV byte harvested from a
clone-finalize every `0x4000` rounds, the AES key being the final digest's
first 16 bytes with each 4-byte word byte-reversed), keyed by the 8-byte
salt in the file header (SALT flag `0x400`). RAR4 stores the **plaintext**
CRC (no hash-key tweak) and carries no password-check value, so a wrong
password surfaces as a CRC mismatch (stored) or corrupt data (compressed).
Verified byte-exact against genuine encrypted v4 archives.

**Fixture provenance:** the committed `enc_rar4*.rar` fixtures were
authored with **rar 6.24** (`tool/generate_fixtures.dart` runs rar 7.x,
which cannot create v4 — same constraint as the method-29 decoder's
missing fixture). They are committed static files; CI needs only the
committed bytes.

RAR4 encrypted **headers** (`rar -ma4 -hp`) remain deferred (typed error):
their layout uses the RAR3 SHA-1 KDF and differs from the RAR5 `-hp` scheme
above, and no committed v4 fixture exists (rar 7.x can't author v4).
