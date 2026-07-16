# koni_sevenz: feature matrix

## Supported

| Feature | Notes |
| --- | --- |
| LZMA, LZMA2, Copy, Deflate folders | decoded via koni_codecs |
| Delta and BCJ (x86) filter chains | applied in place after decompression |
| Solid blocks | whole-folder decode + size-capped LRU cache |
| Compressed (kEncodedHeader) headers | decoded at open |
| AES-256 decryption (P3-3) | `ArchiveReadOptions.password`; iterated-SHA-256 KDF (UTF-16LE password), AES-256-CBC peeled ahead of the codec chain; solid folders and encrypted headers (`-mhe`, password needed at open) |
| Substream CRC-32 verification | on by default; `verifyChecksums: false` opt-out |
| Entry metadata | names (UTF-16), mtimes (FILETIME→UTC ms), unix modes, dirs, symlinks, empty files |
| `.cb7` comic archives | solid CB7 page-flip benched in bench/results |

## Detected → typed error

| Feature | Error |
| --- | --- |
| BCJ2, PPMd, bzip2, other codecs | `UnsupportedCompressionException` naming codec + id, at `openRead`; listing works |
| AES-encrypted stream, no password | `EncryptedArchiveException` at `openRead` (listing works) |
| AES-encrypted header, no password | `EncryptedArchiveException` at open |
| Wrong password | no verifier exists in 7z: surfaces as `CorruptArchiveException` (bad LZMA/inflate) or `ChecksumMismatchException`, never an untyped error |
| Multi-volume, external headers/names | `UnsupportedFeatureException` |

## Writing (P2-4a container, P2-4b LZMA)

| Feature | Notes |
| --- | --- |
| LZMA2 folders (coder `21`) | **default**; via koni_codecs `Lzma2Encoder`, buffers the entry while encoding (the buffer is the match window) |
| LZMA folders (coder `03 01 01`) | selectable; via koni_codecs `LzmaEncoder`, same buffering |
| Compressed headers (kEncodedHeader) | header LZMA-compressed whenever that is smaller; plain otherwise |
| Copy folders (method `00`) | streamed through the compressor; declared size validated |
| Deflate folders (method `04 01 08`) | selectable; via koni_codecs `RawDeflater` |
| Per-entry / global compression | `ArchiveEntrySpec.compression` overrides `ArchiveWriteOptions` |
| Container | signature + start header (next-header CRC), PackInfo, UnpackInfo, per-folder CRC-32, uncompressed FilesInfo |
| Metadata | UTF-16LE names, FILETIME mtimes, unix mode + symlink/dir typing via the Windows attribute word |
| Directories / empty files | empty-stream (+ empty-file) encoding, no folder |
| Symlinks | target stored as content, S_IFLNK in the attribute word; `7zz -snl` restores the link |
| Path safety | `validateWritePath` rejects absolute/drive/`..`-escape with `ArgumentError` |
| Size-mismatch guard | too few → `CorruptArchiveException`; too many → `SizeLimitExceededException` |
| Interop DoD | `7zz t` validates and `7zz x` extracts byte-for-byte (all four coders incl. multi-chunk + fallback LZMA2 and encoded headers; dirs, empty, unicode, symlink, 300-entry multi-byte numbers); the LZMA codecs are additionally liblzma-verified in koni_codecs |

**Not streaming, by construction.** Unlike TAR/ZIP writing, 7z writing
**buffers the compressed packed streams in memory** until `close()`: the
format's leading signature header records the *offset/size/CRC of the
trailing header*, which an append-only sink cannot patch in retrospect.
Input still streams through the compressor, so peak memory is bounded by the
*compressed* archive size, but a Copy-stored `.cb7` effectively holds the
whole archive in RAM. This is inherent to appending a random-access format.

**Deferred to P2-4b (tracked, not silent):** LZMA/LZMA2 folders (and the
default codec switching from deflate to LZMA2), compressed (kEncodedHeader)
headers, and solid folders (today: one folder per non-empty file, so no
cross-file compression and header overhead scales with file count). See
`doc/writing-scope.md`.

## Spec references

- 7zFormat.txt, lzma-specification.txt (LZMA SDK, public domain)
- 7zz observed behavior as the reference tool
