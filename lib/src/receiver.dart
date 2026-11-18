// A receive-only ZMODEM endpoint, built as ONE state machine that is driven
// a byte at a time.
//
// It exists beside [ZModemCore] and its parser, which it does not touch.
// It rests on four rules, each of which the older pair broke somewhere:
//
//  1. It cannot get stuck and it cannot die. Every byte, in every state,
//     has a defined effect; nothing throws; nothing waits for bytes that
//     may never come. What does not belong to a frame is skipped.
//
//  2. What a byte means never depends on how the bytes were cut into
//     deliveries. There is no look-ahead: a cancel is acted on as its
//     fifth CAN arrives, a header as its line end arrives.
//
//  3. The receiver alone owns the session. It knows from the protocol
//     when a session starts and ends, numbers the sessions, and stamps
//     every event with the number. The consumer never resets it because
//     of something the sender did; it passes the number back with each
//     decision, and a decision for a session that is over is refused.
//
//  4. Whether data follows a header is the receiver's own knowledge (it
//     follows ZFILE and ZDATA, and a data packet that ends "more to
//     come"). Nobody arms the parser from outside.
//
// The dialect is the headband firmware's: every header in hex with a
// CRC-16, one file per session, the receiver closing its side with ZRINIT
// and ZFIN once the consumer has confirmed the file. Binary headers,
// which the firmware never sends, are not read.
import 'dart:typed_data';

import 'package:zmodem/src/consts.dart' as consts;
import 'package:zmodem/src/crc.dart';
import 'package:zmodem/src/util/string.dart';
import 'package:zmodem/src/zmodem_fileinfo.dart';
import 'package:zmodem/src/zmodem_frame.dart';

/// Why a session ended.
enum ZEndReason {
  /// The file was confirmed ([ZReceiver.ackFileEnd]) and the sender went
  /// on: it said goodbye, or it started its next session.
  delivered,

  /// The file was skipped ([ZReceiver.skipFile]) and the sender went on:
  /// it said goodbye, cancelled (released firmware ends a skipped file
  /// that way), or started its next session.
  skipped,

  /// The sender said goodbye with no file confirmed or skipped.
  closedBySender,

  /// The sender cancelled: five CAN bytes in a row.
  cancelledBySender,

  /// The sender began a new session (ZRQINIT) while this one was open.
  restartedBySender,

  /// The sender sent something this receiver could not accept where it
  /// stood. The receiver answered with a cancel.
  refused,

  /// The consumer aborted ([ZReceiver.abort]). A cancel was sent.
  abortedByReceiver,

  /// The consumer gave the session up locally ([ZReceiver.giveUp]).
  /// Nothing was sent.
  givenUp,
}

/// Something the consumer should know. [session] is the number of the
/// session it belongs to; pass it back with any decision about it.
abstract class ZRxEvent {
  const ZRxEvent(this.session);

  final int session;
}

/// The sender asked to start a session and was answered.
class ZRxSessionStarted extends ZRxEvent {
  const ZRxSessionStarted(int session) : super(session);

  @override
  String toString() => 'ZRxSessionStarted($session)';
}

/// A file is offered. Answer with [ZReceiver.acceptFile] or
/// [ZReceiver.skipFile].
class ZRxOffer extends ZRxEvent {
  const ZRxOffer(int session, this.fileInfo) : super(session);

  final ZModemFileInfo fileInfo;

  @override
  String toString() => 'ZRxOffer($session, ${fileInfo.pathname})';
}

/// A run of file data begins at [offset] (a ZDATA header).
class ZRxDataStart extends ZRxEvent {
  const ZRxDataStart(int session, this.offset) : super(session);

  final int offset;

  @override
  String toString() => 'ZRxDataStart($session, $offset)';
}

/// One data packet of the file.
class ZRxData extends ZRxEvent {
  const ZRxData(int session, this.data, this.endType, this.crc, this.crcOk)
      : super(session);

  final Uint8List data;

  /// How the packet ended: ZCRCG, ZCRCQ, ZCRCE or ZCRCW.
  final int endType;

  /// The check the sender put on the packet.
  final int crc;

  /// Whether [crc] matches [data]. When it does not, the consumer asks
  /// for the data again with [ZReceiver.reposition].
  final bool crcOk;

  @override
  String toString() => 'ZRxData($session, ${data.length} bytes, ok=$crcOk)';
}

/// The sender says the file is complete at [position] (ZEOF). Nothing is
/// sent back until the consumer answers with [ZReceiver.ackFileEnd] or
/// [ZReceiver.abort].
class ZRxFileEnd extends ZRxEvent {
  const ZRxFileEnd(int session, this.position) : super(session);

  final int position;

  @override
  String toString() => 'ZRxFileEnd($session, $position)';
}

/// The session is over. Events of a later session carry a later number.
class ZRxSessionEnded extends ZRxEvent {
  const ZRxSessionEnded(int session, this.reason) : super(session);

  final ZEndReason reason;

  @override
  String toString() => 'ZRxSessionEnded($session, ${reason.name})';
}

/// Where the session stands.
enum _Session {
  /// No session. Waiting for the sender's ZRQINIT.
  idle,

  /// ZRQINIT answered. Waiting for the offer (ZFILE).
  awaitOffer,

  /// ZFILE seen. Reading the packet with the file's name and length.
  offerInfo,

  /// The offer is with the consumer.
  offerVerdict,

  /// The file was accepted, or a reposition was asked for. Waiting for
  /// the ZDATA header.
  awaitData,

  /// Reading the file's data packets.
  receiving,

  /// ZEOF seen. The file is with the consumer.
  eofVerdict,

  /// The file was confirmed and our ZRINIT and ZFIN are out. Waiting for
  /// the sender's ZFIN.
  closing,

  /// The file was skipped and our ZSKIP is out. Waiting for the sender to
  /// end the session.
  skipped,
}

/// What a byte that is part of no header belongs to.
enum _Parse {
  /// Nothing: the receiver is between frames.
  hunt,

  /// The body of a data packet.
  data,

  /// The two check bytes of a data packet.
  dataCrc,
}

class ZReceiver {
  /// [firstSession] numbers the first session. A consumer that replaces
  /// one receiver with another (the link was re-established) passes a
  /// number above every one the old receiver used.
  ZReceiver({int firstSession = 1, this.onTrace}) : _session = firstSession;

  /// The most data one packet may carry. The firmware sends 1024 bytes;
  /// a packet that grows past this has no end in sight and is dropped.
  static const maxPacket = 16 * 1024;

  final void Function(String message)? onTrace;

  int _session;
  _Session _state = _Session.idle;
  final List<ZRxEvent> _events = [];
  final BytesBuilder _out = BytesBuilder();

  /// The number of the session under way, or of the next one when idle.
  int get session => _session;

  /// No session is under way.
  bool get isIdle => _state == _Session.idle;

  /// The next move is the consumer's: an offer or a finished file is
  /// waiting for its answer.
  bool get isAwaitingConsumer =>
      _state == _Session.offerVerdict || _state == _Session.eofVerdict;

  /// A finished file is waiting for [ackFileEnd] or [abort].
  bool get isAwaitingFileEndVerdict => _state == _Session.eofVerdict;

  /// Bytes seen between frames that were part of nothing, since the
  /// receiver was made. A sender that goes on sending a file this
  /// receiver is not taking shows up here.
  int ignoredBytes = 0;

  /// Header starts that did not hold: digits that were none, a check
  /// that did not match, a line end that was missing.
  int badHeaders = 0;

  // --------------------------------------------------------------- input

  /// Takes [data] from the sender and returns what happened.
  List<ZRxEvent> receive(List<int> data) {
    for (var i = 0; i < data.length; i++) {
      _byte(data[i]);
    }
    return takeEvents();
  }

  /// Takes bytes of [data] from [start] on until something happens or the
  /// data runs out, and returns the index of the first byte not taken.
  /// Collect what happened with [takeEvents].
  ///
  /// A live sender waits for the consumer's answer wherever the protocol
  /// asks for one, so [receive] can take a whole delivery at once. A
  /// recorded stream does not wait: replaying one, the consumer has to
  /// answer at the point the sender waited at, and this is how it stops
  /// there.
  int receiveUntilEvent(List<int> data, [int start = 0]) {
    var at = start;
    while (at < data.length && _events.isEmpty) {
      _byte(data[at++]);
    }
    return at;
  }

  /// Events not yet handed out, including those raised by the consumer's
  /// own calls ([abort], [giveUp]).
  List<ZRxEvent> takeEvents() {
    if (_events.isEmpty) return <ZRxEvent>[];
    final events = List<ZRxEvent>.of(_events);
    _events.clear();
    return events;
  }

  /// Bytes to write to the sender. Empty when there is nothing to say.
  Uint8List takeOutput() => _out.takeBytes();

  bool get hasOutput => _out.isNotEmpty;

  // ----------------------------------------------- the consumer's answers
  //
  // Each takes the number of the session it is about and returns whether
  // it was acted on. An answer for a session that is over, or one the
  // receiver is not waiting for, does nothing.

  /// Accepts the offered file from [offset] on.
  bool acceptFile(int session, int offset) {
    if (session != _session || _state != _Session.offerVerdict) return false;
    _send(ZModemHeader.rpos(offset));
    _state = _Session.awaitData;
    return true;
  }

  /// Declines the offered file: the receiver has it already. The sender
  /// treats a skipped file as delivered.
  bool skipFile(int session) {
    if (session != _session || _state != _Session.offerVerdict) return false;
    _send(ZModemHeader.skip());
    _state = _Session.skipped;
    return true;
  }

  /// Asks the sender to go on from [offset]. Data that is still on its
  /// way is skipped until the sender's ZDATA header arrives.
  bool reposition(int session, int offset) {
    if (session != _session ||
        (_state != _Session.receiving && _state != _Session.awaitData)) {
      return false;
    }
    _send(ZModemHeader.rpos(offset));
    _state = _Session.awaitData;
    _stopData();
    return true;
  }

  /// Acknowledges a data packet that asked for it (ZCRCQ, ZCRCW).
  bool ackFrame(int session, int offset) {
    if (session != _session || _state != _Session.receiving) return false;
    _send(ZModemHeader.ack(offset));
    return true;
  }

  /// Confirms the finished file: it is safely stored. The sender may now
  /// delete its copy. Our side of the session is closed with it.
  bool ackFileEnd(int session) {
    if (session != _session || _state != _Session.eofVerdict) return false;
    _send(ZModemHeader.rinit());
    _send(ZModemHeader.fin());
    _state = _Session.closing;
    return true;
  }

  /// Cancels the session. The sender keeps the file and offers it again.
  bool abort(int session) {
    if (session != _session || _state == _Session.idle) return false;
    _send(ZModemAbortSequence());
    _end(ZEndReason.abortedByReceiver);
    return true;
  }

  /// Forgets the session without telling the sender. For a sender that
  /// has gone quiet: anything sent to it now would be read as the answer
  /// to its next offer.
  bool giveUp(int session) {
    if (session != _session || _state == _Session.idle) return false;
    _end(ZEndReason.givenUp);
    return true;
  }

  // -------------------------------------------------------------- parser
  //
  // Two things are watched on the raw bytes, whatever is being read:
  //
  //  * a cancel: five CAN bytes in a row;
  //  * the start of a header: "**", the escape byte, 'B'.
  //
  // A header start is then followed through its fourteen hex digits, its
  // check and its line end before anything is concluded. If it holds, the
  // header is acted on, and whatever data packet it interrupted is
  // dropped: the sender left that packet unfinished to say this instead.
  // If it does not hold, the bytes go where they would have gone.

  _Parse _parse = _Parse.hunt;

  /// Raw CAN bytes in a row.
  int _cans = 0;

  // The watch for a header start.
  int _pads = 0;
  int _padsBeforeDle = 0;
  bool _padsThenDle = false;

  // A header being followed.
  bool _inHeader = false;
  bool _headerEnd = false;
  bool _sawCr = false;
  final Uint8List _hex = Uint8List(7);
  int _digits = 0;

  /// The raw bytes of the header being followed, from its 'B' on. If it
  /// turns out not to be a header they are read again as what they were.
  final List<int> _held = [];

  // A data packet.
  final BytesBuilder _packet = BytesBuilder();
  int _packetLength = 0;
  bool _packetTooLong = false;
  bool _dle = false;
  int _endType = 0;
  int _crcCount = 0;
  int _crcHigh = 0;
  bool _crcDle = false;

  void _byte(int b) {
    // CAN is also the escape byte (ZDLE), but two of them in a row are
    // never anything but the start of a cancel, so the count is kept on
    // the raw bytes, in every state alike.
    if (b == consts.CAN) {
      _cans++;
      if (_cans == 5) {
        _cancelled();
        return;
      }
      if (_cans > 5) return; // the tail of a cancel already acted on
    } else {
      _cans = 0;
    }
    _route(b);
  }

  void _route(int b) {
    if (_inHeader) {
      _headerByte(b);
      return;
    }
    if (_headerStarts(b)) {
      _inHeader = true;
      _headerEnd = false;
      _digits = 0;
      _held
        ..clear()
        ..add(b);
      return;
    }
    _take(b);
  }

  /// Whether [b] completes "**", the escape byte, 'B'.
  bool _headerStarts(int b) {
    if (_padsThenDle) {
      _padsThenDle = false;
      if (b == consts.ZHEX && _padsBeforeDle >= 2) return true;
      // Not a start. The byte is looked at afresh below.
    }
    if (b == consts.ZPAD) {
      _pads++;
    } else if (b == consts.ZDLE && _pads >= 2) {
      _padsBeforeDle = _pads;
      _pads = 0;
      _padsThenDle = true;
    } else {
      _pads = 0;
    }
    return false;
  }

  /// A byte that is part of no header: file data, or nothing.
  void _take(int b) {
    switch (_parse) {
      case _Parse.hunt:
        if (b != consts.XON &&
            b != consts.CR &&
            b != consts.LF &&
            b != consts.ZPAD &&
            b != consts.ZDLE) {
          ignoredBytes++;
        }
        break;
      case _Parse.data:
        _dataByte(b);
        break;
      case _Parse.dataCrc:
        _crcByte(b);
        break;
    }
  }

  void _headerByte(int b) {
    if (!_headerEnd) {
      final value = _hexValue(b);
      if (value < 0) {
        _notAHeader(b);
        return;
      }
      _held.add(b);
      final at = _digits >> 1;
      _hex[at] = _digits.isEven ? value << 4 : _hex[at] | value;
      _digits++;
      if (_digits < 14) return;

      final crc = CRC16();
      for (var i = 0; i < 5; i++) {
        crc.update(_hex[i]);
      }
      crc.finalize();
      if (crc.value != ((_hex[5] << 8) | _hex[6])) {
        _notAHeader(null);
        return;
      }
      _headerEnd = true;
      _sawCr = false;
      return;
    }

    if (!_sawCr && (b == consts.CR || b == 0x8d)) {
      _sawCr = true;
      _held.add(b);
      return;
    }
    if (b == consts.LF || b == 0x8a) {
      _inHeader = false;
      _held.clear();
      _pads = 0;
      _padsThenDle = false;
      // Whatever data packet this header interrupted is dropped.
      _stopData();
      _header(_hex[0], _hex[1], _hex[2], _hex[3], _hex[4]);
      return;
    }
    _notAHeader(b);
  }

  /// What was being followed is not a header. Its bytes are read again as
  /// what they were. [next] is the byte that showed it, when that byte
  /// was not itself part of what was followed.
  void _notAHeader(int? next) {
    badHeaders++;
    _inHeader = false;
    final held = List<int>.of(_held);
    _held.clear();
    for (final byte in held) {
      _take(byte);
    }
    if (next != null) _route(next);
  }

  void _cancelled() {
    onTrace?.call('<- cancel');
    _stopData();
    if (_state == _Session.skipped) {
      // How released firmware ends a file it was told to skip.
      _end(ZEndReason.skipped);
    } else if (_state != _Session.idle) {
      _end(ZEndReason.cancelledBySender);
    }
  }

  /// Stops reading a data packet; what was read of it is dropped.
  ///
  /// The watch for a header start, and a header that is being followed,
  /// are left alone, as is the CAN count. They are about the bytes that
  /// have arrived, not about what the session expects next, and the
  /// consumer may call in between two halves of a header.
  void _stopData() {
    _parse = _Parse.hunt;
    if (_packetLength > 0) _packet.clear();
    _packetLength = 0;
    _packetTooLong = false;
    _dle = false;
    _crcDle = false;
  }

  void _enterData() {
    _stopData();
    _parse = _Parse.data;
  }

  void _dataByte(int b) {
    if (_dle) {
      if (b == consts.CAN) return; // a run of CANs, counted above
      _dle = false;
      if (b == consts.ZCRCE ||
          b == consts.ZCRCG ||
          b == consts.ZCRCQ ||
          b == consts.ZCRCW) {
        _endType = b;
        _crcCount = 0;
        _crcDle = false;
        _parse = _Parse.dataCrc;
        return;
      }
      _append(_unescape(b));
      return;
    }
    if (b == consts.ZDLE) {
      _dle = true;
      return;
    }
    // Flow-control marks of the link are never file data: a sender
    // escapes those values when they occur in a file.
    if (b == consts.XON || b == consts.XOFF || b == 0x91 || b == 0x93) return;
    _append(b);
  }

  void _append(int value) {
    if (_packetLength >= maxPacket) {
      _packetTooLong = true;
      return;
    }
    _packet.addByte(value);
    _packetLength++;
  }

  void _crcByte(int b) {
    int value;
    if (_crcDle) {
      if (b == consts.CAN) return; // a run of CANs, counted above
      _crcDle = false;
      value = _unescape(b);
    } else if (b == consts.ZDLE) {
      _crcDle = true;
      return;
    } else {
      value = b;
    }
    if (_crcCount == 0) {
      _crcHigh = value;
      _crcCount = 1;
      return;
    }

    final received = (_crcHigh << 8) | value;
    final data = _packet.takeBytes();
    final tooLong = _packetTooLong;
    final endType = _endType;
    final crc = CRC16()
      ..updateAll(data)
      ..update(endType)
      ..finalize();

    // (The watch for a header start runs on across the end of a packet:
    // a sender that broke off right here may have begun its header in
    // what was read as the check bytes.)
    _stopData();
    _dataPacket(data, endType, received, !tooLong && crc.value == received);
  }

  static int _unescape(int b) {
    if (b == consts.ZRUB0) return 0x7f;
    if (b == consts.ZRUB1) return 0xff;
    return b ^ 0x40;
  }

  static int _hexValue(int char) {
    if (char >= 0x30 && char <= 0x39) return char - 0x30;
    if (char >= 0x61 && char <= 0x66) return char - 0x61 + 10;
    if (char >= 0x41 && char <= 0x46) return char - 0x41 + 10;
    return -1;
  }

  // ------------------------------------------------------------- session

  /// The type of the header before this one, for the one tolerance the
  /// older receiver had and senders may lean on: a header that does not
  /// fit, but repeats the type of the header before it, is passed over
  /// instead of being refused.
  int? _lastHeader;

  void _header(int type, int p0, int p1, int p2, int p3) {
    final repeated = _lastHeader == type;
    _lastHeader = type;
    final position = p0 | (p1 << 8) | (p2 << 16) | (p3 << 24);
    onTrace?.call('<- header $type at $position in ${_state.name}');

    if (type == consts.ZRQINIT) {
      if (_state == _Session.awaitOffer) {
        // The sender repeats itself; nothing has begun yet.
        _send(ZModemHeader.rinit());
        return;
      }
      if (_state == _Session.closing) {
        // The file was confirmed; only the sender's goodbye is missing.
        _end(ZEndReason.delivered);
      } else if (_state == _Session.skipped) {
        // The file was skipped; the sender has gone on to its next.
        _end(ZEndReason.skipped);
      } else if (_state != _Session.idle) {
        _end(ZEndReason.restartedBySender);
      }
      _send(ZModemHeader.rinit());
      _state = _Session.awaitOffer;
      _events.add(ZRxSessionStarted(_session));
      return;
    }

    switch (_state) {
      case _Session.idle:
        if (type == consts.ZFIN) {
          // A goodbye repeated after the session is over.
          _send(ZModemHeader.fin());
          return;
        }
        if (type == consts.ZRINIT || repeated) return;
        // Something from a session this receiver is not in: a file it
        // stopped taking, an offer with no ZRQINIT before it. The cancel
        // makes the sender keep the file and start over.
        _send(ZModemAbortSequence());
        return;
      case _Session.awaitOffer:
        if (type == consts.ZFILE) {
          _state = _Session.offerInfo;
          _enterData();
          return;
        }
        break;
      case _Session.offerInfo:
        if (type == consts.ZFILE) {
          _enterData();
          return;
        }
        break;
      case _Session.offerVerdict:
        if (type == consts.ZFILE) return; // the offer, said again
        break;
      case _Session.awaitData:
      case _Session.receiving:
        if (type == consts.ZDATA) {
          _state = _Session.receiving;
          _events.add(ZRxDataStart(_session, position));
          _enterData();
          return;
        }
        if (type == consts.ZEOF) {
          _state = _Session.eofVerdict;
          _events.add(ZRxFileEnd(_session, position));
          return;
        }
        break;
      case _Session.eofVerdict:
        if (type == consts.ZEOF) return; // said again while it waits
        break;
      case _Session.closing:
        if (type == consts.ZFIN) {
          _send(const ZModemOverAndOut());
          _end(ZEndReason.delivered);
        }
        return; // our side is closed: nothing else matters now
      case _Session.skipped:
        if (type == consts.ZFIN) {
          _send(ZModemHeader.fin());
          _end(ZEndReason.skipped);
          return;
        }
        // Anything else, the offer said again included: refused, so
        // that the sender starts over with a session of its own.
        _send(ZModemAbortSequence());
        _end(ZEndReason.refused);
        return;
    }

    if (type == consts.ZFIN) {
      // The sender says goodbye with nothing confirmed or skipped.
      _send(ZModemHeader.fin());
      _end(ZEndReason.closedBySender);
      return;
    }
    if (repeated) return;
    _send(ZModemAbortSequence());
    _end(ZEndReason.refused);
  }

  void _dataPacket(Uint8List data, int endType, int crc, bool crcOk) {
    switch (_state) {
      case _Session.offerInfo:
        final info = crcOk ? _fileInfo(data) : null;
        if (info == null) {
          // The offer could not be read. Not skipped: a skip tells the
          // sender the file is delivered.
          _send(ZModemAbortSequence());
          _end(ZEndReason.refused);
          return;
        }
        _state = _Session.offerVerdict;
        _events.add(ZRxOffer(_session, info));
        return;
      case _Session.receiving:
        _events.add(ZRxData(_session, data, endType, crc, crcOk));
        if (endType == consts.ZCRCG || endType == consts.ZCRCQ) {
          _enterData(); // more follows without a header
        }
        return;
      default:
        return; // a packet nobody is waiting for
    }
  }

  static ZModemFileInfo? _fileInfo(Uint8List data) {
    try {
      final pathname = readCString(data, 0);
      if (pathname.isEmpty) return null;
      final rest = pathname.length + 1;
      final properties = rest < data.length
          ? readCString(data, rest).split(' ')
          : const <String>[];
      int? number(int at) =>
          properties.length > at ? int.tryParse(properties[at]) : null;
      return ZModemFileInfo(
        pathname: pathname,
        length: number(0),
        modificationTime: number(1),
        mode: properties.length > 2 ? properties[2] : null,
        filesRemaining: number(4),
        bytesRemaining: number(5),
      );
    } catch (_) {
      return null;
    }
  }

  void _send(ZModemPacket packet) {
    onTrace?.call('-> $packet');
    _out.add(packet.encode());
  }

  void _end(ZEndReason reason) {
    onTrace?.call('session $_session ended: ${reason.name}');
    _events.add(ZRxSessionEnded(_session, reason));
    _session++;
    _state = _Session.idle;
    _lastHeader = null;
    _stopData();
  }
}
