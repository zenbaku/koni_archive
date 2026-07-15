/// TAR (ustar, PAX, GNU extensions) reader for the koni_archive ecosystem.
///
/// Most applications use the `koni_archive` facade, which registers
/// [TarFormat] automatically. Depend on this package directly only to
/// build a custom format registry.
///
/// Supported: ustar (incl. path prefix), PAX extended headers (per-file and
/// global), GNU long-name/long-link, base-256 numeric fields, v7 (magic-less)
/// tars, and all entry types as metadata (file, directory, symlink,
/// hardlink, FIFO, devices — represented, never materialized). GNU sparse
/// entries are detected and reading them throws a typed error (deferred;
/// see `doc/`).
library;

export 'src/tar_format.dart';
export 'src/tar_reader.dart' show TarReader;
