# koni_sevenz — implementation notes

Decisions made where the format description leaves room, matched against
7zz as the reference tool (PROMPT_V1.md §13.3).

## Spec provenance (§13.7)

Implemented from `7zFormat.txt` and `lzma-specification.txt` in the LZMA
SDK (Igor Pavlov, public domain). LZMA/LZMA2/BCJ/delta decoding lives in
koni_codecs and is differential-tested against liblzma via CPython.

## Laziness caveat (§4)

The 7z header block is usually itself LZMA-compressed (`kEncodedHeader`),
so `open` decodes it — bounded by a 64 MiB header sanity cap (§7). No
entry content is decoded at open.

## Folder decoding model

A folder (solid block) decodes as a whole into one buffer: the first coder
(Copy/LZMA/LZMA2/Deflate) decompresses the packed stream, subsequent
coders must be size-preserving filters (Delta, BCJ x86) applied in place.
Supported folders are simple chains — single packed stream, 1-in/1-out
coders; anything else (BCJ2's four streams) is a typed error. Folder
allocations are capped at 1 GiB (§7: forged sizes must not OOM; real solid
blocks sit far below).

## Solid-block LRU cache (§8)

Decoded folders are cached in an LRU capped at 64 MiB total, keyed by
folder index; the most recently decoded folder is always kept even when it
alone exceeds the cap. This is what makes CB7 page-flipping usable — see
bench/results. Random access to entry N in a solid block costs one folder
decode; every other entry in that block is then a memory slice.

## Metadata mapping

- Directories: empty-stream files that are not empty *files*, or the
  FILE_ATTRIBUTE_DIRECTORY bit.
- Unix modes: attribute high word when the 0x8000 convention bit is set
  (p7zip); S_IFLNK marks symlinks (target is the entry content, like ZIP).
- MTime: Windows FILETIME converted with exact integer arithmetic to
  millisecond precision (sub-ms is dropped; web DateTime is ms anyway).
- Archives with streams but no FilesInfo expose entries named `streamN`.

## Deliberate limits (typed errors)

BCJ2 and PPMd (§8 deferred), AES (encrypted streams at `openRead`;
encrypted headers at open), bzip2/ARM-filters/unknown codecs (named with
their id), external headers/names, multi-volume (§15).

## Writing: the buffering caveat (P2-4a)

A 7z file is `[32-byte signature header][packed streams][header]`. The
signature header sits at offset 0 but records the *offset, size, and CRC of
the trailing header* — unknown until every packed stream and the header are
produced. An append-only `ByteSink` (§16) cannot seek back to patch offset
0, so the writer buffers the packed streams in memory and, at `close`, emits
signature header + packed data + header in one pass. Input still streams
through the compressor (only the compressed output accumulates), so peak
memory is bounded by the *compressed* archive size — but this is a genuine
departure from the TAR/ZIP streaming invariant and is inherent to appending
a random-access format, not a shortcut. Documented on `SevenZWriter` and in
`doc/features.md`.

## Writing: layout (P2-4a)

One folder per non-empty file (non-solid), each a single Copy or Deflate
coder, 1-in/1-out, no properties. This keeps the header the exact inverse of
what the reader parses and lets `SubStreamsInfo` be omitted entirely: with
one substream per folder, the per-folder CRC in `UnpackInfo` *is* the
substream CRC. The header is written uncompressed (`kHeader`, not
`kEncodedHeader`). Solid folders, header compression, and LZMA/LZMA2 are
P2-4b (see `doc/writing-scope.md`); until then there is no cross-file
compression and header overhead scales with the file count.

## Writing: metadata encoding (inverse of the reader)

- Empty content (files and empty-target links) → empty-stream + empty-file,
  no folder. Directories → empty-stream, *not* empty-file, DOS directory
  bit. This is the three-way distinction the reader decodes.
- Names: UTF-16LE, null-terminated, in file order (no trailing separators —
  7z stores plain names, unlike ZIP).
- Attributes: when a unix mode is meaningful, the `FILE_ATTRIBUTE_UNIX_EXTENSION`
  (0x8000) flag with the full `st_mode` in the high 16 bits — S_IFREG /
  S_IFDIR / S_IFLNK. Symlinks store the target as content; `7zz -snl`
  restores them (verified in interop).
- FILETIME (mtime): the exact inverse of the reader's conversion, split into
  32-bit halves with `%`/`~/` arithmetic that stays below 2^53 (JS-safe).

## Writing: default codec (provisional)

Deflate is the default (compressed-by-default, like ZIP). When P2-4b lands
the LZMA2 encoder, the default becomes LZMA2 — a deliberate, tracked default
change, noted so it is not a surprise. `stored` (Copy) is always selectable
per entry or globally.
