import 'byte_source.dart';
import 'exceptions.dart';
import 'read_options.dart';
import 'reader.dart';

/// Descriptor for one archive format: how to detect it and how to open it.
/// Format packages implement one of these; third parties can implement
/// their own and register it: the format set is open, never a closed enum.
abstract class ArchiveFormat {
  /// Const-constructable so format descriptors can be compile-time constants.
  const ArchiveFormat();

  /// Short lower-case format name (e.g. `zip`, `tar`), used in diagnostics
  /// and [ArchiveException.format].
  String get name;

  /// Whether [source] looks like this format.
  ///
  /// Must return `false` (not throw) for input that simply isn't this
  /// format. May read wherever it needs (magic bytes are not always at
  /// offset 0: ZIP detection scans backward from EOF, TAR magic is at
  /// offset 257), but should read as little as possible: detection runs
  /// against every registered format in turn. An [ArchiveException] escaping
  /// this method (e.g. [UnexpectedEofException] from a source shorter than a
  /// probe) is treated by the registry as "does not match".
  Future<bool> matches(ByteSource source);

  /// Opens [source] as this format, eagerly parsing container metadata
  /// (O(entry count), no content decode), honoring [options].
  ///
  /// Called by the driver after [matches], or directly when the caller
  /// forces a format. Throws a typed [ArchiveException] if the source is not
  /// a well-formed archive of this format. Must not close [source].
  Future<ArchiveReader> openReader(
    ByteSource source,
    ArchiveReadOptions options,
  );
}

/// Ordered, mutable registry of [ArchiveFormat]s, what makes koni_archive
/// an ecosystem: new formats plug in without touching core.
///
/// The facade owns a registry pre-populated with the built-in formats;
/// callers can build their own to add formats or restrict the set.
final class ArchiveFormatRegistry {
  /// Creates a registry, optionally pre-populated with [formats].
  ArchiveFormatRegistry([Iterable<ArchiveFormat> formats = const []])
    : _formats = List.of(formats);

  final List<ArchiveFormat> _formats;

  /// Registered formats, in registration order. Unmodifiable view.
  List<ArchiveFormat> get formats => List.unmodifiable(_formats);

  /// Appends [format] to the registry.
  ///
  /// Detection probes formats in registration order and the first match
  /// wins, so register formats with cheap, precise magic checks first.
  void register(ArchiveFormat format) => _formats.add(format);

  /// Probes every registered format in order; returns the first whose
  /// [ArchiveFormat.matches] accepts [source], or null when none does.
  ///
  /// A format whose probe throws [ArchiveException] is treated as
  /// non-matching (a 3-byte input must not abort detection just because one
  /// format's probe reads 4 bytes). Non-[ArchiveException] errors are bugs
  /// and propagate.
  Future<ArchiveFormat?> detect(ByteSource source) async {
    for (final format in _formats) {
      try {
        if (await format.matches(source)) return format;
      } on ArchiveException {
        continue;
      }
    }
    return null;
  }

  /// Detects the format of [source] and opens it: the detection driver
  /// (M1) behind `Archive.open`.
  ///
  /// [format] forces a specific format, skipping detection (the escape
  /// hatch, callers should never normally need it). Throws
  /// [UnsupportedFormatException] when no registered format matches. Does
  /// not take ownership of [source]: on failure the source remains open and
  /// usable.
  Future<ArchiveReader> openReader(
    ByteSource source, {
    ArchiveFormat? format,
    ArchiveReadOptions options = const ArchiveReadOptions(),
  }) async {
    final matched = format ?? await detect(source);
    if (matched == null) {
      throw UnsupportedFormatException(
        'none of the ${_formats.length} registered format(s) '
        '(${_formats.map((f) => f.name).join(', ')}) matches the input',
      );
    }
    return matched.openReader(source, options);
  }
}
