import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:thoughtaker_app/conversations.dart';
import 'package:thoughtaker_app/db.dart';

void main() {
  late AppDb db;
  setUp(() => db = AppDb(sqlite3.openInMemory()));

  void add(int seq, int? startMs, {int storeId = 1, bool speech = true, List<int> bookmarks = const []}) =>
      db.insertChunk(
          storeId: storeId,
          seq: seq,
          bootId: 1,
          flags: speech ? 1 : 0,
          startUptimeMs: 0,
          startMs: startMs,
          durationMs: 60000,
          bookmarksMs: bookmarks,
          crc: seq,
          path: '/x/$storeId-$seq.wav');

  List<List<int>> groups() => [for (final v in groupConversations(db.chunks())) [for (final c in v.chunks) c.seq]];

  test('back-to-back speech chunks form one conversation, newest conversation first', () {
    add(1, 0);
    add(2, 60000);
    add(3, 120000);
    add(4, 600000); // 7 min after seq 3 ended
    expect(groups(), [
      [4],
      [1, 2, 3],
    ]);
  });

  test('a seq gap, a store change or a quiet chunk starts a new conversation', () {
    add(1, 0);
    add(3, 60000); // seq 2 missing
    add(4, 120000, speech: false);
    add(5, 180000, speech: false);
    add(1, 240000, storeId: 2);
    expect(groups(), [
      [1],
      [4, 5],
      [3],
      [1],
    ]);
  });

  test('chunks with unknown time join their neighbours by seq', () {
    add(1, 0);
    add(2, null);
    add(3, null);
    final v = groupConversations(db.chunks()).single;
    expect([for (final c in v.chunks) c.seq], [1, 2, 3]);
    expect(v.startMs, 0);
    expect(v.durationMs, 180000);
  });

  test('bookmarks are counted across the conversation', () {
    add(1, 0, bookmarks: [500]);
    add(2, 60000, bookmarks: [100, 200]);
    final v = groupConversations(db.chunks()).single;
    expect(v.bookmarks, 3);
  });
}
