# koni_xz: implementation notes

Decisions made where the xz format left room.

## Index-driven, read from the end

`.xz` is seekable in koni's model, so the container is parsed backward from
the stream footer, exactly like ZIP's central directory and 7z's end header.
The footer gives the index size; the **index** lists each block's
`(unpaddedSize, uncompressedSize)`; the block start offsets are the running
sum of `roundUp4(unpaddedSize)` from offset 12 (after the stream header). This
is what lets each block's LZMA2 output buffer — which doubles as the LZMA2
dictionary window — be sized exactly without a forward scan, and it makes the
uncompressed size known at open, before any decode.

The per-block header (the filter chain) is parsed lazily at decode time, not at
open: opening reads only the framing (header, footer, index) across every
stream.

## Reconciliation, not assumption (multi-stream)

An `.xz` file may concatenate several streams, each optionally followed by
four-byte-aligned zero padding. The parser walks streams from the end: skip
trailing zero padding (a real footer ends in `YZ`, so its last four bytes are
never all zero — the boundary is unambiguous), read a footer, its index, then
its header, and verify the header flags match the footer flags. It continues
until the file is exactly consumed. Any leftover, an index that does not line
up with its blocks, or a header/footer flag mismatch is a typed
`InvalidHeaderException` — never a silent one-stream assumption.

## Block decode

Each block is independent (its LZMA2 stream starts with a full state + dict
reset), so a fresh `Lzma2Decoder` writes into a fresh, exactly-sized buffer per
block; there is no cross-block dictionary carry (unlike a 7z solid folder). The
compressed data size is derived from the index —
`unpaddedSize - blockHeaderSize - checkSize` — so exactly the packed bytes are
fed to the decoder; the block's optional compressed/uncompressed size fields,
when present, are cross-checked against it. After LZMA2, the non-final filters
are reverse-applied last-to-first (encode order was first-to-last), then the
check is verified.

## Filters

xz allows a chain of up to four filters whose **last** entry is the compressor.
Only LZMA2 (`0x21`) is legal there and the only one supported. The preceding
transform filters supported are delta (`0x03`) and x86 BCJ (`0x04`, start
offset 0), reusing `koni_codecs`' `deltaDecode` / `bcjX86Decode`. Every other
BCJ variant (ARM/ARM64/ARMThumb/PPC/SPARC/IA-64/RISC-V), a non-zero BCJ start
offset (which the whole-buffer BCJ does not model), and any non-LZMA2 final
filter are typed errors, validated before any allocation or decode.

## Integrity checks and CRC-64

The stream flags select the per-block check: None, CRC-32, CRC-64, or SHA-256
(the four algorithms real `.xz` writes). CRC-64 is xz's default, so `koni_xz`
needs it; it lives in `koni_archive_core` as `Crc64` (the `CRC-64/XZ`
parameters). It is held in two 32-bit lanes and verified lane-wise against the
stored little-endian bytes — a native-`int` 64-bit CRC would truncate under
dart2js, the same trap the RAR web gate has caught before. Any other 4-bit
check id is reserved by the spec and rejected at open.

## dart2js arithmetic

Two web-specific hazards, both closed and gated by `xz_web_test.dart` on
dart2js and dart2wasm:

- The multibyte-integer (VLI) decoder never shifts by a variable amount; each
  continuation byte contributes `(byte & 0x7F) * factor` where `factor` is a
  power of two, always exact as a double until the value passes the 2^48 cap
  (a typed error). Sizes and counts therefore decode identically on the VM and
  the web.
- The 2^48 ceiling is written as a decimal literal, not `1 << 48`: a shift of
  32 or more is undefined under dart2js's 32-bit bitwise ops (it silently
  wrapped the constant to a value ≤ 0, which made *every* block count trip the
  guard — caught by the web gate).

## Cost model and bomb guards

The block is the decode unit and its whole output is buffered (it is the LZMA2
window). Default single-threaded `xz` writes one block per stream, so a large
`.xz` decodes one large buffer; `xz -T0 --block-size` splits it into bounded
blocks. `maxEntrySize` rejects a block whose declared uncompressed size already
exceeds it *before* the allocation (the bounded-reader seam only counts yielded
bytes, so it cannot catch an oversized single-block allocation on its own). For
a layered `.tar.xz`, `maxContainerDecodeSize` (falling back to `maxEntrySize`)
caps the open-time decode against the index total before any block is decoded.

## Error translation

The container layer throws typed `ArchiveException`s directly. The LZMA2 codec
throws `FormatException`; the reader and the decompressed source map that to
`CorruptArchiveException` with xz/entry context. A failed check throws
`ChecksumMismatchException` (an `ArchiveException`) straight through.

## Writing

`XzWriteFormat` / `XzWriter` mirror the read side. `.xz` is a single-member
container, so the writer takes exactly one file entry (a second `add*`, or a
directory / link / other type, is rejected) and has no encryption (a password is
rejected, as TAR does). The one entry is LZMA2-compressed by the existing
`koni_codecs` `Lzma2Encoder` (a one-shot whose output already *is* an xz LZMA2
block payload, with the leading state+props+dict reset and the `0x00`
terminator), then framed as a single-block, single-stream `.xz`: stream header →
block header (one LZMA2 filter, `dictSizeProp` property byte, no optional sizes)
→ compressed data → block padding → CRC-64 check → index → footer. `xz_write.dart`
builds it; every constant it emits is the inverse of a check the reader already
performs, so the two are symmetric by construction.

The VLI **encoder** uses `%`/`~/`, never a bitwise `& 0x7F`, for the same
dart2js reason the decoder avoids variable shifts. The MVP is deliberately
narrow — single LZMA2 block, CRC-64 check, no transform filters — matching what
default `xz` emits; splitting large input into multiple blocks to bound memory
is the obvious future enhancement (the encoder is one-shot, so the payload is
buffered while encoding, the same caveat as the 7z LZMA path). `.xz` stores no
filename, so `ArchiveEntrySpec.path` is not written and a write-then-read round
trip preserves content, not the name (the reader derives it from the source
name).

**Verified** two ways, per the project's "CI never needs the tools" policy: a
write→our-own-reader round trip is the cross-platform gate (VM + dart2js +
dart2wasm); `xz -d` decoding our output byte-exact is a VM-only, skip-guarded
interop extra. The empty stream, being fully byte-determined, is asserted
identical to the `xz`-authored `empty.xz` fixture.

## Provenance

The container walk (read and write) is a clean-room implementation from the
public xz file format specification (<https://tukaani.org/xz/xz-file-format.txt>).
The LZMA2 decoder/encoder and the delta / x86 BCJ filters are the existing
`koni_codecs` implementations (the BCJ following the public-domain LZMA SDK /
xz-embedded reference; see `koni_codecs/lib/src/filters.dart`). CRC-64 uses the
standard `CRC-64/XZ` parameters.
