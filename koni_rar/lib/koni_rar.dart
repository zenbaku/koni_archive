/// Clean-room RAR4/RAR5 reader for the koni_archive ecosystem, including
/// CBR comic archives.
///
/// Most applications use the `koni_archive` facade, which registers
/// [RarFormat] automatically. Depend on this package directly only to
/// build a custom format registry.
///
/// Current scope: RAR5 store and compressed (methods 1–5), solid and
/// non-solid, with delta/x86/ARM filters. RAR4, multi-volume, and
/// encrypted archives are detected with typed errors. See
/// `doc/rar-provenance.md` for the clean-room policy and `doc/references.md`
/// for attributions.
library;

export 'src/rar_format.dart';
export 'src/rar_reader.dart' show RarReader;
