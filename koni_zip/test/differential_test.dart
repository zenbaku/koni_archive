@TestOn('vm')
library;

import 'dart:io';

import 'package:archive/archive.dart' as pkg_archive;
import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_zip/koni_zip.dart';
import 'package:test/test.dart';

/// Differential tests against `package:archive` (§11): same fixture, both
/// decoders, same regular-file list and content.
void main() {
  const fixtures = [
    'stored_basic.zip',
    'comment.zip',
    'synthetic_comic.cbz',
    'deflated.zip',
    'synthetic_comic_deflated.cbz',
  ];

  for (final fixture in fixtures) {
    test('$fixture decodes identically to package:archive', () async {
      final bytes = File('test/fixtures/zip/$fixture').readAsBytesSync();

      final theirs = pkg_archive.ZipDecoder().decodeBytes(bytes);
      final theirFiles = {
        for (final f in theirs.files)
          if (f.isFile) f.name: f.content as List<int>,
      };

      final reader = await const ZipFormat().openReader(
        MemoryByteSource(bytes),
        const ArchiveReadOptions(),
      );
      final ourFiles = <String, List<int>>{};
      for (final entry in reader.entries) {
        if (entry.type != ArchiveEntryType.file) continue;
        final chunks = await reader.openRead(entry).toList();
        ourFiles[entry.path] = chunks.expand<int>((c) => c).toList();
      }

      expect(ourFiles.keys.toSet(), theirFiles.keys.toSet());
      for (final MapEntry(key: path, value: content) in ourFiles.entries) {
        expect(content, theirFiles[path], reason: 'content of $path');
      }
    });
  }
}
