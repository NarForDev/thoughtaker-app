import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:thoughtaker_app/ai/on_device_transcription.dart';
import 'package:thoughtaker_app/db.dart';

void main() {
  late AppDb db;
  setUp(() => db = AppDb(sqlite3.openInMemory()));

  int add(int seq) => db.insertChunk(
      storeId: 1,
      seq: seq,
      bootId: 1,
      flags: 1,
      startUptimeMs: 0,
      startMs: seq * 60000,
      durationMs: 60000,
      bookmarksMs: const [],
      crc: seq,
      path: '/x/$seq.wav');

  test('VAD sample offsets map to ms from the chunk start', () {
    expect(segmentMs(0, 0), (0, 0));
    expect(segmentMs(16000, 8000), (1000, 1500));
    expect(segmentMs(959999, 1), (59999, 60000)); // last sample of a 60 s chunk
  });

  test('DC offset is removed before VAD, speech-band signal is kept', () {
    final pcm = Int16List(16000);
    for (var i = 0; i < pcm.length; i++) {
      pcm[i] = 8000 + (i % 16 < 8 ? 1000 : -1000); // 1 kHz square wave riding on a large DC offset
    }
    final out = toFloatNoDc(pcm);
    final tail = out.sublist(8000);
    final mean = tail.reduce((a, b) => a + b) / tail.length;
    expect(mean.abs(), lessThan(0.001));
    expect(tail.reduce((a, b) => a > b ? a : b), closeTo(1000 / 32768, 0.005));
    expect(toFloatNoDc(Int16List(0)), isEmpty);
  });

  test('saveTranscript is searchable, replaces on rerun and marks the chunk done', () {
    final id = add(1);
    expect(db.isTranscribed(id), isFalse);
    db.saveTranscript(id, [(startMs: 1000, endMs: 2500, text: 'kal subah budget email bhejna hai')]);
    expect(db.isTranscribed(id), isTrue);
    expect(db.search('budget').single.startMs, 1000);
    db.saveTranscript(id, [(startMs: 3000, endMs: 4000, text: 'call Asha on Friday')]);
    expect(db.search('budget'), isEmpty);
    expect(db.search('Asha').single.startMs, 3000);
    expect(db.segments(id).single['end_ms'], 4000);
    db.saveTranscript(id, const []); // silent chunk: done, no segments
    expect(db.isTranscribed(id), isTrue);
    expect(db.segments(id), isEmpty);
  });

  test('saveTranscript rolls back on failure', () {
    expect(() => db.saveTranscript(999, [(startMs: 0, endMs: 1, text: 'orphan')]), throwsA(isA<SqliteException>()));
    expect(db.db.select('SELECT * FROM transcript_segments'), isEmpty);
  });

  group('queue', () {
    var plugged = false, active = 0, maxActive = 0;
    final order = <String>[];
    Object? failWith;
    late OnDeviceTranscriptionService svc;

    setUp(() {
      plugged = false;
      active = maxActive = 0;
      order.clear();
      failWith = null;
      svc = OnDeviceTranscriptionService(db, Directory.systemTemp, isPluggedIn: () async => plugged,
          recognize: (path) async {
        active++;
        maxActive = active > maxActive ? active : maxActive;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        if (failWith != null) throw failWith!;
        order.add(path);
        return [(startMs: 0, endMs: 900, text: 'hello $path')];
      })
        ..modelsReady = true;
    });

    test('waits for power by default, then runs one chunk at a time, newest first', () async {
      add(1);
      add(2);
      add(3);
      expect(svc.onlyWhileCharging, isTrue);
      await svc.kick();
      expect(order, isEmpty);
      expect(db.untranscribedCount(), 3);

      plugged = true;
      await Future.wait([svc.kick(), svc.kick(), svc.kick()]);
      expect(order, ['/x/3.wav', '/x/2.wav', '/x/1.wav']);
      expect(maxActive, 1);
      expect(db.untranscribedCount(), 0);
      expect(svc.working, isFalse);
      expect(db.search('hello').length, 3);
    });

    test('turning the charging rule off runs on battery', () async {
      add(1);
      await svc.kick();
      expect(order, isEmpty);
      svc.onlyWhileCharging = false;
      await svc.kick();
      expect(order, ['/x/1.wav']);
      svc.onlyWhileCharging = true;
      expect(db.setting('transcribe_only_charging'), isNull);
    });

    test('a chunk committed mid-drain is picked up by the same drain', () async {
      plugged = true;
      add(1);
      final run = svc.kick();
      add(2);
      svc.kick();
      await run;
      await svc.kick();
      expect(order.toSet(), {'/x/1.wav', '/x/2.wav'});
      expect(db.untranscribedCount(), 0);
    });

    test('nothing runs without models', () async {
      plugged = true;
      svc.modelsReady = false;
      add(1);
      await svc.kick();
      expect(order, isEmpty);
    });

    test('a failure stops the queue, leaves the chunk pending and is reported', () async {
      plugged = true;
      add(1);
      failWith = StateError('model broke');
      await svc.kick();
      expect(svc.error, contains('model broke'));
      expect(db.untranscribedCount(), 1);
      failWith = null;
      await svc.kick();
      expect(svc.error, isNull);
      expect(db.untranscribedCount(), 0);
    });
  });
}
