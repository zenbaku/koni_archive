# koni_archive — Pure Dart Archive Ecosystem (Prompt V1)

This prompt directs an AI coding agent. Work **milestone by milestone** (§14).
Read §13 (agent guardrails) before writing any code.

---

## 1. Mission

Build the **canonical archive ecosystem for pure Dart**: reading (and later writing)
the most common archive formats behind one streaming-first, format-agnostic API.

Hard constraints:

* **No native code. No FFI. No external executables.** Pure Dart only.
* Runs everywhere Dart runs: Flutter (Android, iOS, macOS, Windows, Linux),
  Dart VM, **and the web (dart2js and dart2wasm) — web is a Phase-1 target,
  not a future option.**
* **License: MIT** for all packages. This constrains what reference material may
  be consulted while implementing — see the reference-material policy in §13.7.

The primary use case is **streaming files out of archives**, not extracting to disk.
Flagship consumers: manga/comic readers (CBZ/CBR/CB7/CBT), ebook readers, file
explorers, game asset packs, backup tools. A caller treats an archive as a
**virtual filesystem** and never needs to know which format is underneath.

---

## 2. Package structure

Monorepo using **pub workspaces** (Dart ≥ 3.6):

```text
koni_archive/        # facade: Archive.open(), registers all built-in formats, re-exports
koni_archive_core/   # ByteSource, entry model, exceptions, detection registry, readers, checksums
koni_codecs/         # compression codecs, reusable outside archives (deflate, lzma, ...)
koni_tar/
koni_zip/
koni_gzip/           # .gz single-entry adapter + layered .tar.gz handling
koni_sevenz/
koni_rar/
bench/               # benchmark harness + committed results (workspace member, never published)
```

**Naming rule:** the project and its facade are **`koni_archive`** — never bare
`koni`. This applies everywhere: package names, code identifiers, environment
variables, docs, and prose.

Dependency rules:

* Format packages depend on `koni_archive_core` (and `koni_codecs` where needed) —
  never on each other, never on the facade.
* `koni_archive_core` and `koni_codecs` have **zero runtime package dependencies**.
  SDK libraries are fine, with platform rules below. Exception: web glue may use
  `package:web`.
* Application authors normally depend only on `koni_archive`.

### Platform-neutral core (required for web)

* `package:koni_archive_core/koni_archive_core.dart` imports **no** `dart:io` and no
  JS interop — it must compile on every platform including dart2wasm.
* `package:koni_archive_core/io.dart` — `FileByteSource` (dart:io), explicit opt-in
  import for VM/Flutter-native.
* `package:koni_archive_core/web.dart` — `BlobByteSource` over a browser `Blob`/`File`
  (`package:web` / `dart:js_interop`), explicit opt-in import for web.
* The facade mirrors this split (`koni_archive/io.dart` provides
  `Archive.openFile(String path)`; the main library provides
  `Archive.openBytes(Uint8List)` and `Archive.open(ByteSource)`).

---

## 3. Core abstraction: ByteSource

All readers consume a **seekable, random-access byte source** — never a file path
and never a raw stream:

```dart
/// Random-access byte source. Implementations MUST support concurrent
/// positional reads (pread semantics): overlapping in-flight read() calls
/// must not interfere with each other.
abstract interface class ByteSource {
  int get length;
  Future<Uint8List> read(int offset, int length);
  Future<void> close();
}
```

Phase-1 implementations: `MemoryByteSource` (core), `FileByteSource` (io library),
`BlobByteSource` (web library). Design so an HTTP-range source can be added later as
a separate package (reading one page of a remote CBZ without downloading the whole
file) — nothing in core may assume the source is local or cheap to read.

**Sequential (non-seekable) input** — e.g. a TAR arriving over a socket — is
explicitly **out of scope for Phase 1**. Streaming-first (§4) refers to streaming
entry contents *out*, not consuming non-seekable input.

---

## 4. Public API

```dart
final archive = await Archive.open(source);        // format auto-detected

archive.format;                                    // ArchiveFormat descriptor
archive.entries;                                   // List<ArchiveEntry>, index order
archive.entry('ch01/page001.webp');                // ArchiveEntry?  (null if absent)
archive.exists('ch01/page001.webp');               // bool

archive.openRead(entry);                           // Stream<Uint8List>  — PRIMARY API
archive.openReadPath('ch01/page001.webp');         // sugar; typed error if absent
await archive.readBytes(entry, maxSize: ...);      // Future<Uint8List>, collects stream
await archive.close();                             // idempotent
```

Contracts:

* **Entry-based methods are primary; path-based are sugar.** Duplicate paths are
  legal in ZIP/TAR: `entries` exposes all of them; `entry(path)` resolves
  **last-wins**; lookup is **exact-match, case-sensitive**.
* **Streaming is the primary read API.** `openRead` returns a single-subscription
  `Stream<Uint8List>` with bounded memory use regardless of entry size.
  `readBytes` is a convenience wrapper that collects the stream and honors an
  optional `maxSize` (typed error when exceeded).
* **Concurrency:** multiple entry streams may be open on one `Archive`
  simultaneously (a reader app preloads page N+1 while displaying page N).
  `close()` cancels in-flight streams with a typed error.
* **Laziness:** `open()` parses container metadata (central directory / headers)
  exactly once, eagerly — O(entry count), no content decompression. Entry content
  is decoded only when opened. (Known caveats to document: the 7z header block is
  itself often LZMA-compressed; TAR indexing walks headers across the whole file.)
* Cancelling a stream subscription releases all resources it holds.
* Convenience VFS helpers: `files`, `directories`, `walk()` (document its order),
  `glob()` (facade-level; may depend on `package:glob` there — not in core).
  Synthesize implicit directory entries for the VFS view (many ZIPs omit them).

### ArchiveEntry (immutable — all fields final)

```dart
final class ArchiveEntry {
  final String path;              // normalized: '/' separators, no leading '/', no drive letters
  final ArchiveEntryType type;    // file | directory | symlink | hardlink | other
  final int? compressedSize;      // null where the format doesn't record it (TAR)
  final int uncompressedSize;
  final DateTime? modified;       // always UTC; document per-format precision loss
  final ArchiveCompression compression;   // stored | deflate | lzma | lzma2 | ... | unknown(id)
  final String? linkTarget;       // symlink/hardlink target, metadata only — never followed
  final int? posixMode;
  final int? crc32;
  final bool isEncrypted;
}
```

`ArchiveCompression` must carry the raw method id for `unknown` so diagnostics can
name it. Do **not** add an `isCompressed` bool — derivable from `compression`.

---

## 5. Format detection

* Detection is a **registry**: `koni_archive_core` defines an abstract
  `ArchiveFormat` descriptor (name, `matches(ByteSource)`, `openReader(...)`) and a
  registry; each format package implements one; the facade registers all built-ins
  explicitly (no import-side-effect registration). Third parties can register their
  own formats — this is what makes it an ecosystem. **No closed enum of formats in
  core.**
* `Archive.open` sniffs automatically. `format:` parameter exists as an escape
  hatch, but callers should never need it.
* Detection facts to honor:
  * ZIP: `50 4B 03 04` at offset 0 is not sufficient — self-extracting/prefixed
    ZIPs require scanning backwards from EOF for the end-of-central-directory
    record (comment can push it up to ~64 KiB from the end). Empty ZIPs start
    `50 4B 05 06`.
  * TAR: `ustar` magic at **offset 257**; pre-POSIX v7 tars have no magic —
    fall back to validating the header checksum of block 0.
  * GZIP: `1F 8B`. RAR: `52 61 72 21 1A 07 00` (v4) /
    `52 61 72 21 1A 07 01 00` (v5). 7z: `37 7A BC AF 27 1C`.
  * Layered formats: after the gzip layer, sniff again (`.tar.gz` presents as the
    inner TAR — see §8 GZIP).

---

## 6. Design principles

1. **Streaming-first** — no API that forces a whole entry into memory except the
   explicit `readBytes` convenience.
2. **Random access when the format allows it** — open entry N without decoding
   entries 0..N-1. For solid archives (7z, some RAR), document the cost model and
   cache policy (§8).
3. **Immutable public types.** Entries and descriptors are deeply immutable and
   **isolate-transferable** (decompression is CPU-bound; Flutter apps will wrap
   calls in `Isolate.run` — document this pattern; do not bake isolates into core,
   they don't exist on the web).
4. **Synchronous codec cores.** Every codec in `koni_codecs` is a synchronous,
   chunk-driven state machine implementing `dart:convert`'s
   `Converter`/`startChunkedConversion` idiom. Async lives only at the I/O
   boundary. Never `await` per byte. Codecs must be usable standalone, with no
   archive knowledge.
5. **Format-independent API** — consumers never name `ZipReader`; format packages
   are implementation detail behind the facade.

---

## 7. Security requirements (attacker-facing code — non-negotiable)

* **Path normalization at parse time**: `\` → `/`, strip drive letters and leading
  `/`; entries whose normalized path escapes the root via `..` are exposed with
  their sanitized path plus a flag on the entry — never silently, never raw.
* **Never trust header length/count fields** before sanity-checking against source
  length. An archive claiming 2^32 entries must fail cleanly, not OOM.
* **Decompression bombs**: `readBytes` enforces `maxSize`; decoded output that
  exceeds the entry's claimed `uncompressedSize` is a typed error.
* **Checksums verified by default** (CRC32 for ZIP/gzip): streaming reads verify at
  end-of-stream and error the stream on mismatch; `verifyChecksums: false` opt-out.
* **Symlinks are metadata only** — `openRead` on a symlink never follows the target.
* **Fuzz invariant**: any input bytes either parse or throw a typed
  `ArchiveException`. Never a `RangeError`, never a hang, never unbounded memory.
  (Enforced in CI, §12.)

---

## 8. Per-format requirements

### TAR (`koni_tar`)
* Must support: ustar, **PAX extended headers**, **GNU long-name/long-link**
  entries, base-256 numeric fields, all entry types represented
  (file/dir/symlink/hardlink/fifo/device — represented, not materialized).
* Detect GNU sparse entries and throw a typed error (full support deferred).
* Real-world tarballs depend on PAX/GNU extensions — they are **not** optional.

### ZIP (`koni_zip`)
* Phase order: stored entries first, then deflate via `koni_codecs`.
* Must handle: EOCD scan (§5), data descriptors, implicit directories, backslash
  separators, DOS timestamps (local time, 2 s resolution → normalize to UTC,
  document lossiness).
* **Filename encodings**: honor the UTF-8 flag (general-purpose bit 11); when
  unset, attempt UTF-8 and fall back to CP437; provide a caller-supplied decoder
  hook. Manga archives from assorted tools are exactly where mojibake appears.
* ZIP64: detect and throw a typed error until the hardening milestone implements it.
* Encrypted entries and unsupported methods (bzip2, lzma, ppmd, zstd, …): typed
  error naming the method and id, thrown from `openRead(entry)` — **the rest of the
  archive stays readable**.

### GZIP (`koni_gzip` + codec in `koni_codecs`)
* The deflate/gzip codec lives in `koni_codecs`; `koni_gzip` adapts it to the
  `Archive` abstraction: a bare `.gz` opens as a **single-entry archive** (name
  from FNAME field, else derived from the source).
* Support **multi-member** gzip files (concatenated streams).
* Layering: when the decompressed head sniffs as TAR, present the inner TAR.
  `.tar.gz` **breaks random access** — Phase-1 strategy: sequential decode backed
  by an in-memory cache of decoded data; a seek-index (zran-style) is deferred.
  Document the cost model.

### 7z (`koni_sevenz`)
* The header block is itself usually LZMA-compressed — the LZMA decoder is a
  prerequisite for even listing entries.
* Codec order: LZMA → LZMA2 → BCJ (x86) → delta. **BCJ2 and PPMd are deferred**:
  typed error naming the codec. Encrypted (AES) archives: typed error.
* **Solid blocks**: random access to entry N requires decoding its block from the
  start. Cache the most recently decoded block(s) (small LRU, size-capped) — this
  is what makes CB7 page-flipping usable. Document the policy.

### RAR (`koni_rar`) — must-have (CBR is a flagship use case)
* **RAR5 first** (no filter VM — materially simpler), then **RAR4** (method 29:
  PPMd variant H + the RarVM filter machine). Many real-world CBRs are RAR4, so
  both are required for the manga use case.
* Multi-volume and encrypted archives: typed errors (Phase-1 non-goals).
* **Provenance rules (strict):** there is no official public spec, and the unrar
  source license prohibits using it to re-create RAR compression. Therefore:
  implement **clean-room**; **never read or transcribe unrar source code**, and —
  because this project is MIT — never derive from GPL/LGPL implementations either
  (7-Zip's Rar codecs, The Unarchiver). Acceptable references: independent
  documentation and published format analyses, and permissively licensed
  clean-room implementations (e.g. libarchive's BSD-licensed rar/rar5 readers)
  with attribution per §13.7. Record every reference used in
  `koni_rar/doc/references.md`. Before starting the RAR milestones, write
  `doc/rar-provenance.md` describing this policy and flag it to the project owner
  for sign-off.

---

## 9. Error handling

Typed exception hierarchy rooted at `ArchiveException`:
`UnsupportedFormatException`, `CorruptArchiveException`, `UnexpectedEofException`,
`UnsupportedCompressionException`, `UnsupportedFeatureException`,
`EncryptedArchiveException`, `InvalidHeaderException`, `SizeLimitExceededException`,
`ChecksumMismatchException`, `ArchiveClosedException`.

* Every exception carries **context**: format, byte offset where known, entry path
  where applicable.
* **Entry-scoped failures surface at `openRead(entry)`**, not at `Archive.open` —
  one exotic entry must not brick the archive.
* Mid-decode failures are emitted as the typed error **through the stream**, which
  then closes.
* No generic `Exception`/`StateError` for archive-content problems, ever.

---

## 10. Performance

* Bytes are `Uint8List` end-to-end; use `ByteData`/views; no defensive copies on
  hot paths; no per-byte async.
* Handle archives with tens of thousands of entries: index memory stays
  proportional to entry count with small constants; opening does no content decode.
* Benchmarks are part of the deliverable (§12): list-20k-entry archive, random-read
  one page from a large CBZ, full sequential extract — each compared against
  `package:archive` as the baseline, results committed under `bench/results/`.
  Performance is measured, not asserted.

---

## 11. Testing

Per format: valid / corrupted / truncated / malformed-header archives, zero-length
files, empty archives, nested dirs, Unicode + very long filenames, large files,
duplicate paths, and the format-specific traps in §8. Additionally:

* **Fixture provenance**: fixture archives are generated by reference tools
  (`zip`, `7zz`, `tar`, `rar`) via a checked-in script, and the resulting
  archives are committed. The script runs on the owner's machine using locally
  installed binaries — including the proprietary `rar` tool — and records each
  tool's version in a committed manifest; CI never needs the tools, only the
  committed fixtures. This also covers **synthetic CBZ/CBR/CB7 fixtures** (dummy
  page images), so RAR test archives exist in-repo without shipping copyrighted
  content. Interop with real tools is ground truth — never only
  self-round-tripping.
* **Real-world corpus (owner-provided CBZ/CBR)**: the owner supplies a corpus of
  real manga archives. Contents are copyrighted — the corpus lives **outside the
  repo and is never committed**. Instead, a checked-in script generates per-archive
  **manifests** (entry listing, sizes, CRCs, SHA-256 of decoded contents, produced
  via reference tools) into `test/conformance/manifests/`, which *are* committed.
  A conformance runner reads the corpus path from a `KONI_ARCHIVE_CORPUS_DIR`
  environment variable, decodes every archive with `koni_archive`, and checks it
  against the manifests;
  it skips gracefully (marked, not silently) when the corpus is absent, so public
  CI stays green while local/scheduled runs get full coverage. Fuzz mutators may
  also draw from corpus samples locally.
* **Codec vectors**: test inflate standalone against canonical edge cases
  (degenerate dynamic Huffman, stored-block boundaries) before it's inside ZIP.
* **Differential tests** against `package:archive` where formats overlap.
* **Fuzzing**: corpus-driven harness (bit-flip + truncation mutators over
  fixtures); 60 s smoke run in CI per format, longer scheduled runs. Invariant per
  §7.
* **Memory regression**: stream a multi-GB synthetic entry, assert bounded peak
  memory — this guards the streaming promise in CI.
* Property-based tests with `package:glados` (dev-dependency) where generators fit.

**CI matrix (from Milestone 0):** VM tests on Linux/macOS/Windows; web tests via
`dart test -p chrome` both dart2js **and dart2wasm**. All packages analyzed with a
shared strict `analysis_options.yaml` (`package:lints/recommended` minimum), zero
warnings.

---

## 12. Documentation

* Every format package: `doc/` with architecture overview, spec references,
  supported/unsupported feature matrix, implementation notes explaining tradeoffs.
* Full dartdoc on all public API (enforced: `public_member_api_docs`).
* Facade README: quick start, the virtual-filesystem model, the isolate pattern for
  Flutter, and a comparison table vs `package:archive` (why `koni_archive` exists).
* Example app: a CBZ/CB7 page extractor demonstrating streaming + preloading.

---

## 13. Agent guardrails

1. **One milestone at a time.** Do not implement ahead. Empty package directories
   may be created in M0; no speculative code, no stubbed future formats, no dead
   `// TODO: RAR` scaffolding in shipped code. Defer features via typed errors and
   documented non-goals, not TODOs.
2. **Definition of done applies to every milestone** (§14): all CI platforms green
   (including dart2wasm), new fixtures passing, fuzz smoke clean, dartdoc complete,
   CHANGELOG entry written, benchmarks recorded where the milestone touches a hot
   path.
3. When a spec is ambiguous, match the behavior of the reference tool (`zip`,
   `7zz`, `tar`, `unrar`) and record the decision in the package's `doc/notes.md`.
4. Do not add runtime dependencies beyond §2's policy without flagging it to the
   owner first.
5. Respect §8's RAR provenance rules absolutely.
6. Public API changes after M5 require a deprecation note in the CHANGELOG.
7. **Reference-material policy (applies to all code, not just RAR).** The project
   is MIT-licensed. Specs and RFCs (e.g. RFC 1951/1952, PKWARE APPNOTE) may be
   used freely. Public-domain and permissively licensed implementations
   (public-domain LZMA SDK, zlib, BSD — e.g. libarchive) may be consulted or
   adapted **with their copyright notices retained** in a `NOTICE` file and the
   package's `doc/references.md`. **Never copy or closely paraphrase GPL/LGPL or
   unrar-licensed source.** When in doubt, work from the spec and record the
   decision.

---

## 14. Milestones

Definition of done for **every** milestone = §13.2. Format-specific scope per §8.
Progress is tracked in `ROADMAP.md` — update its status column when starting and
completing a milestone (scope lives here; status lives there).

* **M0 — Scaffolding.** Pub workspace, all package skeletons, shared lints, CI
  matrix incl. dart2js/dart2wasm, fixture-generator script, MIT LICENSE files,
  CHANGELOG/README stubs, conformance-runner + manifest-generator skeletons (§11).
* **M1 — Core.** `ByteSource` + `MemoryByteSource`/`FileByteSource`/
  `BlobByteSource`, byte/bit readers, CRC32 + Adler32, exception hierarchy, entry
  model, path normalization (§7), detection registry + driver.
* **M2 — TAR.** Full §8 TAR scope. Proves the architecture end-to-end.
* **M3 — ZIP, stored entries only.** EOCD scan, central directory, implicit dirs,
  encodings, ZIP64-detect→typed-error.
* **M4 — Inflate + GZIP.** Inflate codec standalone (vector-tested), gzip framing
  incl. multi-member, `koni_gzip` single-entry adapter. Rationale: gzip is the
  thinnest container around inflate (CRC + length trailer for free) — debug the
  codec here, not inside ZIP.
* **M5 — ZIP deflate.** Wire the codec into M3. **First "real" release point** —
  CBZ works end-to-end. Tag 0.1.0 of facade/core/codecs/tar/zip/gzip.
* **M6 — tar.gz.** Layered detection + documented random-access strategy.
* **M7 — ZIP hardening.** ZIP64, data descriptors edge cases, encoding hook,
  encrypted-entry detection polish.
* **M8 — 7z.** Container + LZMA first (header decode requires it), then LZMA2,
  BCJ (x86), delta; solid-block cache. BCJ2/PPMd/AES: typed errors.
* **M9 — RAR5.** Provenance doc + owner sign-off first (§8), then container +
  RAR5 codec. CBR (v5) works.
* **M10 — RAR4.** PPMd variant H + RarVM filters. CBR (v4) works. Largest single
  milestone — expect it to be comparable to several earlier ones combined.

---

## 15. Non-goals (Phase 1)

Encryption/passwords (detect → typed error), archive writing (Phase 2: ZIP + TAR
first, 7z eventually; RAR writing permanently out of scope), self-extracting
execution (reading prefixed ZIPs **is** in scope), multi-volume archives, archive
repair, sequential non-seekable input, GNU sparse tars, BCJ2/PPMd (7z), seek-index
for gzip, legacy obscure codecs (implode, shrink, …) — all deferred with typed
errors where reachable.

---

## 16. Long-term vision

The goal is not "another ZIP library" — it is the canonical archive ecosystem for
Dart: archives as virtual filesystems, streaming-first for media consumption,
codecs reusable outside containers, new formats (XZ, CPIO, ISO, CAB, …) addable by
third parties through the registry without touching core, and eventually symmetric
read/write behind the same format-agnostic API. Application code should never know
or care which archive format it is reading — on any platform Dart supports,
including the browser.
