# koni_codecs

Pure Dart compression codecs — DEFLATE/inflate, gzip framing, and LZMA/LZMA2
(decoders and encoders) — as synchronous chunked converters, usable
standalone or inside the koni_archive ecosystem.

A separate `package:koni_codecs/crypto.dart` entrypoint provides the
cryptographic primitives the archive formats need to read and write
password-protected archives: AES-128/192/256 with CBC and CTR modes, SHA-1,
SHA-256, HMAC, and PBKDF2. Standards-defined, vector-tested, zero-dependency,
and dart2js/dart2wasm-exact. These exist to *read and write* encrypted
archives — they are not constant-time; don't build interactive security
systems on them.

Part of the [koni_archive](https://github.com/koni-archive) monorepo.

> **Status: pre-release** (0.x, git-only). The API stays 0.x with lockstep
> minor bumps until it stabilizes — see the repository's `ROADMAP.md`.
