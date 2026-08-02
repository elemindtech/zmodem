/// Golden-transcript replay: byte streams RECORDED FROM THE REAL
/// FIRMWARE SENDER (RT685, fs_transfer_send over USB VCOM, the same
/// ezm core and dialect config used on BLE) are replayed through the
/// real [ZModemCore] receiver exactly as the app drives it.
///
/// These fixtures are the compatibility contract between a newer
/// firmware and THIS fielded receiver: if a change to this package
/// breaks any replay, a fleet of un-updated apps would break the same
/// way against shipping firmware.
///
/// Each transcript includes everything the wire carried: shell text
/// preamble, the "OOrz\r" link preamble, hex/binary headers with the
/// Elemind XON link marker, CRC16 data subpackets, teardown.
///
/// Recorded 2026-08-02 from firmware @ PR #970 (see
/// test/fixture/fw/manifest.json).
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

class ReplayResult {
  final data = BytesBuilder();
  final outbound = BytesBuilder();
  int offers = 0;
  int restarts = 0;
  bool finished = false;
  bool cancelled = false;
  ZModemFileInfo? fileInfo;
}

/// Replays [transcript] through a fresh core the way the app's
/// bluetooth interface does: feed a chunk, iterate events, drain
/// [ZModemCore.dataToSend] after processing.
ReplayResult replay(
  Uint8List transcript, {
  int chunkSize = 0,
  int acceptOffset = 0,
}) {
  // The fielded core keeps its duplicate-suppression state in STATICS
  // that outlive core instances (see dialect_pin_test.dart). Reset so
  // every replay is hermetic regardless of test order.
  ZModemState.lastHeader = null;
  ZModemState.lastSubPacket = null;

  final core = ZModemCore();
  final r = ReplayResult();

  void feed(Uint8List chunk) {
    for (final event in core.receive(chunk)) {
      if (event is ZFileOfferedEvent) {
        r.offers++;
        r.fileInfo = event.fileInfo;
        core.acceptFile(acceptOffset);
      } else if (event is ZFileDataEvent) {
        r.data.add(event.data);
      } else if (event is ZSessionFinishedEvent) {
        r.finished = true;
      } else if (event is ZSessionCancelEvent) {
        r.cancelled = true;
      } else if (event is ZSessionRestartEvent) {
        r.restarts++;
      }
      r.outbound.add(core.dataToSend());
    }
    r.outbound.add(core.dataToSend());
  }

  if (chunkSize <= 0) {
    feed(transcript);
  } else {
    for (var i = 0; i < transcript.length; i += chunkSize) {
      final end =
          i + chunkSize < transcript.length ? i + chunkSize : transcript.length;
      feed(Uint8List.sublistView(transcript, i, end));
    }
  }
  return r;
}

void main() {
  final dir = Directory('test/fixture/fw');

  Uint8List load(String name) =>
      File('${dir.path}/$name').readAsBytesSync();

  // The package's language level predates records; a tiny case class
  // keeps this file compatible with the fielded pubspec constraint.
  final cases = [
    _Case('happy_2700.bin', 'src_fx_2700.bin', 0),
    _Case('happy_65536.bin', 'src_fx_65536.bin', 0),
    _Case('size_1024.bin', 'src_fx_1024.bin', 0),
    _Case('size_1025.bin', 'src_fx_1025.bin', 0),
    _Case('dedup_32x1k.bin', 'src_fx_dedup.bin', 0),
    _Case('resume_12345.bin', 'src_fx_65536.bin', 12345),
  ];

  // The app delivers BLE payloads in arbitrary chunk sizes; the core
  // must be chunking-agnostic. 0 = one buffer.
  const chunkings = [0, 17, 1];

  for (final c in cases) {
    for (final chunk in chunkings) {
      test('${c.fixture} replays byte-identical (chunk=$chunk)', () {
        final transcript = load(c.fixture);
        final expected = load(c.source).sublist(c.offset);

        final r =
            replay(transcript, chunkSize: chunk, acceptOffset: c.offset);

        expect(r.cancelled, isFalse,
            reason: 'fielded receiver cancelled the session');
        expect(r.offers, 1);
        expect(r.finished, isTrue,
            reason: 'session did not reach ZSessionFinishedEvent');
        final got = r.data.toBytes();
        expect(got.length, expected.length);
        expect(got, expected,
            reason: 'delivered bytes differ from the source payload');
      });
    }
  }

  test('ZFILE metadata arrives with decimal size and mtime', () {
    final r = replay(load('happy_2700.bin'));
    expect(r.fileInfo, isNotNull);
    expect(r.fileInfo!.pathname, 'fx_2700.bin');
    expect(r.fileInfo!.length, 2700);
    // The ecosystem sends mtime as DECIMAL epoch seconds (a deliberate
    // deviation from the spec's octal); the fielded parser reads it
    // with int.parse. A plausible epoch proves it wasn't parsed octal.
    expect(r.fileInfo!.modificationTime, greaterThan(1600000000));
  });

  test('dedup landmine: 32 identical 1 KiB blocks all delivered', () {
    // The fielded receiver silently drops a subpacket whose (type, crc)
    // equal the previous one's (see dialect_pin_test.dart). A sender
    // that slices identical file blocks into identical subpackets
    // loses data with no error. This replay proves the firmware sender
    // varies its slicing so all 32 KiB survive that filter.
    final r = replay(load('dedup_32x1k.bin'));
    expect(r.data.toBytes().length, 32768);
  });

  test('resume: firmware honors a nonzero initial ZRPOS', () {
    final r = replay(load('resume_12345.bin'), acceptOffset: 12345);
    final expected = load('src_fx_65536.bin').sublist(12345);
    expect(r.data.toBytes(), expected);
  });
}
