/// Properties of the new receiver that must hold for ANY input.
///
///  1. It never throws and never gets stuck: after any bytes at all, the
///     next complete session from the sender is taken, and its file comes
///     out whole.
///  2. What happens does not depend on how the bytes are cut into
///     deliveries.
///
/// The streams are random but repeatable (seeded), and are made of the
/// things a real stream is made of, whole and broken: headers, data
/// packets, cancels, escape bytes, line ends, noise.
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zmodem/src/consts.dart' as consts;
import 'package:zmodem/src/receiver.dart';

import 'receiver_wire.dart';

/// A real session, from its ZRQINIT on, broken off at a random byte: so
/// that what follows meets the receiver in every state it has.
Uint8List _brokenSession(Random random) {
  final whole = bytes([
    zrqinit(),
    zfile('s${random.nextInt(9)}.bin', 3000),
    fileBody(content(3000, random.nextInt(50))),
    zfin(),
  ]);
  return whole.sublist(0, random.nextInt(whole.length + 1));
}

/// A stream of [parts] fragments drawn from [random].
Uint8List _stream(Random random, int parts) {
  final out = BytesBuilder();
  if (random.nextInt(3) != 0) out.add(_brokenSession(random));
  for (var i = 0; i < parts; i++) {
    Uint8List piece;
    switch (random.nextInt(14)) {
      case 0:
        piece = zrqinit();
        break;
      case 1:
        piece = zfile('f${random.nextInt(9)}.bin', random.nextInt(5000));
        break;
      case 2:
        piece = zdata(random.nextInt(4096));
        break;
      case 3:
        piece = packet(
          content(random.nextInt(600), random.nextInt(50)),
          [
            consts.ZCRCG,
            consts.ZCRCG,
            consts.ZCRCE,
            consts.ZCRCQ,
            consts.ZCRCW
          ][random.nextInt(5)],
        );
        break;
      case 4:
        piece = zeof(random.nextInt(5000));
        break;
      case 5:
        piece = zfin();
        break;
      case 6:
        piece = cans(1 + random.nextInt(12));
        break;
      case 7:
        piece = hexHeader(random.nextInt(20), random.nextInt(1 << 20));
        break;
      case 8:
        // The start of a header and some of its digits.
        piece = zrqinit().sublist(0, 4 + random.nextInt(15));
        break;
      case 9:
        // The escape byte and whatever follows it.
        piece = Uint8List.fromList([consts.ZDLE, random.nextInt(256)]);
        break;
      case 10:
        piece =
            Uint8List.fromList(List.filled(1 + random.nextInt(4), consts.ZPAD));
        break;
      case 11:
        piece = Uint8List.fromList('\r\n\x11OO'.codeUnits);
        break;
      case 12:
        piece = _brokenSession(random);
        break;
      default:
        piece = Uint8List.fromList(
            List.generate(random.nextInt(40), (_) => random.nextInt(256)));
    }
    // Sometimes only the beginning of the piece gets out.
    if (piece.isNotEmpty && random.nextInt(4) == 0) {
      piece = piece.sublist(0, random.nextInt(piece.length + 1));
    }
    out.add(piece);
  }
  return out.toBytes();
}

/// Everything that happened and everything that was sent, as text.
List<String> _record(Consumer app) => [
      for (final event in app.events)
        event is ZRxData
            ? 'data ${event.session} ${event.crcOk} ${event.endType} '
                '${event.crc} ${event.data.join(",")}'
            : event.toString(),
      'sent ${app.takeSent().join(",")}',
      'ignored ${app.rx.ignoredBytes} bad ${app.rx.badHeaders}',
    ];

void main() {
  final file = content(3000, 4);

  test(
      'after any bytes at all, the next session is taken and its file '
      'comes out whole', () {
    for (var seed = 0; seed < 400; seed++) {
      final random = Random(seed);
      final app = Consumer(ZReceiver())..dice = Random(seed + 1);
      final garbage = _stream(random, 1 + random.nextInt(30));
      final size = [0, 1, 3, 244][random.nextInt(4)];
      if (size == 0) {
        app.feed(garbage);
      } else {
        app.feedCut(garbage, size);
      }

      // From here on the consumer behaves, and the sender is whole.
      app.dice = null;
      app.resumeAt = 0;
      app.feed(bytes([
        zrqinit(),
        zfile('wanted.bin', file.length),
        fileBody(file),
        zfin(),
      ]));

      final reason = 'seed $seed';
      expect(app.offers.last, 'wanted.bin', reason: reason);
      expect(app.file.toBytes(), file, reason: reason);
      expect(app.ended.last, ZEndReason.delivered, reason: reason);
      expect(app.rx.isIdle, isTrue, reason: reason);
    }
  });

  test('how the bytes are cut into deliveries changes nothing', () {
    for (var seed = 1000; seed < 1300; seed++) {
      final stream = _stream(Random(seed), 5 + Random(seed).nextInt(40));
      List<String>? whole;
      for (final size in [0, 1, 2, 7, 244]) {
        final app = Consumer(ZReceiver())..dice = Random(seed);
        if (size == 0) {
          app.feed(stream);
        } else {
          app.feedCut(stream, size);
        }
        final record = _record(app);
        whole ??= record;
        expect(record, whole, reason: 'seed $seed, deliveries of $size');
      }
    }
  });

  test(
      'a whole delivery taken at once and the same bytes taken one event '
      'at a time agree, when the consumer has nothing to answer', () {
    // With no offer and no file end in it, nothing waits on the consumer,
    // so receive() and receiveUntilEvent() must tell the same story.
    for (var seed = 2000; seed < 2200; seed++) {
      final random = Random(seed);
      final stream = bytes([
        for (var i = 0; i < 20; i++)
          [
            cans(1 + random.nextInt(9)),
            zrqinit(),
            zfin(),
            zdata(random.nextInt(99)),
            Uint8List.fromList(
                List.generate(random.nextInt(30), (_) => random.nextInt(256))),
          ][random.nextInt(5)],
      ]);
      final atOnce = ZReceiver();
      final stepped = ZReceiver();
      final a = atOnce.receive(stream).map((e) => e.toString()).toList();
      final b = <String>[];
      var at = 0;
      while (at < stream.length) {
        at = stepped.receiveUntilEvent(stream, at);
        b.addAll(stepped.takeEvents().map((e) => e.toString()));
      }
      expect(b, a, reason: 'seed $seed');
      expect(stepped.takeOutput(), atOnce.takeOutput(), reason: 'seed $seed');
    }
  });

  test('pure noise, a megabyte of it: nothing is reported, nothing is sent',
      () {
    final random = Random(7);
    final rx = ZReceiver();
    for (var i = 0; i < 4096; i++) {
      final noise =
          Uint8List.fromList(List.generate(256, (_) => random.nextInt(256)));
      expect(rx.receive(noise), isEmpty);
    }
    expect(rx.takeOutput(), isEmpty);
    expect(rx.isIdle, isTrue);
  });
}
