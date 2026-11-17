import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:thoughtaker_app/acting/calendar.dart';
import 'package:thoughtaker_app/ai/understanding.dart';
import 'package:thoughtaker_app/db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDb db;
  setUp(() => db = AppDb(sqlite3.openInMemory()));

  int chunk(int seq, {int? startMs}) => db.insertChunk(
      storeId: 1,
      seq: seq,
      bootId: 1,
      flags: 1,
      startUptimeMs: 0,
      startMs: startMs,
      durationMs: 60000,
      bookmarksMs: const [],
      crc: seq * 7,
      path: '/x/$seq.wav');

  int item(int chunkId, String kind, {int? dueMs}) {
    db.saveTranscript(chunkId, [(startMs: 0, endMs: 1, text: 'Send the deck', voice: null)]);
    db.saveItems(chunkId, [(segmentId: db.segments(chunkId).single['id'] as int, kind: kind, text: 'Send deck', dueMs: dueMs)]);
    return db.items().last.id;
  }

  group('delete', () {
    test('deleting a chunk removes its transcript, search hits and items, and tombstones it', () {
      final c = chunk(1);
      item(c, 'task');
      db.deleteChunks([c]);
      expect(db.chunks(), isEmpty);
      expect(db.search('deck'), isEmpty);
      expect(db.items(), isEmpty);
      expect(db.chunkCrc(1, 1), 7); // a re-sent copy is acked, not stored again
    });

    test('deleting nothing or a missing id is a no-op', () {
      chunk(1);
      db.deleteChunks([]);
      db.deleteChunks([999]);
      expect(db.chunks(), hasLength(1));
    });

    test('items saved for a chunk deleted mid-processing are dropped', () {
      final c = chunk(1);
      db.saveTranscript(c, [(startMs: 0, endMs: 1, text: 'x', voice: null)]);
      final seg = db.segments(c).single['id'] as int;
      db.deleteChunks([c]);
      db.saveItems(c, [(segmentId: seg, kind: 'task', text: 'x', dueMs: null)]);
      expect(db.items(), isEmpty);
    });

    test('the event_id column is added once to an existing items table', () {
      final raw = sqlite3.openInMemory();
      AppDb(raw);
      AppDb(raw); // second open must not try to add it again
      expect([for (final r in raw.select('PRAGMA table_info(items)')) r['name']], contains('event_id'));
    });
  });

  group('summaries', () {
    final now = DateTime(2026, 11, 18, 20);
    int at(int day, int hour) => DateTime(2026, 11, day, hour).millisecondsSinceEpoch;

    test('a day is stale until summarised, and again when its spoken chunks change', () {
      final a = chunk(1, startMs: at(17, 9)), b = chunk(2, startMs: at(17, 10));
      final spoken = {a, b};
      expect(staleDays(db.chunks(), spoken, {}, now).single.$1, '2026-11-17');
      expect(staleDays(db.chunks(), spoken, {'2026-11-17': 2}, now), isEmpty);
      expect(staleDays(db.chunks(), spoken, {'2026-11-17': 1}, now).single.$2, hasLength(2));
    });

    test('today waits for 5 new spoken chunks between summaries; silent chunks never count', () {
      final ids = [for (var i = 1; i <= 6; i++) chunk(i, startMs: at(18, 8) + i * 60000)];
      final spoken = ids.take(5).toSet();
      expect(staleDays(db.chunks(), spoken, {}, now).single.$2, hasLength(5));
      expect(staleDays(db.chunks(), spoken, {'2026-11-18': 1}, now), isEmpty); // 4 new
      expect(staleDays(db.chunks(), spoken, {'2026-11-18': 0}, now), hasLength(1)); // 5 new
    });

    test('parseSummary bounds the text and cleans topics', () {
      final s = parseSummary('{"summary": " You agreed to ship Friday. ", "topics": ["Beta Launch", "a,b", "", 3, "${'x' * 40}"]}')!;
      expect(s.text, 'You agreed to ship Friday.');
      expect(s.topics, ['beta launch', 'a b']);
      expect(parseSummary('{"summary": "", "topics": []}'), isNull);
      expect(parseSummary('nope'), isNull);
    });
  });

  group('calendar', () {
    final calls = <MethodCall>[];
    var granted = true, nextId = 100;
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(calendarChannel, (c) async {
        calls.add(c);
        return switch (c.method) { 'hasAccess' => granted, 'insert' => nextId++, _ => null };
      });
    });

    test('open dated items go to the calendar once, and leave it when done', () async {
      final c = chunk(1, startMs: 0);
      final timed = DateTime(2026, 11, 20, 15).millisecondsSinceEpoch;
      final id = item(c, 'task', dueMs: timed);
      final sync = CalendarSync(db);
      await sync.sync();
      await sync.sync();
      final inserts = calls.where((c) => c.method == 'insert').toList();
      expect(inserts, hasLength(1));
      expect(inserts.single.arguments, containsPair('alertMinutes', 60));
      expect(inserts.single.arguments, containsPair('allDay', false));
      expect(db.item(id)!.eventId, 100);
      db.setItemState(id, 'done');
      await sync.sync();
      expect(calls.last.method, 'delete');
      expect(db.item(id)!.eventId, isNull);
    });

    test('date-only items become all-day events at UTC midnight; undated items and facts stay out', () async {
      final c = chunk(1, startMs: 0);
      item(c, 'event', dueMs: DateTime(2026, 11, 21).millisecondsSinceEpoch);
      final sync = CalendarSync(db);
      await sync.sync();
      final insert = calls.singleWhere((c) => c.method == 'insert').arguments as Map;
      expect(insert['allDay'], isTrue);
      expect(insert['beginMs'], DateTime.utc(2026, 11, 21).millisecondsSinceEpoch);
      expect(insert['alertMinutes'], isNull);
      expect(belongsInCalendar(db.items().single), isTrue);
    });

    test('nothing is written without calendar access or with sync off', () async {
      final c = chunk(1, startMs: 0);
      item(c, 'task', dueMs: DateTime(2026, 11, 20, 15).millisecondsSinceEpoch);
      granted = false;
      await CalendarSync(db).sync();
      expect(calls.where((c) => c.method == 'insert'), isEmpty);
      granted = true;
      final sync = CalendarSync(db)..enabled = false;
      await sync.sync();
      expect(calls.where((c) => c.method == 'insert'), isEmpty);
    });
  });
}
