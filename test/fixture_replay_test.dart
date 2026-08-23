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
      } else if (event is ZFileEndEvent) {
        // The receiver no longer auto-acks ZEOF; the app acks once the
        // bytes are durably stored. Replay the happy path: ack immediately
        // so the outbound stream (and its post-ZEOF ZRINIT) is unchanged.
        core.ackFileEnd();
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

/// Scans [outbound] for receiver hex headers and decodes each to
/// `[type, p0, p1, p2, p3]`.
///
/// Every header the receiver sends in these replays is hex format
/// (ZModemHeader.toHex): '**' ZDLE 'B', 14 lowercase-hex chars
/// (type, p0..p3, CRC16), then CR LF and the Elemind XON link
/// marker — 21 bytes total. The CRC and trailer are verified here so
/// a malformed header fails loudly instead of decoding garbage.
List<List<int>> decodeHexHeaders(Uint8List outbound) {
  final headers = <List<int>>[];
  var i = 0;
  while (i + 4 <= outbound.length) {
    final isHexHeader = outbound[i] == ZPAD &&
        outbound[i + 1] == ZPAD &&
        outbound[i + 2] == ZDLE &&
        outbound[i + 3] == ZHEX;
    if (!isHexHeader) {
      i++;
      continue;
    }
    expect(outbound.length - i, greaterThanOrEqualTo(21),
        reason: 'truncated hex header at outbound offset $i');
    final bytes = <int>[];
    for (var k = 0; k < 7; k++) {
      final hex = String.fromCharCodes(outbound, i + 4 + 2 * k, i + 6 + 2 * k);
      bytes.add(int.parse(hex, radix: 16));
    }
    final crc = CRC16()
      ..updateAll(bytes.sublist(0, 5))
      ..finalize();
    expect((bytes[5] << 8) | bytes[6], crc.value,
        reason: 'bad CRC16 on outbound header at offset $i');
    expect(outbound.sublist(i + 18, i + 21), [CR, LF, XON],
        reason: 'outbound header at offset $i lacks the CR LF XON trailer');
    headers.add(bytes.sublist(0, 5));
    i += 21;
  }
  return headers;
}

/// The receiver's complete expected outbound for a clean single-file
/// replay accepted at [offset], derived from the core:
///
/// 1. ZRINIT reply to the sender's ZRQINIT — capability flags in p3
///    (ZModemHeader.rinit), exactly CANFDX|CANOVIO.
/// 2. ZRPOS from acceptFile — offset little-endian, p0 = LSB
///    (ZModemHeader._littleEndian).
/// 3. The ZRINIT re-send after ZEOF, byte-identical to the first.
/// 4. The ZFIN echo answering the sender's ZFIN. The receiver role
///    never emits 'OO' (that belongs to the sender-role close), so
///    these four headers are the ENTIRE outbound stream.
List<List<int>> expectedOutboundHeaders(int offset) => [
      [ZRINIT, 0, 0, 0, CANFDX | CANOVIO],
      [
        ZRPOS,
        offset & 0xff,
        (offset >> 8) & 0xff,
        (offset >> 16) & 0xff,
        (offset >> 24) & 0xff,
      ],
      [ZRINIT, 0, 0, 0, CANFDX | CANOVIO],
      [ZFIN, 0, 0, 0, 0],
    ];

void main() {
  final dir = Directory('test/fixture/fw');

  Uint8List load(String name) => File('${dir.path}/$name').readAsBytesSync();

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

        final r = replay(transcript, chunkSize: chunk, acceptOffset: c.offset);

        expect(r.cancelled, isFalse,
            reason: 'fielded receiver cancelled the session');
        expect(r.offers, 1);
        expect(r.finished, isTrue,
            reason: 'session did not reach ZSessionFinishedEvent');
        final got = r.data.toBytes();
        expect(got.length, expected.length);
        expect(got, expected,
            reason: 'delivered bytes differ from the source payload');

        // The receive direction is only half the contract: the
        // firmware sender equally depends on what this receiver puts
        // on the wire. Pin the exact outbound header sequence and
        // parameter bytes for every fixture and chunking.
        final outbound = r.outbound.toBytes();
        final headers = decodeHexHeaders(outbound);
        expect(headers, expectedOutboundHeaders(c.offset),
            reason: 'receiver outbound header sequence changed');
        expect(outbound.length, headers.length * 21,
            reason: 'receiver emitted bytes outside the expected '
                'hex headers');
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

  test(
      'outbound: opening ZRINIT flags are exactly CANFDX|CANOVIO, '
      'and the post-ZEOF re-send is byte-identical to it', () {
    final r = replay(load('happy_2700.bin'));
    final headers = decodeHexHeaders(r.outbound.toBytes());
    final rinits = headers.where((h) => h[0] == ZRINIT).toList();
    expect(rinits, hasLength(2),
        reason: 'expected the opening ZRINIT and the re-send after ZEOF');
    expect(rinits[0], [ZRINIT, 0, 0, 0, CANFDX | CANOVIO],
        reason: 'capability flags live in p3 and must not grow or '
            'shrink: the firmware sender is designed against exactly '
            'full-duplex + overlapped-I/O, CRC16, no control escaping');
    expect(rinits[1], rinits[0],
        reason: 'the ZRINIT after ZEOF must parse identically to the '
            'opening one');
    // The re-send must come after the ZRPOS (i.e. after the transfer
    // began), not be a startup duplicate.
    expect(headers.indexWhere((h) => h[0] == ZRPOS), 1);
    expect(headers.lastIndexWhere((h) => h[0] == ZRINIT), 2);
    expect(headers.indexWhere((h) => h[0] == ZFIN), 3);
  });

  test(
      'outbound: resume ZRPOS encodes offset 12345 little-endian '
      '(p0 = LSB)', () {
    final r = replay(load('resume_12345.bin'), acceptOffset: 12345);
    final headers = decodeHexHeaders(r.outbound.toBytes());
    final rpos = headers.where((h) => h[0] == ZRPOS).toList();
    // 12345 = 0x3039 -> p0=0x39 p1=0x30 p2=0x00 p3=0x00 on the wire.
    expect(rpos, [
      [ZRPOS, 0x39, 0x30, 0x00, 0x00],
    ]);
  });
}
