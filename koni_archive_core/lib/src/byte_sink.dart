import 'dart:typed_data';

import 'exceptions.dart';

/// Sequential, append-only byte sink — the output abstraction every archive
/// writer targets (Phase 2). The write mirror of [ByteSource], but there is
/// no seeking: archive writing is inherently sequential (TAR is pure append;
/// ZIP streams its data and appends the central directory at the end,
/// tracking offsets via [length]).
///
/// ## Contract
///
/// - [add] appends [bytes]; the buffer is consumed synchronously (the sink
///   must not retain a reference past the returned future — callers may
///   reuse the buffer).
/// - [length] is the total number of bytes written so far — writers use it
///   to record entry offsets (e.g. a ZIP local-header position).
/// - After [close], [add] throws [ArchiveClosedException]. [close] is
///   idempotent.
/// - Nothing may assume the sink is local: an HTTP-upload sink must be
///   possible without core changes. Writers should [add] in as few, as
///   large, calls as practical.
///
/// See also: [ByteSource] (the reading counterpart).
abstract interface class ByteSink {
  /// Total bytes written so far.
  int get length;

  /// Appends [bytes] to the sink.
  ///
  /// Throws [ArchiveClosedException] if the sink is closed.
  Future<void> add(Uint8List bytes);

  /// Flushes and releases any resources. Idempotent.
  Future<void> close();
}

/// A [ByteSink] that accumulates output in memory.
///
/// Call [takeBytes] after [close] to get the written archive as one
/// contiguous [Uint8List]. Works on every platform (including the web,
/// where the result can be wrapped in a browser `Blob`).
final class BytesBuilderSink implements ByteSink {
  final BytesBuilder _builder = BytesBuilder(copy: false);
  bool _closed = false;
  Uint8List? _taken;

  @override
  int get length => _taken?.length ?? _builder.length;

  @override
  Future<void> add(Uint8List bytes) {
    if (_closed) {
      throw ArchiveClosedException('add(${bytes.length}) after close()');
    }
    // Copy: the contract lets callers reuse their buffer after add returns,
    // and BytesBuilder(copy: false) would otherwise retain the view.
    _builder.add(Uint8List.fromList(bytes));
    return Future.value();
  }

  @override
  Future<void> close() {
    _closed = true;
    return Future.value();
  }

  /// Returns the accumulated bytes. Callable once, after [close]; clears the
  /// internal buffer.
  Uint8List takeBytes() {
    if (!_closed) {
      throw StateError('takeBytes() before close()');
    }
    return _taken ??= _builder.takeBytes();
  }
}
