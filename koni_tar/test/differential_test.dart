@TestOn('vm')
library;

import 'dart:io';

import 'package:archive/archive.dart' as pkg_archive;
import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_tar/koni_tar.dart';
import 'package:test/test.dart';

/// Differential tests against `package:archive` where the formats
/// overlap: same fixture, both decoders, same file list and content.
///
/// Scope note: only plain-file entries are compared (the packages model
/// directories/links differently) and only fixtures both handle.
void main() {
  const fixtures = [
    'basic_ustar.tar',
    'v7.tar',
    'duplicate.tar',
    'synthetic_comic.cbt',
    'long_paths_pax.tar',
    'long_paths_gnu.tar',
  ];

  for (final fixture in fixtures) {
    test('$fixture decodes identically to package:archive', () async {
      final bytes = File('test/fixtures/tar/$fixture').readAsBytesSync();

      final theirs = pkg_archive.TarDecoder().decodeBytes(bytes);
      final theirFiles = {
        for (final f in theirs.files)
          if (f.isFile) f.name: f.content as List<int>,
      };

      final reader = await const TarFormat().openReader(
        MemoryByteSource(bytes),
        const ArchiveReadOptions(),
      );
      final ourFiles = <String, List<int>>{};
      for (final entry in reader.entries) {
        if (entry.type != ArchiveEntryType.file) continue;
        final chunks = await reader.openRead(entry).toList();
        ourFiles[entry.path] = chunks.expand<int>((c) => c).toList();
      }

      // Model differences to tolerate: package:archive exposes
      // symlinks/hardlinks as zero-length *files*, and it surfaces GNU 'K'
      // long-link pseudo-entries as files named after the link target.
      // bsdtar ground truth for those shapes is asserted in
      // tar_fixtures_test.dart; here we require that every regular file we
      // decode exists there with byte-identical content.
      expect(ourFiles, isNotEmpty);
      for (final MapEntry(key: path, value: content) in ourFiles.entries) {
        expect(theirFiles, contains(path));
        expect(content, theirFiles[path], reason: 'content of $path');
      }
    });
  }
}
