import 'package:zmodem/src/util/debug.dart';
import 'package:zmodem/src/zmodem_fileinfo.dart';
import 'package:zmodem/src/zmodem_frame.dart';

abstract class ZModemEvent {}

/// The other side has offered a file for transfer.
class ZFileOfferedEvent implements ZModemEvent {
  final ZModemFileInfo fileInfo;

  ZFileOfferedEvent(this.fileInfo);

  @override
  String toString() {
    return DebugStringBuilder('ZFileOfferedEvent')
        .withField('fileInfo', fileInfo)
        .toString();
  }
}

/// A chunk of data of the file currently being received.
class ZFileDataEvent implements ZModemEvent {
  final List<int> data;
  final ZModemDataPacket packet;

  ZFileDataEvent(this.data, this.packet);

  @override
  String toString() {
    return DebugStringBuilder('ZFileDataEvent')
        .withField('data', data.length)
        .toString();
  }
}

/// The file we're currently receiving has been completely transferred.
class ZFileEndEvent implements ZModemEvent {
  @override
  String toString() {
    return 'ZFileEndEvent()';
  }
}
class ZFileEvent implements ZModemEvent {
  final int p0;
  final int p1;
  final int p2;
  final int p3;
  ZFileEvent(this.p0, this.p1, this.p2, this.p3);
  @override
  String toString() {
    return 'ZFileEvent()';
  }
}

class ZDataEvent implements ZModemEvent {
  // final int p0;
  // final int p1;
  // final int p2;
  // final int p3;
  int _offset = 0;
  int get offset => _offset;
  ZDataEvent(int p0, int p1, int p2, int p3) {
    _offset = (p0 << 24) | (p1 << 16) | (p2 << 8) |  (p3 << 0);
  }
  @override
  String toString() {
    return 'ZDataEvent($_offset)';
  }
}



/// The event fired when the ZModem session is fully closed.
class ZSessionFinishedEvent implements ZModemEvent {
  @override
  String toString() {
    return 'ZSessionFinishedEvent()';
  }
}

/// The other side is ready to receive a file.
class ZReadyToSendEvent implements ZModemEvent {
  @override
  String toString() {
    return 'ZReadyToSendEvent()';
  }
}

/// The other side has accepted a file we just offered.
class ZFileAcceptedEvent implements ZModemEvent {
  const ZFileAcceptedEvent(this.offset);

  final int offset;

  @override
  String toString() {
    return 'ZFileAcceptedEvent(offset: $offset)';
  }
}

/// The other side has rejected a file we just offered.
class ZFileSkippedEvent implements ZModemEvent {
  @override
  String toString() {
    return 'ZFileSkippedEvent()';
  }
}
