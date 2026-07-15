# koni_gzip — feature matrix

## Supported

| Feature | Notes |
| --- | --- |
| Single-member `.gz` | opens as a single-entry archive (§8) |
| Multi-member (concatenated) files | decoded as one concatenated stream |
| FNAME entry naming | else derived from source name, else `data` |
| MTIME | UTC, second precision |
| CRC-32 + ISIZE verification | per member, on by default; `verifyChecksums: false` opt-out |
| FEXTRA / FCOMMENT / FHCRC | parsed (FHCRC verified); 1 MiB header cap (§7) |
| Streaming reads | bounded memory for any entry size |

## Supported (layering, M6)

| Feature | Notes |
| --- | --- |
| `.tar.gz` / `.tgz` presentation as the inner TAR | via `GzipFormat(layeredFormats:)` + `GzipDecompressedByteSource` (sequential decode + full in-memory cache — see doc/notes.md for the cost model) |

## Not yet / out of scope

| Feature | Status |
| --- | --- |
| Random access within `.gz` (zran-style seek index) | deferred (§15) |
| Sequential (non-seekable) input | out of scope Phase 1 (§15) |

## Spec references

- RFC 1952 (gzip file format), RFC 1951 (DEFLATE, via koni_codecs)
- gzip(1) observed behavior as the reference tool (§13.3)
