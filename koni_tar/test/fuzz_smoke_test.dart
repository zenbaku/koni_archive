@TestOn('vm')
@Tags(['fuzz'])
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_tar/koni_tar.dart';
import 'package:test/test.dart';

/// Corpus-driven fuzz smoke: bit-flip and truncation mutations over
/// the committed fixtures. Invariant: any input either parses or
/// throws a typed [ArchiveException], never a RangeError, never another
/// error type, never a hang, never unbounded memory.
///
/// Budget: `KONI_ARCHIVE_FUZZ_SECONDS` (CI sets 60; local default 5).
/// Deterministic per run: the seed is printed so failures can be replayed.
void main() {
  test(
    'mutated fixtures parse or throw typed errors only',
    () async {
      final budget = Duration(
        seconds:
            int.tryParse(
              Platform.environment['KONI_ARCHIVE_FUZZ_SECONDS'] ?? '',
            ) ??
            5,
      );
      final seed = DateTime.now().millisecondsSinceEpoch;
      final random = Random(seed);
      printOnFailure('fuzz seed: $seed');

      final fixtures =
          Directory('test/fixtures/tar')
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.tar') || f.path.endsWith('.cbt'))
              .map((f) => f.readAsBytesSync())
              .toList();
      expect(fixtures, isNotEmpty);

      final deadline = DateTime.now().add(budget);
      var iterations = 0;
      while (DateTime.now().isBefore(deadline)) {
        iterations++;
        final base = fixtures[random.nextInt(fixtures.length)];
        final mutated = _mutate(base, random);
        try {
          final reader = await const TarFormat().openReader(
            MemoryByteSource(mutated),
            const ArchiveReadOptions(),
          );
          for (final entry in reader.entries) {
            try {
              // Drain with a hard cap: decoded output beyond the claimed size
              // would be an invariant violation of its own.
              var total = 0;
              await for (final chunk in reader.openRead(entry)) {
                total += chunk.length;
                if (total > mutated.length + 1024 * 1024) {
                  fail(
                    'entry ${entry.path} streamed more bytes than plausible',
                  );
                }
              }
            } on ArchiveException {
              // typed: fine
            }
          }
          await reader.close();
        } on ArchiveException {
          // typed: fine
        }
        // Anything else (RangeError, StateError, TypeError, …) propagates and
        // fails the test, that is the invariant.
      }
      printOnFailure('completed $iterations iterations');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Uint8List _mutate(Uint8List base, Random random) {
  var bytes = Uint8List.fromList(base);
  switch (random.nextInt(3)) {
    case 0: // bit flips
      final flips = 1 + random.nextInt(16);
      for (var i = 0; i < flips; i++) {
        final at = random.nextInt(bytes.length);
        bytes[at] = bytes[at] ^ (1 << random.nextInt(8));
      }
    case 1: // truncation
      bytes = Uint8List.sublistView(bytes, 0, random.nextInt(bytes.length));
    case 2: // both
      if (bytes.length > 1) {
        bytes = Uint8List.fromList(
          Uint8List.sublistView(bytes, 0, 1 + random.nextInt(bytes.length - 1)),
        );
        final flips = 1 + random.nextInt(8);
        for (var i = 0; i < flips && bytes.isNotEmpty; i++) {
          final at = random.nextInt(bytes.length);
          bytes[at] = bytes[at] ^ (1 << random.nextInt(8));
        }
      }
  }
  return bytes;
}
