// ZIP benchmarks (M3, §10): koni_archive vs package:archive.
//
//   dart run --no-enable-asserts bench/bin/zip_bench.dart
//
// Scenarios:
//   1. list        — index a 20k-entry archive (no content decode)
//   2. random page — open + read one page out of a large stored CBZ
//
// Results are printed as a markdown table; commit them under
// bench/results/. Performance is measured, not asserted.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as pkg_archive;
import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_zip/koni_zip.dart';

const int warmupRuns = 2;
const int measuredRuns = 5;

Future<void> main() async {
  final listArchive = _buildStoredZip(entryCount: 20000, entrySize: 64);
  // A ~120-page CBZ with 512 KiB pages: 60 MiB, the flagship shape (§1).
  final cbz = _buildStoredZip(entryCount: 120, entrySize: 512 * 1024);

  stdout.writeln('# ZIP benchmarks (M3)');
  stdout.writeln('');
  stdout.writeln('- date: ${DateTime.now().toUtc().toIso8601String()}');
  stdout.writeln('- dart: ${Platform.version}');
  stdout.writeln('- os: ${Platform.operatingSystemVersion}');
  stdout.writeln(
    '- inputs: list = 20k entries x 64 B stored '
    '(${_mb(listArchive.length)} MiB); cbz = 120 pages x 512 KiB stored '
    '(${_mb(cbz.length)} MiB)',
  );
  stdout.writeln('- runs: best of $measuredRuns (after $warmupRuns warmup)');
  stdout.writeln('');
  stdout.writeln('| scenario | koni_archive | package:archive | ratio |');
  stdout.writeln('| --- | --- | --- | --- |');

  await _scenario(
    'list 20k entries',
    ours: () async {
      final reader = await const ZipFormat().openReader(
        MemoryByteSource(listArchive),
        const ArchiveReadOptions(),
      );
      _use(reader.entries.length);
    },
    theirs: () async {
      final archive = pkg_archive.ZipDecoder().decodeBytes(listArchive);
      _use(archive.files.length);
    },
  );

  // package:archive does not verify checksums on read; measure ours both
  // ways (verification is on by default per §7).
  Future<void> ourPageRead(ArchiveReadOptions options) async {
    final reader = await const ZipFormat().openReader(
      MemoryByteSource(cbz),
      options,
    );
    final page = reader.entries[57];
    var total = 0;
    await for (final chunk in reader.openRead(page)) {
      total += chunk.length;
    }
    _use(total);
  }

  Future<void> theirPageRead() async {
    final archive = pkg_archive.ZipDecoder().decodeBytes(cbz);
    final page = archive.files[57];
    _use((page.content as List<int>).length);
  }

  await _scenario(
    'open CBZ + read 1 page (CRC verified, default)',
    ours: () => ourPageRead(const ArchiveReadOptions()),
    theirs: theirPageRead,
  );
  await _scenario(
    'open CBZ + read 1 page (verifyChecksums: false)',
    ours: () => ourPageRead(const ArchiveReadOptions(verifyChecksums: false)),
    theirs: theirPageRead,
  );

  // M5: the flagship scenario (§10) — random page read from a DEFLATED CBZ.
  final deflatedCbz = _buildDeflatedZip(entryCount: 120, entrySize: 512 * 1024);
  Future<void> ourDeflatedPageRead() async {
    final reader = await const ZipFormat().openReader(
      MemoryByteSource(deflatedCbz),
      const ArchiveReadOptions(),
    );
    final page = reader.entries[57];
    var total = 0;
    await for (final chunk in reader.openRead(page)) {
      total += chunk.length;
    }
    _use(total);
  }

  Future<void> theirDeflatedPageRead() async {
    final archive = pkg_archive.ZipDecoder().decodeBytes(deflatedCbz);
    final page = archive.files[57];
    _use((page.content as List<int>).length);
  }

  await _scenario(
    'open deflated CBZ + read 1 page (CRC verified)',
    ours: ourDeflatedPageRead,
    theirs: theirDeflatedPageRead,
  );
}

/// Deflated variant of [_buildStoredZip] (per-page raw deflate via the
/// platform zlib; bench-only code).
Uint8List _buildDeflatedZip({required int entryCount, required int entrySize}) {
  final content = Uint8List(entrySize);
  for (var i = 0; i < entrySize; i++) {
    content[i] = i % 4 == 0 ? (i ~/ 512) & 0x3F : (i * 31) & 0xFF;
  }
  final compressed = Uint8List.fromList(
    ZLibCodec(level: 6, raw: true).encode(content),
  );
  final crc = Crc32.compute(content);
  final names = [
    for (var i = 0; i < entryCount; i++)
      ascii.encode('pages/page${'$i'.padLeft(5, '0')}.png'),
  ];

  final out = BytesBuilder(copy: false);
  void u16(int v) => out.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(int v) =>
      out.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

  final offsets = <int>[];
  for (final name in names) {
    offsets.add(out.length);
    u32(0x04034B50);
    u16(20);
    u16(0);
    u16(8); // deflate
    u16(0x1883);
    u16(0x5022);
    u32(crc);
    u32(compressed.length);
    u32(entrySize);
    u16(name.length);
    u16(0);
    out.add(name);
    out.add(compressed);
  }
  final cdOffset = out.length;
  for (var i = 0; i < names.length; i++) {
    u32(0x02014B50);
    u16(20);
    u16(20);
    u16(0);
    u16(8);
    u16(0x1883);
    u16(0x5022);
    u32(crc);
    u32(compressed.length);
    u32(entrySize);
    u16(names[i].length);
    u16(0);
    u16(0);
    u16(0);
    u16(0);
    u32(0);
    u32(offsets[i]);
    out.add(names[i]);
  }
  final cdSize = out.length - cdOffset;
  u32(0x06054B50);
  u16(0);
  u16(0);
  u16(names.length);
  u16(names.length);
  u32(cdSize);
  u32(cdOffset);
  u16(0);
  return out.takeBytes();
}

Future<void> _scenario(
  String name, {
  required Future<void> Function() ours,
  required Future<void> Function() theirs,
}) async {
  final ourBest = await _best(ours);
  final theirBest = await _best(theirs);
  final ratio = theirBest.inMicroseconds / ourBest.inMicroseconds;
  stdout.writeln(
    '| $name | ${_ms(ourBest)} ms | ${_ms(theirBest)} ms | '
    '${ratio.toStringAsFixed(2)}x |',
  );
}

Future<Duration> _best(Future<void> Function() run) async {
  for (var i = 0; i < warmupRuns; i++) {
    await run();
  }
  var best = const Duration(days: 1);
  for (var i = 0; i < measuredRuns; i++) {
    final watch = Stopwatch()..start();
    await run();
    watch.stop();
    if (watch.elapsed < best) best = watch.elapsed;
  }
  return best;
}

String _ms(Duration d) => (d.inMicroseconds / 1000).toStringAsFixed(1);

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);

int _sink = 0;
void _use(int value) => _sink ^= value; // defeat dead-code elimination

/// Minimal in-memory stored-ZIP emitter — bench-only code, not shipped.
Uint8List _buildStoredZip({required int entryCount, required int entrySize}) {
  final out = BytesBuilder(copy: false);
  final content = Uint8List(entrySize);
  for (var i = 0; i < entrySize; i++) {
    content[i] = (i * 31 + 7) & 0xFF;
  }
  final crc = Crc32.compute(content);
  final names = [
    for (var i = 0; i < entryCount; i++)
      ascii.encode('dir${i ~/ 1000}/page${'$i'.padLeft(5, '0')}.png'),
  ];

  void u16(int v) => out.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(int v) =>
      out.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

  final offsets = <int>[];
  for (final name in names) {
    offsets.add(out.length);
    u32(0x04034B50);
    u16(20);
    u16(0);
    u16(0);
    u16(0x1883); // 03:04:06
    u16(0x5022); // 2020-01-02
    u32(crc);
    u32(entrySize);
    u32(entrySize);
    u16(name.length);
    u16(0);
    out.add(name);
    out.add(content);
  }
  final cdOffset = out.length;
  for (var i = 0; i < names.length; i++) {
    u32(0x02014B50);
    u16(20);
    u16(20);
    u16(0);
    u16(0);
    u16(0x1883);
    u16(0x5022);
    u32(crc);
    u32(entrySize);
    u32(entrySize);
    u16(names[i].length);
    u16(0);
    u16(0);
    u16(0);
    u16(0);
    u32(0);
    u32(offsets[i]);
    out.add(names[i]);
  }
  final cdSize = out.length - cdOffset;
  u32(0x06054B50);
  u16(0);
  u16(0);
  u16(names.length);
  u16(names.length);
  u32(cdSize);
  u32(cdOffset);
  u16(0);
  return out.takeBytes();
}
