import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:thoughtaker_app/db.dart';
import 'package:thoughtaker_app/protocol.dart';
import 'package:thoughtaker_app/screens/home_screen.dart';
import 'package:thoughtaker_app/conversations.dart';
import 'package:thoughtaker_app/ui/format.dart';
import 'package:thoughtaker_app/ui/painters.dart';
import 'package:thoughtaker_app/ui/widgets.dart';

void main() {
  test('dot-matrix glyphs cover every character the app draws, 7 rows of 5 bits', () {
    for (final ch in '0123456789.:% '.split('')) {
      final rows = dotMatrixGlyphs[ch];
      expect(rows, hasLength(7), reason: ch);
      expect(rows!.every((r) => r >= 0 && r < 32), isTrue, reason: ch);
    }
  });

  test('todayTotals counts the local day only, and speech time only from speech chunks', () {
    final db = AppDb(sqlite3.openInMemory());
    void add(int seq, int? startMs, {int storeId = 1, int flags = 1}) => db.insertChunk(
        storeId: storeId,
        seq: seq,
        bootId: 1,
        flags: flags,
        startUptimeMs: 0,
        startMs: startMs,
        durationMs: 60000,
        bookmarksMs: const [],
        crc: seq,
        path: '/x/$seq.wav');
    final nine = DateTime(2026, 11, 18, 9).millisecondsSinceEpoch;
    add(1, DateTime(2026, 11, 17, 23, 59).millisecondsSinceEpoch); // yesterday
    add(2, nine);
    add(3, nine + 60000, flags: 0); // quiet: counts, adds no speech
    add(4, null); // borrows seq 3's time, so today
    add(1, null, storeId: 2); // no neighbour to borrow from: unplaced
    expect(todayTotals(placeChunks(db.chunks()), DateTime(2026, 11, 18, 15)), (speechMs: 120000, chunks: 3));
  });

  testWidgets('a marked row paints its text (a rounded two-colour border threw and blanked it)', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ListRow(marked: true, child: Text('Send the deck'))));
    expect(tester.takeException(), isNull);
    expect(find.text('Send the deck'), findsOneWidget);
  });

  test('recordingLabel follows the status bits: muted, recording, waiting for the wake word', () {
    DeviceStatus st(int state) => DeviceStatus.parse(Uint8List(32)..[2] = state, 0);
    expect(recordingLabel(st(0x03)), 'Muted'); // muted wins
    expect(recordingLabel(st(0x05)), 'Recording');
    expect(recordingLabel(st(0x04)), 'Waiting for "Perthro"');
    expect(recordingLabel(st(0x00)), 'Not recording'); // wake word off and not keeping audio: storage full or SD error
  });
}
