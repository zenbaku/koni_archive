# koni_gzip: implementation notes

Decisions made where the gzip format left room.

## Single-entry model

A bare `.gz` opens as a one-entry archive. The entry name comes from the
FNAME field when present, else from the source name with a trailing `.gz`
dropped (`ByteSource.name`, a file path or browser File name), else
`data`. FNAME is attacker-controlled and goes through `normalizeEntryPath`
like every other path.

## Sizes and laziness

Opening reads only the member header (first bytes) and the trailer (last
8 bytes); no decompression. `uncompressedSize` is the final ISIZE
field: exact for single-member files under 4 GiB (ISIZE is mod 2^32);
for multi-member files it reflects only the last member. Real integrity
does not depend on it: each member's CRC-32/ISIZE is verified during
streaming (opt-out via `verifyChecksums: false`). `compressedSize` is the
whole container length (framing included).

## Multi-member files

Decoded as one concatenated stream, gzip(1) semantics. The entry is named
by the first member's header.

## Error translation

Codec errors are `FormatException`; the reader maps messages
containing "mismatch" to `ChecksumMismatchException`, "truncated" to
`UnexpectedEofException`, and everything else to
`CorruptArchiveException`, all carrying gzip/entry context.

## tar.gz layering (M6)

`GzipFormat(layeredFormats: [...])` probes the given formats against the
*decompressed* content via `GzipDecompressedByteSource`; the first match
reads the inner archive (the facade layers TAR, so `.tar.gz`/`.tgz`
presents as the inner TAR and `Archive.format` reports `tar`). Dependency
rules forbid koni_gzip from importing koni_tar, which is why the
composition happens in the facade and the mechanism here is generic.

**Cost model:** gzip has no random access. A read at offset N decodes
sequentially up to N and caches *all* decoded bytes in memory; later reads
(including backwards seeks) are served from the cache. Peak memory ≈ the
decompressed bytes touched so far; for a TAR walk that means the whole
inner tarball by the time the last entry is read. A zran-style seek index
is deferred. Only head-sniffing formats belong in `layeredFormats`:
a probe that reads near EOF (like ZIP's) would decode the entire container
during detection.

The inner source's `length` is the trailing ISIZE (exact for
single-member < 4 GiB); a container whose real decoded size differs fails
with a typed error when discovered.
