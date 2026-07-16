import 'dart:typed_data';

import 'lzma.dart';

/// LZMA2 decompression: chunked LZMA with reset control, 7z's default
/// codec and xz's payload format.
///
/// Chunk-driven like [LzmaDecoder]; writes into a caller-provided output
/// buffer of known size. Malformed input throws [FormatException].
final class Lzma2Decoder {
  /// Creates a decoder writing into all of [output]. The 7z coder
  /// attribute byte (encoded dictionary size) is accepted for validation
  /// but not needed: the output buffer is the window.
  Lzma2Decoder({required Uint8List output, int? dictSizeProp})
    : _output = output,
      _lzma = LzmaDecoder(output: output) {
    if (dictSizeProp != null && dictSizeProp > 40) {
      throw const FormatException('invalid LZMA2 dictionary-size property');
    }
  }

  final Uint8List _output;
  final LzmaDecoder _lzma;

  int _outPos = 0;
  bool _finished = false;
  bool _propsKnown = false;

  _L2State _state = _L2State.control;
  final Uint8List _header = Uint8List(5);
  int _headerFilled = 0;
  int _headerNeeded = 0;
  int _control = 0;
  int _chunkRemaining = 0; // packed bytes (LZMA) or raw bytes (copy)

  /// Whether the end-of-stream control byte was seen (or the output buffer
  /// is exactly full; 7z streams routinely omit the terminator because
  /// sizes are recorded in the container).
  bool get isFinished => _finished || _outPos >= _output.length;

  /// Decoded bytes so far.
  int get outputPosition =>
      _state == _L2State.lzmaChunk ? _lzma.outputPosition : _outPos;

  /// Feeds [chunk]. Throws [FormatException] on corruption.
  void addInput(Uint8List chunk) {
    final data = chunk;
    var pos = 0;
    while (pos < data.length && !_finished) {
      switch (_state) {
        case _L2State.control:
          _control = data[pos++];
          if (_control == 0) {
            _finished = true;
          } else if (_control < 0x80) {
            if (_control > 2) {
              throw const FormatException('invalid LZMA2 control byte');
            }
            _headerNeeded = 2; // uncompressed chunk: 16-bit size
            _headerFilled = 0;
            _state = _L2State.header;
          } else {
            // LZMA chunk: 16-bit unpacked-size low bits, 16-bit packed
            // size, plus a props byte when the reset level says so.
            _headerNeeded = ((_control >> 5) & 3) >= 2 ? 5 : 4;
            _headerFilled = 0;
            _state = _L2State.header;
          }

        case _L2State.header:
          while (_headerFilled < _headerNeeded && pos < data.length) {
            _header[_headerFilled++] = data[pos++];
          }
          if (_headerFilled < _headerNeeded) break;
          _startChunk();

        case _L2State.copyChunk:
          final take = _min(_chunkRemaining, data.length - pos);
          _output.setRange(_outPos, _outPos + take, data, pos);
          _outPos += take;
          pos += take;
          _chunkRemaining -= take;
          if (_chunkRemaining == 0) _state = _L2State.control;

        case _L2State.lzmaChunk:
          final take = _min(_chunkRemaining, data.length - pos);
          _lzma.addInput(Uint8List.sublistView(data, pos, pos + take));
          pos += take;
          _chunkRemaining -= take;
          if (_chunkRemaining == 0) {
            _lzma.setInputComplete();
            if (!_lzma.isChunkComplete) {
              throw const FormatException(
                'LZMA2 chunk ended before its declared output size',
              );
            }
            _outPos = _lzma.outputPosition;
            _state = _L2State.control;
          }
      }
    }
    // Nothing carries across calls except an unfinished header (stashed in
    // _header); every chunk state consumes greedily; input after the end
    // marker is the container's concern.
  }

  /// Declares end of input; throws [FormatException] when mid-chunk.
  void finish() {
    if (_state != _L2State.control && !_finished) {
      throw const FormatException('truncated LZMA2 stream');
    }
  }

  void _startChunk() {
    if (_control < 0x80) {
      // Uncompressed chunk; control 1 also resets the dictionary.
      final size = ((_header[0] << 8) | _header[1]) + 1;
      _lzma.setPosition(_outPos);
      if (_control == 1) _lzma.resetDictionary();
      if (_outPos + size > _output.length) {
        throw const FormatException(
          'LZMA2 uncompressed chunk exceeds declared output size',
        );
      }
      _chunkRemaining = size;
      _state = _L2State.copyChunk;
      return;
    }

    final unpackSize =
        (((_control & 0x1F) << 16) | (_header[0] << 8) | _header[1]) + 1;
    final packSize = ((_header[2] << 8) | _header[3]) + 1;
    final reset = (_control >> 5) & 3;
    _lzma.setPosition(_outPos);
    if (reset == 3) _lzma.resetDictionary();
    if (reset >= 2) {
      _lzma.setProps(_header[4]);
      _propsKnown = true;
    } else if (reset == 1) {
      _lzma.resetState();
    }
    if (!_propsKnown) {
      throw const FormatException(
        'LZMA2 chunk uses properties before any were sent',
      );
    }
    if (_outPos + unpackSize > _output.length) {
      throw const FormatException('LZMA2 chunk exceeds declared output size');
    }
    _lzma.beginChunk(_outPos + unpackSize);
    _chunkRemaining = packSize;
    _state = _L2State.lzmaChunk;
  }

  static int _min(int a, int b) => a < b ? a : b;
}

enum _L2State { control, header, copyChunk, lzmaChunk }
