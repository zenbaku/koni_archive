/// Clean-room RAR4/RAR5 reader for the koni_archive ecosystem, including
/// CBR comic archives.
///
/// Most applications use the `koni_archive` facade, which registers
/// [RarFormat] automatically. Depend on this package directly only to
/// build a custom format registry.
///
/// Current scope: RAR5 store and compressed (methods 1–5), solid and
/// non-solid, with delta/x86/ARM filters, and RAR4 method-29 (solid and
/// non-solid) including the RarVM standard filters (delta/x86/RGB/audio) and
/// PPMd variant H (`-mct` text compression, solid and non-solid), plus RAR
/// 2.0/2.6 (unpack v20/v26) LZ. Custom VM programs, a mid-file PPMd→method-29
/// block switch, RAR 1.5 (v15), and the RAR 2.x audio block stay typed errors.
/// Password-protected *files* decrypt via `ArchiveReadOptions.password` —
/// RAR5 with AES-256 (P3-4) and RAR4 with AES-128 (P3-5). RAR5 encrypted
/// *headers* (`-hp`) also read with a password; RAR4 `-hp` stays a typed
/// error. Multi-volume sets (both versions) read when the other volumes are
/// supplied via `ArchiveReadOptions.nextVolume`. See `doc/rar-provenance.md`
/// for the clean-room policy and `doc/references.md` for attributions.
library;

export 'src/rar_format.dart';
export 'src/rar_reader.dart' show RarReader;
