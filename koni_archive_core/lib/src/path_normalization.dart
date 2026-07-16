/// Entry-path normalization, applied by every reader at parse time.
///
/// Archive paths are attacker-controlled input; nothing downstream ever sees
/// a raw one.
library;

/// Result of [normalizeEntryPath]: the sanitized [path] plus whether the
/// original attempted to escape the archive root.
typedef NormalizedEntryPath = ({String path, bool escapedRoot});

/// Normalizes a path as stored in an archive:
///
/// - `\` becomes `/` (some ZIP tools write backslash separators);
/// - a leading drive-letter prefix (`C:`) is stripped;
/// - leading `/` (absolute paths) is stripped;
/// - empty and `.` segments are dropped (this also drops trailing `/`;
///   directory-ness is carried by the entry *type*, not the path);
/// - `..` segments pop the previous segment; a `..` that would climb above
///   the archive root is dropped and sets `escapedRoot`, so callers expose
///   the sanitized path **plus a flag**, never the raw path, and never a
///   silent drop.
///
/// The result may be the empty string (e.g. for a bare `/` or `.` entry
/// denoting the archive root).
NormalizedEntryPath normalizeEntryPath(String rawPath) {
  var path = rawPath.replaceAll(r'\', '/');
  // Drive-letter prefix: `C:/x`, `C:x`, and the degenerate `C:`.
  if (path.length >= 2 && path.codeUnitAt(1) == 0x3A /* : */ ) {
    final letter = path.codeUnitAt(0);
    final isAlpha =
        (letter >= 0x41 && letter <= 0x5A) ||
        (letter >= 0x61 && letter <= 0x7A);
    if (isAlpha) path = path.substring(2);
  }

  final segments = <String>[];
  var escapedRoot = false;
  for (final segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isEmpty) {
        escapedRoot = true;
      } else {
        segments.removeLast();
      }
      continue;
    }
    segments.add(segment);
  }
  return (path: segments.join('/'), escapedRoot: escapedRoot);
}

/// Validates and normalizes a caller-supplied path for **writing** (Phase
/// 2). Unlike [normalizeEntryPath], which silently sanitizes hostile input
/// on read, this rejects a bad path with an [ArgumentError]: the writer's
/// caller is a programmer, and silently rewriting their requested path
/// would be surprising.
///
/// Backslashes become `/`; empty and `.` segments are dropped. Throws
/// [ArgumentError] when the path is absolute (leading `/` or a drive
/// letter), escapes the archive root via `..`, or is empty after cleaning.
/// Returns the cleaned, `/`-separated path.
String validateWritePath(String rawPath) {
  final withSlashes = rawPath.replaceAll(r'\', '/');
  if (withSlashes.startsWith('/')) {
    throw ArgumentError.value(rawPath, 'path', 'must not be absolute');
  }
  if (withSlashes.length >= 2 && withSlashes.codeUnitAt(1) == 0x3A /* : */ ) {
    final letter = withSlashes.codeUnitAt(0);
    final isAlpha =
        (letter >= 0x41 && letter <= 0x5A) ||
        (letter >= 0x61 && letter <= 0x7A);
    if (isAlpha) {
      throw ArgumentError.value(
        rawPath,
        'path',
        'must not contain a drive letter',
      );
    }
  }
  final segments = <String>[];
  for (final segment in withSlashes.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      throw ArgumentError.value(
        rawPath,
        'path',
        'must not escape the archive root with ".."',
      );
    }
    segments.add(segment);
  }
  if (segments.isEmpty) {
    throw ArgumentError.value(rawPath, 'path', 'is empty');
  }
  return segments.join('/');
}
