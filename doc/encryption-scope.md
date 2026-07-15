# Phase 3 — Encryption/password support (read side): scope

Status: **in progress** — scoped 2026-07-15. First item of the deferred
backlog (`ROADMAP.md`), promoted to a phase. Follows the standing
constraints: pure Dart, zero runtime deps in shared packages, VM + dart2js +
dart2wasm, typed errors, interop with reference tools is the definition of
done.

## What this phase is (and is not)

**Reading** password-protected archives across every format we read:

| Format | Scheme | In scope |
| ------ | ------ | -------- |
| ZIP    | Traditional PKWARE ("zipcrypto") | ✅ P3-2 |
| ZIP    | WinZip AES (AE-1/AE-2, method 99, AES-128/192/256-CTR + HMAC-SHA1) | ✅ P3-2 |
| 7z     | AES-256-CBC (coder `06f10701`), incl. encrypted headers (`-mhe`) | ✅ P3-3 |
| RAR5   | AES-256-CBC, PBKDF2-HMAC-SHA256, incl. encrypted headers (`-hp`) and hash-key-tweaked checksums | ✅ P3-4 |
| RAR4   | AES-128-CBC, iterated-SHA-1 KDF (salted file data) | ✅ P3-5 |

**Not** in this phase (deferred, typed errors where reachable):

- **Write-side encryption** (ZIP AES, 7z AES). The writers simply do not
  offer it yet; revisit after the read side proves the primitives.
- **ZIP "strong encryption"** (SES, flag bit 6: DES/3DES/RC2/RC4 PKWARE
  scheme) — patent-encumbered legacy, vanishingly rare in the wild. Typed
  error naming it.
- **RAR4 encrypted headers** (main-header flag 0x80: every header block
  encrypted). Rare + RAR4 is legacy; file-data decryption covers real CBRs.
  Typed error, same message as today.
- Key files, certificates, any non-password credential.

## Public API

One new field, one new exception:

- `ArchiveReadOptions.password` (`String?`). Supplied at open; used lazily —
  opening an encrypted archive without a password still lists entries
  wherever headers are plaintext, and only `openRead` of an encrypted entry
  throws. Encrypted *headers* (7z `-mhe`, RAR5 `-hp`) need the password at
  `Archive.open`.
- `InvalidPasswordException extends EncryptedArchiveException` — thrown where
  the format carries an explicit password check. Reliability varies by
  format and is documented on the exception:
  - RAR5: 8-byte check value → practically certain.
  - WinZip AES: 2-byte PBKDF2 verifier → 1/65536 false accept.
  - zipcrypto: 1-byte check → 1/256 false accept (wrong password can also
    surface as `CorruptArchiveException`/`ChecksumMismatchException`).
  - 7z: **no check value exists**; a wrong password surfaces as corrupt
    LZMA data or a CRC mismatch. Documented, not fixable.
- No password when one is needed → `EncryptedArchiveException` (existing
  behavior, message now says a password is required).

Password → bytes per format (documented on `password`): ZIP takes the
UTF-8 bytes (historically "whatever the local codepage was"; UTF-8 is the
modern, ASCII-compatible choice), 7z and RAR4 take UTF-16LE, RAR5 takes
UTF-8. Non-ASCII passwords on legacy zipcrypto archives made with OEM
codepages may not match — documented lossiness, same spirit as entry-name
encoding (§8).

## Where the code lives

- **`koni_codecs/lib/src/crypto/`** — primitives, reusable and
  archive-agnostic, consistent with the package's "algorithms, zero deps"
  role: AES block cipher (128/192/256, encrypt+decrypt), CBC (decrypt now,
  encrypt exists for tests/future write side), the WinZip-style CTR
  keystream (little-endian counter starting at 1), SHA-1, SHA-256, HMAC,
  PBKDF2. Exported via a `crypto.dart` library within koni_codecs.
- **Format glue stays in the format package** (KDFs and record parsing are
  format-specific): `koni_zip/src/zip_crypto.dart` (zipcrypto keystream +
  AE extra/trailer layout), `koni_sevenz/src/sevenz_crypto.dart` (iterated
  SHA-256 KDF, coder-props parsing), `koni_rar/src/rar_crypto.dart` (RAR5
  PBKDF2 keys + check value + hash-key CRC transform; RAR4 iterated-SHA-1
  KDF).

Derived keys are cached per reader keyed by (salt, iteration count) — RAR
archives reuse one salt across files, 7z reuses one across folders, so each
archive pays for its KDF once, not per entry.

## Security posture (what decryption does and does not promise)

- **Authentication**: WinZip AE verifies the HMAC-SHA1 over the ciphertext
  (10-byte truncation) at end of stream; RAR5 verifies the (possibly
  hash-key-tweaked) CRC as before. zipcrypto and 7z-AES have no MAC —
  integrity there is only the existing CRC checks. None of this is an
  authenticated-encryption guarantee and the dartdoc says so.
- **Not constant-time, no key zeroization.** This is archive reading, not a
  TLS stack; Dart gives no control over copies the GC makes. Recorded as an
  explicit non-goal.
- All existing §7 guards (bomb caps, size sanity, fuzz invariant) apply
  unchanged — decryption sits *under* them, and encrypted fixtures join the
  fuzz pools.

## Provenance

AES (FIPS-197), modes (SP 800-38A), SHA (FIPS-180-4), HMAC (RFC 2104),
PBKDF2 (RFC 8018) — public standards, vector-tested against their own
published test vectors. ZIP: APPNOTE 6.3 + the public WinZip AE-2
specification. 7z: public-domain 7-Zip/LZMA SDK documentation (same basis
as M8/P2-4). RAR5: the official RarLab technote documents the encryption
record, KDF, and check values. RAR4's KDF is not officially documented; the
clean-room references are the ISC-licensed `rarfile` Python library and
published forensic descriptions — same standard as the BSD `libarchive`
references already recorded in `koni_rar/doc/rar-provenance.md` (updated in
P3-5). Still no unrar/GPL sources, ever.

## Milestones

| #    | Scope | Gate |
| ---- | ----- | ---- |
| P3-1 | Crypto primitives in koni_codecs | Published NIST/RFC vectors pass on VM + dart2js + dart2wasm |
| P3-2 | ZIP: zipcrypto + WinZip AE, password API in core | Fixtures authored by `zip`/`7zz` decrypt byte-identical; wrong/missing password typed |
| P3-3 | 7z: AES coder in the chain + encrypted headers | `7zz -p` / `-mhe` fixtures decrypt; solid folders + header case covered |
| P3-4 | RAR5: file + header decryption, tweaked CRCs | `rar -p` / `-hp` fixtures decrypt (store, compressed, solid) |
| P3-5 | RAR4: salted file data | Round-trip against our own RAR4 builder **and** `unrar x` extracts what the builder authors (rar 7.x cannot author v4 — the builder is the fixture source, unrar is the local interop gate) |

Release: lockstep **0.5.0** when P3-5 lands (git-only, same policy as 0.4.0).

## The 7z chain refactor this drags in (named so it is not a surprise)

The M8 folder decoder assumes "first coder = decompressor, rest =
size-preserving in-place filters". An encrypted folder is
`packed → AES → LZMA2 → (filters)`, which breaks both halves of that
assumption. P3-3 generalizes `_decodeFolder` to walk the bind-pair chain
with an explicit buffer per coder output (sizes all come from
`folder.unpackSizes`, so the bomb caps are unchanged). This is a refactor of
decode plumbing only — no header-model changes.
