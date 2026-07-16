# RAR implementation provenance policy

> **Status: APPROVED by the project owner on 2026-07-15.** RAR
> implementation work (M9/M10) may proceed under the rules below
> (§8, §13.5).

## Why this document exists

There is no official public RAR specification, and the unrar source license
explicitly prohibits using its code to re-create the RAR compression
algorithm. This project is MIT-licensed (§1), which additionally rules out
deriving from GPL/LGPL implementations. koni_rar must therefore be a
**clean-room implementation**, and this document defines what may and may
not be consulted.

## Binding rules

1. **Never read, transcribe, or paraphrase unrar source code** (the
   rarlab.com unrar distribution, or any fork of it), in any version, for
   any purpose — including "just to check an edge case".
2. **Never read or derive from GPL/LGPL implementations**, specifically
   including 7-Zip's Rar/Rar5 codecs and The Unarchiver's XADMaster RAR
   code. Their licenses are incompatible with MIT distribution.
3. **Acceptable references**:
   - independent format documentation and published analyses (e.g. the
     rarfile project's documented format notes, format reverse-engineering
     write-ups, academic descriptions of PPMd variant H — Dmitry
     Shkarin's public PPMd papers/code are public domain);
   - **permissively licensed clean-room implementations**, e.g.
     libarchive's BSD-licensed `archive_read_support_format_rar.c` /
     `rar5.c` readers — consultable and adaptable **with copyright notices
     retained** in `koni_rar/NOTICE` and attribution in
     `koni_rar/doc/references.md` (§13.7);
   - the `unrar` **binary** as a black-box reference tool: observed
     behavior, produced output, and exit codes may guide testing (§13.3) —
     never its source.
4. **Every reference used must be recorded** in `koni_rar/doc/references.md`
   at the time it is first consulted: what it is, its license, what it was
   used for.
5. Test fixtures are generated with the proprietary `rar` tool on the
   owner's machine (§11) — using the tool's *output* is fine; the
   restriction is on *source code* provenance.
6. If a question cannot be answered from acceptable references, the answer
   is determined empirically: craft inputs, observe the reference tool,
   record the finding in `doc/notes.md`. When in doubt, leave the feature
   as a typed `UnsupportedFeatureException` and document it.

## Scope reminders (Phase 1)

- RAR5 first (M9): no filter VM, materially simpler. Then RAR4 (M10):
  method-29 LZSS+Huffman. The **RarVM standard filters** (delta, x86 E8/E9,
  RGB, audio) were later added in `rar4_filters.dart`, adapted from
  libarchive's BSD `rar.c` (`parse_filter`/`compile_program`/
  `execute_filter_*`, the `membr_*` bit-reader — libarchive's names and
  structure, not unrar's). A *generic* interpreter for non-standard VM
  programs, and PPMd variant H, stay typed errors: the boundary is
  **license-bounded** (the only interpreter reference is GPL unrar) per rule
  6 above ("when in doubt, typed error + document"), not difficulty-bounded.
- Multi-volume and encrypted archives: typed errors (§8 non-goals).
- RAR *writing* is permanently out of scope (§15).

## Sign-off

- [x] Project owner approved this policy (2026-07-15, recorded from owner instruction in the working session)
