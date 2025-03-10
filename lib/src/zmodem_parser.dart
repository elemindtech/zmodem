// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:typed_data';

import 'package:zmodem/src/buffer.dart';
import 'package:zmodem/src/consts.dart' as consts;
import 'package:zmodem/src/zmodem_frame.dart';
import 'package:zmodem/src/crc.dart';
import 'package:zmodem/src/zmodem_header_parser.dart';

class ZModemParser implements Iterator<ZModemPacket> {
  final _buffer = ChunkBuffer();
  final _abortSequence = ZModemAbortSequence();

  late final Iterator<ZModemPacket?> _parser = _createParser().iterator;

  void Function(int)? onPlainText;

  ZModemPacket? _current;

  /// The last parsed packet.
  @override
  ZModemPacket get current {
    if (_current == null) {
      throw StateError('No event has been parsed yet');
    }
    return _current!;
  }

  /// Adds more data to the buffer for the parser to consume. Call [moveNext]
  /// after this to parse the next packet.
  void addData(Uint8List data) {
    _buffer.add(data);
  }

  /// Let the parser parse the next packet. Returns true if a packet is parsed.
  /// After returning true, the [current] property will be set to the parsed
  /// packet.
  @override
  bool moveNext() {
    _parser.moveNext();

    final packet = _parser.current;

    if (packet == null) {
      return false;
    }

    _current = packet;
    return true;
  }

  var _expectDataSubpacket = false;

  /// Tells the parser to expect the next packet to be a data subpacket.
  ///
  /// This is necessary because lrzsz produces plain text beween ZMODEM frames
  /// and it's impossible to distinguish between plain text and a data subpacket
  /// without this prompt....
  void expectDataSubpacket() {
    _expectDataSubpacket = true;
  }

  /// Creates an instance of zmodem parser.
  ///
  /// This uses the sync* generator syntax to be able to yield when no enough
  /// data is available and resume the context later when more data is added.
  ///
  /// The returned iterator yields null when no enough data is available and
  /// yields a [ZModemPacket] when a packet is parsed.
  Iterable<ZModemPacket?> _createParser() sync* {
    while (true) {
      //_buffer.printCurrentChunk();
      if (_expectDataSubpacket) {
        _abortSequence.reset();
        _expectDataSubpacket = false;
        yield* _parseDataSubpacket();
        continue;
      }

      while (_buffer.length < 4) {
        yield null;
      }
      
      //42, 42, 24, 88, 66, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 13,
      if (_buffer.peek() == consts.ZPAD) {
        if (_buffer.peek(1) == consts.ZPAD &&
            _buffer.peek(2) == consts.ZDLE &&
            _buffer.peek(3) == consts.ZHEX) {
          _buffer.expect(consts.ZPAD);
          _buffer.expect(consts.ZPAD);
          _buffer.expect(consts.ZDLE);
          _buffer.expect(consts.ZHEX);
          yield* _parseHexHeader();
          continue;
        }

        if (_buffer.peek(1) == consts.ZDLE && _buffer.peek(2) == consts.ZBIN) {
          _buffer.expect(consts.ZPAD);
          _buffer.expect(consts.ZDLE);
          _buffer.expect(consts.ZBIN);
          yield* _parseBinaryPacket();
          continue;
        }
      }
      final byte = _buffer.readByte();
      if(byte == consts.CAN) {
        if(_abortSequence.aborted(byte)) {
          yield ZModemAbortSequence();
          continue;
        } else {
          continue;
        }
      } else {
        _abortSequence.reset();
        _handleDirtyChar(byte);
      }

      //_handleDirtyChar(_buffer.readByte());
    }
  }

  void _handleDirtyChar(int byte) {

    if (byte == consts.XON) {
      return;
    }

    
    


    onPlainText?.call(byte);
  }
//42, 42, 24, 88, 66, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 13,
  Iterable<ZModemPacket?> _parseHexHeader() sync* {
    const asciiFields = 1 + 4 + 2;
    const headerLength = asciiFields * 2;
    //print('Parse header ${_buffer.length}, $headerLength');
    // Hex header has fixed length, so we can check the length before reading.
    while (_buffer.length < headerLength) {
      yield null;
    }

    final frameType = _buffer.readAsciiByte();
    final p0 = _buffer.readAsciiByte();
    final p1 = _buffer.readAsciiByte();
    final p2 = _buffer.readAsciiByte();
    final p3 = _buffer.readAsciiByte();
    final crc0 = _buffer.readAsciiByte();
    final crc1 = _buffer.readAsciiByte();

    //('Frame type $frameType');

    while (_buffer.isEmpty) {
      //print('header buffer is empty');
      yield null;
    }

    // Consume the optional CR before the LF.
    var next = _buffer.peek();
    if (next == consts.CR || next == 0x8D) {
      _buffer.readByte();

      while (_buffer.isEmpty) {
        yield null;
      }
    }

    // _buffer.expect(consts.LF);
    next = _buffer.peek();

    if(next != 0x8a && next != 0x0a) {
      _buffer.expect(0x8a);
    } else {
      _buffer.readByte();
    }

    // Check for XON character,
    next = _buffer.peek();

    if(next == 0x11) {
      _buffer.readByte();
    } 
    yield ZModemHeader(frameType, p0, p1, p2, p3);
  }

  Iterable<ZModemPacket?> _parseBinaryPacket() sync* {
    // Binary header has variable length, though it always has at least 7 bytes.
    while (_buffer.length < 7) {
      yield null;
    }

    while (!_buffer.hasEscaped) yield null;
    final frameType = _buffer.readEscaped()!;

    while (!_buffer.hasEscaped) yield null;
    final p0 = _buffer.readEscaped()!;

    while (!_buffer.hasEscaped) yield null;
    final p1 = _buffer.readEscaped()!;

    while (!_buffer.hasEscaped) yield null;
    final p2 = _buffer.readEscaped()!;

    while (!_buffer.hasEscaped) yield null;
    final p3 = _buffer.readEscaped()!;

    while (!_buffer.hasEscaped) yield null;
    final crc0 = _buffer.readEscaped()!;

    while (!_buffer.hasEscaped) yield null;
    final crc1 = _buffer.readEscaped()!;
    yield ZModemHeader(frameType, p0, p1, p2, p3);
  }

  Iterable<ZModemPacket?> _parseDataSubpacket() sync* {
    final buffer = BytesBuilder();
    //final headerParser = ZModemHeaderParser();
    while (true) {
      final char = _buffer.readEscaped(abortSequence: _abortSequence);

      if (char == null) {
        yield null;
        continue;
      }

      switch (char) {
        case consts.CANABORT:
          yield ZModemAbortSequence();
          return;
        case consts.ZCRCE | consts.ZDLEESC:
        case consts.ZCRCG | consts.ZDLEESC:
        case consts.ZCRCQ | consts.ZDLEESC:
        case consts.ZCRCW | consts.ZDLEESC:
          // We get these at the end of a subpacket/frame.
          while (!_buffer.hasEscaped) yield null;
          final crc0 = _buffer.readEscaped();

          while (!_buffer.hasEscaped) yield null;
          final crc1 = _buffer.readEscaped();

          final type = char ^ consts.ZDLEESC;
          final payload = buffer.takeBytes();
          yield ZModemDataPacket(type, payload,crc0!, crc1!);
          return;
        
        default:
          buffer.addByte(char);
          continue;
      }
    }
  }
}

extension _ChunkBufferExtensions on ChunkBuffer {

        
  static int _toHex(int char) {
    if (char >= 0x30 && char <= 0x39) {
      return char - 0x30;
    } else if (char >= 0x41 && char <= 0x46) {
      return char - 0x41 + 10;
    } else if (char >= 0x61 && char <= 0x66) {
      return char - 0x61 + 10;
    } else {
      throw ArgumentError.value(char, 'char', 'Not a hex character');
    }
  }

  int readAsciiByte() {
    final high = _toHex(readByte());
    final low = _toHex(readByte());
    return high * 16 + low;
  }

  /// Reads a byte from the buffer, escaping it if necessary. This operation
  /// may consume more than one byte from the buffer if the byte is escaped.
  /// Returns `null` if the buffer is empty or if the buffer contains only
  /// the escape character.
  int? readEscaped({ZModemAbortSequence? abortSequence}) {
    if (isEmpty) {
      return null;
    }

    if (peek() != consts.ZDLE) {
      return readByte();
    }

    if (length < 2) {
      return null;
    }

    expect(consts.ZDLE);

    // If we got here, we know we got a ZDLE/CAN. Check if 
    // we need to abort.
    if(abortSequence?.aborted(consts.ZDLE) == true) {
      return consts.CANABORT; 
    }


    final byte = readByte();

    if(byte == consts.CAN) {
      if(abortSequence?.aborted(consts.ZDLE) == true) {
        return consts.CANABORT;
      }
    } else {
      abortSequence?.reset();
    }


    switch (byte) {
      case consts.ZCRCE:
      case consts.ZCRCG:
      case consts.ZCRCQ:
      case consts.ZCRCW:
        return byte | consts.ZDLEESC;
      case consts.ZRUB0:
        return 0x7f;
      case consts.ZRUB1:
        return 0xff;
      default:
        return byte ^ 0x40;
    }
  }

  bool get hasEscaped {
    final next = peek();

    if (next == consts.ZDLE) {
      return length >= 2;
    } else {
      return length >= 1;
    }
  }
}
