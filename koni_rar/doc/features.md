# koni_rar — feature matrix

## Supported

| Feature | Notes |
| --- | --- |
| RAR5 store (method 0) | streamed with CRC verification |
| RAR5 compressed (methods 1–5) | clean-room LZ+Huffman decoder |
| RAR5 solid archives | shared window, per-file cache, random access |
| RAR5 filters: delta, x86 (E8/E8E9), ARM | applied in place after decode |
| **RAR4 store + method-29** (non-solid) | clean-room v29 LZSS+Huffman — what real CBRs use; corpus-verified vs unrar |
| Entry metadata | UTF-8 names, mtime (UTC), unix modes, dirs, symlinks (RAR5 REDIR) |
| CRC-32 verification | on by default; `verifyChecksums: false` opt-out |
| `.cbr` comic archives | CBR v5 and v4 (the real-world flagship) |

## Detected → typed error

| Feature | Error |
| --- | --- |
| RAR4 PPMd blocks | `UnsupportedFeatureException` at `openRead` (corpus doesn't use them) |
| RAR4 RarVM filters (symbol 257) | `UnsupportedFeatureException` at `openRead`; the rest of the archive still reads |
| Solid RAR4 | `UnsupportedFeatureException` (real CBRs are non-solid) |
| Encrypted entries (`-p`) | `EncryptedArchiveException` at `openRead` |
| Encrypted headers (`-hp`) | `EncryptedArchiveException` at open |
| Multi-volume (split) | `UnsupportedFeatureException` |

## Provenance (§8, §13.5)

Clean-room per `doc/rar-provenance.md` (owner-approved 2026-07-15). No
unrar or GPL source consulted; container/bitstream layout follows
libarchive's BSD `rar5.c` (attribution in `doc/references.md` and
`NOTICE`), verified against `rar`/`unrar` output.
