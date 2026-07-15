/// Format-agnostic archive reading for pure Dart — the facade of the
/// koni_archive ecosystem.
///
/// Open any supported archive with [Archive.open] (auto-detected) or
/// [Archive.openBytes] and treat it as a read-only virtual filesystem;
/// stream entries out with [Archive.openRead]. Built-in formats register
/// here as their milestones land (see ROADMAP.md at the repository root).
///
/// This library is platform-neutral. Platform sugar is an explicit opt-in
/// import mirroring the core split (§2):
///
/// - `package:koni_archive/io.dart` — `openArchiveFile` (VM,
///   Flutter-native);
/// - `package:koni_archive/web.dart` — `openArchiveBlob` (browser).
library;

export 'package:koni_archive_core/koni_archive_core.dart'
    show
        ArchiveClosedException,
        ArchiveCompression,
        ArchiveEntry,
        ArchiveEntryType,
        ArchiveException,
        ArchiveFormat,
        ArchiveFormatRegistry,
        ArchiveEntrySpec,
        ArchiveReadOptions,
        ArchiveReader,
        ArchiveWriteFormat,
        ArchiveWriteOptions,
        ArchiveWriter,
        ByteSink,
        ByteSource,
        BytesBuilderSink,
        ChecksumMismatchException,
        CorruptArchiveException,
        EncryptedArchiveException,
        EntryNotFoundException,
        InvalidHeaderException,
        MemoryByteSource,
        NormalizedEntryPath,
        SizeLimitExceededException,
        UnexpectedEofException,
        UnsupportedCompressionException,
        UnsupportedFeatureException,
        UnsupportedFormatException,
        normalizeEntryPath,
        validateWritePath;

export 'package:koni_sevenz/koni_sevenz.dart' show SevenZWriteFormat;
export 'package:koni_tar/koni_tar.dart' show TarWriteFormat;
export 'package:koni_zip/koni_zip.dart' show ZipWriteFormat;

export 'src/archive.dart';
