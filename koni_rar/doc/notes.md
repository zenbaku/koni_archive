# koni_rar — implementation notes

Decisions made where the format is undocumented, matched against `rar`/
`unrar` output (§13.3). Provenance: see `doc/rar-provenance.md` (clean-room
policy, owner-approved) and `doc/references.md` (BSD/libarchive attribution).

## Scope (M9)

RAR5 (`Rar!\x1A\x07\x01\x00`): store and compressed methods 1–5, solid
and non-solid, with delta / x86 (E8/E8E9) / ARM filters. RAR4
(`...\x07\x00`) is detected and refused with a typed error (M10). Multi-
volume and encrypted (`-p`/`-hp`) archives are typed errors (§15).

## Container

Base blocks: `CRC32, varint(headerSize), headerType, flags, [extraSize],
[dataSize], body, extra`. File headers carry flags, unpacked size,
attributes, optional mtime/CRC, compression info (method, version, solid,
dict shift), host OS, and a UTF-8 name. Extra records (encryption at 0x01,
redirect/symlink target at 0x05) sit at the header tail. Service headers
(metadata) are parsed and skipped. RAR5 stores version 0 meaning "5.0";
the reader normalizes to 50.

## Decompressor

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
