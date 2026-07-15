# koni_tar — implementation notes

Decisions made where the spec is ambiguous, matched against the reference
tools (bsdtar/GNU tar) per §13.3.

## Laziness caveat (§4)

`openReader` indexes eagerly and does no content reads, but TAR has no
central directory: indexing inherently reads one 512-byte header per entry
across the whole file. Cost is O(entry count) reads, O(index) memory.

## Header parsing

- **Checksums**: computed over the block with the chksum field as spaces.
  Historic tars summed *signed* bytes; both sums are accepted (GNU tar
  behavior). A block failing both is `InvalidHeaderException`.
- **Numeric fields**: octal with space/NUL padding in any layout; GNU
  base-256 (marker bit 0x80, big-endian two's complement — negative values
  occur in pre-1970 mtimes). Values beyond 2^53 − 1 throw
  `UnsupportedFeatureException` on every platform — one uniform cap (the
  dart2js exact-integer limit; ~9 PB dwarfs any real archive field) rather
  than platform-dependent behavior.
- **Name encoding**: header string fields are decoded as UTF-8 with a
  Latin-1 fallback (old formats don't specify an encoding; decoding never
  throws). PAX values are UTF-8 per POSIX.
- **End of archive**: two consecutive zero blocks, or EOF at a block
  boundary (many writers under-pad); a partial trailing block ends the walk.
  A *lone* zero block between entries is tolerated (matches bsdtar's
  leniency).

## Metadata precedence

PAX (`path`, `linkpath`, `size`, `mtime`) beats GNU long name/link beats the
header field — GNU tar's behavior when both appear. Global (`g`) records
apply to all subsequent entries and are overridden by per-file (`x`)
records. PAX/long-name payloads are capped at 1 MiB (attacker-controlled
allocation, §7).

## Data-block accounting for non-file entries

Hardlink/symlink/directory/device/fifo entries consume **no** data blocks
even when their size field is nonzero (historic tars record the source size
on hardlinks; GNU tar and bsdtar both skip no data there). Their recorded
size is still exposed as metadata. Regular files and unknown type flags
consume `ceil(size/512)` blocks — the conservative choice that keeps the
walk aligned for vendor-specific entries.

## GNU sparse ('S')

Represented, not decoded (§8): old-GNU sparse extension blocks are skipped
so the walk stays aligned, the entry lists with its real size, and
`openRead` throws `UnsupportedFeatureException`. PAX-sparse
(`GNU.sparse.*` attributes) entries are detected the same way. One sparse
entry never bricks the rest of the archive (§9).

## Detection (§5)

`ustar` at offset 257 (POSIX and old-GNU); otherwise block 0 must pass the
header checksum (magic-less v7). An all-zero first block is accepted as an
empty archive when the source length is a multiple of 512 (`tar -cf x.tar
-T /dev/null` produces exactly this; bsdtar lists it as empty). Because the
v7 fallback is heuristic, TAR should be registered *after* precise-magic
formats in a registry.

## Differential testing vs package:archive

package:archive models symlinks/hardlinks as zero-length files and surfaces
GNU `K` (long-link) pseudo-entries as files named after the link target, so
the differential tests compare regular-file content only; link/type shapes
are asserted against bsdtar's listing instead (fixtures test).

## Writing (P2-2)

`TarWriter` emits POSIX ustar, falling back to a PAX (`x`) extended header
when a field does not fit: names longer than the 100+155 name/prefix
fields (and not splittable on a `/`), link targets over 100 bytes, and
sizes past the 11-octal-digit ustar limit (~8 GiB). The header field
encoding mirrors the reader — same block offsets, octal fields, and
signed-tolerant checksum, computed with the chksum field spaced.

Streaming: `addStream` writes the header (size first, as ustar requires)
then streams the data and pads to the 512-byte block; a byte count that
differs from the declared size is a typed error (the header is already
written, so the archive would be corrupt). Directories get a trailing
slash; uid/gid are 0. `close()` writes the two zero end blocks.

**Interop is the definition of done** (`test/tar_writer_interop_test.dart`,
`interop` tag): the system `tar`/`bsdtar` extracts what we write
byte-for-byte, including PAX long-name and unicode entries. Round-trip
through our own reader is also tested but is not sufficient on its own.
