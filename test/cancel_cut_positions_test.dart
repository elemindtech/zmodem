/// The sender can be cut at ANY byte of a data frame: the cancel then starts
/// in the middle of an escape pair, in the middle of the payload, right
/// after a subpacket's end marker (where its two CRC bytes belong), between
/// the two CRC bytes, or after them. Five consecutive CANs are a cancel in
/// every one of those places, reported once, with nothing left over for the
/// next session.
///
/// Also here: the "tail of a reported cancel" state ends at the first byte
/// that is not a CAN, so a later, separate cancel is never swallowed.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zmodem/zmodem.dart';
import 'package:zmodem/src/consts.dart' as consts;
import 'package:zmodem/src/zmodem_frame.dart'
    show ZModemAbortSequence, ZModemDataPacket, ZModemHeader, ZModemPacket;
import 'package:zmodem/src/zmodem_parser.dart';

void _resetStatics() {
  ZModemState.lastHeader = null;
  ZModemState.lastSubPacket = null;
}

Uint8List _cans(int n) => Uint8List.fromList(List.filled(n, consts.CAN));

List<ZModemEvent> _feed(ZModemCore core, List<int> bytes, int size) {
  final data = Uint8List.fromList(bytes);
  final events = <ZModemEvent>[];
  for (var at = 0; at < data.length; at += size) {
    final end = (at + size) > data.length ? data.length : at + size;
    events.addAll(core.receive(Uint8List.sublistView(data, at, end)));
  }
  return events;
}

/// A receiver in the middle of a file, armed for the next subpacket.
ZModemCore _receiverMidFile() {
  final server = ZModemCore();
  final client = ZModemCore();
  server.initiateSend();
  client.receive(server.dataToSend()).toList();
  server.receive(client.dataToSend()).toList();
  server.offerFile(ZModemFileInfo(pathname: 'd.bin', length: 100000));
  client.receive(server.dataToSend()).toList();
  client.acceptFile(0);
  server.receive(client.dataToSend()).toList();
  server.sendFileData(Uint8List(1024));
  client.receive(server.dataToSend()).toList();
  expect(client.isIdle, isFalse);
  client.dataToSend();
  return client;
}

/// A complete new offer; [prefix] is sent first (what a sender prints before
/// it opens a session).
List<ZModemEvent> _nextOffer(ZModemCore client, {List<int> prefix = const []}) {
  final server = ZModemCore();
  final events = <ZModemEvent>[];
  server.initiateSend();
  events.addAll(_feed(client, [...prefix, ...server.dataToSend()], 64));
  final rinit = client.dataToSend();
  expect(rinit, isNotEmpty, reason: 'the receiver must answer ZRQINIT');
  server.receive(rinit).toList();
  server.offerFile(ZModemFileInfo(pathname: 'next.bin', length: 4096));
  events.addAll(_feed(client, server.dataToSend(), 64));
  return events;
}

/// One ZCRCG subpacket whose payload needs every kind of escape and has
/// ZPADs in it.
Uint8List _awkwardSubpacket() {
  const kinds = [0x18, 0x2a, 0x11, 0x41, 0x13, 0x2a, 0x10, 0x90];
  final payload = Uint8List.fromList(
    List<int>.generate(48, (i) => kinds[i % kinds.length]),
  );
  return ZModemDataPacket.fileData(payload).encode();
}

List<ZModemPacket> _packets(ZModemParser parser, List<int> bytes) {
  parser.addData(Uint8List.fromList(bytes));
  final out = <ZModemPacket>[];
  while (parser.moveNext()) {
    out.add(parser.current);
  }
  return out;
}

void main() {
  setUp(_resetStatics);

  group('a cancel that starts at any byte of a subpacket', () {
    final subpacket = _awkwardSubpacket();

    // 5: the least that is a cancel. 8: firmware up to 2.6.1 and from 2.6.4.
    // 10: firmware 2.6.2 / 2.6.3.
    for (final n in [5, 8, 10]) {
      for (final size in [64, 1]) {
        test('$n CANs, deliveries of $size, every cut position', () {
          for (var cut = 0; cut <= subpacket.length; cut++) {
            _resetStatics();
            final client = _receiverMidFile();
            final why = 'cut after byte $cut of ${subpacket.length}';
            final before = client
                .receive(Uint8List.sublistView(subpacket, 0, cut))
                .toList();
            expect(before.whereType<ZSessionCancelEvent>(), isEmpty,
                reason: why);
            final events = _feed(client, _cans(n), size);
            expect(events.whereType<ZSessionCancelEvent>(), hasLength(1),
                reason: why);
            expect(client.isIdle, isTrue, reason: why);
            final offer = _nextOffer(client);
            expect(offer.whereType<ZSessionCancelEvent>(), isEmpty,
                reason: 'the next offer was cancelled; $why');
            expect(offer.whereType<ZFileOfferedEvent>(), hasLength(1),
                reason: 'the next offer was not offered; $why');
          }
        });
      }
    }

    test('right after the end marker, where the CRC bytes belong', () {
      // The first four CANs are read as the two CRC bytes; the fifth is the
      // first byte of what would be the next subpacket.
      final marker = subpacket.lastIndexOf(consts.ZCRCG);
      expect(subpacket[marker - 1], consts.ZDLE);
      for (final n in [5, 8]) {
        _resetStatics();
        final client = _receiverMidFile();
        client
            .receive(Uint8List.sublistView(subpacket, 0, marker + 1))
            .toList();
        final events = _feed(client, _cans(n), 64);
        expect(events.whereType<ZSessionCancelEvent>(), hasLength(1),
            reason: '$n CANs');
        expect(_nextOffer(client).whereType<ZFileOfferedEvent>(), hasLength(1),
            reason: '$n CANs');
      }
    });
  });

  group('what a sender prints before it starts over', () {
    test('"OO" and "rz" between the cancel and the offer', () {
      final client = _receiverMidFile();
      _feed(client, _cans(8), 64);
      final offer = _nextOffer(client, prefix: 'OOrz\r'.codeUnits);
      expect(offer.whereType<ZSessionCancelEvent>(), isEmpty);
      expect(offer.whereType<ZFileOfferedEvent>(), hasLength(1));
    });
  });

  group('the tail of a reported cancel ends at the first other byte', () {
    test('text, then a second run: a second cancel', () {
      final parser = ZModemParser();
      expect(_packets(parser, _cans(8)).whereType<ZModemAbortSequence>(),
          hasLength(1));
      expect(_packets(parser, 'rz\r'.codeUnits), isEmpty);
      expect(_packets(parser, _cans(8)).whereType<ZModemAbortSequence>(),
          hasLength(1));
    });

    test('a binary header, then a second run: a second cancel', () {
      final header = ZModemHeader.data(0).toBinary();
      expect(header.sublist(0, 3), [consts.ZPAD, consts.ZDLE, consts.ZBIN]);
      final parser = ZModemParser();
      expect(_packets(parser, _cans(8)).whereType<ZModemAbortSequence>(),
          hasLength(1));
      expect(_packets(parser, header).whereType<ZModemHeader>(), hasLength(1));
      expect(_packets(parser, _cans(8)).whereType<ZModemAbortSequence>(),
          hasLength(1));
    });

    test('a data subpacket, then a second run: a second cancel', () {
      final parser = ZModemParser();
      expect(_packets(parser, _cans(8)).whereType<ZModemAbortSequence>(),
          hasLength(1));
      parser.expectDataSubpacket();
      final frameEnd = [0x41, consts.ZDLE, consts.ZCRCE, 0x12, 0x34];
      expect(_packets(parser, frameEnd).whereType<ZModemDataPacket>(),
          hasLength(1));
      expect(_packets(parser, _cans(8)).whereType<ZModemAbortSequence>(),
          hasLength(1));
    });

    test('a run that continues is still one cancel, however it is delivered',
        () {
      final parser = ZModemParser();
      var aborts = 0;
      for (var i = 0; i < 40; i++) {
        aborts +=
            _packets(parser, _cans(1)).whereType<ZModemAbortSequence>().length;
      }
      expect(aborts, 1);
    });
  });
}
