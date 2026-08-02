/// Dialect pins: each test locks one quirk of THIS fielded receiver
/// that senders (firmware ezm core, desktop ezmodem) must design
/// around. These are not aspirations — they document the shipped
/// behavior a fleet of un-updated apps exhibits. If a change here
/// breaks a pin, the sender-side law in the firmware must be
/// re-audited before the change ships.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zmodem/zmodem.dart' hide XON;
import 'package:zmodem/src/consts.dart' as consts;
import 'package:zmodem/src/zmodem_frame.dart';

/// fw-style hex header: '**' ZDLE 'B' + hex(type, p LE) + hex(crc16)
/// + CR LF, optionally followed by the Elemind XON link marker.
Uint8List hexHeader(int type, int p, {bool xon = true}) {
  final raw = [
    type,
    p & 0xFF,
    (p >> 8) & 0xFF,
    (p >> 16) & 0xFF,
    (p >> 24) & 0xFF,
  ];
  var crc = 0;
  for (final b in raw) {
    crc ^= b << 8;
    for (var i = 0; i < 8; i++) {
      crc = ((crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1) & 0xFFFF;
    }
  }
  final body = [...raw, crc >> 8, crc & 0xFF];
  final hex = body
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .codeUnits;
  return Uint8List.fromList([
    consts.ZPAD, consts.ZPAD, consts.ZDLE, consts.ZHEX,
    ...hex, 0x0d, 0x0a,
    if (xon) consts.XON,
  ]);
}

List<ZModemEvent> feed(ZModemCore core, Uint8List data) {
  final events = core.receive(data).toList();
  return events;
}

void resetStatics() {
  ZModemState.lastHeader = null;
  ZModemState.lastSubPacket = null;
}

void main() {
  setUp(resetStatics);

  group('link framing', () {
    test('PIN: hex header with the Elemind XON link marker delivers, '
        'and the XON is consumed silently', () {
      final seenText = <int>[];
      final withXon = hexHeader(consts.ZFIN, 0, xon: true);
      final events =
          ZModemCore(onPlainText: seenText.add).receive(withXon).toList();
      expect(events.whereType<ZSessionFinishedEvent>(), hasLength(1));
      expect(seenText, isNot(contains(consts.XON)),
          reason: 'the link marker must not leak into plain text');
    });

    test('PIN: this parser revision also delivers a header whose '
        'stream (momentarily) ends at LF', () {
      // The trailer parse peeks for a following XON; ChunkBuffer.peek
      // returns null on an empty buffer, so delivery does not wait for
      // a post-LF byte IN THIS REVISION. The firmware still appends
      // XON to every hex header: it is the physical-layer liveness
      // marker of the Elemind link dialect and belt-and-suspenders
      // against parser revisions that were stricter here.
      final core = ZModemCore();
      final bare = hexHeader(consts.ZFIN, 0, xon: false);
      expect(feed(core, bare).whereType<ZSessionFinishedEvent>(),
          hasLength(1));
    });

    test('PIN: the hex trailer REQUIRES LF - CR followed by anything '
        'else throws a StateError out of receive()', () {
      // Senders must terminate hex headers with CR LF (or LF). There
      // is no graceful recovery inside the parser: the generator
      // throws and the session is unusable from then on.
      final core = ZModemCore();
      final bad = BytesBuilder()
        ..add(hexHeader(consts.ZFIN, 0, xon: false).sublist(0, 19)) // ..CR
        ..add([consts.XON]); // XON where LF belongs
      expect(() => core.receive(bad.toBytes()).toList(),
          throwsStateError);
    });
  });

  group('session state machine', () {
    test('PIN: a closed session ignores ZRQINIT — only ZFIN gets "OO"',
        () {
      // After finishSession() the receiver sits in its closed state.
      // A firmware retrying ZRQINIT gets silence (this stranded
      // multi-session syncs until the firmware learned to cancel and
      // reopen); only the peer's ZFIN elicits the final OO.
      final core = ZModemCore();
      core.finishSession();
      core.dataToSend(); // drain our ZFIN

      expect(feed(core, hexHeader(consts.ZRQINIT, 0)), isEmpty);
      expect(core.dataToSend(), isEmpty,
          reason: 'no ZRINIT reply from a closed session');

      final fin = feed(core, hexHeader(consts.ZFIN, 0));
      expect(fin.whereType<ZSessionFinishedEvent>(), hasLength(1));
      final oo = core.dataToSend();
      expect(String.fromCharCodes(oo), contains('OO'));
    });

    test(
        'PIN: an unexpected header type CANCELS the session (5xCAN) '
        'unless it repeats the previous header type', () {
      // Base-state law: duplicate same-type headers are silently
      // ignored; any OTHER unexpected header aborts. Senders must
      // never surprise this receiver: e.g. exactly ONE ZDATA per
      // ZRPOS, never a stray control header mid-stream.
      final core = ZModemCore();
      core.initiateReceive();
      core.dataToSend();

      // ZEOF is unexpected in ZRinit state -> cancel + 5xCAN
      final events = feed(core, hexHeader(11 /* ZEOF */, 0));
      expect(events.whereType<ZSessionCancelEvent>(), hasLength(1));
      final out = core.dataToSend();
      final cans =
          out.where((b) => b == 0x18).length; // CAN == ZDLE == 0x18
      expect(cans, greaterThanOrEqualTo(5),
          reason: 'abort sequence must carry the CAN run');

      // ...but the SAME unexpected type again is ignored (duplicate).
      resetStatics();
      final core2 = ZModemCore();
      core2.initiateReceive();
      core2.dataToSend();
      feed(core2, hexHeader(11, 0)); // records lastHeader = ZEOF
      core2.dataToSend();
      final dup = feed(core2, hexHeader(11, 0));
      expect(dup, isEmpty, reason: 'duplicate unexpected type is ignored');
    });
  });

  group('duplicate-subpacket suppression', () {
    test(
        'PIN: a stray data subpacket whose (type, crc) equal the '
        'previous one is silently dropped — and the memory of the '
        'previous one is STATIC across core instances', () {
      // This is why the firmware sender varies its subpacket slicing
      // for files with repeated content, and why its dedup tracker
      // survives session restarts: the receiver's comparison state
      // outlives the session object itself. (A data subpacket only
      // surfaces when the parser is armed; states without their own
      // subpacket handler fall through to the base handler that does
      // this check.)
      final fileInfo = ZModemFileInfo(pathname: 'x', length: 3);
      final infoPacket = ZModemDataPacket.fileInfo(fileInfo);

      // Prime the static from core A: arm the parser so the stray is
      // parsed while the state (fresh init) has no subpacket handler.
      final coreA = ZModemCore();
      coreA.parser.expectDataSubpacket();
      final strayA = feed(coreA, infoPacket.encode());
      expect(strayA.whereType<ZSessionCancelEvent>(), hasLength(1),
          reason: 'first stray subpacket aborts the session');
      coreA.dataToSend();

      // A brand-new core still remembers it: the identical stray is
      // now IGNORED instead of aborting.
      final coreB = ZModemCore();
      coreB.parser.expectDataSubpacket();
      final strayB = feed(coreB, infoPacket.encode());
      expect(strayB, isEmpty,
          reason: 'identical (type, crc) suppressed via STATIC state');
      expect(coreB.dataToSend(), isEmpty);
    });
  });

  group('data subpacket re-arm', () {
    Uint8List zbinHeader(int type, int p) =>
        ZModemHeader(type, p & 0xFF, (p >> 8) & 0xFF, (p >> 16) & 0xFF,
                (p >> 24) & 0xFF)
            .encode();

    Uint8List dataSubpacket(List<int> bytes, {bool eof = false}) =>
        ZModemDataPacket.fileData(Uint8List.fromList(bytes), eof: eof)
            .encode();

    ZModemCore receivingCore() {
      final core = ZModemCore();
      core.initiateReceive();
      core.dataToSend();
      final offer = BytesBuilder()
        ..add(zbinHeader(4 /* ZFILE */, 0))
        ..add(ZModemDataPacket.fileInfo(
                ZModemFileInfo(pathname: 'f', length: 4096))
            .encode());
      final events = feed(core, offer.toBytes());
      expect(events.whereType<ZFileOfferedEvent>(), hasLength(1));
      core.acceptFile();
      core.dataToSend();
      return core;
    }

    test('PIN: ZCRCG re-arms the parser for the next subpacket', () {
      final core = receivingCore();
      final stream = BytesBuilder()
        ..add(zbinHeader(10 /* ZDATA */, 0))
        ..add(dataSubpacket(List.filled(100, 0x41))) // ZCRCG
        ..add(dataSubpacket(List.filled(100, 0x42))); // ZCRCG
      final events = feed(core, stream.toBytes());
      expect(events.whereType<ZFileDataEvent>(), hasLength(2),
          reason: 'streaming ZCRCG subpackets flow without new headers');
    });

    test(
        'PIN: a ZCRCE-terminated subpacket does NOT re-arm, and a '
        're-sent ZDATA header is ALSO swallowed as a duplicate — there '
        'is no sender-side recovery from a mid-file ZCRCE', () {
      // Two quirks compound here. (1) After ZCRCE the parser is not
      // re-armed, so a following subpacket without a fresh header is
      // eaten as plain text. (2) The obvious fix — resend ZDATA — is
      // ALSO dropped, because an unexpected header repeating the
      // previous header's TYPE is ignored by the duplicate filter.
      // Recovery only happens when the RECEIVER times out and sends
      // ZRPOS (which moves it to a state that expects ZDATA again).
      // This is why the firmware streams ZCRCG and reserves ZCRCE
      // strictly for the final subpacket before ZEOF.
      final core = receivingCore();
      final stream = BytesBuilder()
        ..add(zbinHeader(10, 0))
        ..add(dataSubpacket(List.filled(100, 0x41), eof: true)) // ZCRCE
        ..add(dataSubpacket(List.filled(100, 0x42))); // orphaned
      final events = feed(core, stream.toBytes());
      expect(events.whereType<ZFileDataEvent>(), hasLength(1),
          reason: 'post-ZCRCE subpacket must vanish without an event');

      // The re-sent ZDATA header is suppressed as a duplicate type,
      // taking its subpacket down with it.
      final resent = BytesBuilder()
        ..add(zbinHeader(10, 100))
        ..add(dataSubpacket(List.filled(50, 0x43)));
      final more = feed(core, resent.toBytes());
      expect(more.whereType<ZFileDataEvent>(), isEmpty,
          reason: 'duplicate-type ZDATA header is dropped silently');
      expect(more.whereType<ZSessionCancelEvent>(), isEmpty,
          reason: 'no cancel either: the loss is completely silent');
    });
  });

  group('ZFILE info parsing', () {
    test(
        'PIN: a ZFILE whose info block lacks a decimal size CRASHES '
        'the receive iteration (uncaught FormatException)', () {
      // The fielded parser calls int.parse on the first property with
      // no validation. Senders MUST always provide "size mtime ..."
      // with a plain decimal size; there is no graceful skip.
      final core = ZModemCore();
      core.initiateReceive();
      core.dataToSend();

      final bogusInfo = Uint8List.fromList([
        ...'f'.codeUnits, 0, // pathname
        ...'notanumber'.codeUnits, 0, // properties
      ]);
      final offer = BytesBuilder()
        ..add(ZModemHeader(4, 0, 0, 0, 0).encode())
        ..add(ZModemDataPacket(consts.ZCRCW, bogusInfo).encode());

      expect(
        () => core.receive(offer.toBytes()).toList(),
        throwsFormatException,
      );
    });
  });
}
