# koni_rar — implementation notes

Decisions made where the format is undocumented, matched against `rar`/
`unrar` output (§13.3). Provenance: see `doc/rar-provenance.md` (clean-room
policy, owner-approved) and `doc/references.md` (BSD/libarchive attribution).

## Scope (M9 + M10)

RAR5 (`Rar!\x1A\x07\x01\x00`): store and compressed methods 1–5, solid
and non-solid, with delta / x86 (E8/E8E9) / ARM filters.

RAR4 (`Rar!\x1A\x07\x00`, M10): the v1.5 container + store and the
method-29 (v2.9/v3+) LZSS+Huffman codec, **non-solid**. This is what the
real-world CBR corpus uses (`-m0` store and `-m3`/`-m5` method-29). The
following RAR4 features are **deferred as typed errors**, matched to what
the corpus needs: PPMd variant H, the RarVM filter machine (one
double-page spread in the corpus uses a filter), and solid RAR4 (its
cross-file persistent-table semantics differ from RAR5; real CBRs are
non-solid). Multi-volume and encrypted (`-p`/`-hp`) archives are typed
errors across both versions (§15).

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
LZ window. Symbol 257 (filter) and PPMd blocks throw a `FormatException`
the reader maps to `UnsupportedFeatureException`, so one filtered entry
never bricks the rest of the archive (verified against the corpus).

## RAR4 container (M10)

`rar4_container.dart`: v1.5 base blocks (`crc16, type, flags, size`,
optional 4-byte add-size), MAIN/FILE/ENDARC headers. File data follows its
header; the walk advances by `headerSize + packSize`. Method 0x30 → store,
0x31–0x35 → 1–5. Names are UTF-8 (the RAR4 Unicode name-compression scheme
past a NUL is not decoded — the ASCII/UTF-8 prefix is used; documented
lossiness, rare for CBRs). DOS timestamps → UTC.

## Testing

**CI coverage caveat:** rar 7.x cannot author v4 fixtures, so there is **no
committed RAR4 method-29 fixture and CI does not regression-guard the
method-29 decoder.** It is verified only against the owner's *local*
(gitignored) CBR corpus via the conformance runner — byte-identical to
`unrar` across ~360 real pages, which the default CRC-32 verify makes a
strong check (a wrong byte throws `ChecksumMismatchException`). What CI
*does* cover on every platform: the RAR4 container + store path (a
hand-built archive in `rar4_test.dart`) and the RAR4 container under fuzz
(seeded into `fuzz_smoke_test.dart`). The method-29 decoder itself is not
fuzzed (no fixture); the container is.