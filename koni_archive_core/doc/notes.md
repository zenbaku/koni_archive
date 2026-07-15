# koni_archive_core — implementation notes

Decisions made where the spec left room (recorded per §13.3).

## Exception hierarchy shape (M1)

§9 lists the required exception types flat; we nest where it helps `catch`
ergonomics without changing the required names:

- `UnexpectedEofException`, `InvalidHeaderException`, and
  `ChecksumMismatchException` extend `CorruptArchiveException` — truncation,
  bad headers, and checksum failures *are* corruption, and
  `on CorruptArchiveException` should catch them.
- `UnsupportedCompressionException` extends `UnsupportedFeatureException`.
- `EntryNotFoundException` is an addition beyond the §9 list: §4 requires a
  "typed error if absent" from `openReadPath` and no listed type fits.

## ByteSource EOF and close behavior (M1)

- `read()` past the end throws `UnexpectedEofException` (typed), not
  `RangeError`: out-of-range reads are almost always driven by
  attacker-controlled header fields (§7), and the fuzz invariant bans
  `RangeError`. Negative offset/length stays `ArgumentError` — that is a
  programmer error, not archive content.
- `read()` after `close()` throws `ArchiveClosedException` (typed) so that
  `Archive.close()` racing in-flight decodes surfaces typed errors (§4).
- `MemoryByteSource` returns *views* over the caller's buffer (§10, no
  defensive copies); mutating the buffer afterwards is visible.
- `FileByteSource` serializes reads internally over the single
  `RandomAccessFile` cursor: pread *semantics* (no interference), not
  OS-level parallelism.

## ByteReader 64-bit reads (M1)

`readUint64le/be` compose two 32-bit reads (dart2js has no
`ByteData.getUint64`). On the JS target, a value above 2^53 − 1 throws
`UnsupportedFeatureException` instead of silently losing precision; the VM
and dart2wasm read the full range.

## Path normalization (M1, §7)

- Only `..` escaping the root sets the `escapedRoot` flag, per §7's wording.
  Absolute paths and drive letters are stripped silently — they are common
  benign tool output (absolute-path tars), while an escaping `..` is the
  actual traversal signal.
- Trailing `/` is dropped: directory-ness is carried by the entry *type*.
- The normalized path may be `''` for archive-root entries (a bare `/`).

## Detection registry (M1, §5)

- Formats are probed in registration order; first match wins. Registration
  order is therefore meaningful: cheap, precise magics belong first.
- A probe that throws `ArchiveException` counts as "no match" (a 3-byte
  input must not abort detection because one format's probe reads 4 bytes).
  Other error types are bugs and propagate.
- `ArchiveFormatRegistry.openReader` does not take ownership of the source:
  on failure the source stays open so the caller can retry with an explicit
  `format:` or close it themselves.
