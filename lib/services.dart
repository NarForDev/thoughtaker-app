import 'dart:io';

import 'package:flutter/foundation.dart';

import 'acting/calendar.dart';
import 'acting/reminders.dart';
import 'ai/on_device_transcription.dart';
import 'ai/understanding.dart';
import 'conversations.dart';
import 'db.dart';
import 'pendant.dart';

/// Everything the screens work with, built once in main().
class Services {
  Services({
    required this.db,
    required this.pendant,
    required this.transcriber,
    required this.understanding,
    required this.reminders,
    required this.calendar,
    required this.partialDir,
  });

  final AppDb db;
  final PendantController pendant;
  final OnDeviceTranscriptionService transcriber;
  final UnderstandingService understanding;
  final Reminders reminders;
  final CalendarSync calendar;
  final Directory partialDir;

  /// Fires whenever synced, transcribed or understood data may have changed.
  late final Listenable changes = Listenable.merge([pendant, transcriber, understanding, calendar]);

  List<Chunk> chunksOnDay(String day) => [
        for (final (c, at) in placeChunks(db.chunks()))
          if (at != null && dayKey(at) == day) c,
      ];

  /// Deletes chunks with everything derived from them: transcript, items, their calendar events and reminders,
  /// and the audio files. A tombstone keeps the pendant from syncing them back.
  Future<void> deleteChunks(List<Chunk> chunks) async {
    final ids = [for (final c in chunks) c.id];
    for (final i in db.itemsOfChunks(ids)) {
      await calendar.remove(i);
      if (i.remindMs != null) await reminders.cancel(i.id);
    }
    db.deleteChunks(ids);
    for (final c in chunks) {
      try {
        await File(c.path).delete();
      } on FileSystemException {
        // already gone
      }
    }
    pendant.dataChanged();
  }

  /// Every conversation, half-synced file, voice profile and summary on this phone. The pairing stays.
  Future<void> deleteEverything() async {
    await deleteChunks(db.chunks());
    db.clearDerived();
    if (await partialDir.exists()) {
      await for (final f in partialDir.list()) {
        await f.delete();
      }
    }
    pendant.dataChanged();
  }
}
