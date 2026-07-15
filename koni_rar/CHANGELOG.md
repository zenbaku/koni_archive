# Changelog

## 0.3.0-dev (unreleased)

- M9: RAR5 reader.
  - Clean-room decoder (owner-approved provenance policy): LZ + Huffman
    literals, distance cache, delta/x86/ARM filters; store and methods
    1–5, solid and non-solid, verified against `rar`/`unrar` output.
  - Container: base blocks, file/service headers, extra records
    (encryption, symlink REDIR), UTF-8 names, mtime, unix modes.
  - CBR (v5) works end-to-end (bench recorded). RAR4, multi-volume, and
    encrypted archives are typed errors; §7 hardened (size caps, uniform
    integer cap, permissive UTF-8, fuzz smoke in CI).
- M0: package scaffolding.
