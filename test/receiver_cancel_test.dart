/// A cancel from the sender is five or more CAN bytes in a row. The new
/// receiver must act on it as its fifth CAN arrives, exactly once, wherever
/// it falls and however it is cut into deliveries, and must be ready for
/// the sender's next session straight after.
///
/// What released headband firmware sends for one failed or cancelled send:
/// 8 CANs in one delivery (up to 2.6.1, and 2.6.4 on); 10 (5 + 5, the
/// second five one byte per delivery) or 16 on 2.6.2 and 2.6.3.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zmodem/src/consts.dart' as consts;
import 'package:zmodem/src/receiver.dart';

import 'receiver_wire.dart';

/// How a run of CANs reaches the receiver.
enum _Cut { whole, byteByByte, fiveThenRest }

void _deliver(Consumer app, Uint8List run, _Cut cut) {
  switch (cut) {
    case _Cut.whole:
      app.feed(run);
      break;
    case _Cut.byteByByte:
      app.feedCut(run, 1);
      break;
    case _Cut.fiveThenRest:
      app.feed(run.sublist(0, 5));
      if (run.length > 5) app.feedCut(run.sublist(5), 1);
      break;
  }
}

void main() {
  final file = content(4000);

  /// Brings a fresh consumer to a named point of a session.
  final stages = <String, void Function(Consumer)>{
    'waiting for the offer': (app) {
      app.feed(zrqinit());
    },
    'the offer is with the consumer': (app) {
      app.feed(zrqinit());
      app.rx.receive(zfile('a.bin', file.length));
    },
    'waiting for the data to start': (app) {
      app.feed(zrqinit());
      app.feed(zfile('a.bin', file.length));
    },
    'between two data packets': (app) {
      app.feed(zrqinit());
      app.feed(zfile('a.bin', file.length));
      app.feed(zdata(0));
      app.feed(packet(file.sublist(0, 1024)));
    },
    'the finished file is with the consumer': (app) {
      app.feed(zrqinit());
      app.feed(zfile('a.bin', file.length));
      final body = fileBody(file);
      app.rx.receive(body);
    },
    'the file is confirmed, the goodbye has not come': (app) {
      app.feed(zrqinit());
      app.feed(zfile('a.bin', file.length));
      app.feed(fileBody(file));
    },
  };

  for (final stage in stages.entries) {
    group('a cancel while ${stage.key}', () {
      for (var length = 5; length <= 16; length++) {
        for (final cut in _Cut.values) {
          test('$length CANs, ${cut.name}', () {
            final app = Consumer(ZReceiver());
            stage.value(app);
            app.takeSent();
            app.rx.takeEvents();
            final endedBefore = app.ended.length;

            _deliver(app, cans(length), cut);

            expect(
                app.ended.sublist(endedBefore), [ZEndReason.cancelledBySender],
                reason: 'reported once');
            expect(app.takeSent(), isEmpty, reason: 'nothing is sent back');
            expect(app.rx.isIdle, isTrue);
            expectCleanSession(app, 'b.bin', content(900, 5));
          });
        }
      }
    });
  }

  group('a cancel with no session open', () {
    for (final length in [5, 8, 10, 16]) {
      test('$length CANs: nothing is reported and nothing is sent', () {
        final app = Consumer(ZReceiver());
        app.feedCut(cans(length), 1);
        expect(app.events, isEmpty);
        expect(app.takeSent(), isEmpty);
        expectCleanSession(app, 'a.bin', file);
      });
    }
  });

  group('fewer than five CANs are no cancel', () {
    test('four, between frames', () {
      final app = Consumer(ZReceiver());
      app.feed(zrqinit());
      app.feed(cans(4));
      app.feed(zfile('a.bin', file.length));
      expect(app.ended, isEmpty);
      expect(app.offers, ['a.bin']);
    });

    test('five that are not in a row', () {
      final app = Consumer(ZReceiver());
      app.feed(zrqinit());
      app.feed([...cans(3), 0x41, ...cans(2)]);
      expect(app.ended, isEmpty);
    });
  });

  // The sender breaks off wherever it happens to be. Every byte position
  // of everything it sends in a session is tried as the place where the
  // CANs begin.
  group('a cancel that cuts into what the sender was saying', () {
    final pieces = <String, Uint8List>{
      'the offer': zfile('a.bin', file.length),
      'the start of the data': zdata(0),
      'a data packet': packet(content(300, 7)),
      'the end of the file': bytes([
        packet(file.sublist(0, 200), consts.ZCRCE),
        zeof(200),
      ]),
    };

    /// What must have been said before [piece] for it to be in place.
    void lead(Consumer app, String piece) {
      app.feed(zrqinit());
      if (piece == 'the offer') return;
      app.feed(zfile('a.bin', file.length));
      if (piece == 'the start of the data') return;
      app.feed(zdata(0));
    }

    for (final piece in pieces.entries) {
      for (final length in [5, 8, 10]) {
        test('${piece.key}, cut at every byte, $length CANs', () {
          for (var at = 0; at <= piece.value.length; at++) {
            for (final cut in [_Cut.whole, _Cut.byteByByte]) {
              final app = Consumer(ZReceiver());
              lead(app, piece.key);
              app.takeSent();
              final reason = '${piece.key} cut at $at, ${cut.name}';

              app.feed(piece.value.sublist(0, at));
              final endedBefore = app.ended.length;
              _deliver(app, cans(length), cut);

              // Whatever the piece had got across before the cut, the
              // session it belonged to is over, and it ended once.
              final after = app.ended.sublist(endedBefore);
              expect(after.length, lessThanOrEqualTo(1), reason: reason);
              expect(app.rx.isIdle, isTrue, reason: reason);
              expect(holdsCancel(app.takeSent()), isFalse,
                  reason: '$reason: no cancel is sent back');
              expectCleanSession(app, 'b.bin', content(500, 3));
            }
          }
        });
      }
    }
  });

  test('the tail of a long cancel does not reach into the next session', () {
    final app = Consumer(ZReceiver());
    app.feed(zrqinit());
    app.feed(zfile('a.bin', file.length));
    app.feed(zdata(0));
    // Sixteen CANs, then the next session in the same delivery.
    app.feed(bytes([
      cans(16),
      zrqinit(),
    ]));
    expect(app.ended, [ZEndReason.cancelledBySender]);
    expect(app.started, [1, 2]);
    expect(headerTypes(app.takeSent()).last, consts.ZRINIT);
  });
}
