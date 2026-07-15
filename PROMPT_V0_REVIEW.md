# Review of PROMPT_V0 — Suggestions & Refinements

Reviewed: 2026-07-15.

> **Decisions recorded 2026-07-15** (author's answers to §10; where these differ from
> the recommendations below, the decisions win and are reflected in `PROMPT_V1.md`):
>
> 1. **RAR: must-have.** Scheduled as real milestones (RAR5 first, then RAR4), not a
>    decision gate. Legal/provenance review becomes an explicit pre-implementation
>    step instead of a go/no-go.
> 2. **Web/WASM: full support in Phase 1.** Browser byte sources and dart2js/dart2wasm
>    test runs in CI from the start — not just "keep the door open".
> 3. **Naming: `koni_*` family.** `koni_archive` facade, `koni_archive_core`,
>    `koni_codecs`, `koni_tar`, `koni_zip`, `koni_gzip`, `koni_sevenz`, `koni_rar`.
>    The project/facade is always referred to as `koni_archive` — bare `koni` is
>    never used, anywhere.
> 4. **Audience: AI coding agent.** V1 is written imperatively with per-milestone
>    definitions of done and explicit guardrails.
> 5. **License: MIT.** No problem for the library itself; it constrains *inbound*
>    reference material — no deriving from GPL/LGPL or unrar-licensed code.
>    Encoded as a reference-material policy in V1 §13.7 and the RAR provenance
>    rules in V1 §8.
> 6. **Corpus: owner provides real CBZ/CBR archives.** Copyrighted content — kept
>    outside the repo; committed manifests + a conformance runner instead
>    (V1 §11). Additionally, the owner's locally installed reference binaries
>    (incl. the proprietary `rar` tool) generate committed synthetic fixtures —
>    so RAR test archives exist in-repo without copyrighted content. Verdict: the V0 prompt is a strong foundation — the philosophy
(streaming-first, virtual filesystem, format-agnostic) is right, and the milestone
ordering is mostly sensible. The issues below fall into three buckets: **internal
contradictions** to fix, **missing architectural decisions** that will be expensive to
retrofit, and **format-specific realism checks**. Concrete replacement text is proposed
where useful. Open questions for the author are collected at the end.

---

## 1. Contradictions & inconsistencies in V0

### 1.1 "Lazy parsing" section contradicts itself

V0 says *"Opening an archive should be inexpensive"* and *"Metadata should be parsed
eagerly"* in the same section. Proposed rewording:

> `Archive.open()` parses the container's metadata (ZIP central directory, 7z header,
> TAR header walk) exactly once, eagerly. This is O(entry count) and required for
> random access. Entry **content** is never decoded at open time — decompression
> happens only when a caller opens an entry.
>
> Caveat to document: the 7z header is itself often LZMA-compressed, so "open" for 7z
> includes one small decompression step. For plain TAR, building the index requires a
> full sequential scan of the file (headers only, skipping content) — still cheap, but
> O(file size / seek granularity), not O(1).

### 1.2 `ArchiveEntry` sketch violates the immutability principle

Design Principle 5 says immutable, but the sketch has non-final public fields. It is
also missing fields real consumers need. Proposed shape:

```dart
final class ArchiveEntry {
  final String path;              // normalized, '/' separators, no leading '/'
  final ArchiveEntryType type;    // file | directory | symlink | other
  final int? compressedSize;      // null when format doesn't record it (e.g. TAR)
  final int uncompressedSize;
  final DateTime? modified;       // always UTC; document precision loss (DOS = 2s, local)
  final ArchiveCompression compression;  // stored | deflate | lzma | ... | unknown(id)
  final String? linkTarget;       // for symlinks/hardlinks
  final int? posixMode;           // from TAR/unix ZIPs, null otherwise
  final int? crc32;               // when the format records one
  final bool isEncrypted;         // so unsupported-encryption can fail with a typed error
}
```

Drop `isCompressed` — it's derivable (`compression != stored`) and redundant state on
an immutable object is a bug magnet.

### 1.3 Two package layouts offered — pick one

A prompt should not offer alternatives; the implementer will pick arbitrarily.
Recommended: facade + core + one package per format + codecs:

```text
<facade>/          # re-exports, depends on all formats, wires up detection registry
<core>/            # sources, readers, entry model, exceptions, registry interfaces
<codecs>/          # deflate/inflate, lzma, bzip2, ... (no archive knowledge)
<fmt>_tar/  <fmt>_zip/  <fmt>_sevenz/  <fmt>_rar/
```

Note on naming: `archive` is taken on pub.dev (the long-standing package by Brendan
Duncan), and `archive_plus` may read as a fork of it. Naming is an open question
(§10); the prompt should use placeholders until decided. `archive_7z` is also not a
valid Dart package/identifier prefix conflict-wise — package names can't start a
library identifier with a digit-friendly name cleanly; prefer `..._sevenz` or `..._7zip`
(package names themselves may contain digits, but `archive_7z`'s default library name
`archive_7z` is fine — still, `sevenz` avoids awkwardness in class prefixes).

### 1.4 `open()` return type is left ambiguous

V0 shows both `Stream<List<int>>` and `Future<ArchiveInputStream>`. Pick one and state
it. Recommendation: **`Stream<Uint8List>`** —

* `Uint8List`, not `List<int>`: it's what `dart:io` emits anyway, avoids a defensive
  copy, and signals the contract (bytes, not arbitrary ints).
* A plain `Stream` composes with the whole ecosystem (`pipe`, `transform`,
  `http`, `flutter` image decoding) with zero new concepts. A custom
  `ArchiveInputStream` class earns its keep only if you need seek-within-entry —
  defer that until a real consumer asks.

### 1.5 API surface has duplicates — consolidate

V0 lists `contains()` *and* `exists()`, `entries` *and* `files`/`directories`,
`file(path)` *and* `open(path)` *and* a future `[]` operator. Proposed consolidated
surface:

```dart
abstract interface class Archive {
  /// Sniffs the format from magic bytes. `format` is an escape hatch for
  /// ambiguous inputs, not the normal path.
  static Future<Archive> open(ByteSource source, {ArchiveFormat? format});

  ArchiveFormat get format;
  List<ArchiveEntry> get entries;            // index order, immutable
  ArchiveEntry? entry(String path);          // null if absent
  bool exists(String path);

  Stream<Uint8List> openRead(ArchiveEntry entry);
  Stream<Uint8List> openReadPath(String path);       // sugar; throws typed error if absent
  Future<Uint8List> readBytes(ArchiveEntry entry);   // collects the stream
  Future<void> close();                              // idempotent
}
```

Make the *entry-based* methods primary and path-based ones sugar: entry-based lookup
is unambiguous when an archive contains duplicate paths (legal in ZIP and TAR — see
§3.3), and avoids double hash lookups in hot loops. `files`/`directories`/`walk()`/
`glob()` are fine as convenience getters/extensions; note that `glob()` implies a
dependency on `package:glob` unless reimplemented (see dependency policy, §10).

---

## 2. Biggest gap: the input-source abstraction

`Archive.open(file)` never says what `file` **is**. This is the single most
architecturally consequential omission, because it determines platform reach
(web/WASM), concurrency, and whether remote archives are possible. The prompt should
define it explicitly:

```dart
/// Random-access byte source. Implementations must support concurrent
/// positional reads (pread semantics): two in-flight read() calls must not
/// corrupt each other.
abstract interface class ByteSource {
  int get length;
  Future<Uint8List> read(int offset, int length);
  Future<void> close();
}
```

* Ship `FileByteSource` (dart:io `RandomAccessFile`) and `MemoryByteSource`
  (`Uint8List`) in Phase 1.
* Design so an `HttpRangeByteSource` can exist later — reading page 5 of a remote CBZ
  via HTTP range requests without downloading the whole file is a genuine
  differentiator for the stated manga/ebook use case.
* **`dart:io` must not appear in core's public API.** Put `FileByteSource` behind a
  conditional import or in a small `..._io` package. This is what keeps the web/WASM
  door open; it costs almost nothing now and is painful to retrofit.

### 2.1 Concurrency contract (currently unstated)

A manga reader will preload page N+1 while displaying page N. The prompt should state:
**multiple entry streams may be open concurrently on one `Archive`**, and therefore
sources must support positional reads rather than a single shared cursor. Also state
what `close()` does to in-flight streams (recommendation: cancels them with a typed
error).

### 2.2 Streaming *input* vs streaming *output* — V0 conflates them

V0's "streaming-first" consistently means streaming **entry contents out** (good).
That is different from consuming a **non-seekable input** (e.g. a TAR arriving over a
socket). ZIP/7z/RAR fundamentally require a seekable source (ZIP's central directory
is at EOF). Recommendation: Phase 1 requires a seekable `ByteSource`; sequential
one-pass decoding from a `Stream<List<int>>` (really only meaningful for TAR and
gzip) is explicitly deferred and, if added, is a per-format API, not part of the
`Archive` abstraction.

---

## 3. Second gap: no security model

Archive parsers are attacker-facing code. A library aiming to be canonical needs a
security section. Minimum content:

### 3.1 Path handling / zip-slip
Normalize paths at parse time: convert `\` to `/`, strip drive letters and leading
`/`, and reject or neutralize `..` segments (policy: entries whose normalized path
escapes the archive root are exposed with a flag or rejected — pick one and document
it). The "virtual filesystem" framing makes this the library's job, not the caller's.

### 3.2 Decompression bombs & hostile metadata
* Never trust header length fields before sanity-checking against source length.
* `readBytes()` should honor a caller-suppliable `maxSize` and compare the claimed
  `uncompressedSize` against actual decoded output (mismatch ⇒ typed error).
* Bound allocations while parsing metadata (an archive claiming 2^32 entries must not
  OOM the process before the first sanity check).

### 3.3 Duplicate paths
Legal in ZIP and TAR (later entries traditionally win in TAR). Define lookup policy
(recommend: last-wins for `entry(path)`, all visible via `entries`).

### 3.4 Integrity
Verify CRC32 (ZIP/gzip) during reads by default, erroring the stream at the end on
mismatch; provide `verifyChecksums: false` for callers who prefer speed. Symlink
entries are metadata only — `openRead` on a symlink never follows the target.

### 3.5 Fuzzing
Add to the testing section: a corpus-driven fuzz harness (bit-flip and truncation
mutators over the fixture corpus). The invariant: *any* input either parses or throws
a typed `ArchiveException` — never a `RangeError`, never a hang, never unbounded
memory.

---

## 4. Format-specific realism checks

### 4.1 TAR — the "simple" format has mandatory extensions
Plain ustar caps names at 100 chars and sizes at 8 GiB. Real-world tarballs rely on
**PAX extended headers** and **GNU long-name/long-link entries**; without them the
reader fails on a large fraction of tars in the wild. These must be in scope for the
TAR milestone, not "later". Also: entry types beyond file/dir (symlink, hardlink,
fifo, char/block dev) must at least be *represented* (see `ArchiveEntryType`), and
base-256 numeric fields supported. GNU sparse files: detect and throw a typed error
(defer full support).

### 4.2 Detection table has errors and omissions
* `ustar` magic sits at **offset 257**, not 0 — and pre-POSIX (v7) tars have **no
  magic at all**; detection needs a fallback heuristic (validate the header checksum
  field of block 0).
* **GZIP magic `1F 8B` is missing** even though GZIP is Milestone 4.
* ZIP detection must not rely on `50 4B 03 04` at offset 0 alone: self-extracting
  and prefixed ZIPs require scanning backwards for the end-of-central-directory
  record (which may be up to ~64 KiB from EOF due to the comment field). Empty ZIPs
  start with `50 4B 05 06`.
* Layered formats: `.tar.gz` sniffs as gzip; after the gzip layer, sniff again.
  Detection should be a **registry of per-format detectors** (contributed by each
  format package), not a hardcoded table in core — V0's `ArchiveFormat` *enum* in
  core prevents third-party formats; make it a class-based descriptor instead.
* Keep "caller never specifies the format" as the default, but allow the
  `format:` override — ambiguous inputs exist.

### 4.3 GZIP is not an archive — define its place
gzip is a compression stream with a single payload. Two clean options; the prompt
should pick:
1. Expose it only as a codec (`archive_codecs`), plus a thin adapter so
   `Archive.open()` on a `.gz` yields a single-entry archive (entry name from the
   FNAME field or the source name).
2. Codec only; `Archive.open` rejects bare `.gz`.

Recommendation: option 1 — it keeps the "caller doesn't care about format" promise.
Also handle **multi-member gzip** (concatenated streams — legal and common from
parallel compressors) and note that `.tar.gz` **breaks random access**: document the
Phase-1 strategy (recommend: sequential decode with an in-memory or caller-provided
cache; gzip seek-index construction à la `zran` is explicitly deferred).

### 4.4 7z — scope the codec set explicitly
Realistic notes for the prompt:
* The 7z **header itself is usually LZMA-compressed** — you need the LZMA decoder
  before you can even list entries.
* **Solid blocks**: random access to entry N requires decoding the block from its
  start. Define the cache policy (recommend: cache the current decoded block, LRU of
  1–2 blocks, size-capped) — this matters enormously for the CB7 page-flip use case.
* Phase the codecs: LZMA → LZMA2 → BCJ (x86) → delta. **BCJ2 is a four-stream codec
  and significantly hairier — defer it explicitly** (state it in non-goals with a
  typed error). PPMd: defer. Encrypted 7z (AES): detect and throw typed error.

### 4.5 RAR — flag the legal and effort reality
The prompt treats RAR as just another milestone. It is not:
* There is **no official public specification** of the RAR compression algorithms.
  The unrar source license explicitly forbids using it to re-create the RAR
  compression algorithm; clean-room *decompression* is a legal grey zone that the
  project should consciously accept or reject — "unless legally feasible" in V0 is
  only said about *writing*, but the reading side is where the real question lives.
* **RAR4 (method 29)** requires a PPMd variant-H implementation *and* the RarVM
  filter virtual machine. **RAR5** dropped the VM and is materially simpler. If RAR
  proceeds, RAR5-first is the pragmatic order — but note many CBR files in the wild
  are RAR4.
* Effort estimate: RAR alone is comparable to all other milestones combined.

Recommendation: make RAR an explicit **decision gate** after 7z ships, not a
scheduled milestone, and record the CBR use case as the driver so the decision has
its context. (See open question in §10.)

---

## 5. Architecture refinements

### 5.1 Format registry instead of a core enum
Core defines `ArchiveFormat` (abstract descriptor: name, detector, `openReader`)
and a registry. Each format package implements it; the **facade** package registers
all built-ins explicitly (no import-side-effect magic). Third parties can register
their own (CPIO, ISO, …) — this is what makes the "ecosystem" claim real.

### 5.2 Codecs as synchronous chunked converters
Implement codec cores as **synchronous, chunk-driven** state machines, ideally
fitting `dart:convert`'s `Converter` + `startChunkedConversion` idiom. Rationale:
* Composable with the whole `dart:convert` ecosystem, trivially testable.
* Usable both on the VM (wrapped in isolates) and on the web (no isolates there).
* Async belongs at the I/O boundary only — per-byte `await` would destroy
  performance.

### 5.3 Isolates / jank (Flutter reality check)
Decompression is CPU-bound; on the Flutter UI isolate it will jank page turns —
precisely the flagship use case. The prompt should require:
* All public types (entries, options, results) are **isolate-transferable**.
* Document the `Isolate.run` pattern for offloading, and/or provide an optional
  helper — but don't bake isolate usage into core (it doesn't exist on the web).

### 5.4 Dependency policy — state one
Recommend: **zero runtime dependencies** for core and codecs (dev-dependencies
unrestricted; `meta` acceptable if needed). `glob()` support either reimplements
matching or lives in the facade with a `package:glob` dependency. This is a
pub.dev-trust and supply-chain statement worth making explicitly.

### 5.5 WASM compatibility
Target `dart2wasm` from day one: no `dart:html` (use `package:web` if web glue is
ever needed), no `dart:io` in core (§2). Add "compiles under dart2wasm" to CI even
before web is officially supported — it's nearly free and prevents drift.

---

## 6. Error-handling refinements

The typed-exception list is good. Add:
* Every exception carries **context**: format, byte offset, entry path where
  applicable. `CorruptArchiveException('bad CRC')` without an offset is unhelpful.
* Distinguish **archive-fatal** from **entry-scoped** failures:
  `UnsupportedCompressionException` for one entry must be thrown from
  `openRead(entry)` — the rest of the archive stays usable. V0 doesn't say when
  errors surface; this is the kind of contract implementers guess wrong.
* Name the method/id in `UnsupportedCompressionException` (e.g. "zstd (93)").
* Streams that fail mid-decode emit the typed error through the stream, then close.

---

## 7. Testing & tooling additions

Beyond V0's (good) list:
* **Fixture provenance**: generate fixtures with reference tools (`zip`, `7zz`,
  `tar`, `rar`) via a checked-in script; commit the binaries. Interop with real
  tools is the ground truth, not self-round-tripping.
* **Differential testing** against `package:archive` (and CLI tools) where formats
  overlap.
* **Codec test vectors**: inflate has canonical edge cases (dynamic Huffman with
  degenerate trees, stored-block boundaries); test the codec standalone before it's
  buried inside ZIP.
* **Fuzzing** (§3.5) and **memory regression**: stream a multi-GB synthetic entry
  and assert bounded peak RSS — this guards the core "streaming" promise in CI.
* **CI matrix**: Linux/macOS/Windows VM tests; dart2js + dart2wasm compile (and, if
  cheap, run unit subset).
* **Monorepo tooling**: pub workspaces (Dart 3.6+) — simpler than melos for this
  layout. Shared `analysis_options.yaml` with `package:lints/recommended` or
  stricter.
* **Benchmarks**: a `_bench` package comparing against `package:archive` on the
  real workloads (list 10k-entry archive; random-access one page from CBZ; full
  extract) so "performance" is measured, not asserted.

---

## 8. Milestone restructure (proposal)

Two changes to V0's ordering, with rationale:

1. **Add Milestone 0** — repo scaffolding: workspace layout, CI, lints, fixture
   generator, `ByteSource` + `FileByteSource`/`MemoryByteSource`. (V0's Milestone 1
   half-covers this; splitting keeps "infrastructure" from silently absorbing weeks.)
2. **Validate inflate inside gzip before ZIP-with-deflate.** Inflate is the
   riskiest early deliverable; gzip is the thinnest possible container around it
   (with CRC32 + length trailer for free verification). Debugging a fresh inflate
   inside a fresh ZIP reader means two suspects for every failure.

```text
M0  Scaffolding, CI, fixtures, ByteSource
M1  Core: entry model, exceptions, detection registry, CRC32, byte/bit readers
M2  TAR (incl. PAX + GNU long names; symlink/hardlink representation)
M3  ZIP container, stored entries only (EOCD scan, central directory, ZIP64 detection→typed error)
M4  Inflate codec (standalone, vector-tested) + GZIP reader (incl. multi-member)
M5  ZIP deflate entries (wire codec into M3) — first "real" release point
M6  tar.gz composition (layered detection; documented random-access strategy)
M7  ZIP64 + encoding hardening (CP437/UTF-8 flag, data descriptors)
M8  7z: container + LZMA, then LZMA2, BCJ, delta (BCJ2/PPMd deferred w/ typed errors)
M9  RAR decision gate (legal review + RAR5-vs-RAR4 scoping) — not a scheduled milestone
```

Per-milestone, add a **definition of done**: fixtures passing, fuzz-clean for N
minutes, dartdoc complete, benchmark recorded. If this prompt drives an AI coding
agent, "definition of done" plus "do not implement ahead of the current milestone"
are the two highest-leverage lines you can add.

---

## 9. Smaller nits

* **Timestamps**: normalize `modified` to UTC and document precision/zone loss per
  format (ZIP DOS times are local, 2-second resolution; TAR is epoch UTC; PAX gives
  sub-second).
* **Filename encodings**: ZIP is CP437 unless the UTF-8 flag (bit 11) is set; many
  real archives lie. Policy: honor the flag, fall back to UTF-8-then-CP437 decode,
  and offer a caller-supplied decoder hook. TAR PAX is UTF-8. This deserves its own
  paragraph in the prompt — manga archives from assorted tools are exactly where
  mojibake shows up.
* **Case sensitivity**: `entry(path)` is exact-match; say so.
* **Implicit directories**: many ZIPs have no directory entries; synthesize them for
  the VFS view (document it).
* **`archive.walk()` / `glob()`**: define `walk()` order (index order? depth-first
  over the synthesized tree?).
* **Property-based testing**: name a library if you want it used
  (e.g. `package:glados`), otherwise agents/contributors will skip it.
* **Docs**: keep per-format `doc/` notes (spec references, supported/unsupported
  matrix) as V0 says — also add a top-level comparison table vs `package:archive`
  (why this library exists) for the README.
* **Versioning**: all packages 0.x with lockstep minor bumps until Phase 2; state
  the semver policy in the prompt so changelogs start disciplined.

---

## 10. Open questions for the author

1. **Naming/branding.** `archive` is taken on pub.dev; `archive_plus` reads as a
   fork. The repo is `koni_archive` — is `koni_*` the intended brand? Prompt should
   settle placeholders vs final names.
2. **Web/WASM timeline.** Recommendation is "design for it now, test it later"
   (§2, §5.5) — is actual web *support* (published, tested) a Phase-1 requirement,
   or is keeping the door open enough?
3. **RAR stance.** Must-have because of CBR, or decision-gated (§4.5)? This changes
   the roadmap's tail significantly, and the legal question should be answered
   deliberately.
4. **Prompt audience.** Is this prompt for an AI coding agent, human contributors,
   or both? It changes the refinement style (acceptance criteria and guardrails vs
   prose rationale).
5. **Sequential (non-seekable) input** — e.g. TAR over a socket: explicitly out of
   Phase 1 (recommended, §2.2)?
6. **Dependency policy** — zero runtime deps for core/codecs (recommended, §5.4)?
7. **Driving application.** Is there a real app (manga reader?) whose corpus and
   access patterns can seed fixtures and benchmarks? Real-world CBZ/CBR files are
   worth more than synthetic ones.
8. **License & publishing.** Publish to pub.dev under which license? (Affects
   whether studying GPL/unrar-licensed reference code is acceptable during
   development.)
