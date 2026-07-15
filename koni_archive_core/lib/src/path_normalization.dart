/// Entry-path normalization, applied by every reader at parse time (§7).
///
/// Archive paths are attacker-controlled input; nothing downstream ever sees
/// a raw one.
library;

/// Result of [normalizeEntryPath]: the sanitized [path] plus whether the
/// original attempted to escape the archive root.
typedef NormalizedEntryPath = ({String path, bool escapedRoot});

/// Normalizes a path as stored in an archive (§7):
///
/// - `\` becomes `/` (some ZIP tools write backslash separators);
/// - a leading drive-letter prefix (`C:`) is stripped;
/// - leading `/` (absolute paths) is stripped;
/// - empty and `.` segments are dropped (this also drops trailing `/` —
///   directory-ness is carried by the entry *type*, not the path);
/// - `..` segments pop the previous segment; a `..` that would climb above
///   the archive root is dropped and sets `escapedRoot`, so callers expose
///   the sanitized path **plus a flag** — never the raw path, and never a
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
