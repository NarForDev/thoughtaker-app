import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:thoughtaker_app/db.dart';
import 'package:thoughtaker_app/conversations.dart';

void main() {
  late AppDb db;
  setUp(() => db = AppDb(sqlite3.openInMemory()));

  int add(int seq, int? startMs, {int storeId = 1, int flags = 1}) => db.insertChunk(
      storeId: storeId,
      seq: seq,
      bootId: 1,
      flags: flags,
      startUptimeMs: 0,
      startMs: startMs,
      durationMs: 60000,
      bookmarksMs: const [500],
      crc: seq * 11,
      path: '/x/$seq.wav');

  test('chunks, settings and boot offsets round-trip', () {
    add(2, 1000);
    expect(db.chunkCrc(1, 2), 22);
    expect(db.chunkCrc(1, 3), isNull);
    expect(db.chunks().single.bookmarksMs, [500]);
    db.setSetting('device_id', 'aa:bb');
    expect(db.setting('device_id'), 'aa:bb');
    db.setSetting('device_id', null);
    expect(db.setting('device_id'), isNull);
    db.saveBootOffset(1, 4, -5);
    expect(db.bootOffset(1, 4), -5);
    expect(db.bootOffset(1, 5), isNull);
  });

  test('FTS5 search over transcript segments, with literal quoting', () {
    final id = add(1, 0);
    db.db.execute(
        'INSERT INTO transcript_segments(chunk_id, start_ms, end_ms, speaker, text) VALUES (?, ?, ?, ?, ?)',
        [id, 1200, 3400, 'Asha', 'I will send the "budget" email tomorrow']);
    final hits = db.search('budget email');
    expect(hits.single.chunkId, id);
    expect(hits.single.startMs, 1200);
    expect(hits.single.snippet, contains('\x02budget\x03')); // marked for highlighting
    expect(db.search('AND OR "'), isEmpty); // FTS syntax in user input must not throw
    db.db.execute('DELETE FROM transcript_segments');
    expect(db.search('budget'), isEmpty);
  });

  test('timeline places unknown-time chunks next to their known neighbours, newest first', () {
    add(1, 1000);
    add(2, null);
    add(3, 200000);
    add(4, null);
    final order = [for (final (c, _) in placeChunks(db.chunks())) c.seq];
    expect(order, [4, 3, 2, 1]);
  });
}
