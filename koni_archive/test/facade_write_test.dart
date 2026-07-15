import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive/koni_archive.dart';
import 'package:test/test.dart';

/// Minimal write format proving `Archive.create` drives the write SPI end
/// to end (real formats — TAR at P2-2, ZIP at P2-3 — plug in the same way).
final class _LineWriteFormat extends ArchiveWriteFormat {
  const _LineWriteFormat();

  @override
  String get name => 'lines';

  @override
  ArchiveWriter openWriter(ByteSink sink, ArchiveWriteOptions options) =>
      _LineWriter(this, sink);
}

final class _LineWriter extends ArchiveWriter {
  _LineWriter(this.format, this._sink);

  @override
  final ArchiveWriteFormat format;
  final ByteSink _sink;

  @override
  Future<ArchiveEntry> addStream(
    ArchiveEntrySpec spec,
    Stream<Uint8List> content, {
    required int size,
  }) async {
    final path = validateWritePath(spec.path);
    await _sink.add(Uint8List.fromList(utf8.encode('$path=')));
    await for (final chunk in content) {
      await _sink.add(chunk);
    }
    await _sink.add(Uint8List.fromList(utf8.encode('\n')));
    return ArchiveEntry(path: path, type: spec.type, uncompressedSize: size);
  }

  @override
  Future<ArchiveEntry> addEntry(ArchiveEntrySpec spec) async {
    final path = validateWritePath(spec.path);
    return ArchiveEntry(path: path, type: spec.type, uncompressedSize: 0);
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('Archive.create writes through a ByteSink', () async {
    final sink = BytesBuilderSink();
    final writer = Archive.create(sink, format: const _LineWriteFormat());
    expect(writer.format.name, 'lines');

    await writer.addBytes(
      ArchiveEntrySpec(path: 'a.txt'),
      Uint8List.fromList(utf8.encode('one')),
    );
    await writer.addBytes(
      ArchiveEntrySpec(path: 'b.txt'),
      Uint8List.fromList(utf8.encode('two')),
    );
    await writer.close();
    await sink.close();

    expect(utf8.decode(sink.takeBytes()), 'a.txt=one\nb.txt=two\n');
  });
}
