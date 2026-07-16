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
delta filter on 37 pages of one volume). The following RAR4 features are
**deferred as typed errors**: PPMd variant H and *custom* (non-standard) VM
filter programs — a license-bounded boundary, not a difficulty one: the
only interpreter reference is GPL unrar, and the standard filters are the
ones real archives emit. File encryption (`-p`) is supported on both
versions and RAR5 header encryption (`-hp`) reads with a password (see
below); RAR4 `-hp` and multi-volume stay typed errors (§15).

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
LZ window. Symbol 257 reads a RarVM filter (see below); PPMd blocks still
throw a `FormatException` the reader maps to `UnsupportedFeatureException`,
so a PPMd entry never bricks the rest of the archive.

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
