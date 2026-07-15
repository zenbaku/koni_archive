# Static RAR fixtures (NOT tool-generated)

These archives are **irreplaceable by `tool/generate_fixtures.dart`** and
live here, outside `test/fixtures/rar/`, on purpose: the generator wipes
its own `test/fixtures/<set>` directory before each run
(`outDir.deleteSync(recursive: true)`), and it runs rar 7.x, which **cannot
author RAR4 (v4)** — `-ma4` was removed. Keeping these under `rar/` would
mean the next `dart run tool/generate_fixtures.dart --only rar` silently
deletes them.

| File | Provenance |
| --- | --- |
| `enc_rar4_store.rar` | rar 6.24, `-ma4 -m0 -psecret` — encrypted RAR4 store (hello.txt, lorem.txt, nested/notes.txt) |
| `enc_rar4.rar` | rar 6.24, `-ma4 -m3 -psecret` — encrypted RAR4 compressed (same members) |

To regenerate (only if the content must change): download rar 6.24
(`https://www.rarlab.com/rar/rarmacos-arm-624.tar.gz`; a `curl` download
avoids the Gatekeeper quarantine that blocks the Homebrew cask) and re-author
with the commands above. See `koni_rar/doc/notes.md` for the encryption
format details these exercise.
