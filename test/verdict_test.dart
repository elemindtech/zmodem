/// End-to-end acknowledgment (item 7): on ZEOF the receiver must NOT
/// auto-reply ZRINIT. It emits a [ZFileEndEvent] and waits in the
/// awaiting-verdict state until the consumer has durably stored the bytes,
/// then either [ZModemCore.ackFileEnd] (ZRINIT -> sender deletes its copy)
/// or [ZModemCore.abortSession] (CAN -> sender RETAINS and re-offers). This
/// is what lets the app verify the on-disk length before the firmware — which
/// erases each chunk on bare protocol success — believes delivery worked.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zmodem/zmodem.dart';
import 'package:zmodem/src/consts.dart' as consts;
import 'package:zmodem/src/zmodem_frame.dart' show ZModemDataPacket;

void resetStatics() {
  ZModemState.lastHeader = null;
  ZModemState.lastSubPacket = null;
}

/// A sender+receiver pair driven exactly to the moment the receiver has
/// emitted ZFileEndEvent for a [length]-byte file, with NO verdict issued.
class _Pair {
  final ZModemCore server = ZModemCore();
  final ZModemCore client = ZModemCore();
  ZFileEndEvent? end;

  _Pair(int length) {
    server.initiateSend();
    client.receive(server.dataToSend()).toList(); // ZRQINIT -> ZRINIT
    server.receive(client.dataToSend()).toList(); // ZRINIT -> ready
    server.offerFile(ZModemFileInfo(pathname: 'd.bin', length: length));
    client.receive(server.dataToSend()).toList(); // ZFILE -> offered
    client.acceptFile(0); // ZRPOS(0)
    server.receive(client.dataToSend()).toList(); // accepted -> sending
    server.sendFileData(Uint8List(length));
    client.receive(server.dataToSend()).toList(); // ZDATA + payload
    server.finishSending(length); // ZCRCE + ZEOF
    for (final e in client.receive(server.dataToSend())) {
      if (e is ZFileEndEvent) end = e;
    }
  }
}

/// A fw-style hex header of arbitrary type (dialect the fielded parser reads).
Uint8List _hexHeader(int type, int pos) {
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

Uint8List zrqinitHeader() => _hexHeader(consts.ZRQINIT, 0);

/// A fw-style ZEOF hex header (matches the dialect the fielded parser reads).
Uint8List zeofHeader(int pos) {
  final raw = [
    consts.ZEOF,
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

int _canCount(Uint8List out) => out.where((b) => b == consts.ZDLE).length;

void main() {
  setUp(resetStatics);

  group('end-to-end ack (verdict on ZEOF)', () {
    test('ZEOF yields a ZFileEndEvent carrying the full file length', () {
      final p = _Pair(2700);
      expect(p.end, isNotNull);
      expect(p.end!.position, 2700,
          reason: 'ZEOF position is the little-endian file length');
    });

    test('the receiver sends NOTHING back until a verdict is issued', () {
      final p = _Pair(2700);
      // No ZRINIT, no ZRPOS, no ZFIN — the sender is held, still holding
      // its copy, until the consumer decides.
      expect(p.client.dataToSend(), isEmpty,
          reason: 'no auto-ack on ZEOF: the file must not be counted '
              'delivered before the consumer verifies it');
    });

    test('ackFileEnd() replies ZRINIT and lets the session complete', () {
      final p = _Pair(2700);
      p.client.ackFileEnd();
      // The sender sees ZRINIT and is ready for the next file.
      expect(
          p.server.receive(p.client.dataToSend()), [isA<ZReadyToSendEvent>()]);
      // Normal teardown still works.
      p.client.finishSession();
      final out = p.client.dataToSend();
      expect(out, isNotEmpty, reason: 'ZFIN should be queued by finishSession');
    });

    test('abortSession() sends a CAN run and NO ZRINIT', () {
      final p = _Pair(2700);
      p.client.abortSession();
      final out = p.client.dataToSend();
      expect(_canCount(out), greaterThanOrEqualTo(5),
          reason: 'abort must carry the 5x CAN run so the sender ABORTS '
              '(retains the file) rather than seeing success');
      // Crucially, no ZRINIT hex header is emitted — the sender must not
      // read this as success. A ZRINIT hex header would appear as the
      // ASCII "01" type field after the '**' ZDLE 'B' preamble.
      expect(String.fromCharCodes(out).contains('B01'), isFalse,
          reason: 'abort must not carry a ZRINIT header');
      // The receiver has reset itself to the idle/init state.
      expect(p.client.isIdle, isTrue,
          reason: 'abortSession returns the receiver to the init state');
    });

    test('ackFileEnd() is a no-op outside the awaiting-verdict state', () {
      // A fresh core is in the init state; ackFileEnd must not enqueue a
      // stray ZRINIT that could desync a later session.
      final core = ZModemCore();
      core.ackFileEnd();
      expect(core.dataToSend(), isEmpty);
    });

    test('a retransmitted ZEOF while awaiting the verdict is ignored', () {
      final p = _Pair(2700);
      // The sender resends ZEOF (it has not heard back). It must NOT
      // produce a second ZFileEndEvent nor disturb the held state.
      final dup = p.client.receive(zeofHeader(2700)).toList();
      expect(dup, isEmpty, reason: 'duplicate ZEOF is deduplicated');
      expect(p.client.dataToSend(), isEmpty,
          reason: 'still awaiting the verdict, still silent');
      // The verdict still works after the duplicate.
      p.client.ackFileEnd();
      expect(
          p.server.receive(p.client.dataToSend()), [isA<ZReadyToSendEvent>()]);
    });

    test('ackFileEnd() reports whether the ack was actually issued', () {
      final p = _Pair(2700);
      expect(p.client.isAwaitingVerdict, isTrue);
      expect(p.client.ackFileEnd(), isTrue,
          reason: 'first ack from the verdict state is issued');
      expect(p.client.isAwaitingVerdict, isFalse);
      expect(p.client.ackFileEnd(), isFalse,
          reason: 'a second ack (or one after a restart) must report '
              'failure so the caller does not finishSession a session '
              'that is no longer awaiting the verdict');
    });

    test('an 8-CAN spray maps to exactly ONE cancel event', () {
      // The firmware answers every failed send with EIGHT CANs; the
      // counter must reset after firing so the spray does not yield one
      // cancel per surplus CAN.
      final core = ZModemCore();
      final events =
          core.receive(Uint8List.fromList(List.filled(8, 0x18))).toList();
      expect(events.whereType<ZSessionCancelEvent>(), hasLength(1));
    });

    test('stray subpackets after an abort are dropped without a CAN reply', () {
      final p = _Pair(2700);
      p.client.abortSession();
      p.client.dataToSend(); // drain our CAN run
      // 1-3 in-flight ZCRCG subpackets can still arrive; the parser is
      // still armed from the aborted transfer.
      p.client.parser.expectDataSubpacket();
      final stray = p.client
          .receive(
              ZModemDataPacket.fileData(Uint8List.fromList([1, 2, 3])).encode())
          .toList();
      expect(stray, isEmpty, reason: 'dropped silently');
      expect(p.client.dataToSend(), isEmpty,
          reason: 'no CAN-per-packet churn after our own abort');
    });

    test('a closed session honors ZRQINIT (restart) after the verdict', () {
      final p = _Pair(2700);
      p.client.ackFileEnd();
      p.client.finishSession();
      p.client.dataToSend(); // drain ZRINIT + ZFIN
      // The firmware's ZFIN reply is lost; it starts the next session.
      final events = p.client.receive(zrqinitHeader()).toList();
      expect(events.whereType<ZSessionRestartEvent>(), hasLength(1));
      expect(p.client.dataToSend(), isNotEmpty,
          reason: 'the new session gets its ZRINIT instead of silence');
    });

    test('0-byte file: ZEOF with no ZDATA still awaits a verdict', () {
      final p = _Pair(0);
      expect(p.end, isNotNull);
      expect(p.end!.position, 0);
      expect(p.client.dataToSend(), isEmpty,
          reason: 'even a 0-byte file is not auto-acked');
      p.client.ackFileEnd();
      expect(
          p.server.receive(p.client.dataToSend()), [isA<ZReadyToSendEvent>()]);
    });
  });
}
