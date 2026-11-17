import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:thoughtaker_app/acting/actions.dart';
import 'package:thoughtaker_app/ai/understanding.dart';
import 'package:thoughtaker_app/db.dart';

void main() {
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
      crc: seq,
      path: '/x/$seq.wav');

  test('parseItems keeps only well-formed items that point at a real line', () {
    const reply = '''{"items": [
      {"kind": "my_promise", "line": 2, "text": " Send Ravi the deck ", "due": "2026-11-20"},
      {"kind": "event", "line": 1, "text": "Dentist", "due": "2026-11-21T15:30"},
      {"kind": "hack", "line": 1, "text": "x", "due": ""},
      {"kind": "task", "line": 3, "text": "out of range", "due": ""},
      {"kind": "task", "line": 1, "text": "   ", "due": ""},
      {"kind": "fact", "line": "1", "text": "line is a string", "due": ""},
      {"kind": "fact", "line": 1, "text": "Gate code 4412", "due": "someday"}
    ]}''';
    final items = parseItems(reply, [10, 20]);
    expect([for (final i in items) (i.segmentId, i.kind, i.text)], [
      (20, 'my_promise', 'Send Ravi the deck'),
      (10, 'event', 'Dentist'),
      (10, 'fact', 'Gate code 4412'),
    ]);
    expect(items[0].dueMs, DateTime(2026, 11, 20).millisecondsSinceEpoch);
    expect(items[1].dueMs, DateTime(2026, 11, 21, 15, 30).millisecondsSinceEpoch);
    expect(items[2].dueMs, isNull);
    expect(parseItems('not json', [1]), isEmpty);
    expect(parseItems('{"items": 3}', [1]), isEmpty);
    expect(parseItems('{"items": [{"kind":"task","line":1,"text":"${'a' * 400}","due":""}]}', [1]).single.text.length,
        300);
  });

  test('items are saved per chunk and vanish when the chunk is re-transcribed', () {
    final c = chunk(1, startMs: 1000);
    db.saveTranscript(c, [(startMs: 0, endMs: 900, text: 'hello', voice: null), (startMs: 1000, endMs: 2000, text: "I'll send it", voice: null)]);
    expect(db.nextUnextracted()?.id, c);
    final seg = db.segments(c)[1]['id'] as int;
    db.saveItems(c, [(segmentId: seg, kind: 'my_promise', text: 'Send it', dueMs: null)]);
    expect(db.nextUnextracted(), isNull);
    final item = db.items(state: 'open').single;
    expect((item.kind, item.atMs, item.saidMs, item.quote), ('my_promise', 1000, 2000, "I'll send it"));
    db.setItemState(item.id, 'done');
    expect(db.items(state: 'open'), isEmpty);
    db.saveTranscript(c, [(startMs: 0, endMs: 900, text: 'again', voice: null)]);
    expect(db.items(), isEmpty);
    expect(db.nextUnextracted()?.id, c);
  });

  test('a chunk with no speech lines is never queued for understanding', () {
    db.saveTranscript(chunk(1), []);
    expect(db.nextUnextracted(), isNull);
  });

  test('the service drains the queue through generate and stops when not allowed', () async {
    final c = chunk(1);
    db.saveTranscript(c, [(startMs: 0, endMs: 900, text: 'Call mum tonight', voice: null)]);
    var allowed = false;
    final prompts = <String>[];
    final s = UnderstandingService(db, Directory.systemTemp, mayRunNow: () async => allowed, generate: (system, user) async {
      prompts.add(user);
      return '{"items": [{"kind": "task", "line": 1, "text": "Call mum", "due": ""}]}';
    });
    await s.kick();
    expect(db.items(), isEmpty);
    allowed = true;
    await s.kick();
    expect(prompts.single, contains('1. Speaker: Call mum tonight'));
    expect(db.items().single.text, 'Call mum');
  });

  Item item(String kind, {int? dueMs}) {
    final c = chunk(9);
    db.saveTranscript(c, [(startMs: 0, endMs: 1, text: 'x', voice: null)]);
    db.saveItems(c, [(segmentId: db.segments(c).single['id'] as int, kind: kind, text: 'Send the deck', dueMs: dueMs)]);
    return db.items().single;
  }

  test('defaultReminder: 1 h before a timed deadline, 9:00 on a dated one, 2 days to follow up', () {
    final now = DateTime(2026, 11, 18, 12);
    expect(defaultReminder(item('task', dueMs: DateTime(2026, 11, 19, 15).millisecondsSinceEpoch), now),
        DateTime(2026, 11, 19, 14).millisecondsSinceEpoch);
  });

  test('defaultReminder for a date-only deadline and a promise made to you', () {
    final now = DateTime(2026, 11, 18, 12);
    expect(defaultReminder(item('event', dueMs: DateTime(2026, 11, 20).millisecondsSinceEpoch), now),
        DateTime(2026, 11, 20, 9).millisecondsSinceEpoch);
  });

  test('defaultReminder follows up on their promise and skips the past', () {
    final now = DateTime(2026, 11, 18, 12);
    expect(defaultReminder(item('their_promise'), now), DateTime(2026, 11, 20, 9).millisecondsSinceEpoch);
  });

  test('defaultReminder is null for a past deadline or a fact', () {
    final now = DateTime(2026, 11, 18, 12);
    expect(defaultReminder(item('task', dueMs: DateTime(2026, 11, 18, 12, 30).millisecondsSinceEpoch), now), isNull);
  });

  test('draftFor words a message per kind, and has none for facts', () {
    expect(draftFor(item('my_promise')), 'Hi! As promised: Send the deck.');
  });

  test('draftFor has nothing for a fact', () {
    expect(draftFor(item('fact')), isNull);
  });
}
