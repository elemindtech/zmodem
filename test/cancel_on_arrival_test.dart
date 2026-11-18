/// A cancel from the sender (five or more consecutive CAN bytes) must be
/// acted on when its fifth CAN arrives, exactly once, and must leave nothing
/// behind that can touch the next session.
///
/// What released headband firmware sends for one failed or cancelled send:
///
///   up to 2.6.1, and 2.6.4 on   8 CANs, one delivery
///   2.6.2 and 2.6.3            10 CANs (5 + 5), the second five one byte
///                              per delivery; 16 when two sends fail back
///                              to back
///
/// Before this file's change the parser consumed nothing until four bytes
/// were buffered, so it always held the last three back. Eight happened to
/// work (five read, three held). Five, ten and sixteen left a cancel that
/// was only recognised when the NEXT session's first bytes arrived, and it
/// cancelled that session: the sender's offer was answered and then refused.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zmodem/zmodem.dart';
import 'package:zmodem/src/consts.dart' as consts;
import 'package:zmodem/src/zmodem_frame.dart' show ZModemDataPacket;

void _resetStatics() {
  ZModemState.lastHeader = null;
  ZModemState.lastSubPacket = null;
}

Uint8List _cans(int n) => Uint8List.fromList(List.filled(n, consts.CAN));

/// Feeds [bytes] to [core] in deliveries of the given [sizes] (the last size
/// repeats; `[1]` is one byte per delivery) and returns every event.
List<ZModemEvent> _feed(ZModemCore core, Uint8List bytes, List<int> sizes) {
  final events = <ZModemEvent>[];
  var at = 0;
  var i = 0;
  while (at < bytes.length) {
    final size = sizes[i < sizes.length ? i : sizes.length - 1];
    final end = (at + size) > bytes.length ? bytes.length : at + size;
    events.addAll(core.receive(Uint8List.sublistView(bytes, at, end)));
    at = end;
    i++;
  }
  return events;
}

/// A receiver in the middle of a file: it has accepted the offer and taken
/// one ZCRCG subpacket, so the parser is armed for the next subpacket.
ZModemCore _receiverMidFile() {
  final server = ZModemCore();
  final client = ZModemCore();
  server.initiateSend();
  client.receive(server.dataToSend()).toList(); // ZRQINIT -> ZRINIT
  server.receive(client.dataToSend()).toList();
  server.offerFile(ZModemFileInfo(pathname: 'd.bin', length: 100000));
  client.receive(server.dataToSend()).toList(); // ZFILE -> offered
  client.acceptFile(0);
  server.receive(client.dataToSend()).toList();
  server.sendFileData(Uint8List(1024));
  final got = client.receive(server.dataToSend()).toList(); // ZDATA + ZCRCG
  expect(got.whereType<ZFileDataEvent>(), hasLength(1));
  expect(client.isIdle, isFalse);
  expect(client.dataToSend(), isEmpty);
  return client;
}

/// A receiver between frames: it has answered ZRQINIT and waits for ZFILE,
/// so the parser is at its top level, not inside a subpacket.
ZModemCore _receiverBetweenFrames() {
  final server = ZModemCore();
  final client = ZModemCore();
  server.initiateSend();
  client.receive(server.dataToSend()).toList();
  expect(client.dataToSend(), isNotEmpty); // our ZRINIT
  expect(client.isIdle, isFalse);
  return client;
}

/// Runs a complete new offer against [client] (ZRQINIT, then ZFILE) and
/// returns every event it produced. The offer must come out as offered.
List<ZModemEvent> _nextOffer(ZModemCore client,
    {List<int> sizes = const [64]}) {
  final server = ZModemCore();
  final events = <ZModemEvent>[];
  server.initiateSend();
  events.addAll(_feed(client, server.dataToSend(), sizes)); // ZRQINIT
  final rinit = client.dataToSend();
  expect(rinit, isNotEmpty, reason: 'the receiver must answer ZRQINIT');
  server.receive(rinit).toList();
  server.offerFile(ZModemFileInfo(pathname: 'next.bin', length: 4096));
  events.addAll(_feed(client, server.dataToSend(), sizes)); // ZFILE
  return events;
}

void _expectOfferSurvives(List<ZModemEvent> events, String why) {
  expect(events.whereType<ZSessionCancelEvent>(), isEmpty,
      reason: 'the next offer was cancelled ($why)');
  expect(events.whereType<ZFileOfferedEvent>(), hasLength(1),
      reason: 'the next offer was not offered ($why)');
}

void main() {
  setUp(_resetStatics);

  group('the cancel is acted on as its fifth CAN arrives', () {
    test('mid-file, five CANs in one delivery (2.6.2 / 2.6.3 session cancel)',
        () {
      final client = _receiverMidFile();
      final events = client.receive(_cans(5)).toList();
      expect(events.whereType<ZSessionCancelEvent>(), hasLength(1));
      expect(events, hasLength(1));
    });

    test('mid-file, five CANs one byte per delivery: on the fifth', () {
      final client = _receiverMidFile();
      for (var i = 0; i < 4; i++) {
        expect(client.receive(_cans(1)).toList(), isEmpty,
            reason: 'CAN ${i + 1} of 5 is not a cancel yet');
      }
      expect(client.receive(_cans(1)).toList().whereType<ZSessionCancelEvent>(),
          hasLength(1));
    });

    test('mid-file, split four and one', () {
      final client = _receiverMidFile();
      expect(client.receive(_cans(4)).toList(), isEmpty);
      expect(client.receive(_cans(1)).toList().whereType<ZSessionCancelEvent>(),
          hasLength(1));
    });

    test('between frames, five CANs in one delivery', () {
      final client = _receiverBetweenFrames();
      expect(client.receive(_cans(5)).toList().whereType<ZSessionCancelEvent>(),
          hasLength(1));
    });

    test('between frames, five CANs one byte per delivery: on the fifth', () {
      final client = _receiverBetweenFrames();
      for (var i = 0; i < 4; i++) {
        expect(client.receive(_cans(1)).toList(), isEmpty);
      }
      expect(client.receive(_cans(1)).toList().whereType<ZSessionCancelEvent>(),
          hasLength(1));
    });

    test('the receiver does not answer a cancel with one of its own', () {
      final mid = _receiverMidFile();
      mid.receive(_cans(8)).toList();
      expect(mid.dataToSend(), isEmpty);
      final between = _receiverBetweenFrames();
      between.receive(_cans(8)).toList();
      expect(between.dataToSend(), isEmpty);
    });
  });

  group('one run of CANs is one cancel, whatever its length', () {
    // 5..16 covers every released sender: 8 (up to 2.6.1, 2.6.4 on), 10 and
    // 16 (2.6.2 / 2.6.3), and the lengths around them.
    for (final where in ['mid-file', 'between frames']) {
      for (var n = 5; n <= 16; n++) {
        for (final sizes in [
          [64], // the whole run in one delivery
          [1], // one byte per delivery
          [5, 64], // the session's five, then the rest
        ]) {
          test('$where, $n CANs, deliveries of $sizes', () {
            final client = where == 'mid-file'
                ? _receiverMidFile()
                : _receiverBetweenFrames();
            final events = _feed(client, _cans(n), sizes);
            expect(events.whereType<ZSessionCancelEvent>(), hasLength(1),
                reason: 'exactly one cancel for one run');
            expect(events, hasLength(1));
            expect(client.isIdle, isTrue);
            // Nothing of the run may be left to land on the next session.
            _expectOfferSurvives(_nextOffer(client), '$n CANs, $sizes');
          });
        }
      }
    }

    test('the next offer survives when it arrives one byte at a time', () {
      final client = _receiverMidFile();
      _feed(client, _cans(10), [5, 1]);
      _expectOfferSurvives(_nextOffer(client, sizes: [1]), 'byte-wise offer');
    });

    test('a later, separate cancel is still a cancel', () {
      final client = _receiverMidFile();
      expect(_feed(client, _cans(8), [64]).whereType<ZSessionCancelEvent>(),
          hasLength(1));
      // A new offer gets as far as ZFILE, then the sender cancels again.
      _expectOfferSurvives(_nextOffer(client), 'first re-offer');
      expect(_feed(client, _cans(8), [64]).whereType<ZSessionCancelEvent>(),
          hasLength(1),
          reason: 'the second run is a new cancel, not the tail of the first');
      expect(client.isIdle, isTrue);
    });
  });

  group('the core is parked as the cancel is parsed', () {
    test('a peer cancel leaves the core in the init state at once', () {
      final client = _receiverMidFile();
      client.receive(_cans(5)).toList();
      expect(client.isIdle, isTrue,
          reason: 'no consumer call is needed to park the core');
    });

    test('cancel and the next ZRQINIT in ONE delivery: the offer survives', () {
      // The consumer handles events after the whole delivery has been
      // parsed. If parking waited for it, the ZRQINIT behind the cancel
      // would be read mid-file, and a reset applied afterwards would discard
      // the handshake; the ZFILE that follows is then refused.
      final client = _receiverMidFile();
      final server = ZModemCore()..initiateSend();
      final zrqinit = server.dataToSend();
      final delivery = Uint8List.fromList([..._cans(8), ...zrqinit]);
      final events = client.receive(delivery).toList();
      expect(events.whereType<ZSessionCancelEvent>(), hasLength(1));
      expect(events.whereType<ZSessionRestartEvent>(), isEmpty,
          reason: 'read from the init state, a ZRQINIT is not a restart');
      final rinit = client.dataToSend();
      expect(rinit, isNotEmpty, reason: 'ZRQINIT answered');
      expect(client.isIdle, isFalse, reason: 'the new session is under way');
      server.receive(rinit).toList();
      server.offerFile(ZModemFileInfo(pathname: 'next.bin', length: 4096));
      final offer = client.receive(server.dataToSend()).toList();
      _expectOfferSurvives(offer, 'cancel + ZRQINIT in one delivery');
    });

    test('a verdict issued after a peer cancel is a no-op', () {
      // Drive a receiver to the awaiting-verdict state (ZEOF received).
      final server = ZModemCore();
      final client = ZModemCore();
      server.initiateSend();
      client.receive(server.dataToSend()).toList();
      server.receive(client.dataToSend()).toList();
      server.offerFile(ZModemFileInfo(pathname: 'd.bin', length: 512));
      client.receive(server.dataToSend()).toList();
      client.acceptFile(0);
      server.receive(client.dataToSend()).toList();
      server.sendFileData(Uint8List(512));
      client.receive(server.dataToSend()).toList();
      server.finishSending(512);
      client.receive(server.dataToSend()).toList();
      expect(client.isAwaitingVerdict, isTrue);

      client.receive(_cans(8)).toList();
      expect(client.isAwaitingVerdict, isFalse);
      expect(client.ackFileEnd(), isFalse,
          reason: 'the sender cancelled: there is nothing left to acknowledge');
      expect(client.dataToSend(), isEmpty);
    });
  });

  group('what must not be taken for a cancel', () {
    test('an escaped byte split across two deliveries still decodes', () {
      // 0x18 in the payload is sent as ZDLE 0x58. When the delivery ends on
      // the ZDLE, the parser must wait for the 0x58, not act on the ZDLE.
      final client = _receiverMidFile();
      final packet =
          ZModemDataPacket.fileData(Uint8List.fromList([1, 0x18, 2])).encode();
      final cut = packet.indexOf(consts.ZDLE) + 1;
      expect(packet[cut], consts.ZDLEE);
      final first = client.receive(Uint8List.sublistView(packet, 0, cut));
      expect(first.toList(), isEmpty);
      final events =
          client.receive(Uint8List.sublistView(packet, cut)).toList();
      expect(events.whereType<ZSessionCancelEvent>(), isEmpty);
      final data = events.whereType<ZFileDataEvent>().single;
      expect(data.data, [1, 0x18, 2]);
    });

    test('four CANs, then data, then a lone ZDLE: no cancel', () {
      // Only five CONSECUTIVE CANs are a cancel. The count must not survive
      // the data bytes and turn the lone ZDLE into a fifth.
      final client = _receiverMidFile();
      final events = client
          .receive(Uint8List.fromList([..._cans(4), 0x41, 0x42, consts.ZDLE]))
          .toList();
      expect(events.whereType<ZSessionCancelEvent>(), isEmpty);
      expect(client.isIdle, isFalse);
    });

    test('four CANs between frames, then a header: no cancel', () {
      final client = _receiverBetweenFrames();
      expect(client.receive(_cans(4)).toList(), isEmpty);
      // The sender starts over; the four CANs must not count towards a
      // cancel that a single stray CAN could then complete.
      final server = ZModemCore()..initiateSend();
      client.receive(server.dataToSend()).toList();
      expect(client.receive(_cans(1)).toList(), isEmpty,
          reason: 'one CAN after a header is not the fifth of anything');
    });
  });

  group('look-ahead is kept where a frame start needs it', () {
    test('a ZRQINIT arriving one byte at a time is answered once', () {
      final client = ZModemCore();
      final server = ZModemCore()..initiateSend();
      final events = _feed(client, server.dataToSend(), [1]);
      expect(events.whereType<ZSessionCancelEvent>(), isEmpty);
      final reply = client.dataToSend();
      expect(reply, isNotEmpty);
      expect(client.dataToSend(), isEmpty, reason: 'answered once');
    });

    test('text between frames is delivered as it arrives', () {
      final seen = <int>[];
      final client = ZModemCore(onPlainText: seen.add);
      client.receive(Uint8List.fromList('O'.codeUnits)).toList();
      expect(seen, 'O'.codeUnits,
          reason: 'one byte of text does not wait for three more');
      client.receive(Uint8List.fromList('O'.codeUnits)).toList();
      expect(seen, 'OO'.codeUnits);
    });
  });
}
