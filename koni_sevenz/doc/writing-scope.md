# P2-4 — 7z write: scope proposal

Status: **proposal, not started.** This document scopes the work so the
build order and the deferrals are agreed before any code. It follows the
Phase 2 pattern (P2-1 API, P2-2 TAR, P2-3 ZIP) and the standing constraints:
pure Dart, VM + dart2js + dart2wasm, streaming/bounded memory, typed errors,
interop is the definition of done.

## The one fact that dominates this milestone

The 7z **reader** (M8) decodes LZMA, LZMA2, Copy, Deflate, Delta, and BCJ.
Every one of those codecs in koni_codecs is **decode-only**. The only
*encoder* in the entire project is `DeflateEncoder`, built for P2-3.

So "7z write" is really two very different jobs:

1. **The container** — assemble a valid 7z file around already-produced
   compressed streams. Medium effort, well-understood, reuses the reader's
   structures and the DeflateEncoder.
2. **The LZMA encoder** — a from-scratch LZMA/LZMA2 *compressor*. This is
   the single largest and riskiest item in the milestone, larger than any
   Phase 2 item so far. It does **not** fall out of the reader.

Conflating the two is the trap. They split cleanly into P2-4a and P2-4b.

## Why "invert the reader" is the wrong mental model

The reader *parses whatever layout it is handed*. The writer must *decide the
layout*, and those decisions have no decoder analog to mirror:

- **Folder / solid-block grouping.** One folder per file? One solid folder
  for everything? Size-bounded solid folders? Pack order, when to reset the
  dictionary. The reader never made any of these choices.
- **The match finder is net-new code.** We reuse the *algorithm* idea from
  deflate's hash-chain finder (the user's "reuse logic, not code" principle),
  but not the code: deflate is hard-capped at a 32 KiB window with min-match
  3, while LZMA wants a large dictionary and gains ratio from rep-distance
  matches deflate has no concept of.

What *is* genuinely mirror-able from the M8 decoder: the range-coder
direction inverts (range **encoder** ≈ 100 lines, symmetric to the decoder),
and the probability-model layout and context computation are **identical**
between encode and decode — only the update direction differs. That shared
core is why the encoder is feasible clean-room; it is not why it is small.

Estimating the LZMA encoder from the decoder's ~400 lines is an undercount:
encoders run larger than their decoders, and the match finder plus layout
logic are additive on top of the mirror-able parts.

---

## P2-4a — Container + Copy/Deflate (no new codec)

The full 7z write container, proven end-to-end with codecs we already trust
(Copy = memcpy; Deflate = the P2-3 encoder, which the reader already decodes
as a 7z folder). When P2-4b adds the LZMA encoder, the container is already
interop-verified, so the only new thing under test is the encoder itself.

In scope:

- **Signature + start header**: `7z\xBC\xAF\x27\x1C`, version, start-header
  CRC, and the next-header offset/size/CRC (fiddly, must-do, easy to get
  subtly wrong — enumerated here so it is not glossed).
- **Header assembly (uncompressed, kHeader 0x01):** PackInfo (pack sizes),
  UnpackInfo (folders → coders → codersUnpackSize, folder CRCs),
  SubStreamsInfo (per-file sizes and CRC-32), FilesInfo. Header **compression**
  (kEncodedHeader 0x17) is deferred to P2-4b — writing the header plain
  removes a dependency and simplifies the first cut.
- **Coders:** Copy (`00`) and Deflate (`04 01 08`), selectable per the write
  options / per entry, same knob as ZIP.
- **Folder / solid strategy:** start simple and documented — one folder per
  file for stored, optional size-bounded solid folders for compressed;
  chosen by the writer, not inherited.
- **Metadata (inverse of the reader's mapping):** UTF-16LE names, FILETIME
  mtimes, WinAttributes (unix mode in the high bits, dir/symlink/readonly),
  and the three-way **empty-stream vs empty-file vs directory** encoding
  (the bit-vector distinction the reader decodes and the writer must produce).
- **CRC-32 everywhere the format wants it:** pack streams, folder unpack,
  and per-substream — reusing core `Crc32`.
- **Path safety:** `validateWritePath`, same as TAR/ZIP.
- **Typed errors:** size mismatches, unsupported requested codec.

Interop DoD (P2-4a): `7zz t` validates and `7zz x` extracts our output
byte-for-byte; plus round-trip through our own reader. Local gate,
marked-skip when `7zz` is absent — consistent with the ZIP writer and the
reader's reference-tool approach.

Standalone value of stopping here: honest but narrow. The ZIP writer already
covers "write a compressed archive" with a simpler container, so P2-4a's only
genuine niche is `.cb7` (already-compressed images, where Copy folders make a
valid 7z without an LZMA encoder). It is not a satisfying permanent endpoint.

---

## P2-4b — LZMA / LZMA2 encoder (the load-bearing milestone)

Make the 7z writer actually a 7z writer. This is where the real effort and
risk live.

In scope:

- **Range encoder** — symmetric to the M8 range decoder (~100 lines).
- **LZMA state machine** — reuse the decoder's probability-model layout and
  context math (literal/match/rep contexts, pos-state), driven in the encode
  direction with lockstep model updates.
- **Match finder** — hash-chain over a large dictionary (the deflate
  *approach*, rebuilt for LZMA's window and rep-distance matches). New code.
- **Parsing: greedy/lazy, not optimal.** Correct-first, ratio-later — the
  same philosophy as the fixed-Huffman deflate encoder. Any valid
  literal/match sequence with a correct range coder and lockstep model
  updates **decodes fine**; 7zz's optimal parser (the LZMA "optimum" price
  DP) is a *ratio* lever, not a correctness requirement. Deferring it is a
  ratio deferral, named as such — not a defect.
- **LZMA2 framing** — chunk headers, dict-reset control, uncompressed-chunk
  fallback. A thin wrapper once LZMA exists; LZMA2 is 7z's actual default
  codec, so this is what makes our output "normal."
- **Wire into the container** as the default coder; enable **kEncodedHeader**
  (compress the header itself with LZMA), completing the deferral from 4a.

Interop DoD (P2-4b), two levels:

1. **LZMA raw stream vs liblzma** — the strongest, container-independent
   gate. Our encoder's output decodes correctly under CPython's `lzma`
   (liblzma) *and* our own M8 decoder. Runs before any container wiring.
   CI-capable: ubuntu runners ship python3 with lzma; our own decoder runs on
   every platform including web.
2. **7z container vs `7zz t`/`7zz x`** — local gate, marked-skip when absent
   (7zz is not guaranteed on CI runners), same as 4a.

---

## Explicitly deferred (typed errors or simply not built)

- **Optimal LZMA parsing** — ratio work; greedy/lazy ships first.
- **Delta / BCJ *encode* filters** — the reader decodes them, but they help
  executables, not comics. Not folded into 4a just because delta-encode is
  ~10 lines: easy-but-pointless is still scope creep. Add only on a concrete
  need.
- **AES encryption** — matches the read-side non-goal (§15).
- **BCJ2, PPMd** — not even on the read side beyond BCJ/x86.
- **Multi-volume, external headers/names** — read-side non-goals, stay so.

## The decision this scopes

The tiers are not independent picks. Copy/Deflate-only is a niche middle, not
a satisfying stop, and if 4b is never going to happen then 4a's container
complexity is hard to justify against the ZIP writer we already have. So the
real choice is:

- **Commit to the LZMA path (4a → 4b)** — the format-faithful 7z writer,
  accepting that 4b is the biggest single milestone in the project.
- **Defer 7z-write entirely** — Phase 2 ends at TAR + ZIP write; 7z-write
  moves to the deferred backlog, revisited on a concrete need.
- (Copy/Deflate-only, stopping at 4a — available, but only earns its keep for
  the `.cb7`-with-precompressed-images niche.)
