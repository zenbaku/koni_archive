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
