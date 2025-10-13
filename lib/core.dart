import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:zmodem/src/util/string.dart';
import 'package:zmodem/src/zmodem_event.dart';
import 'package:zmodem/src/zmodem_fileinfo.dart';
import 'package:zmodem/src/zmodem_parser.dart';
import 'package:zmodem/src/zmodem_frame.dart';
import 'package:zmodem/src/consts.dart' as consts;

typedef ZModemTraceHandler = void Function(String message);

typedef ZModemTextHandler = void Function(int char);

typedef ZModemExceptionHandler = void Function<T extends ZModemState>(ZModemState state);

/// Contains the state of a ZModem session.
class ZModemCore {
  ZModemCore({this.onTrace, this.onException, this.onPlainText});

  late final _parser = ZModemParser()..onPlainText = onPlainText;

  final _sendQueue = Queue<ZModemPacket>();

  // ignore: unused_field
  Uint8List? _attnSequence;

  late ZModemState _state = _ZInitState(this);

  bool get isFinished => _state is _ZFinState;
  bool get isIdle => _state is _ZInitState;

  final maxDataSubpacketSize = 8192;

  final ZModemTraceHandler? onTrace;

  final ZModemTextHandler? onPlainText;

  final ZModemExceptionHandler? onException;

  /// Attempts to resynchronize the parser after a parsing error.
  /// Returns true if a potential frame start was found.
  bool attemptResync() {
    return _parser.attemptResync();
  }

  requireState<T extends ZModemState>() {
    if (_state is! T) {
      // throw ZModemException(
      //   'Invalid state: ${_state.runtimeType}, expected: $T',
      // );
      onException?.call<T>(_state);
    }
     
   }// onException?.call(T, _state);

  Iterable<ZModemEvent> receive(Uint8List data) sync* {
    _parser.addData(data);
    while (_parser.moveNext()) {
      final packet = _parser.current;
      onTrace?.call('<- $packet');

      if (packet is ZModemHeader) {
        final event = _state.handleHeader(packet);
        ZModemState.lastHeader = packet;
        if (event != null) {
          // Logger.d ('Yield header');
          yield event;
        }
      } else if (packet is ZModemDataPacket) {
        final event = _state.handleDataSubpacket(packet);
        ZModemState.lastSubPacket = packet;
        if (event != null) {
          yield event;
        }
      } else if (packet is ZModemAbortSequence) {
         yield ZSessionCancelEvent();
      }
    }
  }

  void _enqueue(ZModemPacket packet) {
    _sendQueue.add(packet);
  }

  void _expectDataSubpacket() {
    _parser.expectDataSubpacket();
  }

  void _requireState<T extends ZModemState>() {
    if (_state is! T) {
      throw ZModemException(
        'Invalid state: ${_state.runtimeType}, expected: $T',
      );
      //onException?.call<T>(_state);
    }
  }

  bool _checkState<T extends ZModemState>() {
    if (_state is! T) {
      return false;
      //onException?.call<T>(_state);
    }
    return true;
  }


  bool get hasDataToSend => _sendQueue.isNotEmpty;

  Uint8List dataToSend() {
    final builder = BytesBuilder();

    while (_sendQueue.isNotEmpty) {
      onTrace?.call('-> ${_sendQueue.first}');
      builder.add(_sendQueue.removeFirst().encode());
    }

    return builder.toBytes();
  }

  void initiateSend() {
    //_requireState<_ZInitState>();
    if(!_checkState<_ZInitState>()) {
      return;
    }
    _enqueue(ZModemHeader.rqinit());
    _state = _ZRqinitState(this);
  }

  void initiateReceive() {
    //_requireState<_ZInitState>();
    if(!_checkState<_ZInitState>()) {
      return;
    }
    _enqueue(ZModemHeader.rinit());
    _state = _ZRinitState(this);
  }

  void acceptFile([int offset = 0]) {
    //_requireState<_ZReceivedFileProposalState>();
    if(!_checkState<_ZReceivedFileProposalState>()) {
      return;
    }
    _enqueue(ZModemHeader.rpos(offset));
    _state = _ZWaitingContentState(this);
  }

   void positionFile([int offset = 0]) {
     _enqueue(ZModemHeader.rpos(offset));
     _state = _ZWaitingContentState(this);
    
  }

  void ackFrame(int offset) {
    _enqueue(ZModemHeader.ack(offset));
  }

  void abortSession() {
    _enqueue(ZModemAbortSequence());
    _state = _ZInitState(this);
  }

  void resetSession() {
    _state = _ZInitState(this);
  }


  void skipFile() {
    //_requireState<_ZReceivedFileProposalState>();
    if(!_checkState<_ZReceivedFileProposalState>()) {
      return;
    }
    _enqueue(ZModemHeader.skip());
    _state = _ZRinitState(this);
  }

  void offerFile(ZModemFileInfo fileInfo) {
    //_requireState<_ZReadyToSendState>();
    if(!_checkState<_ZReadyToSendState>()) {
      return;
    }
    _enqueue(ZModemHeader.file());
    _enqueue(ZModemDataPacket.fileInfo(fileInfo));
    _state = ZSentFileProposalState(this);
  }

  void sendFileData(Uint8List data) {
    //_requireState<_ZSendingContentState>();
    if(!_checkState<_ZSendingContentState>()) {
      return;
    }

    for (var i = 0; i < data.length; i += maxDataSubpacketSize) {
      final end = min(i + maxDataSubpacketSize, data.length);
      _enqueue(ZModemDataPacket.fileData(Uint8List.sublistView(data, i, end)));
    }
  }

  void finishSending(int offset) {
    //_requireState<_ZSendingContentState>();
    if(!_checkState<_ZSendingContentState>()) {
      return;
    }
    _enqueue(ZModemDataPacket.fileData(Uint8List(0), eof: true));
    _enqueue(ZModemHeader.eof(offset));
    _state = _ZRqinitState(this);
  }

  void finishSession() {
    if (_state is _ZClosedState || _state is _ZFinState) {
      return;
    }

    _enqueue(ZModemHeader.fin());
    _state = _ZClosedState(this);
  }
}

class ZModemException implements Exception {
  ZModemException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class ZModemState {
  ZModemState(this.core);

  final ZModemCore core;
  static ZModemDataPacket? lastSubPacket;
  static ZModemHeader? lastHeader;



  ZModemEvent? handleHeader(ZModemHeader header) {
    
    switch (header.type) {
      case consts.ZRQINIT:
        core._enqueue(ZModemHeader.rinit());
        core._state = _ZRinitState(core);
        return ZSessionRestartEvent();
      case consts.ZFIN:
        core._enqueue(ZModemHeader.fin());
        core._state = _ZFinState(core);
        return ZSessionFinishedEvent();
      
      default:
        if( lastHeader != null && 
          header.type == lastHeader?.type) 
        {
          // Ignore duplicates.
          //print("Ignore duplicate");
          return null;
        }
       
        // If we get any other unexpected message in any state, 
        // send cancel to the sender. 
        core._enqueue(ZModemAbortSequence());
        core._state = _ZInitState(core);
        return ZSessionCancelEvent();
        //throw ZModemException('Unexpected header: $header (state: $this)');
    }
    
  }

  ZModemEvent? handleDataSubpacket(ZModemDataPacket packet) {
    //throw ZModemException('Unexpected data subpacket: $packet (state: $this)');

    if( lastSubPacket != null && 
        packet.type == lastSubPacket?.type &&
        packet.crc0 == lastSubPacket?.crc0 &&
        packet.crc1 == lastSubPacket?.crc1) 
    {
      // ignore duplicates.
      return null;
    }

    core._enqueue(ZModemAbortSequence());
    core._state = _ZInitState(core);
    return ZSessionCancelEvent();
    
  }
}

/// A state where no messages have been sent or received yet. Waiting for
/// our or the other side to initiate the session.
class _ZInitState extends ZModemState {
  _ZInitState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZRINIT:
        core._state = _ZReadyToSendState(core);
        return ZReadyToSendEvent();
      case consts.ZRQINIT:
        core._enqueue(ZModemHeader.rinit());
        core._state = _ZRinitState(core);
        return null;
      default:
        return super.handleHeader(header);
    }
  }
}

/// A state where we have requested a file transfer and waiting a file proposal.
class _ZRinitState extends ZModemState {
  _ZRinitState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZSINIT:
        core._enqueue(ZModemHeader.ack());
        core._state = _ZSinitState(core);
        core._expectDataSubpacket();
        break;
      case consts.ZFILE:
        core._state = _ZReceivedFileProposalState(core);
        core._expectDataSubpacket();
        return ZFileEvent(header.p0, header.p1, header.p2, header.p3);
        //break;
      case consts.ZFIN:
        core._enqueue(ZModemHeader.fin());
        core._state = _ZFinState(core);
        return ZSessionFinishedEvent();
      
      default:
        return super.handleHeader(header);
    }
    return null;
  }
}

/// A state where the other side is going to send us the attn sequence.
class _ZSinitState extends ZModemState {
  _ZSinitState(super.core);

  @override
  ZModemEvent? handleDataSubpacket(ZModemDataPacket packet) {
    if (packet.data.length <= 1) {
      core._attnSequence = null;
    } else {
      core._attnSequence = packet.data.sublist(1);
    }
    core._state = _ZRinitState(core);
    return null;
  }
}

/// A state where we've got a file proposal, but haven't decided whether to
/// accept it or not.
class _ZReceivedFileProposalState extends ZModemState {
  _ZReceivedFileProposalState(super.core);

  @override
  ZModemEvent? handleDataSubpacket(ZModemDataPacket packet) {
    final pathname = readCString(packet.data, 0);
    final propertyString = readCString(packet.data, pathname.length + 1);
    final properties = propertyString.split(' ');

    final fileInfo = ZModemFileInfo(
      pathname: pathname,
      length: properties.isNotEmpty ? int.parse(properties[0]) : null,
      modificationTime: properties.length > 1 ? int.parse(properties[1]) : null,
      mode: properties.length > 2 ? properties[2] : null,
      filesRemaining: properties.length > 4 ? int.parse(properties[4]) : null,
      bytesRemaining: properties.length > 5 ? int.parse(properties[5]) : null,
    );

    return ZFileOfferedEvent(fileInfo);
  }
}

/// A state where we've accepted a file proposal, but haven't received the ZDATA
/// header yet.
class _ZWaitingContentState extends ZModemState {
  _ZWaitingContentState(super.core);

  @override
  ZModemEvent? handleDataSubpacket(ZModemDataPacket packet) {
    return null;
  }

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZDATA:
        core._state = _ZReceivingContentState(core);
        core._expectDataSubpacket();
        return ZDataEvent(header.p3, header.p2, header.p1, header.p0);
      case consts.ZEOF:
        // Handle ZEOF here in the case of a 0 byte file size.
        core._enqueue(ZModemHeader.rinit());
        core._state = _ZRinitState(core);
        return ZFileEndEvent();
      default:
        return super.handleHeader(header);
    }
  }
}

/// A state where we've received the ZDATA header, and are receiving the file
/// contents.
class _ZReceivingContentState extends ZModemState {
  _ZReceivingContentState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZEOF:

        core._enqueue(ZModemHeader.rinit());
        core._state = _ZRinitState(core);
        return ZFileEndEvent();
      
      default:
        return super.handleHeader(header);
    }
  }

  @override
  ZModemEvent? handleDataSubpacket(ZModemDataPacket packet) {
    // If we got a ZCRCG or ZCRCQ here, expect another pone. This is because 
    // we do not always get a ZDATA header with each frame, so need to expect 
    // another subpacket.
    if (packet.type == consts.ZCRCG || 
        packet.type == consts.ZCRCQ) {
      //print('Expecting subpacket ${packet.type}');
      core._expectDataSubpacket();
    }
    
    return ZFileDataEvent(packet.data, packet);
  }
}

/// A state where we've requested the other side to receive a file from us, but
/// haven't been notified that it's ready yet.
class _ZRqinitState extends ZModemState {
  _ZRqinitState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZRINIT:
        core._state = _ZReadyToSendState(core);
        return ZReadyToSendEvent();
      default:
        return super.handleHeader(header);
    }
  }
}

/// A state where the other side has notified us that it's ready to receive a
/// file from us.
class _ZReadyToSendState extends ZModemState {
  _ZReadyToSendState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZRINIT:
        // Ignore delayed ZRINIT retry.
        return null;
      default:
        return super.handleHeader(header);
    }
  }
}

/// A state where we've sent a file proposal, but haven't received a response
/// from the other side yet.
class ZSentFileProposalState extends ZModemState {
  ZSentFileProposalState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZRINIT:
        // Ignore delayed ZRINIT retry.
        return null;
      case consts.ZRPOS:
        core._enqueue(ZModemHeader.data(0)); // TODO: parse p0 ~ p3
        core._state = _ZSendingContentState(core);
        return ZFileAcceptedEvent(header.p0); // TODO: parse p0 ~ p3
      case consts.ZSKIP:
        core._state = _ZReadyToSendState(core);
        return ZFileSkippedEvent();
      default:
        return super.handleHeader(header);
    }
  }
}

/// A state where we've sent the ZDATA header, and are sending chunks of file
/// contents.
class _ZSendingContentState extends ZModemState {
  _ZSendingContentState(super.core);
}

/// A state where we as the sender have sent the ZFIN header, and are waiting
/// for the other side to acknowledge it.
class _ZClosedState extends ZModemState {
  _ZClosedState(super.core);

  @override
  ZModemEvent? handleHeader(ZModemHeader header) {
    switch (header.type) {
      case consts.ZFIN:
        core._enqueue(ZModemOverAndOut());
        core._state = _ZFinState(core);
        return ZSessionFinishedEvent();
    }
    return null;
  }
}

/// A state where the session is fully closed.
class _ZFinState extends ZModemState {
  _ZFinState(super.core);
}
