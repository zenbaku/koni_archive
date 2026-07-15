/// Pure Dart cryptographic primitives for the archive formats that need
/// them (Phase 3, `doc/encryption-scope.md`): AES with CBC/CTR modes,
/// SHA-1, SHA-256, HMAC, and PBKDF2.
///
/// A separate entrypoint from the compression codecs
/// (`package:koni_codecs/koni_codecs.dart`) — import it only where
/// decryption is actually wired in. Everything here is standards-defined
/// (FIPS-197, SP 800-38A, FIPS 180-4, RFC 2104, RFC 8018), vector-tested,
/// zero-dependency, and dart2js/dart2wasm-exact.
///
/// Scope honesty: these primitives exist to *read and write* encrypted
/// archives. They are not constant-time and make no key-zeroization
/// promises — do not build interactive security systems on them.
library;

export 'src/crypto/aes.dart';
export 'src/crypto/aes_modes.dart';
export 'src/crypto/block_hash.dart';
export 'src/crypto/hmac.dart';
export 'src/crypto/pbkdf2.dart';
export 'src/crypto/sha1.dart';
export 'src/crypto/sha256.dart';
