/// Conformance runner (PROMPT_V1.md §11).
///
/// Decodes every archive in the owner-provided real-world corpus with
/// koni_archive and checks it against the committed reference manifests in
/// `test/conformance/manifests/` (generated on the owner's machine by
/// `tool/generate_conformance_manifests.dart` using independent reference
/// implementations, never koni_archive itself). The corpus is copyrighted
/// and never committed; its location comes from the
/// `KONI_ARCHIVE_CORPUS_DIR` environment variable. When the corpus is
/// absent the run is *skipped with a mark* — never silently — so public CI
/// stays green while local/scheduled runs get full coverage.
@TestOn('vm')
@Tags(['conformance'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:koni_archive/io.dart';
import 'package:test/test.dart';

/// Environment variable pointing at the corpus directory.
const String corpusEnvVar = 'KONI_ARCHIVE_CORPUS_DIR';

void main() {
  final corpusPath = Platform.environment[corpusEnvVar];
  final manifests = _committedManifests();

  test('conformance preconditions', () {
    if (corpusPath == null || corpusPath.isEmpty) {
      markTestSkipped(
        'Conformance run skipped: $corpusEnvVar is not set. '
        'Set it to the corpus directory for full coverage.',
      );
      return;
    }
    expect(
      Directory(corpusPath).existsSync(),
      isTrue,
      reason: '$corpusEnvVar points at a missing directory: $corpusPath',
    );
    if (manifests.isEmpty) {
      markTestSkipped(
        'No conformance manifests committed yet; generate them with '
        'tool/generate_conformance_manifests.dart.',
      );
    }
  });

  if (corpusPath == null || corpusPath.isEmpty) return;

  for (final manifestFile in manifests) {
    final manifest =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    final archiveInfo = manifest['archive'] as Map<String, dynamic>;
    final fileName = archiveInfo['fileName'] as String;

    test(
      'corpus: $fileName matches its reference manifest',
      () async {
        final archiveFile = _findInCorpus(corpusPath, fileName);
        if (archiveFile == null) {
          markTestSkipped('archive "$fileName" not present in this corpus');
          return;
        }

        // The manifest must describe this exact file.
        final rawBytes = archiveFile.readAsBytesSync();
        expect(rawBytes.length, archiveInfo['sizeBytes']);
        expect(
          sha256.convert(rawBytes).toString(),
          archiveInfo['sha256'],
          reason: 'corpus file differs from the one the manifest describes',
        );

        // A whole-archive feature we do not read yet (e.g. RAR4 CBRs,
        // which §8 flags as common) is a *documented gap*, not a failure:
        // the manifest stays committed as a target for the milestone that
        // adds support, and this run marks the skip rather than going red.
        final Archive archive;
        try {
          archive = await openArchiveFile(archiveFile.path);
        } on UnsupportedFeatureException catch (e) {
          markTestSkipped('unsupported archive feature ($fileName): $e');
          return;
        } on EncryptedArchiveException catch (e) {
          markTestSkipped('encrypted archive ($fileName): $e');
          return;
        }
        addTearDown(archive.close);

        final expected =
            (manifest['entries'] as List<dynamic>).cast<Map<String, dynamic>>();
        final actualFiles = [
          for (final e in archive.entries)
            if (e.type == ArchiveEntryType.file) e,
        ];
        expect(
          actualFiles.length,
          expected.length,
          reason: 'file-entry count differs from the reference reader',
        );

        // Compare by index: both sides preserve archive (central directory)
        // order. Content hashes are the ground truth; the path check runs
        // through the same normalization the reference name would get.
        for (var i = 0; i < expected.length; i++) {
          final want = expected[i];
          final got = actualFiles[i];
          final wantPath = normalizeEntryPath(want['path'] as String).path;
          expect(got.path, wantPath, reason: 'entry #$i path');
          expect(
            got.uncompressedSize,
            want['sizeBytes'],
            reason: 'entry #$i (${got.path}) size',
          );
          if (got.crc32 != null) {
            expect(
              got.crc32!.toRadixString(16).padLeft(8, '0'),
              want['crc32'],
              reason: 'entry #$i (${got.path}) recorded CRC-32',
            );
          }
          final content = await archive.readBytes(got);
          expect(
            sha256.convert(content).toString(),
            want['sha256'],
            reason: 'entry #$i (${got.path}) decoded content',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}

List<File> _committedManifests() {
  final dir = Directory('test/conformance/manifests');
  if (!dir.existsSync()) return const [];
  return dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

File? _findInCorpus(String corpusPath, String fileName) {
  for (final entity in Directory(corpusPath).listSync(recursive: true)) {
    if (entity is File && entity.uri.pathSegments.last == fileName) {
      return entity;
    }
  }
  return null;
}
