# koni_rar — feature matrix

## Supported

| Feature | Notes |
| --- | --- |
| RAR5 store (method 0) | streamed with CRC verification |
| RAR5 compressed (methods 1–5) | clean-room LZ+Huffman decoder |
| Solid archives | shared window, per-file cache, random access |
| Filters: delta, x86 (E8/E8E9), ARM | applied in place after decode |
| Entry metadata | UTF-8 names, mtime (UTC), unix modes, dirs, symlinks (REDIR) |
| CRC-32 verification | on by default; `verifyChecksums: false` opt-out |
| `.cbr` comic archives | CBR (v5) page-flip benched in bench/results |

## Detected → typed error

| Feature | Error |
| --- | --- |
| RAR4 archives | `UnsupportedFeatureException` (M10 scope) |
| Encrypted entries (`-p`) | `EncryptedArchiveException` at `openRead` |
| Encrypted headers (`-hp`) | `EncryptedArchiveException` at open |
| Multi-volume (split) | `UnsupportedFeatureException` |

## Provenance (§8, §13.5)

Clean-room per `doc/rar-provenance.md` (owner-approved 2026-07-15). No
unrar or GPL source consulted; container/bitstream layout follows
libarchive's BSD `rar5.c` (attribution in `doc/references.md` and
`NOTICE`), verified against `rar`/`unrar` output.
