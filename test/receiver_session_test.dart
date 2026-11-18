/// The new receiver's sessions: what it answers, what it tells the
/// consumer, and how it numbers what belongs together.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zmodem/src/consts.dart' as consts;
import 'package:zmodem/src/receiver.dart';

import 'receiver_wire.dart';

void main() {
  late ZReceiver rx;
  late Consumer app;
  final file = content(5000);

  setUp(() {
    rx = ZReceiver();
    app = Consumer(rx);
  });

  /// Takes the consumer to the middle of a file: session started, offer
  /// accepted, ZDATA and [packets] data packets of 1024 bytes taken.
  void midFile({int packets = 2}) {
    app.feed(zrqinit());
    app.feed(zfile('a.bin', file.length));
    app.feed(zdata(0));
    for (var i = 0; i < packets; i++) {
      app.feed(packet(file.sublist(i * 1024, (i + 1) * 1024)));
    }
    app.takeSent();
    expect(app.file.length, packets * 1024);
  }

  group('one file', () {
    test('offered, received whole, finished', () {
      expectCleanSession(app, 'a.bin', file);
      expect(app.started, [1]);
      expect(rx.ignoredBytes, 0, reason: 'nothing in a clean session is noise');
      expect(rx.badHeaders, 0);
    });

    for (final size in [1, 7, 244]) {
      test('the same in deliveries of $size', () {
        final stream = bytes([
          zrqinit(),
          zfile('a.bin', file.length),
          fileBody(file),
          zfin(),
        ]);
        app.feedCut(stream, size);

        expect(app.offers, ['a.bin']);
        expect(app.file.toBytes(), file);
        expect(app.ended, [ZEndReason.delivered]);
        expect(headerTypes(app.takeSent()), [
          consts.ZRINIT,
          consts.ZRPOS,
          consts.ZRINIT,
          consts.ZFIN,
        ]);
      });
    }

    test('resumed from where the consumer has it', () {
      app.resumeAt = 3000;
      expectCleanSession(app, 'a.bin', file);
    });

    test('a file with nothing in it: the end comes with no data', () {
      app.feed(zrqinit());
      app.feed(zfile('empty.bin', 0));
      app.takeSent();
      app.feed(zeof(0));
      expect(headerTypes(app.takeSent()), [consts.ZRINIT, consts.ZFIN]);
      app.feed(zfin());
      expect(app.ended, [ZEndReason.delivered]);
    });

    test('two files, one session each, numbered one after the other', () {
      expectCleanSession(app, 'a.bin', file);
      expectCleanSession(app, 'b.bin', content(300, 2));
      expect(app.started, [1, 2]);
      expect(rx.session, 3);
    });
  });

  group('the number of the session', () {
    test('every event carries it', () {
      expectCleanSession(app, 'a.bin', file);
      expect(app.events.map((e) => e.session).toSet(), {1});
    });

    test('a receiver starts numbering where it is told to', () {
      rx = ZReceiver(firstSession: 40);
      app = Consumer(rx);
      expectCleanSession(app, 'a.bin', file);
      expect(app.started, [40]);
    });

    test('an answer about a session that is over does nothing', () {
      app.feed(zrqinit());
      final offered = rx.receive(zfile('a.bin', file.length));
      final session = offered.whereType<ZRxOffer>().single.session;
      rx.receive(cans(8));
      expect(rx.isIdle, isTrue);
      rx.takeOutput();

      expect(rx.acceptFile(session, 0), isFalse);
      expect(rx.skipFile(session), isFalse);
      expect(rx.reposition(session, 0), isFalse);
      expect(rx.ackFrame(session, 0), isFalse);
      expect(rx.ackFileEnd(session), isFalse);
      expect(rx.abort(session), isFalse);
      expect(rx.takeOutput(), isEmpty, reason: 'nothing is sent');
    });

    test('an answer the receiver is not waiting for does nothing', () {
      app.feed(zrqinit());
      app.takeSent();
      expect(rx.acceptFile(rx.session, 0), isFalse, reason: 'no offer yet');
      expect(rx.ackFileEnd(rx.session), isFalse, reason: 'no file end yet');
      expect(rx.takeOutput(), isEmpty);
    });

    test('an old answer cannot touch the session that followed', () {
      // The offer of session 1 is with the consumer when the sender
      // starts over and offers again. The consumer's answer to the first
      // offer arrives late.
      app.feed(zrqinit());
      final first = rx.receive(zfile('a.bin', file.length));
      final old = first.whereType<ZRxOffer>().single.session;
      final second = rx.receive(bytes([zrqinit(), zfile('a.bin', 5000)]));
      final current = second.whereType<ZRxOffer>().single.session;
      rx.takeOutput();
      expect(current, old + 1);

      expect(rx.acceptFile(old, 1234), isFalse);
      expect(rx.takeOutput(), isEmpty);
      expect(rx.acceptFile(current, 0), isTrue);
      expect(headerTypes(rx.takeOutput()), [consts.ZRPOS]);
    });
  });

  group('the sender starts over', () {
    test('ZRQINIT said again before the offer: answered again, one session',
        () {
      app.feed(zrqinit());
      app.feed(zrqinit());
      app.feed(zrqinit());
      expect(headerTypes(app.takeSent()),
          [consts.ZRINIT, consts.ZRINIT, consts.ZRINIT]);
      expect(app.started, [1]);
      expect(app.ended, isEmpty);

      app.feed(zfile('a.bin', file.length));
      expect(holdsCancel(app.takeSent()), isFalse);
      expect(app.offers, ['a.bin']);
    });

    test(
        'between two data packets: the old session ends, the new offer is '
        'accepted', () {
      midFile();
      app.feed(zrqinit());

      expect(headerTypes(app.takeSent()), [consts.ZRINIT]);
      expect(app.ended, [ZEndReason.restartedBySender]);
      expect(app.started, [1, 2]);

      app.feed(zfile('a.bin', file.length));
      final answer = app.takeSent();
      expect(holdsCancel(answer), isFalse, reason: 'the offer is not refused');
      expect(headerTypes(answer), [consts.ZRPOS]);
    });

    test('in the middle of a data packet, at every byte of it', () {
      final whole = packet(file.sublist(2048, 3072));
      for (var cut = 0; cut <= whole.length; cut++) {
        rx = ZReceiver();
        app = Consumer(rx);
        midFile();

        app.feed(whole.sublist(0, cut));
        app.feed(zrqinit());
        expect(app.started.length, 2, reason: 'cut at $cut: a new session');
        expect(app.ended.last, ZEndReason.restartedBySender,
            reason: 'cut at $cut');
        expectCleanSessionAfterStart(app, 'a.bin', file);
      }
    });

    test('while an offer is with the consumer', () {
      app.feed(zrqinit());
      rx.receive(zfile('a.bin', file.length));
      app.feed(zrqinit());
      expect(app.ended, [ZEndReason.restartedBySender]);
      expectCleanSessionAfterStart(app, 'a.bin', file);
    });

    test('while a finished file is with the consumer', () {
      midFile(packets: 4);
      app.handle(rx.receive(packet(file.sublist(4096), consts.ZCRCE)));
      final end = rx.receive(zeof(file.length));
      expect(end.single, isA<ZRxFileEnd>());
      app.feed(zrqinit());
      expect(app.ended, [ZEndReason.restartedBySender]);
      expect(rx.ackFileEnd(end.single.session), isFalse,
          reason: 'the late confirmation is refused');
      expectCleanSessionAfterStart(app, 'a.bin', file);
    });

    // Firmware 2.4.15 sends the goodbye of one file and the ZRQINIT of the
    // next back to back. The older receiver answered the ZRQINIT and was
    // then rebuilt by its consumer, so the offer that followed met a
    // receiver that knew of no session and was refused.
    test(
        'the goodbye of one file and the start of the next in one '
        'delivery: the next offer is accepted', () {
      app.feed(zrqinit());
      app.feed(zfile('a.bin', file.length));
      app.feed(fileBody(file));
      app.takeSent();

      app.feed(bytes([zfin(), zrqinit()]));
      final sent = app.takeSent();
      expect(String.fromCharCodes(sent).startsWith('OO'), isTrue);
      expect(headerTypes(sent), [consts.ZRINIT]);
      expect(app.ended, [ZEndReason.delivered]);
      expect(app.started, [1, 2]);

      expectCleanSessionAfterStart(app, 'b.bin', content(700, 3));
    });

    test(
        'with the file confirmed but no goodbye: the old session counts '
        'as finished', () {
      app.feed(zrqinit());
      app.feed(zfile('a.bin', file.length));
      app.feed(fileBody(file));
      app.feed(zrqinit());
      expect(app.ended, [ZEndReason.delivered]);
      expect(app.started, [1, 2]);
    });
  });

  group('goodbyes', () {
    // A skip tells the sender the receiver has the file. Released
    // firmware ends the session with its run of CANs after that; the
    // protocol's own way is a goodbye. Either way the session ended as a
    // skip, not as a cancel.
    Consumer skipped() {
      app.feed(zrqinit());
      final offer = rx.receive(zfile('a.bin', file.length)).single;
      rx.takeOutput();
      expect(rx.skipFile(offer.session), isTrue);
      expect(headerTypes(rx.takeOutput()), [consts.ZSKIP]);
      app.takeSent();
      return app;
    }

    test(
        'a skipped file, then the run of CANs firmware sends: ended as '
        'skipped', () {
      skipped().feed(cans(8));
      expect(app.ended, [ZEndReason.skipped]);
      expect(app.takeSent(), isEmpty);
      expectCleanSession(app, 'b.bin', content(400, 2));
    });

    test('a skipped file, then a goodbye: returned, ended as skipped', () {
      skipped().feed(zfin());
      expect(headerTypes(app.takeSent()), [consts.ZFIN]);
      expect(app.ended, [ZEndReason.skipped]);
    });

    test(
        'a skipped file, then the next ZRQINIT with nothing in between: '
        'the skip is over and a new session has begun', () {
      skipped();
      final old = rx.session;
      app.feed(zrqinit());
      expect(app.ended, [ZEndReason.skipped]);
      expect(app.started, [old, old + 1]);
      expect(headerTypes(app.takeSent()), [consts.ZRINIT]);

      // An answer meant for the skipped file cannot land on the next.
      final next = rx.receive(zfile('b.bin', 300)).single;
      expect(next.session, old + 1);
      expect(rx.acceptFile(old, 0), isFalse);
      expect(rx.acceptFile(next.session, 0), isTrue);
    });

    test(
        'a skipped file, then another offer in the same session: '
        'refused', () {
      skipped().feed(zfile('b.bin', 300));
      expect(holdsCancel(app.takeSent()), isTrue);
      expect(app.ended, [ZEndReason.refused]);
    });

    test('a goodbye said again when nothing is open is returned, quietly', () {
      expectCleanSession(app, 'a.bin', file);
      final before = app.events.length;
      app.feed(zfin());
      expect(headerTypes(app.takeSent()), [consts.ZFIN]);
      expect(app.events.length, before);
    });
  });

  group('what does not fit is refused', () {
    test('an offer with no ZRQINIT before it: a cancel, once', () {
      app.feed(zfile('a.bin', file.length));
      final first = app.takeSent();
      expect(holdsCancel(first), isTrue);
      expect(first.length, 5);
      expect(app.offers, isEmpty);
      expect(rx.isIdle, isTrue);

      app.feed(zfile('a.bin', file.length));
      expect(app.takeSent(), isEmpty, reason: 'the same again is passed over');
      expectCleanSession(app, 'a.bin', file);
    });

    test(
        'a file this receiver is not taking: its data is passed over, its '
        'end is refused, and the next session works', () {
      final other = content(3000, 9);
      app.feed(fileBody(other));
      final sent = app.takeSent();
      expect(app.events, isEmpty);
      expect(sent, [...cans(5), ...cans(5)],
          reason: 'one cancel for the ZDATA, one for the ZEOF');
      expect(rx.ignoredBytes, greaterThan(2900));
      expectCleanSession(app, 'a.bin', file);
    });

    test('a header that has no place in the session ends it', () {
      app.feed(zrqinit());
      app.takeSent();
      app.feed(zdata(0));
      expect(holdsCancel(app.takeSent()), isTrue);
      expect(app.ended, [ZEndReason.refused]);
      expectCleanSession(app, 'a.bin', file);
    });

    test('an offer whose check does not match is refused, never skipped', () {
      final offer = zfile('a.bin', file.length);
      offer[offer.length - 1] ^= 0x01;
      app.feed(zrqinit());
      app.takeSent();
      app.feed(offer);
      final sent = app.takeSent();
      expect(holdsCancel(sent), isTrue);
      expect(headerTypes(sent), isEmpty);
      expect(app.offers, isEmpty);
      expect(app.ended, [ZEndReason.refused]);
    });

    test(
        'the end of a file said again while it is with the consumer: '
        'nothing', () {
      midFile(packets: 4);
      app.handle(rx.receive(packet(file.sublist(4096), consts.ZCRCE)));
      final first = rx.receive(zeof(file.length));
      final again = rx.receive(zeof(file.length));
      expect(first.single, isA<ZRxFileEnd>());
      expect(again, isEmpty);
      expect(rx.takeOutput(), isEmpty);
      expect(rx.ackFileEnd(first.single.session), isTrue);
    });
  });

  group("the consumer's own endings", () {
    test('abort at the end of a file: a cancel, and the session is over', () {
      midFile(packets: 4);
      final end = rx.receive(zeof(file.length)).single;
      expect(rx.abort(end.session), isTrue);
      expect(rx.takeOutput(), cans(5));
      expect(rx.takeEvents().single.toString(),
          'ZRxSessionEnded(1, abortedByReceiver)');
      expectCleanSession(app, 'a.bin', file);
    });

    test(
        'giving a file up sends nothing; what the sender still sends is '
        'passed over and its end refused', () {
      midFile();
      expect(rx.giveUp(rx.session), isTrue);
      app.handle(rx.takeEvents());
      expect(app.ended, [ZEndReason.givenUp]);
      expect(app.takeSent(), isEmpty);

      for (var at = 2048; at < 4096; at += 1024) {
        app.feed(packet(file.sublist(at, at + 1024)));
      }
      app.feed(packet(file.sublist(4096), consts.ZCRCE));
      expect(app.takeSent(), isEmpty, reason: 'data alone draws no answer');
      app.feed(zeof(file.length));
      expect(app.takeSent(), cans(5));

      app.resumeAt = 2048;
      expectCleanSession(app, 'a.bin', file);
    });

    test(
        'giving up on a session that is over does not end the one that '
        'followed', () {
      midFile();
      final old = rx.session;
      app.feed(zrqinit());
      expect(rx.session, old + 1);
      expect(rx.giveUp(old), isFalse);
      expect(rx.takeEvents(), isEmpty);
      expectCleanSessionAfterStart(app, 'a.bin', file);
    });

    test('giving up with nothing open does nothing', () {
      expect(rx.giveUp(rx.session), isFalse);
      expect(rx.takeEvents(), isEmpty);
    });

    test(
        'a packet that fails its check: the consumer asks again, what is '
        'on its way is passed over, and the file still comes out right', () {
      midFile();
      final bad = packet(file.sublist(2048, 3072));
      bad[10] ^= 0x20;
      final event = rx.receive(bad).single as ZRxData;
      expect(event.crcOk, isFalse);

      expect(rx.reposition(event.session, 2048), isTrue);
      expect(headerTypes(rx.takeOutput()), [consts.ZRPOS]);
      // Two more packets were already on their way.
      expect(rx.receive(packet(file.sublist(3072, 4096))), isEmpty);
      expect(rx.receive(packet(file.sublist(4096), consts.ZCRCE)), isEmpty);

      app.feed(fileBody(file, from: 2048));
      expect(app.events.whereType<ZRxDataStart>().last.offset, 2048);
      expect(app.file.toBytes(), file);
      expect(headerTypes(app.takeSent()), [consts.ZRINIT, consts.ZFIN]);
    });

    test(
        'flow-control marks of the link inside a data packet are not '
        'file data', () {
      // A sender escapes these four values when they occur in a file,
      // so one that arrives bare was put there by the link.
      midFile();
      final data = file.sublist(2048, 2148);
      final wire = packet(data).toList()
        ..insert(40, 0x93)
        ..insert(30, 0x91)
        ..insert(20, consts.XOFF)
        ..insert(10, consts.XON);
      final event = rx.receive(wire).single as ZRxData;
      expect(event.crcOk, isTrue);
      expect(event.data, data);
    });

    test('a packet that asks for an acknowledgement can be given one', () {
      midFile();
      final event =
          rx.receive(packet(file.sublist(2048, 3072), consts.ZCRCQ)).single;
      expect(rx.ackFrame(event.session, 3072), isTrue);
      expect(headerTypes(rx.takeOutput()), [consts.ZACK]);
      // More follows a ZCRCQ packet without a header.
      expect(
          rx.receive(packet(file.sublist(3072, 4096))).single, isA<ZRxData>());
    });
  });

  group('what is not a header is not acted on', () {
    test('a header whose check does not match', () {
      final header = zrqinit();
      header[6] = 0x31; // a digit changed
      app.feed(header);
      expect(app.takeSent(), isEmpty);
      expect(app.events, isEmpty);
      expect(rx.badHeaders, 1);
      expectCleanSession(app, 'a.bin', file);
    });

    test(
        'a header with something that is no digit in it; a real header '
        'that begins right there is still seen', () {
      final broken = zrqinit().sublist(0, 9); // "**", ZDLE, 'B', five digits
      app.feed(bytes([broken, zrqinit()]));
      expect(headerTypes(app.takeSent()), [consts.ZRINIT]);
      expect(app.started, [1]);
    });

    test('a header with no line end', () {
      final header = zrqinit().sublist(0, 18); // digits complete, no CR LF
      app.feed(bytes([header, 'xyz'.codeUnits]));
      expect(app.takeSent(), isEmpty);
      expect(app.events, isEmpty);
      expectCleanSession(app, 'a.bin', file);
    });

    test('a header that ends in LF alone, or in CR LF with no XON', () {
      final lfOnly = [...zrqinit().sublist(0, 18), consts.LF];
      app.feed(lfOnly);
      expect(headerTypes(app.takeSent()), [consts.ZRINIT]);
      app.feed(hexHeader(consts.ZFIN, 0, false));
      expect(headerTypes(app.takeSent()), [consts.ZFIN]);
    });

    test('a binary header (the firmware sends none) is passed over', () {
      app.feed([consts.ZPAD, consts.ZDLE, consts.ZBIN, 0, 0, 0, 0, 0, 0, 0]);
      expect(app.takeSent(), isEmpty);
      expect(app.events, isEmpty);
      expectCleanSession(app, 'a.bin', file);
    });

    test(
        'a data packet with no end in sight is reported as bad, once it '
        'ends', () {
      midFile();
      final long = Uint8List(ZReceiver.maxPacket + 500);
      final event = rx.receive(packet(long)).single as ZRxData;
      expect(event.crcOk, isFalse);
      expect(event.data.length, ZReceiver.maxPacket);
    });
  });

  // The firmware up to 2.6.1 frames a session differently from the
  // firmware the recorded transcripts come from: "rz" and a carriage
  // return before ZRQINIT, XON after EVERY hex header (so a bare XON is
  // the first byte where the offer's packet and the first data packet
  // are read), XON after a packet that waits for an acknowledgement, the
  // last data packet ending that way, and "OO" after its goodbye.
  group('a session as firmware 2.4.15 frames it', () {
    Uint8List withXon(Uint8List header) => bytes([
          header,
          [consts.XON],
        ]);

    void run(int size) {
      final sent = BytesBuilder();
      void say(Uint8List wire) {
        if (size == 0) {
          app.feed(wire);
        } else {
          app.feedCut(wire, size);
        }
        sent.add(app.takeSent());
      }

      say(bytes(['rz\r'.codeUnits, zrqinit()]));
      say(bytes([
        withXon(hexHeader(consts.ZFILE, 0, false)),
        zfile('a.bin', file.length)
            .sublist(hexHeader(consts.ZFILE, 0, false).length),
        [consts.XON],
      ]));
      say(bytes([
        withXon(zdata(0)),
        packet(file.sublist(0, 1024)),
        packet(file.sublist(1024, 2048)),
        packet(file.sublist(2048), consts.ZCRCW),
        [consts.XON],
      ]));
      say(zeof(file.length));
      say(bytes([zfin(), 'OO'.codeUnits]));

      expect(app.offers, ['a.bin']);
      expect(app.badPackets, 0);
      expect(app.file.toBytes(), file);
      expect(app.ended, [ZEndReason.delivered]);
      final out = sent.toBytes();
      expect(headerTypes(out), [
        consts.ZRINIT,
        consts.ZRPOS,
        consts.ZACK, // for the last packet, which waits for it
        consts.ZRINIT,
        consts.ZFIN,
      ]);
      expect(holdsCancel(out), isFalse);
    }

    test('in whole deliveries', () => run(0));
    test('one byte per delivery', () => run(1));
    test('in deliveries of 244', () => run(244));
  });

  // The consumer answers when it gets to it, and that can be between
  // two deliveries that carry the two halves of a header. Its call must
  // not make the receiver forget the half it has.
  group('the consumer calls in the middle of a header', () {
    for (var cut = 1; cut < zrqinit().length - 1; cut++) {
      test('asking for data again, the next ZDATA cut at byte $cut', () {
        midFile();
        final header = zdata(2048);
        if (cut >= header.length) return;
        app.feed(header.sublist(0, cut));
        expect(rx.reposition(rx.session, 2048), isTrue);
        rx.takeOutput();
        final events = rx.receive(header.sublist(cut));
        expect(events.single, isA<ZRxDataStart>(), reason: 'cut at $cut');
      });

      test('giving up, the next ZRQINIT cut at byte $cut', () {
        midFile();
        final header = zrqinit();
        app.feed(header.sublist(0, cut));
        expect(rx.giveUp(rx.session), isTrue);
        app.handle(rx.takeEvents());
        app.feed(header.sublist(cut));
        expect(app.started.length, 2, reason: 'cut at $cut');
        expect(headerTypes(app.takeSent()).last, consts.ZRINIT);
      });
    }

    test(
        'the sender broke off after a packet\'s end mark and its header '
        'begins where the check bytes were read: asking for the data '
        'again does not lose it', () {
      midFile();
      final whole = packet(file.sublist(2048, 3072));
      // Everything up to and including the end mark, then ZRQINIT.
      app.rx.receive(whole.sublist(0, whole.length - 2));
      final header = zrqinit();
      final bad = rx.receive(header.sublist(0, 2)).single as ZRxData;
      expect(bad.crcOk, isFalse, reason: '"**" was read as the check');
      expect(rx.reposition(bad.session, 2048), isTrue);
      rx.takeOutput();

      app.feed(header.sublist(2));
      expect(app.ended, [ZEndReason.restartedBySender]);
      expect(headerTypes(app.takeSent()), [consts.ZRINIT]);
    });
  });

  group('a header where file data was expected', () {
    // The sender left its data packet unfinished to say something else.
    // What it says is acted on; the unfinished packet is dropped.
    final half = packet(file.sublist(2048, 3072)).sublist(0, 400);

    test(
        'the end of the file: reported, with the unfinished packet '
        'dropped', () {
      midFile();
      app.feed(half);
      final end = rx.receive(zeof(file.length)).single as ZRxFileEnd;
      expect(end.position, file.length);
      expect(app.file.length, 2048);
    });

    test('a new run of data: taken from where it says', () {
      midFile();
      app.feed(half);
      app.feed(fileBody(file, from: 2048));
      expect(app.events.whereType<ZRxDataStart>().last.offset, 2048);
      expect(app.file.toBytes(), file);
    });

    test(
        'a goodbye: returned, and the session is over with nothing '
        'delivered', () {
      midFile();
      app.feed(half);
      app.feed(zfin());
      expect(headerTypes(app.takeSent()), [consts.ZFIN]);
      expect(app.ended, [ZEndReason.closedBySender]);
    });

    test('an offer: refused', () {
      midFile();
      app.feed(half);
      app.feed(zfile('b.bin', 10));
      expect(holdsCancel(app.takeSent()), isTrue);
      expect(app.ended, [ZEndReason.refused]);
    });
  });

  group('file data that looks like the start of a header stays file data', () {
    // A sender that escapes every control character writes the byte 0x02
    // as the escape byte followed by 'B'. After two '*' that is, on the
    // wire, exactly how a hex header begins.
    Uint8List packetWith(List<int> wire, List<int> decoded) {
      final crc = CRC16Of(decoded, consts.ZCRCG);
      return bytes([
        wire,
        [consts.ZDLE, consts.ZCRCG, crc >> 8, crc & 0xff],
      ]);
    }

    void expectData(List<int> wire, List<int> decoded) {
      midFile();
      final event = rx.receive(packetWith(wire, decoded)).single as ZRxData;
      expect(event.data, decoded);
      expect(event.crcOk, isTrue);
      expect(app.ended, isEmpty);
    }

    test('followed by something that is no digit', () {
      expectData(
        [1, 2, 0x2a, 0x2a, consts.ZDLE, 0x42, 0x39, 0x47, 5],
        [1, 2, 0x2a, 0x2a, 0x02, 0x39, 0x47, 5],
      );
    });

    test('followed by fourteen digits whose check does not match', () {
      final digits = '0123456789abcd'.codeUnits;
      expectData(
        [0x2a, 0x2a, consts.ZDLE, 0x42, ...digits, 7, 8],
        [0x2a, 0x2a, 0x02, ...digits, 7, 8],
      );
    });

    test('followed by a whole header but for its line end', () {
      final header = zrqinit().sublist(4, 18); // the fourteen digits
      expectData(
        [0x2a, 0x2a, consts.ZDLE, 0x42, ...header, 0x55],
        [0x2a, 0x2a, 0x02, ...header, 0x55],
      );
    });

    test('cut short by the end of the packet', () {
      expectData(
        [9, 0x2a, 0x2a, 0x2a, consts.ZDLE, 0x42, 0x30, 0x30],
        [9, 0x2a, 0x2a, 0x2a, 0x02, 0x30, 0x30],
      );
    });

    test('twice in a row', () {
      expectData(
        [0x2a, 0x2a, consts.ZDLE, 0x42, 0x2a, 0x2a, consts.ZDLE, 0x42, 0x40],
        [0x2a, 0x2a, 0x02, 0x2a, 0x2a, 0x02, 0x40],
      );
    });
  });
}

/// The rest of a clean session for a consumer whose ZRQINIT has just been
/// answered.
void expectCleanSessionAfterStart(Consumer app, String name, Uint8List file) {
  final endedBefore = app.ended.length;
  app.takeSent();
  app.feed(zfile(name, file.length));
  final answer = app.takeSent();
  expect(holdsCancel(answer), isFalse, reason: 'the offer is not refused');
  expect(headerTypes(answer), [consts.ZRPOS]);
  app.feed(fileBody(file, from: app.resumeAt));
  expect(headerTypes(app.takeSent()), [consts.ZRINIT, consts.ZFIN]);
  expect(app.file.toBytes(), file.sublist(app.resumeAt));
  app.feed(zfin());
  expect(app.ended.sublist(endedBefore), [ZEndReason.delivered]);
}

/// CRC-16 of [data] followed by the packet's end type.
// ignore: non_constant_identifier_names
int CRC16Of(List<int> data, int endType) {
  var crc = 0;
  for (final b in [...data, endType]) {
    crc ^= b << 8;
    for (var i = 0; i < 8; i++) {
      crc = ((crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1) & 0xffff;
    }
  }
  return crc;
}
