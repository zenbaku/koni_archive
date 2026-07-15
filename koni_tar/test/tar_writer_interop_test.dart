@TestOn('vm')
@Tags(['interop'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_tar/koni_tar.dart';
import 'package:test/test.dart';

/// Interop is the real definition-of-done (per doc/writing.md): a reference
/// `tar` must extract what we wrote, byte-for-byte. Skipped (marked) when
/// `tar` is absent so public CI stays green; run locally / on machines with
/// the tool.
void main() {
  final tar = _findTar();

  test('bsdtar/GNU tar extracts a koni_tar-written archive', () async {
    if (tar == null) {
      markTestSkipped('no `tar` on PATH; interop check skipped');
      return;
    }

    final files = <String, Uint8List>{
      'hello.txt': Uint8List.fromList(utf8.encode('hello, writer!\n')),
      'nested/deep/data.bin': Uint8List.fromList(
        List.generate(5000, (i) => (i * 13 + 7) & 0xFF),
      ),
      '日本語/ページ001.txt': Uint8List.fromList(utf8.encode('unicode page\n')),
      '${'L' * 160}.txt': Uint8List.fromList(utf8.encode('a long name\n')),
    };

    final sink = BytesBuilderSink();
    final writer = const TarWriteFormat().openWriter(
      sink,
      const ArchiveWriteOptions(),
    );
    await writer.addEntry(
      ArchiveEntrySpec(path: 'nested', type: ArchiveEntryType.directory),
    );
    for (final MapEntry(key: path, value: content) in files.entries) {
      await writer.addBytes(
        ArchiveEntrySpec(
          path: path,
          modified: DateTime.utc(2020, 1, 2, 3, 4, 6),
        ),
        content,
      );
    }
    await writer.close();
    await sink.close();

    final dir = Directory.systemTemp.createTempSync('koni_tar_interop');
    try {
      final archivePath = '${dir.path}/out.tar';
      File(archivePath).writeAsBytesSync(sink.takeBytes());

      final extractDir = Directory('${dir.path}/x')..createSync();
      final result = await Process.run(
        tar,
        ['-xf', archivePath, '-C', extractDir.path],
        environment: {'LC_ALL': 'en_US.UTF-8', 'LANG': 'en_US.UTF-8'},
      );
      expect(result.exitCode, 0, reason: 'tar failed: ${result.stderr}');

      for (final MapEntry(key: path, value: content) in files.entries) {
        final extracted = File('${extractDir.path}/$path');
        expect(extracted.existsSync(), isTrue, reason: 'missing $path');
        expect(
          extracted.readAsBytesSync(),
          content,
          reason: 'content of $path differs from what we wrote',
        );
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('the reference tar lists our entries', () async {
    if (tar == null) {
      markTestSkipped('no `tar` on PATH; interop check skipped');
      return;
    }
    final sink = BytesBuilderSink();
    final writer = const TarWriteFormat().openWriter(
      sink,
      const ArchiveWriteOptions(),
    );
    await writer.addBytes(
      ArchiveEntrySpec(path: 'a.txt'),
      Uint8List.fromList(utf8.encode('a')),
    );
    await writer.addBytes(
      ArchiveEntrySpec(path: 'b/c.txt'),
      Uint8List.fromList(utf8.encode('c')),
    );
    await writer.close();
    await sink.close();

    final dir = Directory.systemTemp.createTempSync('koni_tar_list');
    try {
      final archivePath = '${dir.path}/list.tar';
      File(archivePath).writeAsBytesSync(sink.takeBytes());
      final result = await Process.run(tar, ['-tf', archivePath]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final listed =
          (result.stdout as String)
              .split('\n')
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty)
              .toSet();
      expect(listed, containsAll(<String>['a.txt', 'b/c.txt']));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}

String? _findTar() {
  // Windows bundles bsdtar as tar.exe, but its handling of UTF-8 entry names
  // on the Windows filesystem/console codepage differs from the Unix `tar`
  // this interop check targets — an entry like `日本語/ページ001.txt` doesn't
  // land under that exact name. The archive bytes we write are the same on
  // every platform and are validated against GNU tar (Linux) and bsdtar
  // (macOS) in CI, so skip the extraction check on Windows rather than assert
  // a Windows-specific tool quirk.
  if (Platform.isWindows) return null;
  for (final candidate in ['/usr/bin/tar', '/bin/tar', 'tar']) {
    try {
      final result = Process.runSync(candidate, ['--version']);
      if (result.exitCode == 0) return candidate;
    } on ProcessException {
      continue;
    }
  }
  return null;
}
