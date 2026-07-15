# koni_zip — feature matrix

## Supported

| Feature | Notes |
| --- | --- |
| Stored entries (method 0) | streamed in 64 KiB chunks, bounded memory |
| Deflate entries (method 8) | via koni_codecs (M5); decoded-size and bomb guards (§7) |
| ZIP64 (M7) | EOCD64 record + locator (prefix-tolerant), per-entry 0x0001 extras; values beyond 2^53 − 1 → typed error |
| Caller-supplied name decoder (M7) | `ArchiveReadOptions.entryNameDecoder` for unflagged names (Shift-JIS mojibake etc.) |
| Traditional PKWARE decryption (P3-2) | `ArchiveReadOptions.password`; 12-byte header check byte (CRC or DOS-time high byte); decrypt→inflate |
| WinZip AES decryption (P3-2) | method 99, AES-128/192/256-CTR + PBKDF2-HMAC-SHA1 key derivation, 2-byte verifier, HMAC-SHA1 authentication; AE-1 verifies the plaintext CRC, AE-2 relies on the MAC |
| Data descriptors with or without `PK\x07\x08` | central directory values are authoritative |
| CRC-32 verification | on by default, errors the stream at its end; `verifyChecksums: false` opt-out (§7) |
| EOCD scan | comments up to 64 KiB, trailing-junk tolerance |
| Prefixed / SFX archives | offset delta recovered from the EOCD |
| Data-descriptor archives (flag bit 3) | central directory values are authoritative |
| Filename encodings | UTF-8 flag honored; strict-UTF-8-then-CP437 fallback |
| Timestamps | DOS (2 s, wall-time-as-UTC) + `UT` extra field (unix, 1 s) |
| Unix modes / symlink typing | from external attributes (host 3) |
| Implicit directories | synthesized by the facade VFS view (§4) |
| Duplicate paths | all exposed, index order; `entry()` is last-wins |
| `.cbz` comic archives | stored + deflated CBZs work end-to-end |

## Writing (P2-3)

| Feature | Notes |
| --- | --- |
| Stored entries (method 0) | streamed; declared size validated against bytes |
| Deflate entries (method 8) | default; via koni_codecs `RawDeflater`, universally decodable |
| Per-entry / global compression | `ArchiveEntrySpec.compression` overrides `ArchiveWriteOptions` |
| Streaming, append-only output | local header + data descriptor (flag bit 3); no seek-back, works to a socket/Blob sink |
| Data descriptors | `PK\x07\x08` + crc/csize/usize after each entry |
| Central directory + EOCD | assembled at `close()`; central values authoritative |
| ZIP64 (EOCD64 + locator, 0x0001 extras) | emitted only when count > 0xFFFF or a size/offset > 32-bit; interop-validated at 70k entries |
| Directories | zero-length stored entries, trailing `/` |
| Symlinks | target stored as content, S_IFLNK external attribute |
| UTF-8 names | always, with language-encoding flag (bit 11) |
| Unix mode / DOS timestamp | external attributes (host 3); DOS 2 s wall-time-as-UTC |
| Path safety | `validateWritePath` rejects absolute/drive/`..`-escape with `ArgumentError` |
| Size-mismatch guard | too few bytes → `CorruptArchiveException`; too many → `SizeLimitExceededException` |
| Interop DoD | Info-ZIP `unzip -t` validates and `unzip` extracts our output byte-for-byte (incl. ZIP64 + unicode) |

## Detected → typed error

| Feature | Error |
| --- | --- |
| Methods other than stored/deflate (bzip2, lzma, ppmd, zstd, …) | `UnsupportedCompressionException` naming method + id, at `openRead` |
| Encrypted entry, no password supplied | `EncryptedArchiveException` at `openRead`; listing works |
| Wrong password | `InvalidPasswordException` (AES verifier / traditional check byte); a traditional-cipher false accept is caught by the CRC |
| ZIP strong encryption (SES, bit 6) | `EncryptedArchiveException` — patent-encumbered legacy, out of scope (`doc/encryption-scope.md`) |
| Multi-volume (spanned, incl. ZIP64 disk fields) | `UnsupportedFeatureException` (§15 non-goal) |

## Spec references

- PKWARE APPNOTE.TXT (ZIP file format specification)
- WinZip AE-2 encryption specification (AES-CTR + HMAC-SHA1 layout)
- Info-ZIP zip(1)/unzip(1) and 7-Zip 7zz observed behavior as reference
  tools (§13.3); 7zz authors the WinZip AES fixtures
