// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:typed_data';

import 'package:zmodem/src/buffer.dart';
import 'package:zmodem/src/consts.dart' as consts;
import 'package:zmodem/src/crc.dart';
import 'package:zmodem/src/zmodem_frame.dart';

class ZModemParser implements Iterator<ZModemPacket> {
  final _buffer = ChunkBuffer();
  final _abortSequence = ZModemAbortSequence();

  /// True from the moment a cancel is recognised until the first byte that
  /// is not a CAN. The rest of that run belongs to the same cancel and is
  /// dropped: released firmware sends 8, 10 or 16 CANs for one failed send,
  /// and counting the surplus towards a second cancel would aim it at the
  /// next session.
  var _inCancelRun = false;

  void _endCancelRun() {
    _inCancelRun = false;
    _abortSequence.reset();
  }

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

  /// Get access to the chunk buffer for diagnostics
  ChunkBuffer get buffer => _buffer;

  /// Attempts to resynchronize the parser by searching for the next
  /// ZMODEM frame start sequence (**). This is useful after a parsing error
  /// to help the parser recover from corrupted data.
  /// Returns true if a potential frame start was found.
  bool attemptResync() {
    return _buffer.resyncToNextFrame();
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
        // Not _endCancelRun(): the CAN count is kept. A sender cut right
        // after a subpacket's end marker puts the first four CANs of its
        // cancel where the two CRC bytes belong; the fifth arrives here.
        // Every byte that is not a CAN resets the count, so nothing
        // older than the bytes just read can be carried in.
        _inCancelRun = false;
        _expectDataSubpacket = false;
        yield* _parseDataSubpacket();
        continue;
      }

      while (_buffer.isEmpty) {
        yield null;
      }

      // Only a frame start needs look-ahead: four bytes tell a hex or a
      // binary header from stray text. Every other byte is acted on as it
      // arrives. Waiting for four bytes regardless of what they were held
      // back the last three bytes of whatever came last. When that was the
      // peer's cancel (five CANs, or the tail of ten or sixteen), the
      // cancel was only recognised once the NEXT session's first bytes
      // arrived, and it cancelled that session instead.
      //42, 42, 24, 88, 66, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 13,
      if (_buffer.peek() == consts.ZPAD) {
        while (_buffer.length < 4) {
          yield null;
        }

        if (_buffer.peek(1) == consts.ZPAD &&
            _buffer.peek(2) == consts.ZDLE &&
            _buffer.peek(3) == consts.ZHEX) {
          _endCancelRun();
          _buffer.expect(consts.ZPAD);
          _buffer.expect(consts.ZPAD);
          _buffer.expect(consts.ZDLE);
          _buffer.expect(consts.ZHEX);
          yield* _parseHexHeader();
          continue;
        }

        if (_buffer.peek(1) == consts.ZDLE && _buffer.peek(2) == consts.ZBIN) {
          _endCancelRun();
          _buffer.expect(consts.ZPAD);
          _buffer.expect(consts.ZDLE);
          _buffer.expect(consts.ZBIN);
          yield* _parseBinaryPacket();
          continue;
        }
      }
      final byte = _buffer.readByte();
      if(byte == consts.CAN) {
        if (_inCancelRun) {
          // The tail of a cancel that has already been reported.
          continue;
        }
        if(_abortSequence.aborted(byte)) {
          _inCancelRun = true;
          yield ZModemAbortSequence();
          continue;
        } else {
          continue;
        }
      } else {
        _endCancelRun();
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
    // A sender that cancels in the middle of a header follows the digits
    // it got out with CANs. The digits are looked at one by one as they
    // arrive, and the header is given up at the first CAN, which is left
    // for the caller: the cancel is counted now. Waiting for all fourteen
    // bytes held the cancel back until the next session's bytes arrived,
    // and decoding the CAN as a digit then threw, which ends this
    // generator for good (the parser never produced another packet).
    // Any other byte that is not a digit still throws below, as before.
    for (var i = 0; i < headerLength; i++) {
      while (_buffer.length <= i) {
        yield null;
      }
      if (_buffer.peek(i) == consts.CAN) {
        for (var j = 0; j < i; j++) {
          _buffer.readByte();
        }
        return;
      }
    }

    final frameType = _buffer.readAsciiByte();
    final p0 = _buffer.readAsciiByte();
    final p1 = _buffer.readAsciiByte();
    final p2 = _buffer.readAsciiByte();
    final p3 = _buffer.readAsciiByte();
    // ignore: unused_local_variable
    final crc0 = _buffer.readAsciiByte();
    // ignore: unused_local_variable
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

    if (next == consts.CAN) {
      // Cancelled before the line end. All fourteen digits are in, so the
      // header stands; the CANs are left for the caller to count.
    } else if(next != 0x8a && next != 0x0a) {
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
    // ignore: unused_local_variable
    final crc0 = _buffer.readEscaped()!;

    while (!_buffer.hasEscaped) yield null;
    // ignore: unused_local_variable
    final crc1 = _buffer.readEscaped()!;
    yield ZModemHeader(frameType, p0, p1, p2, p3);
  }

  Iterable<ZModemPacket?> _parseDataSubpacket() sync* {
    final buffer = BytesBuilder();
    // Raw ZPADs read in a row, just now, as file data.
    var zpads = 0;
    //final headerParser = ZModemHeaderParser();
    while (true) {
      if (zpads >= 2) {
        final restart = _restartHeaderAhead();
        if (restart == null) {
          // Not enough bytes yet to tell.
          yield null;
          continue;
        }
        if (restart) {
          // The sender has given this file up and is opening a new
          // session. Drop the unfinished subpacket, report the end of
          // the old session, then read the ZRQINIT as the header it is.
          _buffer.expect(consts.ZDLE);
          _buffer.expect(consts.ZHEX);
          _endCancelRun();
          yield ZModemSenderRestart();
          yield* _parseHexHeader();
          return;
        }
      }

      final rawZpad = _buffer.isNotEmpty && _buffer.peek() == consts.ZPAD;
      final char = _buffer.readEscaped(abortSequence: _abortSequence);

      if (char == null) {
        yield null;
        continue;
      }
      zpads = rawZpad ? zpads + 1 : 0;

      switch (char) {
        case consts.CANABORT:
          // Whatever CANs follow are the tail of this cancel.
          _inCancelRun = true;
          yield ZModemAbortSequence();
          return;
        case consts.ZCRCE | consts.ZDLEESC:
        case consts.ZCRCG | consts.ZDLEESC:
        case consts.ZCRCQ | consts.ZDLEESC:
        case consts.ZCRCW | consts.ZDLEESC:
          // We get these at the end of a subpacket/frame. CANs read as
          // CRC bytes count towards a cancel like any others.
          while (!_buffer.hasEscaped) yield null;
          final crc0 = _buffer.readEscaped(abortSequence: _abortSequence);

          while (!_buffer.hasEscaped) yield null;
          // (Neither read can complete a cancel: the end marker reset the
          // count and two reads raise it to four at most.)
          final crc1 = _buffer.readEscaped(abortSequence: _abortSequence);

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

extension _RestartDetection on ZModemParser {
  /// Called inside a data subpacket right after two raw ZPADs: is what
  /// follows the rest of a ZRQINIT hex header (`ZDLE ZHEX`, fourteen hex
  /// digits for type 0, four flag bytes and a matching CRC, and the line
  /// end)?
  ///
  /// A sender that drops a file without its cancel reaching us (it was
  /// reset, or it could not send the cancel) starts over with ZRQINIT.
  /// Read as file data, that header and everything after it vanish into
  /// the unfinished subpacket and the sender's offers go unanswered until
  /// it times out. `ZPAD ZPAD ZDLE ZHEX` cannot be file data from the
  /// headband: its senders escape only ZDLE, 0x10, 0x11, 0x13 (and those
  /// with the top bit set), so a ZDLE in file data is never followed by
  /// ZHEX. The digits and the CRC are checked all the same, so that data
  /// from a sender that escapes every control character is not mistaken.
  ///
  /// Returns null while more bytes are needed to decide. It never waits
  /// for bytes that file data would not also bring: the first byte that
  /// does not fit answers false.
  bool? _restartHeaderAhead() {
    const digits = 14;
    if (_buffer.isEmpty) return null;
    if (_buffer.peek() != consts.ZDLE) return false;
    if (_buffer.length < 2) return null;
    if (_buffer.peek(1) != consts.ZHEX) return false;

    final nibbles = <int>[];
    for (var i = 0; i < digits; i++) {
      if (_buffer.length < 3 + i) return null;
      final char = _buffer.peek(2 + i);
      if (char == null) return null;
      final nibble = _hexValue(char);
      if (nibble == null) return false;
      nibbles.add(nibble);
    }

    final bytes = [
      for (var i = 0; i < digits; i += 2) nibbles[i] * 16 + nibbles[i + 1],
    ];
    if (bytes[0] != consts.ZRQINIT) return false;
    final crc = CRC16()
      ..updateAll(bytes.sublist(0, 5))
      ..finalize();
    if (crc.value != (bytes[5] << 8 | bytes[6])) return false;

    // The line end too (LF, or CR LF), so that the header parser, which
    // throws on anything else there, is only ever handed a header it
    // will accept: a restart is never reported and then lost.
    var at = 2 + digits;
    var end = _buffer.peek(at);
    if (end == null) return null;
    if (end == consts.CR || end == 0x8d) {
      at++;
      end = _buffer.peek(at);
      if (end == null) return null;
    }
    return end == 0x0a || end == 0x8a;
  }

  static int? _hexValue(int char) {
    if (char >= 0x30 && char <= 0x39) return char - 0x30;
    if (char >= 0x41 && char <= 0x46) return char - 0x41 + 10;
    if (char >= 0x61 && char <= 0x66) return char - 0x61 + 10;
    return null;
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
      // A cancel is five CONSECUTIVE CANs: any other byte ends the count.
      abortSequence?.reset();
      return readByte();
    }

    if (length < 2) {
      // A ZDLE needs the byte after it, with one exception: the fifth CAN
      // of a cancel. The sender has stopped, so nothing may follow it until
      // the next session starts; it is acted on now, not then.
      if (abortSequence != null && abortSequence.oneShortOfAbort) {
        expect(consts.ZDLE);
        abortSequence.aborted(consts.ZDLE);
        return consts.CANABORT;
      }
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
