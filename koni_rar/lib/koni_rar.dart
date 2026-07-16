/// Clean-room RAR4/RAR5 reader for the koni_archive ecosystem, including
/// CBR comic archives.
///
/// Most applications use the `koni_archive` facade, which registers
/// [RarFormat] automatically. Depend on this package directly only to
/// build a custom format registry.
///
/// Current scope: RAR5 store and compressed (methods 1–5), solid and
/// non-solid, with delta/x86/ARM filters, and RAR4 method-29 (solid and
/// non-solid) including RarVM filters — the standard set (delta/x86/RGB/audio)
/// run natively and any other program on a generic interpreter — and PPMd
/// variant H (`-mct` text compression, solid and non-solid), plus RAR 2.0/2.6
/// (unpack v20/v26) LZ. A mid-file PPMd→method-29 block switch, a filter
/// reached *through* PPMd, RAR 1.5 (v15), and the RAR 2.x audio block stay
/// typed errors.
/// Password-protected *files* decrypt via `ArchiveReadOptions.password` —
/// RAR5 with AES-256 (P3-4) and RAR4 with AES-128 (P3-5). Encrypted *headers*
/// (`-hp`) also read with a password, for both RAR5 and RAR4. Multi-volume
/// sets (both versions) read when the other volumes are supplied via
/// `ArchiveReadOptions.nextVolume`. See `doc/rar-provenance.md` for the
/// clean-room policy and `doc/references.md` for attributions.
library;

export 'src/rar_format.dart';
export 'src/rar_reader.dart' show RarReader;
