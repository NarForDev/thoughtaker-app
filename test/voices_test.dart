import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:thoughtaker_app/db.dart';
import 'package:thoughtaker_app/voices.dart';

Float32List v(List<double> xs) => Float32List.fromList(xs);

void main() {
  test('cosine', () {
    expect(cosine(v([1, 0]), v([2, 0])), closeTo(1, 1e-6));
    expect(cosine(v([1, 0]), v([0, 3])), closeTo(0, 1e-6));
    expect(cosine(v([1, 0]), v([-1, 0])), closeTo(-1, 1e-6));
    expect(cosine(v([0, 0]), v([1, 0])), 0);
  });

  test('isMyVoice matches any sample at or above the threshold', () {
    expect(isMyVoice(v([1, 0]), []), isFalse);
    expect(isMyVoice(v([1, 0.1]), [v([0, 1]), v([1, 0])]), isTrue);
    expect(isMyVoice(v([1, 0]), [v([0, 1])]), isFalse);
  });

  test('a "not me" sample closer than any of yours overrules a match', () {
    final mine = [v([1, 0])], notMine = [v([0.8, 0.6])];
    expect(isMyVoice(v([0.85, 0.5]), mine), isTrue);
    expect(isMyVoice(v([0.85, 0.5]), mine, notMine), isFalse);
    expect(isMyVoice(v([1, 0.05]), mine, notMine), isTrue);
  });

  test('scores near the threshold are unsure, clear ones are not', () {
    expect(isUnsure(voiceThreshold), isTrue);
    expect(isUnsure(voiceThreshold + voiceUnsureMargin + 0.01), isFalse);
    expect(isUnsure(0.05), isFalse);
    expect(myVoiceScore(v([1, 0]), []), 0);
  });

  test('nearestSpeaker picks the closest centroid above the threshold, else null', () {
    final c = {1: v([1, 0]), 2: v([0.8, 0.6])};
    expect(nearestSpeaker(c, v([0.7, 0.7])), 2);
    expect(nearestSpeaker(c, v([1, -0.1])), 1);
    expect(nearestSpeaker(c, v([-1, 0])), isNull);
    expect(nearestSpeaker({}, v([1, 0])), isNull);
  });

  test('addToMean keeps a running mean and bytes round-trip', () {
    expect(addToMean(v([2, 0]), 1, v([0, 2])), [1, 1]);
    expect(addToMean(v([1, 1]), 3, v([5, 1])), [2, 1]);
    expect(voiceFromBytes(Uint8List.fromList([0, ...voiceBytes(v([1.5, -2]))]).sublist(1)), [1.5, -2]);
  });

  group('db', () {
    late AppDb db;
    late int chunk;
    setUp(() {
      db = AppDb(sqlite3.openInMemory());
      chunk = db.insertChunk(
          storeId: 1, seq: 1, bootId: 1, flags: 1, startUptimeMs: 0, startMs: 0, durationMs: 60000,
          bookmarksMs: const [], crc: 1, path: '/x/1.wav');
    });

    final me = v([1, 0, 0]), asha = v([0, 1, 0]), ravi = v([0, 0, 1]);
    List<String?> speakers() => [for (final s in db.segments(chunk)) s['speaker'] as String?];
    void save() => db.saveTranscript(chunk, [
          (startMs: 0, endMs: 2000, text: 'I will send the budget', voice: me),
          (startMs: 2000, endMs: 4000, text: 'thanks, budget by Friday', voice: asha),
          (startMs: 4000, endMs: 6000, text: 'see you then', voice: v([0.1, 0.95, 0])),
          (startMs: 6000, endMs: 6500, text: 'ok', voice: null),
          (startMs: 6500, endMs: 9000, text: 'bye', voice: ravi),
        ]);

    test('new voices become Person N, repeat voices join them, short lines stay unlabelled', () {
      save();
      expect(speakers(), ['Person 1', 'Person 2', 'Person 2', null, 'Person 3']);
      expect(db.lineSpeaker(db.segments(chunk)[3]['id'] as int), isNull);
    });

    test("That's me labels matching lines You, reset undoes it", () {
      save();
      db.markAsMe(db.segments(chunk).first['id'] as int);
      expect(db.voiceSampleCount(), 1);
      expect(speakers(), ['You', 'Person 2', 'Person 2', null, 'Person 3']);
      save(); // a new transcript uses the profile directly
      expect(speakers().first, 'You');
      expect(db.search('budget', speaker: 'You').single.startMs, 0);
      db.resetVoiceProfile();
      expect(db.voiceSampleCount(), 0);
      expect(speakers().first, 'Person 1');
    });

    test('rename updates lines and search; the same name merges two people', () {
      save();
      final segs = db.segments(chunk);
      db.renameSpeaker(db.lineSpeaker(segs[1]['id'] as int)!, 'Asha');
      db.renameSpeaker(db.lineSpeaker(segs[4]['id'] as int)!, 'Asha');
      expect(speakers(), ['Person 1', 'Asha', 'Asha', null, 'Asha']);
      expect(db.people(), ['Asha', 'Person 1']);
      expect(db.search('budget', speaker: 'Asha').single.startMs, 2000);
      expect(db.search('', speaker: 'Asha').length, 3);
      expect(db.search(''), isEmpty);
      expect(db.search('Asha').length, 3); // FTS indexes the new speaker name
    });

    test('search matches word starts and marks the match for highlighting', () {
      save();
      final hit = db.search('budg').first;
      expect(hit.snippet, contains('\x02budget\x03'));
      expect(db.search('thank').single.startMs, 2000);
    });

    test('relabelOlder re-queues only chunks that have no voices', () {
      final quiet = db.insertChunk(
          storeId: 1, seq: 2, bootId: 1, flags: 1, startUptimeMs: 0, startMs: 60000, durationMs: 60000,
          bookmarksMs: const [], crc: 2, path: '/x/2.wav');
      save();
      db.saveTranscript(quiet, [(startMs: 0, endMs: 900, text: 'hello there', voice: null)]);
      db.relabelOlder();
      expect(db.isTranscribed(chunk), isTrue);
      expect(db.isTranscribed(quiet), isFalse);
    });

    test('unsure lines are asked about once; "not me" relabels them and teaches the profile', () {
      db.saveTranscript(chunk, [
        (startMs: 0, endMs: 2000, text: 'I will send the budget', voice: me),
        (startMs: 2000, endMs: 4000, text: 'thanks, budget by Friday', voice: asha),
        (startMs: 4000, endMs: 6000, text: 'sounds a bit like me', voice: v([0.5, 0.85, 0])),
      ]);
      expect(db.voiceChecks(), isEmpty); // no profile yet, nothing to compare with
      final segs = db.segments(chunk);
      db.markAsMe(segs[0]['id'] as int);
      expect(speakers(), ['You', 'Person 2', 'You']); // a weak match still counts as you
      final unsure = db.voiceChecks().single;
      expect(unsure['segment_id'], segs[2]['id']);
      db.markNotMe(segs[2]['id'] as int);
      expect(speakers(), ['You', 'Person 2', 'Person 2']);
      expect(db.voiceChecks(), isEmpty); // answered, never asked again
      expect(db.voiceSampleCount(), 1); // "not me" samples do not count as your voice
    });

    test('speakerSamples lists each voice once, most lines first, with its newest line as the sample', () {
      save();
      final rows = db.speakerSamples();
      expect([for (final r in rows) (r['speaker'], r['lines'], r['text'])],
          [('Person 2', 2, 'see you then'), ('Person 1', 1, 'I will send the budget'), ('Person 3', 1, 'bye')]);
      db.markAsMe(rows[1]['segment_id'] as int);
      expect(db.speakerSamples()[1]['speaker'], 'You');
    });
  });
}
