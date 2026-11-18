import 'dart:convert';
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

  List<Row> lines(List<String> texts) {
    final c = chunk(100 + texts.length);
    db.saveTranscript(c, [for (final (i, t) in texts.indexed) (startMs: i * 1000, endMs: i * 1000 + 900, text: t, voice: null)]);
    return db.segments(c);
  }

  String reply(List<(String, int, String, String)> items) => jsonEncode({
        'items': [for (final (kind, line, text, due) in items) {'kind': kind, 'line': line, 'text': text, 'due': due}],
      });

  test('parseItems keeps only well-formed items that point at a real line', () {
    final l = lines(['Dentist on Friday at 3:30 pm, remember that', "I'll send Ravi the deck tomorrow",
      'The gate code is 4412 for the building']);
    const json = '''{"items": [
      {"kind": "my_promise", "line": 2, "text": " Send Ravi the deck ", "due": "2026-11-20"},
      {"kind": "event", "line": 1, "text": "Dentist appointment", "due": "2026-11-21T15:30"},
      {"kind": "hack", "line": 1, "text": "x", "due": ""},
      {"kind": "task", "line": 4, "text": "out of range", "due": ""},
      {"kind": "task", "line": 1, "text": "   ", "due": ""},
      {"kind": "fact", "line": "1", "text": "line is a string", "due": ""},
      {"kind": "fact", "line": 3, "text": "Gate code 4412", "due": "someday"}
    ]}''';
    final items = parseItems(json, l);
    expect([for (final i in items) (i.segmentId, i.kind, i.text)], [
      (l[1]['id'], 'my_promise', 'Send Ravi the deck'),
      (l[0]['id'], 'event', 'Dentist appointment'),
      (l[2]['id'], 'fact', 'Gate code 4412'),
    ]);
    expect(items[0].dueMs, DateTime(2026, 11, 20).millisecondsSinceEpoch);
    expect(items[1].dueMs, DateTime(2026, 11, 21, 15, 30).millisecondsSinceEpoch);
    expect(items[2].dueMs, isNull);
    expect(parseItems('not json', l), isEmpty);
    expect(parseItems('{"items": 3}', l), isEmpty);
  });

  test('parseItems drops what a small model pulls out of TV: captions, fragments, copies, unrelated text', () {
    // Real lines and items from the phone, recorded next to a TV.
    final l = lines([
      '[Music]',
      '(crowd cheering)',
      'Yes.',
      'set this new original version.',
      "It's not that we have friends over and we're sent us to the original audition.",
      'The door is not here, friends over at work.',
      'The right answer. Everyone listen for their key. Only everyone listen for...',
      "I don't need a replacement for low-key. I don't need a replacement for lowkey.",
    ]);
    expect(
        parseItems(
            reply([
              ('fact', 1, 'Music', ''),
              ('event', 2, '(crowd cheering)', '2026-11-18T05:25'),
              ('fact', 3, 'Yes.', ''),
              ('task', 4, 'set this new original version.', '2026-11-18T05:29'),
              ('task', 5, "It's not that we have friends over and we're sent us to the original audition.", ''),
              ('task', 6, 'Send us the original', '2026-11-18T05:28'),
              ('event', 7, 'and friends over and over again set us the resolution', ''),
              ('fact', 8, 'I need a replacement for lowkey', ''),
            ]),
            l),
        isEmpty);
  });

  test("a due date the line never mentions is dropped, e.g. the prompt's own date copied in", () {
    final l = lines(['Remember to renew the car insurance before it lapses']);
    final item = parseItems(reply([('task', 1, 'Renew car insurance', '2026-11-18T05:31')]), l).single;
    expect(item.dueMs, isNull);
    expect(buildPrompt(l, null, DateTime(2026, 11, 18, 5, 31)), startsWith('Today is Wednesday 2026-11-18.\n'));
  });

  test('once you have a voice profile, a conversation you never spoke in is not read', () async {
    final c = chunk(1); // time unknown, so no day summary is due either
    db.saveTranscript(c, [(startMs: 0, endMs: 900, text: 'Officer, call dispatch about Westbrook tonight', voice: null)]);
    db.db.execute("INSERT INTO voice_samples(embedding) VALUES (x'00')");
    var calls = 0;
    final s = UnderstandingService(db, Directory.systemTemp, mayRunNow: () async => true, generate: (_, _, _) async {
      calls++;
      return '{"items": []}';
    });
    await s.kick();
    expect(calls, 0);
    expect(db.nextUnextracted(), isNull);
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
    db.saveTranscript(c, [(startMs: 0, endMs: 900, text: 'Remind me to call mum tonight', voice: null)]);
    var allowed = false;
    final prompts = <String>[];
    final s = UnderstandingService(db, Directory.systemTemp, mayRunNow: () async => allowed, generate: (system, user, schema) async {
      prompts.add(user);
      return '{"items": [{"kind": "task", "line": 1, "text": "Call mum", "due": ""}]}';
    });
    await s.kick();
    expect(db.items(), isEmpty);
    allowed = true;
    await s.kick();
    expect(prompts.single, contains('1. Speaker: Remind me to call mum tonight'));
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
