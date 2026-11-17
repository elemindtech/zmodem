/// The sender can also be cut in the middle of a HEADER. The headband sends
/// every header as a hex header (ZPAD ZPAD ZDLE ZHEX, fourteen hex digits,
/// CR LF XON), so a cancel then follows the start of one, or some of its
/// digits, or all of its digits without the line end.
///
/// The hex header parser used to wait for all fourteen digits before looking
/// at any of them, and to throw on the first that was not a digit. The CANs
/// were held back until the next session's bytes arrived, and the throw
/// ended the parser's generator: it never produced another packet, so the
/// receiver answered nothing until the app's fifty-empty-deliveries watchdog
/// replaced it.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zmodem/zmodem.dart';
import 'package:zmodem/src/consts.dart' as consts;

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

/// A hex header with a correct CRC, as headband firmware sends it.
Uint8List _hexHeader(int type, [int pos = 0]) {
  final raw = [
    type,
    pos & 0xFF,
    (pos >> 8) & 0xFF,
    (pos >> 16) & 0xFF,
    (pos >> 24) & 0xFF,
  ];
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

/// Answered ZRQINIT, waiting for the offer: the next header is ZFILE.
ZModemCore _waitingForOffer() {
  final server = ZModemCore();
  final client = ZModemCore();
  server.initiateSend();
  client.receive(server.dataToSend()).toList();
  client.dataToSend();
  return client;
}

/// Accepted the offer, waiting for the data: the next header is ZDATA.
ZModemCore _waitingForData() {
  final server = ZModemCore();
  final client = ZModemCore();
  server.initiateSend();
  client.receive(server.dataToSend()).toList();
  server.receive(client.dataToSend()).toList();
  server.offerFile(ZModemFileInfo(pathname: 'd.bin', length: 100000));
  client.receive(server.dataToSend()).toList();
  client.acceptFile(0);
  client.dataToSend();
  return client;
}

/// In the file, after a frame that ended (ZCRCE): the next header is ZEOF
/// or another ZDATA.
ZModemCore _betweenDataFrames() {
  final client = _waitingForData();
  client.receive(_hexHeader(consts.ZDATA)).toList();
  final frameEnd = [0x41, 0x42, consts.ZDLE, consts.ZCRCE, 0x12, 0x34];
  client.receive(Uint8List.fromList(frameEnd)).toList();
  expect(client.isIdle, isFalse);
  client.dataToSend();
  return client;
}

List<ZModemEvent> _nextOffer(ZModemCore client) {
  final server = ZModemCore();
  final events = <ZModemEvent>[];
  server.initiateSend();
  events.addAll(_feed(client, server.dataToSend(), 64));
  final rinit = client.dataToSend();
  expect(rinit, isNotEmpty, reason: 'the receiver must answer ZRQINIT');
  server.receive(rinit).toList();
  server.offerFile(ZModemFileInfo(pathname: 'next.bin', length: 4096));
  events.addAll(_feed(client, server.dataToSend(), 64));
  return events;
}

void main() {
  setUp(_resetStatics);

  final names = [
    'the offer (ZFILE)',
    'the start of the data (ZDATA)',
    'the end of the file (ZEOF)',
  ];
  final receivers = <ZModemCore Function()>[
    _waitingForOffer,
    _waitingForData,
    _betweenDataFrames,
  ];
  final headers = [
    _hexHeader(consts.ZFILE),
    _hexHeader(consts.ZDATA),
    _hexHeader(consts.ZEOF, 100000),
  ];

  group('a cancel that cuts a hex header short', () {
    for (var k = 0; k < names.length; k++) {
      final name = names[k];
      final receiver = receivers[k];
      final header = headers[k];
      // 5: the least that is a cancel. 8: firmware up to 2.6.1 and from
      // 2.6.4. 10: firmware 2.6.2 / 2.6.3.
      for (final n in [5, 8, 10]) {
        for (final size in [64, 1]) {
          test('$name, $n CANs, deliveries of $size, every cut', () {
            for (var cut = 1; cut < header.length; cut++) {
              _resetStatics();
              final client = receiver();
              final why = 'cut after byte $cut of ${header.length}';
              client.receive(Uint8List.sublistView(header, 0, cut)).toList();
              final events = _feed(client, _cans(n), size);
              expect(
                events.whereType<ZSessionCancelEvent>(),
                hasLength(1),
                reason: why,
              );
              expect(client.isIdle, isTrue, reason: why);
              // The parser must still be alive and nothing may be left over.
              final offer = _nextOffer(client);
              expect(
                offer.whereType<ZSessionCancelEvent>(),
                isEmpty,
                reason: 'the next offer was cancelled; $why',
              );
              expect(
                offer.whereType<ZFileOfferedEvent>(),
                hasLength(1),
                reason: 'the next offer was not offered; $why',
              );
            }
          });
        }
      }
    }
  });

  group('whole headers are read as before', () {
    test('a header that arrives one byte at a time', () {
      final client = _waitingForData();
      final events = _feed(client, _hexHeader(consts.ZDATA), 1);
      expect(events.whereType<ZSessionCancelEvent>(), isEmpty);
      expect(client.isIdle, isFalse);
    });

    test('LF only, CR LF, and no XON are all accepted', () {
      for (final tail in [
        [0x0a],
        [0x0d, 0x0a],
        [0x0d, 0x8a],
        [0x0d, 0x0a, consts.XON],
      ]) {
        _resetStatics();
        final client = _waitingForData();
        final header = [..._hexHeader(consts.ZDATA).sublist(0, 18), ...tail];
        final events = _feed(client, header, 64);
        expect(events.whereType<ZSessionCancelEvent>(), isEmpty,
            reason: 'tail $tail');
        expect(client.isIdle, isFalse, reason: 'tail $tail');
      }
    });
  });
}
