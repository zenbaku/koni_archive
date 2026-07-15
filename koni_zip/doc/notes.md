# koni_zip — implementation notes

Decisions made where the spec (PKWARE APPNOTE) is ambiguous, matched against
the reference tools (Info-ZIP zip/unzip) per PROMPT_V1.md §13.3.

## EOCD location (§5)

Backward scan over the last 22 + 65535 bytes. A candidate whose comment
length lands exactly at EOF wins; otherwise the last signature found is
used — Info-ZIP tolerates trailing junk ("extra bytes at end") and so do
we. No candidate → `InvalidHeaderException`.

## Prefixed / self-extracting archives (§5, §15)

Recorded offsets in SFX archives are relative to the original archive
start. The prefix length is recovered as
`eocdOffset − cdSize − cdOffset` and added to the central-directory offset
and every local-header offset (same recovery unzip performs). A *negative*
delta means the central directory overlaps the EOCD → corrupt.

## Central directory is authoritative

Entry metadata (sizes, CRC, method, flags) is read from the central
directory only. Local headers are read lazily at `openRead` just to locate
the content (their name/extra lengths differ from the central ones in
practice) and to validate the signature. This is also what makes
data-descriptor archives (flag bit 3, sizes zero in the local header) work
without touching the descriptor: the central values are final. Descriptor
edge cases beyond that are M7 scope.

## Timestamps

DOS timestamps are local wall time, 2-second resolution, no zone: the wall
time is exposed *as if* UTC (documented lossiness, §8). When a `UT`
(0x5455) extended-timestamp extra field carries an mtime, it wins — unix
epoch UTC, 1-second precision.

## Filename encodings (§8)

Flag bit 11 set → UTF-8 by declaration, decoded permissively (invalid
sequences become U+FFFD rather than failing the entry). Flag unset → strict
UTF-8 attempted first (many tools wrote unflagged UTF-8), CP437 fallback.
The caller-supplied decoder hook is M7 scope.

## Entry types

Directory when the raw name ends in a separator, the DOS directory
attribute bit is set, or a unix host's mode says S_IFDIR. Unix-host
S_IFLNK marks a symlink — but ZIP stores the link target as the entry
*content*, not metadata, so `linkTarget` stays null; reading the entry
yields the target (never followed, §7).

## Deflate decoding (M5)

Deflate entries stream through koni_codecs' resumable inflater. The decoded
byte count must equal the central directory's uncompressed size (larger →
`SizeLimitExceededException`, the §7 bomb guard, detected incrementally;
smaller → `CorruptArchiveException`), and CRC-32 is verified by default. A
deflate stream that ends before `csize` compressed bytes are consumed is
tolerated (the central values are authoritative for locating data; some
writers pad).

## Typed-error limits

- Compression methods other than stored/deflate →
  `UnsupportedCompressionException` naming the method and id. The rest of
  the archive stays readable (§9).
- Encrypted entries (flag bit 0, or method 99 AE-x) →
  `EncryptedArchiveException` at `openRead`; `isEncrypted` is set on the
  entry.
- Multi-volume EOCD (disk numbers, incl. nonzero ZIP64 disk fields) →
  `UnsupportedFeatureException` (§15 non-goal).

## ZIP64 (M7)

The EOCD64 record is located by scanning backwards from the locator (whose
recorded offset is wrong for prefixed archives; writers place the record
immediately before the locator, and an 8 KiB window covers extensible
records). The prefix delta uses the same `end − size − offset` recovery as
the classic EOCD. Per-entry 0xFFFFFFFF/0xFFFF markers defer to the 0x0001
extra field in its fixed order. 64-bit values beyond 2^53 − 1 throw a
uniform typed error on every platform — which also keeps hostile fields
from wrapping negative on the VM (found by the fuzzer, §7).

## Encoding hook (M7)

`ArchiveReadOptions.entryNameDecoder` receives the raw name bytes of
entries *without* the UTF-8 flag (the flag is authoritative when set) and
replaces the strict-UTF-8-then-CP437 heuristic — the Shift-JIS mojibake
escape hatch (§8). No committed mojibake fixture exists because no
reference tool on the fixture machine writes unflagged non-UTF-8 names;
the case is covered by a hand-built archive in the synthetic suite.

## AE-x (M7 polish)

Method 99 entries surface the *actual* inner method from the 0x9901 extra
field in `ArchiveEntry.compression` while staying `isEncrypted` (reading
throws `EncryptedArchiveException`). The strong-encryption flag (bit 6)
also marks entries encrypted.
