# koni_sevenz — feature matrix

## Supported

| Feature | Notes |
| --- | --- |
| LZMA, LZMA2, Copy, Deflate folders | decoded via koni_codecs |
| Delta and BCJ (x86) filter chains | applied in place after decompression |
| Solid blocks | whole-folder decode + size-capped LRU cache (§8) |
| Compressed (kEncodedHeader) headers | decoded at open (§4 caveat) |
| Substream CRC-32 verification | on by default; `verifyChecksums: false` opt-out |
| Entry metadata | names (UTF-16), mtimes (FILETIME→UTC ms), unix modes, dirs, symlinks, empty files |
| `.cb7` comic archives | solid CB7 page-flip benched in bench/results |

## Detected → typed error

| Feature | Error |
| --- | --- |
| BCJ2, PPMd, bzip2, other codecs | `UnsupportedCompressionException` naming codec + id, at `openRead`; listing works |
| AES-encrypted streams | `EncryptedArchiveException` at `openRead` |
| AES-encrypted headers | `EncryptedArchiveException` at open |
| Multi-volume, external headers/names | `UnsupportedFeatureException` |

## Spec references

- 7zFormat.txt, lzma-specification.txt (LZMA SDK, public domain)
- 7zz observed behavior as the reference tool (§13.3)
