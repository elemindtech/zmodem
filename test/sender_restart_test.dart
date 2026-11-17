/// A sender that gives a file up without its cancel reaching the receiver
/// starts over with ZRQINIT. The receiver is still inside a data subpacket,
/// where every byte is file data, so the header and everything after it
/// used to vanish into the unfinished subpacket: the sender's offers went
/// unanswered until it timed out (110 s on headband firmware 2.6.2 and
/// later), and only its timeout's cancel freed the receiver.
///
/// Headband firmware 2.6.2 and 2.6.3 do exactly this when a session start
/// cancels a transfer (the cancel cannot leave the device), and any firmware
/// does it after a reset in the middle of a file.
///
/// The parser now recognises a ZRQINIT hex header inside a data subpacket,
/// ends the old session and answers the new one. Nothing else inside a
/// subpacket is treated as a header.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zmodem/zmodem.dart';
import 'package:zmodem/src/consts.dart' as consts;
import 'package:zmodem/src/zmodem_frame.dart'
    show ZModemAbortSequence, ZModemDataPacket, ZModemPacket;
import 'package:zmodem/src/zmodem_parser.dart';

void _resetStatics() {
  ZModemState.lastHeader = null;
  ZModemState.lastSubPacket = null;
}

List<ZModemEvent> _feed(ZModemCore core, List<int> bytes, int size) {
  final data = Uint8List.fromList(bytes);
  final events = <ZModemEvent>[];
  for (var at = 0; at < data.length; at += size) {
    final end = (at + size) > data.length ? data.length : at + size;
    events.addAll(core.receive(Uint8List.sublistView(data, at, end)));
  }
  return events;
}

/// A receiver in the middle of a file (parser armed for the next subpacket).
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
  expect(client.dataToSend(), isEmpty);
  return client;
}

/// The bytes a fresh sender puts on the wire to open a session.
Uint8List _zrqinit() => (ZModemCore()..initiateSend()).dataToSend();

/// A hex header of any type with a correct CRC, as headband firmware sends.
Uint8List _hexHeader(int type,
    [int p0 = 0, int p1 = 0, int p2 = 0, int p3 = 0]) {
  final raw = [type, p0, p1, p2, p3];
  var crc = 0;
  for (final b in raw) {
    crc ^= b << 8;
    for (var i = 0; i < 8; i++) {
      crc = ((crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1) & 0xFFFF;
    }
  }
  final body = [...raw, crc >> 8, crc & 0xFF];
  final hex =
      body.map((b) => b.toRadixString(16).padLeft(2, '0')).join().codeUnits;
  return Uint8List.fromList([
    consts.ZPAD,
    consts.ZPAD,
    consts.ZDLE,
    consts.ZHEX,
    ...hex,
    0x0d,
    0x0a,
    consts.XON,
  ]);
}

/// Completes the offer that [zrqinit] opened and returns the events.
List<ZModemEvent> _offerAfter(ZModemCore client, {int size = 64}) {
  final server = ZModemCore()..initiateSend();
  server.dataToSend(); // its ZRQINIT has already been delivered by the test
  final rinit = client.dataToSend();
  expect(rinit, isNotEmpty, reason: 'the receiver must answer the ZRQINIT');
  expect(rinit.where((b) => b == consts.CAN).length, lessThan(5),
      reason: 'the answer is a ZRINIT, not a cancel');
  server.receive(rinit).toList();
  server.offerFile(ZModemFileInfo(pathname: 'next.bin', length: 4096));
  return _feed(client, server.dataToSend(), size);
}

/// Parses [bytes] as the body of one data subpacket, in deliveries of [size].
List<ZModemPacket> _parseAsSubpacket(List<int> bytes, int size) {
  final parser = ZModemParser()..expectDataSubpacket();
  final out = <ZModemPacket>[];
  final data = Uint8List.fromList(bytes);
  for (var at = 0; at < data.length; at += size) {
    final end = (at + size) > data.length ? data.length : at + size;
    parser.addData(Uint8List.sublistView(data, at, end));
    while (parser.moveNext()) {
      out.add(parser.current);
    }
  }
  return out;
}

void main() {
  setUp(_resetStatics);

  group('a ZRQINIT where file data was expected', () {
    test('ends the old session and is answered', () {
      final client = _receiverMidFile();
      final events = _feed(client, _zrqinit(), 64);
      expect(events.whereType<ZSessionCancelEvent>(), hasLength(1),
          reason: 'the file being received is over');
      expect(events.whereType<ZSessionRestartEvent>(), isEmpty,
          reason: 'the core is parked first, then reads the ZRQINIT');
      expect(client.isIdle, isFalse, reason: 'the new session is under way');
      final offer = _offerAfter(client);
      expect(offer.whereType<ZSessionCancelEvent>(), isEmpty);
      expect(offer.whereType<ZFileOfferedEvent>(), hasLength(1));
    });

    test('one byte per delivery', () {
      final client = _receiverMidFile();
      final events = _feed(client, _zrqinit(), 1);
      expect(events.whereType<ZSessionCancelEvent>(), hasLength(1));
      final offer = _offerAfter(client, size: 1);
      expect(offer.whereType<ZFileOfferedEvent>(), hasLength(1));
    });

    test('split at every offset', () {
      final header = _zrqinit();
      for (var cut = 1; cut < header.length; cut++) {
        _resetStatics();
        final client = _receiverMidFile();
        final events = [
          ...client.receive(Uint8List.sublistView(header, 0, cut)),
          ...client.receive(Uint8List.sublistView(header, cut)),
        ];
        expect(events.whereType<ZSessionCancelEvent>(), hasLength(1),
            reason: 'cut after byte $cut');
        final offer = _offerAfter(client);
        expect(offer.whereType<ZFileOfferedEvent>(), hasLength(1),
            reason: 'cut after byte $cut');
      }
    });

    test('behind part of a subpacket that was never finished', () {
      // The sender was cut in the middle of a subpacket: 300 bytes of data
      // with no terminator, then nothing, then its new ZRQINIT.
      final client = _receiverMidFile();
      final partial = List<int>.generate(300, (i) => 0x30 + (i % 10));
      expect(_feed(client, partial, 64), isEmpty);
      final events = _feed(client, _zrqinit(), 64);
      expect(events.whereType<ZSessionCancelEvent>(), hasLength(1));
      expect(events.whereType<ZFileDataEvent>(), isEmpty,
          reason: 'the unfinished subpacket is dropped, not delivered');
      final offer = _offerAfter(client);
      expect(offer.whereType<ZFileOfferedEvent>(), hasLength(1));
    });

    test('behind file data that itself ends in ZPADs', () {
      final client = _receiverMidFile();
      _feed(client, [0x41, consts.ZPAD, consts.ZPAD, consts.ZPAD], 64);
      final events = _feed(client, _zrqinit(), 64);
      expect(events.whereType<ZSessionCancelEvent>(), hasLength(1));
      expect(_offerAfter(client).whereType<ZFileOfferedEvent>(), hasLength(1));
    });

    test('the receiver sends a ZRINIT and no cancel', () {
      final client = _receiverMidFile();
      _feed(client, _zrqinit(), 64);
      final out = client.dataToSend();
      expect(out, isNotEmpty);
      expect(out.where((b) => b == consts.CAN).length, lessThan(5));
    });

    test('the offer re-sent while the first answer is in flight', () {
      // Firmware 2.6.2 / 2.6.3 re-sends ZRQINIT every 10 s until answered.
      final client = _receiverMidFile();
      final first = _feed(client, _zrqinit(), 64);
      expect(first.whereType<ZSessionCancelEvent>(), hasLength(1));
      final second = _feed(client, _zrqinit(), 64);
      expect(second.whereType<ZSessionCancelEvent>(), isEmpty,
          reason: 'a repeat of the offer is not another cancel');
    });
  });

  group('file data is still file data', () {
    test('ZPAD ZPAD followed by an escaped byte', () {
      // 0x18 travels as ZDLE 0x58, 0x11 as ZDLE 0x51: the ZDLE after the
      // two ZPADs is an escape, not the start of a header.
      for (final b in [0x18, 0x10, 0x11, 0x13, 0x90, 0x91, 0x93]) {
        _resetStatics();
        final client = _receiverMidFile();
        final payload = [1, consts.ZPAD, consts.ZPAD, b, 2];
        final packet =
            ZModemDataPacket.fileData(Uint8List.fromList(payload)).encode();
        final events = _feed(client, packet, 64);
        expect(events.whereType<ZSessionCancelEvent>(), isEmpty,
            reason: 'byte 0x${b.toRadixString(16)}');
        expect(events.whereType<ZFileDataEvent>().single.data, payload,
            reason: 'byte 0x${b.toRadixString(16)}');
      }
    });

    test('ZPAD ZPAD ZDLE ZHEX followed by something that is not hex', () {
      // A sender that escapes every control character sends 0x02 as
      // ZDLE 0x42 (ZHEX). The digits decide; 'Z' is not one.
      final body = [
        consts.ZPAD, consts.ZPAD, consts.ZDLE, consts.ZHEX, 0x5a, 0x31, //
        consts.ZDLE, consts.ZCRCG, 0, 0,
      ];
      for (final size in [64, 1]) {
        final packets = _parseAsSubpacket(body, size);
        expect(packets.whereType<ZModemAbortSequence>(), isEmpty);
        final data = packets.whereType<ZModemDataPacket>().single;
        expect(data.data, [consts.ZPAD, consts.ZPAD, 0x02, 0x5a, 0x31]);
      }
    });

    test('fourteen hex digits that are not a ZRQINIT', () {
      // Same look, different header type (ZFIN): not a session start.
      final fin = _hexHeader(consts.ZFIN);
      final body = [...fin.sublist(0, 18), consts.ZDLE, consts.ZCRCG, 0, 0];
      final packets = _parseAsSubpacket(body, 64);
      expect(packets.whereType<ZModemAbortSequence>(), isEmpty);
      expect(packets.whereType<ZModemDataPacket>(), hasLength(1));
    });

    test('a ZRQINIT look-alike whose CRC is wrong', () {
      final bad = _zrqinit().sublist(0, 18);
      bad[17] = 0x31; // last CRC digit: '0' -> '1'
      final body = [...bad, consts.ZDLE, consts.ZCRCG, 0, 0];
      final packets = _parseAsSubpacket(body, 64);
      expect(packets.whereType<ZModemAbortSequence>(), isEmpty);
      expect(packets.whereType<ZModemDataPacket>(), hasLength(1));
    });

    test(
        'a ZRQINIT cut off before its line end is data, and the parser '
        'lives', () {
      // Eighteen bytes of a ZRQINIT, then something that is not a line
      // end. The header parser would throw on that, which ends the parser
      // for good; the check must not hand it over. The whole ZRQINIT that
      // follows is then recognised.
      final client = _receiverMidFile();
      final truncated = [..._zrqinit().sublist(0, 18), 0x41, 0x42];
      expect(_feed(client, truncated, 64), isEmpty);
      final events = _feed(client, _zrqinit(), 64);
      expect(events.whereType<ZSessionCancelEvent>(), hasLength(1));
      expect(_offerAfter(client).whereType<ZFileOfferedEvent>(), hasLength(1));
    });

    test('a delivery that ends on two ZPADs does not hold the data up', () {
      // The check needs the next byte; when it is ordinary data the
      // subpacket carries on and is delivered whole.
      final client = _receiverMidFile();
      final payload = [1, 2, consts.ZPAD, consts.ZPAD, 3, 4];
      final packet =
          ZModemDataPacket.fileData(Uint8List.fromList(payload)).encode();
      final cut = packet.lastIndexOf(consts.ZPAD) + 1;
      expect(client.receive(Uint8List.sublistView(packet, 0, cut)).toList(),
          isEmpty);
      final events =
          client.receive(Uint8List.sublistView(packet, cut)).toList();
      expect(events.whereType<ZFileDataEvent>().single.data, payload);
    });
  });
}
