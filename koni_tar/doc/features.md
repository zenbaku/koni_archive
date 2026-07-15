# koni_tar — feature matrix

## Supported

| Feature | Notes |
| --- | --- |
| POSIX ustar | incl. the 155-byte path prefix field |
| PAX extended headers (`x`) | `path`, `linkpath`, `size`, `mtime` (sub-second, pre-epoch); other records parsed and ignored |
| PAX global headers (`g`) | apply to subsequent entries; per-file records win |
| GNU long name (`L`) / long link (`K`) | any length (1 MiB sanity cap, §7) |
| Old GNU format | `ustar  \0` magic |
| Pre-POSIX v7 | no magic; detected via header checksum |
| Base-256 numeric fields | sizes > 8 GiB, pre-1970 mtimes |
| Entry types | file, directory, symlink, hardlink, fifo, character/block device, contiguous (as file), unknown (as `other`) — all metadata-only |
| Duplicate paths | all exposed, index order |
| `.cbt` comic archives | plain tar by another name |
| Signed header checksums | historic tars |
| Streaming reads | 64 KiB chunks, bounded memory for any entry size |

## Detected → typed error

| Feature | Error |
| --- | --- |
| GNU sparse (old `S` and PAX `GNU.sparse.*`) | `UnsupportedFeatureException` at `openRead`; listing still works |
| Numeric fields beyond 2^53 − 1 (uniform cap, all platforms) | `UnsupportedFeatureException` |

## Writing (Phase 2, P2-2)

| Feature | Notes |
| --- | --- |
| ustar output | the interoperable default |
| PAX extended headers | emitted for long names/links and >8 GiB sizes |
| name/prefix split | long names that fall on a `/` use ustar's prefix field |
| Directories, symlinks, other types | via `addEntry` |
| Streaming input | `addStream` with a required, validated size |

## Out of scope

Sequential (non-seekable) input for reading, multi-volume archives, GNU
long-name (`L`) emission (PAX is used instead — more portable).

## Spec references

- POSIX.1-2017 `pax` interchange format (ustar + extended headers)
- GNU tar manual, "GNU tar and POSIX tar" / "Sparse Files" appendices
- No source code from GPL implementations was consulted (§13.7); behavior
  cross-checked against bsdtar/GNU tar binaries as reference tools.
