import 'dart:collection';
import 'dart:typed_data';

class ChunkBuffer {
  /// The chunks that have been added to the buffer but not yet consumed. Each
  /// chunk is guaranteed to have at least one byte.
  final _backlog = Queue<Uint8List>();

  /// Maximum number of chunks to keep in backlog to prevent unbounded memory growth
  static const int _maxBacklogSize = 50;

  /// Track peak backlog size for diagnostics
  int _backlogPeakSize = 0;

  /// The number of bytes in the buffer that have not been consumed.
  var _length = 0;

  /// Read offset into [_chunkOffset].
  var _readOffset = 0;

  Uint8List? _currentChunk;

  Uint8List? get currentChunk => _currentChunk;

  /// Number of bytes in the buffer that have not been consumed.
  int get length => _length;

  bool get isEmpty => _length == 0;

  bool get isNotEmpty => _length > 0;

  void add(Uint8List chunk) {
    if (chunk.isEmpty) {
      return;
    }
    if (_currentChunk != null) {
      // Enforce maximum backlog size to prevent memory exhaustion
      // If backlog is full, this indicates the consumer is too slow
      if (_backlog.length >= _maxBacklogSize) {
        // This is a critical condition - parser can't keep up with incoming data
        // Drop the oldest chunk to prevent OOM, but this may cause data corruption
        print('WARNING: ChunkBuffer backlog full ($_maxBacklogSize chunks) - '
            'dropping oldest chunk. Parser may be too slow.');
        final droppedChunk = _backlog.removeFirst();
        _length -= droppedChunk.length;
      }
      _backlog.add(chunk);
      
      // Track peak backlog size for diagnostics
      if (_backlog.length > _backlogPeakSize) {
        _backlogPeakSize = _backlog.length;
        // Log when backlog grows significantly (>50% capacity)
        if (_backlog.length > _maxBacklogSize ~/ 2) {
          print('ChunkBuffer backlog growing: ${_backlog.length}/$_maxBacklogSize '
              '(peak: $_backlogPeakSize, $_length bytes buffered)');
        }
      }
    } else {
      _currentChunk = chunk;
    }
    _length += chunk.length;
  }

  void expect(int byte) {
    final actual = readByte();

    if (actual != byte) {
      throw StateError(
        'Expected 0x${byte.toRadixString(16)}, got 0x${actual.toRadixString(16)}',
      );
    }
  }

  int? peek([int offset = 0]) {
    var currentChunk = _currentChunk;

    if (currentChunk == null) {
      return null;
    }

    if (_readOffset + offset < currentChunk.length) {
      return currentChunk[_readOffset + offset];
    }
    offset -= (currentChunk.length - _readOffset);

    for (var chunk in _backlog) {
      if (offset < chunk.length) {
        return chunk[offset];
      }
      offset -= chunk.length;
    }

    return null;
  }
  void printUint8ListAsHex(Uint8List data) {
    String hexString = data.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(', ');
    print(hexString.toUpperCase());
  }

  void printCurrentChunk() {
    printUint8ListAsHex(_currentChunk!);
  }

  int readByte() {
    while (true) {
      var currentChunk = _currentChunk;

      if (currentChunk == null) {
        throw StateError('No chunk has been added to the buffer yet');
      }

      if (_readOffset < currentChunk.length) {
        _length--;
        return currentChunk[_readOffset++];
      }

      if (_backlog.isEmpty) {
        throw StateError('No more bytes to read');
      }

      _currentChunk = _backlog.removeFirst();
      _readOffset = 0;
    }
  }

  /// Attempts to resync the buffer by searching for the next ZPAD sequence.
  /// ZPAD is the start of a ZMODEM frame: ** (0x2A, 0x2A)
  /// Returns true if a ZPAD sequence was found and buffer was repositioned.
  bool resyncToNextFrame() {
    const zpad = 0x2A; // '*' character
    
    // Scan through buffer looking for ** pattern
    while (length >= 2) {
      final byte1 = peek(0);
      final byte2 = peek(1);
      
      if (byte1 == zpad && byte2 == zpad) {
        // Found potential frame start
        return true;
      }
      
      // Skip this byte and continue searching
      try {
        readByte();
      } catch (e) {
        // End of buffer reached
        return false;
      }
    }
    
    return false;
  }

  /// Get diagnostic information about the buffer state
  /// Returns a map with current backlog size, peak size, and buffered bytes
  Map<String, int> getDiagnostics() {
    return {
      'backlogSize': _backlog.length,
      'backlogPeak': _backlogPeakSize,
      'bufferedBytes': _length,
      'maxBacklogSize': _maxBacklogSize,
    };
  }

  /// Reset diagnostic counters (call at start of new session)
  void resetDiagnostics() {
    _backlogPeakSize = 0;
  }
}
