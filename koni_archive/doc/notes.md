# koni_archive (facade) — implementation notes

Decisions made where PROMPT_V1.md leaves room (recorded per §13.3).

## Platform sugar is top-level functions, not statics (M1)

§2 sketches `Archive.openFile(String path)` in `koni_archive/io.dart`. Dart
cannot add static members to a class from another library, and defining
`Archive` itself in an io library would drag `dart:io` into the
platform-neutral facade. So the platform sugar is top-level:

- `koni_archive/io.dart` → `openArchiveFile(String path)`
- `koni_archive/web.dart` → `openArchiveBlob(web.Blob blob)`

Both libraries re-export the main facade, so one import suffices per
platform.

## Built-in format registration (M1, §5)

`builtInFormats` is a facade-level registry populated by explicit code in
the facade (no import-side-effect registration). It is empty until format
milestones land; `Archive.open` uses it by default and accepts a custom
registry.

## Ownership and stream lifecycle (M1, §4)

- On success, `Archive.open` owns the `ByteSource` and closes it in
  `close()`. On failure the source is left open and usable (`openArchiveFile`
  closes its own file handle on failure, since the caller never saw it).
- The facade wraps every reader stream so `close()` semantics are uniform
  across format packages: in-flight streams get `ArchiveClosedException`
  and are closed; upstream subscriptions are cancelled.

## VFS view semantics (M1, §4)

- `entries` is the raw index-order list, duplicates included. `entry(path)`
  is exact-match, case-sensitive, last-wins, over **stored** entries only.
- `walk()` / `files` / `directories` / `glob()` present the VFS view: one
  node per unique path (last-wins), implicit parent directories synthesized
  as directory entries with size 0.
- `walk()` order (documented per §4): depth-first pre-order; each directory
  precedes its contents; siblings in code-unit order of their names; the
  archive root itself is not emitted.
- `glob()` uses `package:glob` with the URL path context (case-sensitive,
  `/`-separated) so patterns behave identically on every OS.
