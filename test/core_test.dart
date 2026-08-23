import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zmodem/zmodem.dart';

void main() {
  group('ZModemCore', () {
    test('can act as both client and server', () {
      final server = ZModemCore();
      final client = ZModemCore();

      server.initiateSend();
      client.receive(server.dataToSend()).drain();
      expect(server.receive(client.dataToSend()), [isA<ZReadyToSendEvent>()]);

      server.offerFile(ZModemFileInfo(pathname: 'foo', length: 123));
      final events = client.receive(server.dataToSend()).toList();
      // The fork emits a ZFileEvent alongside the offer.
      expect(events, [isA<ZFileEvent>(), isA<ZFileOfferedEvent>()]);

      final fileInfo = events.whereType<ZFileOfferedEvent>().single.fileInfo;
      expect(fileInfo.pathname, 'foo');
      expect(fileInfo.length, 123);

      client.acceptFile();
      expect(server.receive(client.dataToSend()), [isA<ZFileAcceptedEvent>()]);

      server.sendFileData(Uint8List.fromList([1, 2, 3]));
      // The fork announces the ZDATA frame itself before its payload.
      expect(client.receive(server.dataToSend()),
          [isA<ZDataEvent>(), isA<ZFileDataEvent>()]);

      server.finishSending(3);
      final endEvents = client.receive(server.dataToSend()).toList();
      expect(endEvents, [
        isA<ZFileDataEvent>(), // ZCRCE
        isA<ZFileEndEvent>(), // ZEOF
      ]);
      // The receiver no longer auto-replies ZRINIT on ZEOF: the consumer
      // must acknowledge once it has durably stored the bytes. The ZEOF
      // position is the full file length.
      expect(endEvents.whereType<ZFileEndEvent>().single.position, 3);
      client.ackFileEnd();

      expect(server.receive(client.dataToSend()), [isA<ZReadyToSendEvent>()]);

      server.finishSession();
      // expect(
      //   client.receive(server.dataToSend()),
      //   [isA<ZSessionFinishedEvent>()],
      // );
    });
  });
}

extension on Iterable {
  void drain() {
    for (final _ in this) {}
  }
}
