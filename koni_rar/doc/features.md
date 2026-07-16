# koni_rar — feature matrix

## Supported

| Feature | Notes |
| --- | --- |
| RAR5 store (method 0) | streamed with CRC verification |
| RAR5 compressed (methods 1–5) | clean-room LZ+Huffman decoder |
| RAR5 solid archives | shared window, per-file cache, random access |
| RAR5 filters: delta, x86 (E8/E8E9), ARM | applied in place after decode |
| RAR5 file decryption (`-p`, P3-4) | `ArchiveReadOptions.password`; AES-256-CBC, iterated-HMAC-SHA256 KDF, 8-byte password check, hash-key-tweaked CRC — store, compressed, solid |
| RAR4 file decryption (`-p`, P3-5) | AES-128-CBC, the RAR3 SHA-1 KDF (`0x40000` rounds, header salt); plaintext CRC verified — store and compressed. Fixtures authored with rar 6.24 (7.x cannot create v4) |
| **RAR4 store + method-29** (solid and non-solid) | clean-room v29 LZSS+Huffman — what real CBRs use; corpus-verified vs unrar |
| **RAR 2.0** (unpack v20) **LZ** | clean-room LZSS+Huffman (`rar20_decoder.dart`); byte-exact vs unrar on VM/dart2js/dart2wasm. Fixtures authored with DOS RAR 2.50 under DOSBox. **v26** (RAR 2.6) routes to the same decoder (rardecode maps `20, 26` together) but is **untested** — DOS RAR 2.50 does not author v26. *Solid* v20 continuations are a typed error (below) |
| RAR4 RarVM **standard** filters (delta, x86 E8/E9, RGB, audio) | applied in place after decode; byte-exact vs rar 6.24 |
| **RAR4 PPMd** (variant H, `-mct`) | clean-room Ppmd7 (public-domain) + RAR range decoder; byte-exact vs unrar on VM/dart2js/dart2wasm — non-solid **and solid** |
| RAR4 solid archives (method-29 **and PPMd**) | shared tables/offset-cache/window (method-29) or shared model/escape/window (PPMd) across the run; per-file cache, random access |
| RAR5 header encryption (`-hp`, read) | decrypts headers + data with `ArchiveReadOptions.password` (R2) |
| Multi-volume RAR (RAR4 + RAR5) | split files reassembled via `ArchiveReadOptions.nextVolume` (store + compressed) |
| Entry metadata | UTF-8 names, mtime (UTC), unix modes, dirs, symlinks (RAR5 REDIR) |
| CRC-32 verification | on by default; `verifyChecksums: false` opt-out |
| `.cbr` comic archives | CBR v5 and v4 (the real-world flagship) |

## Detected → typed error

| Feature | Error |
| --- | --- |
| RAR4 *custom* (non-standard) VM filter programs | `UnsupportedFeatureException` at `openRead`; the rest of the archive still reads. License-bounded (only the GPL unrar describes a generic interpreter) |
| RAR4 mid-file PPMd→method-29 (LZSS) block switch | `UnsupportedFeatureException`; needs `-mct` auto-mode over content that alternates text and non-text (rare). A code-0 to another PPMd block *is* handled (see `doc/notes.md`) |
| RAR 1.5 (unpack v15), and the RAR 2.0/2.6 multimedia/**audio** block | `UnsupportedFeatureException`. No correct permissive reference — v15: `rardecode` returns `ErrUnsupportedDecoder`; audio: `rardecode`'s predictor mis-decodes it vs unrar. Only the GPL unrar has either. Store decodes at any version |
| Encrypted entry, no password | `EncryptedArchiveException` at `openRead` (listing works) |
| Wrong RAR5 password | `InvalidPasswordException` (reliable 8-byte check value) |
| Wrong RAR4 password | RAR4 has no check value: surfaces as `ChecksumMismatchException` (stored) or `CorruptArchiveException` (compressed garbage) — never an untyped error |
| RAR4 encrypted headers (`-hp`) | `EncryptedArchiveException` at open — deferred (RAR5 `-hp` reads) |
| Multi-volume without a `nextVolume` resolver | `UnsupportedFeatureException` |

## Provenance (§8, §13.5)

Clean-room per `doc/rar-provenance.md` (owner-approved 2026-07-15). No
unrar or GPL source consulted; container/bitstream layout follows
libarchive's BSD `rar5.c`/`rar.c`, and the PPMd model the public-domain
Ppmd7 codec (attribution in `doc/references.md` and `NOTICE`), verified
against `rar`/`unrar` output.
