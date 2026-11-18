/// The new receiver against byte streams RECORDED FROM THE REAL FIRMWARE
/// SENDER (see fixture_replay_test.dart for where they come from), and
/// against the older receiver driven over the same streams.
///
/// Three things are held here:
///
///  * the file that comes out is the file that went in, byte for byte;
///  * what the receiver puts on the wire is, byte for byte, what the older
///    receiver puts on the wire when it is driven the way the app drives
///    it (ZRINIT and ZFIN together once the file is confirmed, "OO" for
///    the sender's goodbye);
///  * neither depends on how the stream is cut into deliveries.
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zmodem/zmodem.dart';

class _Case {
  final String fixture;
  final String source;
  final int offset;
  _Case(this.fixture, this.source, this.offset);
}

class _Result {
  final data = BytesBuilder();
  final outbound = BytesBuilder();
  final ended = <ZEndReason>[];
  int offers = 0;
  int badPackets = 0;
  ZModemFileInfo? fileInfo;
}

Iterable<Uint8List> _cut(Uint8List bytes, int size) sync* {
  if (size <= 0) {
    yield bytes;
    return;
  }
  for (var at = 0; at < bytes.length; at += size) {
    final end = at + size < bytes.length ? at + size : bytes.length;
    yield Uint8List.sublistView(bytes, at, end);
  }
}

/// The new receiver, with the consumer the app is: accept, take the data,
/// confirm the file.
_Result _new(Uint8List transcript, {int chunk = 0, int offset = 0}) {
  final rx = ZReceiver();
  final r = _Result();
  for (final piece in _cut(transcript, chunk)) {
    // A recording does not wait for answers as the headband did, so the
    // consumer answers at each point where something happened.
    var at = 0;
    while (at < piece.length) {
      at = rx.receiveUntilEvent(piece, at);
      for (final event in rx.takeEvents()) {
        if (event is ZRxOffer) {
          r.offers++;
          r.fileInfo = event.fileInfo;
          expect(rx.acceptFile(event.session, offset), isTrue);
        } else if (event is ZRxData) {
          if (!event.crcOk) r.badPackets++;
          r.data.add(event.data);
        } else if (event is ZRxFileEnd) {
          expect(rx.ackFileEnd(event.session), isTrue);
        } else if (event is ZRxSessionEnded) {
          r.ended.add(event.reason);
        }
      }
      r.outbound.add(rx.takeOutput());
    }
  }
  return r;
}

/// The older receiver, driven as the app's transfer manager drives it.
_Result _old(Uint8List transcript, {int chunk = 0, int offset = 0}) {
  ZModemState.lastHeader = null;
  ZModemState.lastSubPacket = null;
  final core = ZModemCore();
  final r = _Result();
  for (final piece in _cut(transcript, chunk)) {
    for (final event in core.receive(piece)) {
      if (event is ZFileOfferedEvent) {
        r.offers++;
        core.acceptFile(offset);
      } else if (event is ZFileDataEvent) {
        r.data.add(event.data);
      } else if (event is ZFileEndEvent) {
        if (core.ackFileEnd()) core.finishSession();
      } else if (event is ZSessionFinishedEvent) {
        r.ended.add(ZEndReason.delivered);
      }
      r.outbound.add(core.dataToSend());
    }
    r.outbound.add(core.dataToSend());
  }
  return r;
}

void main() {
  final dir = Directory('test/fixture/fw');
  Uint8List load(String name) => File('${dir.path}/$name').readAsBytesSync();

  final cases = [
    _Case('happy_2700.bin', 'src_fx_2700.bin', 0),
    _Case('happy_65536.bin', 'src_fx_65536.bin', 0),
    _Case('size_1024.bin', 'src_fx_1024.bin', 0),
    _Case('size_1025.bin', 'src_fx_1025.bin', 0),
    _Case('dedup_32x1k.bin', 'src_fx_dedup.bin', 0),
    _Case('resume_12345.bin', 'src_fx_65536.bin', 12345),
  ];

  // One buffer; the size of a BLE notification; an odd size; one byte.
  const chunkings = [0, 244, 17, 1];

  for (final c in cases) {
    for (final chunk in chunkings) {
      test('${c.fixture}: the file arrives whole (deliveries of $chunk)', () {
        final r = _new(load(c.fixture), chunk: chunk, offset: c.offset);

        expect(r.offers, 1);
        expect(r.badPackets, 0);
        expect(r.ended, [ZEndReason.delivered]);
        expect(r.data.toBytes(), load(c.source).sublist(c.offset));
      });

      test(
          '${c.fixture}: the wire carries what the older receiver sends '
          '(deliveries of $chunk)', () {
        final transcript = load(c.fixture);
        final was = _old(transcript, chunk: chunk, offset: c.offset);
        final now = _new(transcript, chunk: chunk, offset: c.offset);

        expect(was.ended, [ZEndReason.delivered], reason: 'the older receiver');
        expect(now.outbound.toBytes(), was.outbound.toBytes());
        expect(now.data.toBytes(), was.data.toBytes());
      });
    }
  }

  test('the offer carries the name, the length and the time', () {
    final r = _new(load('happy_2700.bin'));
    expect(r.fileInfo!.pathname, 'fx_2700.bin');
    expect(r.fileInfo!.length, 2700);
    expect(r.fileInfo!.modificationTime, greaterThan(1600000000));
  });

  test('what goes out for one file: ZRINIT, ZRPOS, ZRINIT, ZFIN, "OO"', () {
    final out =
        _new(load('resume_12345.bin'), offset: 12345).outbound.toBytes();
    final text = String.fromCharCodes(out);
    final headers = RegExp(r'\*\*\x18B([0-9a-f]{14})\r\n\x11')
        .allMatches(text)
        .map((m) => m.group(1)!.substring(0, 10))
        .toList();
    expect(headers, [
      '0100000003', // ZRINIT, full duplex + overlapped I/O
      '0939300000', // ZRPOS 12345, least significant byte first
      '0100000003', // ZRINIT: the file is confirmed
      '0800000000', // ZFIN: our side is closed
    ]);
    expect(text.endsWith('OO'), isTrue);
    expect(out.length, 4 * 21 + 2);
  });
}
