/// What a headband puts on the wire, built by hand, and a consumer that
/// answers the receiver the way the app does. For the receiver's tests.
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zmodem/src/consts.dart' as consts;
import 'package:zmodem/src/crc.dart';
import 'package:zmodem/src/zmodem_frame.dart';
import 'package:zmodem/zmodem.dart' show ZModemFileInfo;
import 'package:zmodem/src/receiver.dart';

/// A hex header as the firmware sends it: "**", ZDLE, 'B', fourteen hex
/// digits (type, four position bytes least significant first, CRC-16),
/// CR LF, and XON after the headers that no data follows.
Uint8List hexHeader(int type, [int position = 0, bool xon = true]) {
  final raw = [
    type,
    position & 0xff,
    (position >> 8) & 0xff,
    (position >> 16) & 0xff,
    (position >> 24) & 0xff,
  ];
  final crc = CRC16()
    ..updateAll(raw)
    ..finalize();
  final digits = [...raw, crc.value >> 8, crc.value & 0xff]
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return Uint8List.fromList([
    consts.ZPAD,
    consts.ZPAD,
    consts.ZDLE,
    consts.ZHEX,
    ...digits.codeUnits,
    consts.CR,
    consts.LF,
    if (xon) consts.XON,
  ]);
}

Uint8List zrqinit() => hexHeader(consts.ZRQINIT);
Uint8List zfin() => hexHeader(consts.ZFIN);
Uint8List zeof(int position) => hexHeader(consts.ZEOF, position);

/// ZFILE and the packet with the file's name and length.
Uint8List zfile(String name, int length) => bytes([
      hexHeader(consts.ZFILE, 0, false),
      ZModemDataPacket.fileInfo(
        ZModemFileInfo(pathname: name, length: length, modificationTime: 1),
      ).encode(),
    ]);

/// ZDATA at [position]; the data packets follow it.
Uint8List zdata(int position) => hexHeader(consts.ZDATA, position, false);

/// One data packet. [end] is ZCRCG ("more follows") unless said otherwise.
Uint8List packet(List<int> data, [int end = consts.ZCRCG]) =>
    ZModemDataPacket(end, Uint8List.fromList(data)).encode();

Uint8List cans(int count) => Uint8List.fromList(List.filled(count, consts.CAN));

Uint8List bytes(List<List<int>> parts) {
  final builder = BytesBuilder();
  for (final part in parts) {
    builder.add(part);
  }
  return builder.toBytes();
}

/// File content that needs every kind of escape and holds runs of '*'.
Uint8List content(int length, [int seed = 1]) => Uint8List.fromList(
      List.generate(length, (i) {
        final v = (i * 31 + seed * 17) & 0xff;
        if (i % 97 == 0) return consts.ZDLE;
        if (i % 89 == 0) return consts.XON;
        if (i % 83 == 0) return consts.ZPAD;
        if (i % 79 == 0) return 0x7f;
        if (i % 73 == 0) return 0xff;
        return v;
      }),
    );

/// The whole of one file as the headband sends it once it has been asked
/// to start at [from]: ZDATA, the data in packets of [size], ZEOF.
Uint8List fileBody(Uint8List file, {int from = 0, int size = 1024}) {
  final parts = <List<int>>[zdata(from)];
  for (var at = from; at < file.length; at += size) {
    final end = at + size < file.length ? at + size : file.length;
    parts.add(packet(
      Uint8List.sublistView(file, at, end),
      end == file.length ? consts.ZCRCE : consts.ZCRCG,
    ));
  }
  if (from >= file.length) parts.add(packet(const [], consts.ZCRCE));
  parts.add(zeof(file.length));
  return bytes(parts);
}

/// The app's part: it accepts every offer at [resumeAt], keeps the data,
/// and confirms a file once all of it is there.
class Consumer {
  Consumer(this.rx);

  final ZReceiver rx;

  /// Where to start an offered file. Changed by a test that resumes.
  int resumeAt = 0;

  /// When set, the consumer does not behave: it answers offers and
  /// finished files as the dice fall (accept, skip, abort, or nothing
  /// at all), asks again after some bad packets, and now and then gives
  /// the session up. The dice are thrown once per event, so the same
  /// events draw the same answers however the bytes were delivered.
  Random? dice;

  final events = <ZRxEvent>[];
  final offers = <String>[];
  final ended = <ZEndReason>[];
  final started = <int>[];
  final sent = BytesBuilder();
  final file = BytesBuilder();
  int badPackets = 0;
  int? expectedLength;

  /// What the receiver has written back since the last call.
  Uint8List takeSent() {
    sent.add(rx.takeOutput());
    return sent.takeBytes();
  }

  /// Feeds [data], answering at each point where something happened, as
  /// a live sender's waits allow the app to.
  void feed(List<int> data) {
    var at = 0;
    while (at < data.length) {
      at = rx.receiveUntilEvent(data, at);
      handle(rx.takeEvents());
    }
    sent.add(rx.takeOutput());
  }

  /// Feeds [data] in deliveries of [size] bytes.
  void feedCut(List<int> data, int size) {
    for (var at = 0; at < data.length; at += size) {
      final end = at + size < data.length ? at + size : data.length;
      feed(data.sublist(at, end));
    }
  }

  void handle(List<ZRxEvent> happened) {
    for (final event in happened) {
      events.add(event);
      final dice = this.dice;
      if (dice != null) {
        _misbehave(event, dice.nextInt(100));
        sent.add(rx.takeOutput());
        continue;
      }
      if (event is ZRxSessionStarted) {
        started.add(event.session);
      } else if (event is ZRxOffer) {
        offers.add(event.fileInfo.pathname);
        expectedLength = event.fileInfo.length;
        file.clear();
        expect(rx.acceptFile(event.session, resumeAt), isTrue);
      } else if (event is ZRxData) {
        if (event.crcOk) {
          file.add(event.data);
          if (event.endType == consts.ZCRCQ || event.endType == consts.ZCRCW) {
            // The sender waits for this before it goes on.
            rx.ackFrame(event.session, resumeAt + file.length);
          }
        } else {
          badPackets++;
        }
      } else if (event is ZRxFileEnd) {
        expect(rx.ackFileEnd(event.session), isTrue);
      } else if (event is ZRxSessionEnded) {
        ended.add(event.reason);
      }
      sent.add(rx.takeOutput());
    }
  }
}

extension Misbehaving on Consumer {
  void _misbehave(ZRxEvent event, int roll) {
    if (event is ZRxSessionStarted) {
      started.add(event.session);
    } else if (event is ZRxSessionEnded) {
      ended.add(event.reason);
      return;
    } else if (event is ZRxOffer) {
      offers.add(event.fileInfo.pathname);
      file.clear();
      if (roll < 60) {
        rx.acceptFile(event.session, resumeAt);
      } else if (roll < 75) {
        rx.skipFile(event.session);
      } else if (roll < 85) {
        rx.abort(event.session);
      }
    } else if (event is ZRxData) {
      if (event.crcOk) {
        file.add(event.data);
        if (roll < 30) rx.ackFrame(event.session, file.length);
      } else {
        badPackets++;
        if (roll < 50) rx.reposition(event.session, file.length);
      }
    } else if (event is ZRxFileEnd) {
      if (roll < 60) {
        rx.ackFileEnd(event.session);
      } else if (roll < 80) {
        rx.abort(event.session);
      }
    }
    // Now and then the consumer gives up on whatever is open, and
    // now and then it answers for a session that is long over.
    if (roll % 20 == 7) rx.giveUp(event.session);
    if (roll % 20 == 13) rx.acceptFile(event.session - 1, 0);
    handle(rx.takeEvents());
  }
}

/// Whether [data] holds a cancel: five CAN bytes in a row.
bool holdsCancel(List<int> data) {
  var run = 0;
  for (final byte in data) {
    run = byte == consts.CAN ? run + 1 : 0;
    if (run >= 5) return true;
  }
  return false;
}

/// The types of the hex headers in [data], in order.
List<int> headerTypes(List<int> data) {
  final text = String.fromCharCodes(data);
  return RegExp(r'\*\*\x18B([0-9a-f]{2})')
      .allMatches(text)
      .map((m) => int.parse(m.group(1)!, radix: 16))
      .toList();
}

/// A complete session for one file, sent to a consumer that is idle:
/// it must be offered, received whole and finished.
void expectCleanSession(Consumer app, String name, Uint8List file) {
  final offersBefore = app.offers.length;
  final endedBefore = app.ended.length;
  final badBefore = app.badPackets;
  app.takeSent();

  app.feed(zrqinit());
  expect(headerTypes(app.takeSent()), [consts.ZRINIT], reason: 'ZRQINIT');
  app.feed(zfile(name, file.length));
  final answer = app.takeSent();
  expect(holdsCancel(answer), isFalse, reason: 'the offer is not refused');
  expect(headerTypes(answer), [consts.ZRPOS], reason: 'the offer is accepted');
  expect(app.offers.sublist(offersBefore), [name]);
  app.feed(fileBody(file, from: app.resumeAt));
  expect(headerTypes(app.takeSent()), [consts.ZRINIT, consts.ZFIN]);
  expect(app.file.toBytes(), file.sublist(app.resumeAt));
  expect(app.badPackets, badBefore);
  app.feed(zfin());
  expect(String.fromCharCodes(app.takeSent()), 'OO');
  expect(app.ended.sublist(endedBefore), [ZEndReason.delivered]);
  expect(app.rx.isIdle, isTrue);
}
