import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'voices.dart';

// sqlite3 (not sqflite) because it bundles its own SQLite with FTS5; Android's system SQLite may lack it.
/// [voice] is a speaker embedding, present only for regions long enough to tell voices apart.
typedef Segment = ({int startMs, int endMs, String text, Float32List? voice});

class Chunk {
  Chunk(Row r)
      : id = r['id'] as int,
        storeId = r['store_id'] as int,
        seq = r['seq'] as int,
        flags = r['flags'] as int,
        startMs = r['start_ms'] as int?,
        durationMs = r['duration_ms'] as int,
        bookmarksMs = [
          for (final s in (r['bookmarks'] as String).split(','))
            if (s.isNotEmpty) int.parse(s),
        ],
        path = r['path'] as String;

  final int id, storeId, seq, flags, durationMs;
  final int? startMs; // null = time unknown
  final List<int> bookmarksMs;
  final String path;
  bool get hasSpeech => flags & 1 != 0;
  bool get bookmarked => flags & 2 != 0;
}

class SearchHit {
  SearchHit(Row r)
      : chunkId = r['chunk_id'] as int,
        startMs = r['start_ms'] as int,
        speaker = r['speaker'] as String?,
        snippet = r['snippet'] as String;
  final int chunkId, startMs;
  final String? speaker;
  final String snippet;
}

/// Something worth acting on, pulled from one transcript line.
class Item {
  Item(Row r)
      : id = r['id'] as int,
        kind = r['kind'] as String,
        text = r['text'] as String,
        dueMs = r['due_ms'] as int?,
        state = r['state'] as String,
        remindMs = r['remind_ms'] as int?,
        eventId = r['event_id'] as int?,
        chunkId = r['chunk_id'] as int,
        atMs = r['start_ms'] as int,
        chunkStartMs = r['chunk_start_ms'] as int?,
        speaker = r['speaker'] as String?,
        quote = r['quote'] as String;

  final int id, chunkId, atMs; // atMs: offset of the source line in its chunk
  final String kind, text, state, quote;
  final int? dueMs, remindMs, chunkStartMs, eventId; // eventId: its entry in the phone calendar
  final String? speaker;

  /// When it was said, if the chunk's time is known.
  int? get saidMs => chunkStartMs == null ? null : chunkStartMs! + atMs;
}

typedef NewItem = ({int segmentId, String kind, String text, int? dueMs});

const _itemSelect = 'SELECT i.*, s.chunk_id, s.start_ms, s.speaker, s.text AS quote, c.start_ms AS chunk_start_ms '
    'FROM items i JOIN transcript_segments s ON s.id = i.segment_id JOIN chunks c ON c.id = s.chunk_id';

class AppDb {
  AppDb(this.db) {
    db.execute('''
      PRAGMA foreign_keys = ON;
      PRAGMA secure_delete = ON;
      CREATE TABLE IF NOT EXISTS chunks(
        id INTEGER PRIMARY KEY,
        store_id INTEGER NOT NULL,
        seq INTEGER NOT NULL,
        boot_id INTEGER NOT NULL,
        flags INTEGER NOT NULL,
        start_uptime_ms INTEGER NOT NULL,
        start_ms INTEGER,
        duration_ms INTEGER NOT NULL,
        bookmarks TEXT NOT NULL,
        crc INTEGER NOT NULL,
        path TEXT NOT NULL,
        UNIQUE(store_id, seq));
      CREATE TABLE IF NOT EXISTS boot_offsets(
        store_id INTEGER NOT NULL,
        boot_id INTEGER NOT NULL,
        epoch_offset_ms INTEGER NOT NULL,
        PRIMARY KEY(store_id, boot_id));
      CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS transcript_segments(
        id INTEGER PRIMARY KEY,
        chunk_id INTEGER NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
        start_ms INTEGER NOT NULL,
        end_ms INTEGER NOT NULL,
        speaker TEXT,
        text TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS transcribed(
        chunk_id INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE);
      CREATE INDEX IF NOT EXISTS segments_chunk ON transcript_segments(chunk_id, start_ms);
      CREATE TABLE IF NOT EXISTS extracted(
        chunk_id INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE);
      CREATE TABLE IF NOT EXISTS items(
        id INTEGER PRIMARY KEY,
        segment_id INTEGER NOT NULL REFERENCES transcript_segments(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        text TEXT NOT NULL,
        due_ms INTEGER,
        state TEXT NOT NULL DEFAULT 'open',
        remind_ms INTEGER);
      CREATE INDEX IF NOT EXISTS items_segment ON items(segment_id);
      CREATE TABLE IF NOT EXISTS speakers(id INTEGER PRIMARY KEY, name TEXT NOT NULL, centroid BLOB NOT NULL, n INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS voiceprints(
        segment_id INTEGER PRIMARY KEY REFERENCES transcript_segments(id) ON DELETE CASCADE,
        embedding BLOB NOT NULL,
        speaker_id INTEGER REFERENCES speakers(id));
      CREATE TABLE IF NOT EXISTS voice_samples(id INTEGER PRIMARY KEY, embedding BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS deleted_chunks(
        store_id INTEGER NOT NULL, seq INTEGER NOT NULL, crc INTEGER NOT NULL, PRIMARY KEY(store_id, seq));
      CREATE TABLE IF NOT EXISTS daily_summaries(
        day TEXT PRIMARY KEY, text TEXT NOT NULL, topics TEXT NOT NULL, chunk_count INTEGER NOT NULL);
      CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts USING fts5(
        text, speaker, content='transcript_segments', content_rowid='id');
      CREATE TRIGGER IF NOT EXISTS segments_ai AFTER INSERT ON transcript_segments BEGIN
        INSERT INTO transcript_fts(rowid, text, speaker) VALUES (new.id, new.text, new.speaker);
      END;
      CREATE TRIGGER IF NOT EXISTS segments_ad AFTER DELETE ON transcript_segments BEGIN
        INSERT INTO transcript_fts(transcript_fts, rowid, text, speaker) VALUES ('delete', old.id, old.text, old.speaker);
      END;
      CREATE TRIGGER IF NOT EXISTS segments_au AFTER UPDATE ON transcript_segments BEGIN
        INSERT INTO transcript_fts(transcript_fts, rowid, text, speaker) VALUES ('delete', old.id, old.text, old.speaker);
        INSERT INTO transcript_fts(rowid, text, speaker) VALUES (new.id, new.text, new.speaker);
      END;
    ''');
    // Columns added after the table first shipped.
    final itemColumns = {for (final r in db.select('PRAGMA table_info(items)')) r['name']};
    if (!itemColumns.contains('event_id')) db.execute('ALTER TABLE items ADD COLUMN event_id INTEGER');
  }

  final Database db;

  String? setting(String key) => db.select('SELECT value FROM settings WHERE key = ?', [key]).firstOrNull?['value'];

  void setSetting(String key, String? value) => value == null
      ? db.execute('DELETE FROM settings WHERE key = ?', [key])
      : db.execute('INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)', [key, value]);

  void saveBootOffset(int storeId, int bootId, int offsetMs) => db.execute(
      'INSERT OR REPLACE INTO boot_offsets(store_id, boot_id, epoch_offset_ms) VALUES (?, ?, ?)',
      [storeId, bootId, offsetMs]);

  int? bootOffset(int storeId, int bootId) => db.select(
      'SELECT epoch_offset_ms FROM boot_offsets WHERE store_id = ? AND boot_id = ?',
      [storeId, bootId]).firstOrNull?['epoch_offset_ms'];

  /// The stored crc if this chunk is already committed (its ACK may have been lost) or was deleted by the user,
  /// so a re-sent chunk is acked again but never stored again.
  int? chunkCrc(int storeId, int seq) => db.select(
      'SELECT crc FROM chunks WHERE store_id = ?1 AND seq = ?2 UNION ALL SELECT crc FROM deleted_chunks WHERE store_id = ?1 AND seq = ?2',
      [storeId, seq]).firstOrNull?['crc'];

  /// Deletes chunks with their transcripts, voices and items, leaving a tombstone each. Files are the caller's.
  void deleteChunks(List<int> ids) {
    if (ids.isEmpty) return;
    final list = List.filled(ids.length, '?').join(',');
    db.execute('BEGIN');
    try {
      db.execute('INSERT OR REPLACE INTO deleted_chunks SELECT store_id, seq, crc FROM chunks WHERE id IN ($list)', ids);
      db.execute('DELETE FROM chunks WHERE id IN ($list)', ids);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    db.execute("INSERT INTO transcript_fts(transcript_fts) VALUES ('optimize')"); // drop deleted text from the index
  }

  /// Everything learned about voices and days, for "Delete everything".
  void clearDerived() => db.execute('DELETE FROM voice_samples; DELETE FROM voiceprints; DELETE FROM speakers; '
      'DELETE FROM daily_summaries;');

  int insertChunk({
    required int storeId,
    required int seq,
    required int bootId,
    required int flags,
    required int startUptimeMs,
    required int? startMs,
    required int durationMs,
    required List<int> bookmarksMs,
    required int crc,
    required String path,
  }) {
    db.execute(
        'INSERT INTO chunks(store_id, seq, boot_id, flags, start_uptime_ms, start_ms, duration_ms, '
        'bookmarks, crc, path) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [storeId, seq, bootId, flags, startUptimeMs, startMs, durationMs, bookmarksMs.join(','), crc, path]);
    return db.lastInsertRowId;
  }

  /// All chunks in recording order (store, then seq).
  List<Chunk> chunks() => db.select('SELECT * FROM chunks ORDER BY store_id, seq').map(Chunk.new).toList();

  Chunk? chunk(int id) => db.select('SELECT * FROM chunks WHERE id = ?', [id]).map(Chunk.new).firstOrNull;

  List<Row> segments(int chunkId) =>
      db.select('SELECT * FROM transcript_segments WHERE chunk_id = ? ORDER BY start_ms', [chunkId]);

  bool isTranscribed(int chunkId) => db.select('SELECT 1 FROM transcribed WHERE chunk_id = ?', [chunkId]).isNotEmpty;

  // Newest first: after a backlog the user wants today's conversations searchable before last week's.
  Chunk? nextUntranscribed() => db
      .select('SELECT * FROM chunks WHERE id NOT IN (SELECT chunk_id FROM transcribed) ORDER BY id DESC LIMIT 1')
      .map(Chunk.new)
      .firstOrNull;

  int untranscribedCount() =>
      db.select('SELECT count(*) AS n FROM chunks WHERE id NOT IN (SELECT chunk_id FROM transcribed)').first['n'];

  /// Replaces the chunk's transcript and marks it done, atomically, so a crash never leaves half a transcript.
  void saveTranscript(int chunkId, List<Segment> segments) {
    if (chunk(chunkId) == null) return; // deleted while it was being transcribed
    db.execute('BEGIN');
    try {
      db.execute('DELETE FROM transcript_segments WHERE chunk_id = ?', [chunkId]); // cascades to its items
      db.execute('DELETE FROM extracted WHERE chunk_id = ?', [chunkId]);
      final mine = _voiceSamples();
      final insert = db.prepare(
          'INSERT INTO transcript_segments(chunk_id, start_ms, end_ms, speaker, text) VALUES (?, ?, ?, ?, ?)');
      for (final s in segments) {
        final v = s.voice;
        final speakerId = v == null ? null : _assignSpeaker(v);
        insert.execute([chunkId, s.startMs, s.endMs, v == null ? null : _label(v, mine, speakerId!), s.text]);
        if (v != null) {
          db.execute('INSERT INTO voiceprints(segment_id, embedding, speaker_id) VALUES (?, ?, ?)',
              [db.lastInsertRowId, voiceBytes(v), speakerId]);
        }
      }
      insert.close();
      db.execute('INSERT OR IGNORE INTO transcribed(chunk_id) VALUES (?)', [chunkId]);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Next transcribed chunk with speech whose items were not pulled out yet, newest first.
  Chunk? nextUnextracted() => db
      .select('SELECT c.* FROM chunks c JOIN transcribed t ON t.chunk_id = c.id '
          'WHERE c.id NOT IN (SELECT chunk_id FROM extracted) '
          'AND EXISTS (SELECT 1 FROM transcript_segments s WHERE s.chunk_id = c.id) ORDER BY c.id DESC LIMIT 1')
      .map(Chunk.new)
      .firstOrNull;

  /// Replaces the chunk's items and marks it done, atomically.
  void saveItems(int chunkId, List<NewItem> items) {
    if (chunk(chunkId) == null) return; // deleted while it was being read
    db.execute('BEGIN');
    try {
      db.execute('DELETE FROM items WHERE segment_id IN (SELECT id FROM transcript_segments WHERE chunk_id = ?)',
          [chunkId]);
      final insert = db.prepare('INSERT INTO items(segment_id, kind, text, due_ms) VALUES (?, ?, ?, ?)');
      for (final i in items) {
        insert.execute([i.segmentId, i.kind, i.text, i.dueMs]);
      }
      insert.close();
      db.execute('INSERT OR IGNORE INTO extracted(chunk_id) VALUES (?)', [chunkId]);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Items in [state] (all when null): due ones first by date, then newest said first.
  List<Item> items({String? state}) => db
      .select('$_itemSelect ${state == null ? '' : 'WHERE i.state = ?'} '
          'ORDER BY i.due_ms IS NULL, i.due_ms, c.start_ms DESC, s.start_ms DESC', [?state])
      .map(Item.new)
      .toList();

  List<Item> chunkItems(int chunkId) =>
      db.select('$_itemSelect WHERE s.chunk_id = ? ORDER BY s.start_ms', [chunkId]).map(Item.new).toList();

  Item? item(int id) => db.select('$_itemSelect WHERE i.id = ?', [id]).map(Item.new).firstOrNull;

  void setItemState(int id, String state) => db.execute('UPDATE items SET state = ? WHERE id = ?', [state, id]);

  void setReminder(int id, int? atMs) => db.execute('UPDATE items SET remind_ms = ? WHERE id = ?', [atMs, id]);

  void setEventId(int id, int? eventId) => db.execute('UPDATE items SET event_id = ? WHERE id = ?', [eventId, id]);

  /// Items of these chunks that still have a calendar event or a reminder to clean up.
  List<Item> itemsOfChunks(List<int> chunkIds) => db
      .select('$_itemSelect WHERE s.chunk_id IN (${List.filled(chunkIds.length, '?').join(',')})', chunkIds)
      .map(Item.new)
      .toList();

  /// Chunks that have at least one transcript line.
  Set<int> spokenChunkIds() => {for (final r in db.select('SELECT DISTINCT chunk_id FROM transcript_segments')) r['chunk_id'] as int};

  /// Day summaries by local day key (YYYY-MM-DD).
  Map<String, ({String text, List<String> topics, int chunkCount})> summaries() => {
        for (final r in db.select('SELECT * FROM daily_summaries'))
          r['day'] as String: (
            text: r['text'] as String,
            topics: (r['topics'] as String).split(',').where((t) => t.isNotEmpty).toList(),
            chunkCount: r['chunk_count'] as int,
          ),
      };

  void saveSummary(String day, String text, List<String> topics, int chunkCount) => db.execute(
      'INSERT OR REPLACE INTO daily_summaries(day, text, topics, chunk_count) VALUES (?, ?, ?, ?)',
      [day, text, topics.join(','), chunkCount]);

  List<Float32List> _voiceSamples() =>
      [for (final r in db.select('SELECT embedding FROM voice_samples')) voiceFromBytes(r['embedding'])];

  String _label(Float32List voice, List<Float32List> mine, int speakerId) => isMyVoice(voice, mine)
      ? 'You'
      : db.select('SELECT name FROM speakers WHERE id = ?', [speakerId]).first['name'] as String;

  /// Adds [voice] to the nearest known speaker, or starts a new "Person N".
  int _assignSpeaker(Float32List voice) {
    final rows = db.select('SELECT id, centroid, n FROM speakers');
    final id = nearestSpeaker({for (final r in rows) r['id'] as int: voiceFromBytes(r['centroid'])}, voice);
    if (id == null) {
      db.execute("INSERT INTO speakers(name, centroid, n) SELECT 'Person ' || (coalesce(max(id), 0) + 1), ?, 1 "
          'FROM speakers', [voiceBytes(voice)]);
      return db.lastInsertRowId;
    }
    final r = rows.firstWhere((r) => r['id'] == id);
    final n = r['n'] as int;
    db.execute('UPDATE speakers SET centroid = ?, n = ? WHERE id = ?',
        [voiceBytes(addToMean(voiceFromBytes(r['centroid']), n, voice)), n + 1, id]);
    return id;
  }

  /// Rewrites every voiced line's speaker from the current profile and speaker names.
  void _relabel() {
    final mine = _voiceSamples();
    db.execute('BEGIN');
    try {
      for (final r in db.select('SELECT segment_id, embedding, speaker_id FROM voiceprints')) {
        db.execute('UPDATE transcript_segments SET speaker = ?1 WHERE id = ?2 AND speaker IS NOT ?1',
            [_label(voiceFromBytes(r['embedding']), mine, r['speaker_id']), r['segment_id']]);
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// The speaker heard on this line, or null when it was too short to recognise.
  int? lineSpeaker(int segmentId) =>
      db.select('SELECT speaker_id FROM voiceprints WHERE segment_id = ?', [segmentId]).firstOrNull?['speaker_id'];

  int voiceSampleCount() => db.select('SELECT count(*) AS n FROM voice_samples').first['n'];

  /// "That's me": adds this line's voice to the profile and relabels lines that now match it.
  void markAsMe(int segmentId) {
    db.execute('INSERT INTO voice_samples(embedding) SELECT embedding FROM voiceprints WHERE segment_id = ?', [segmentId]);
    _relabel();
  }

  void resetVoiceProfile() {
    db.execute('DELETE FROM voice_samples');
    _relabel();
  }

  /// Giving two speakers the same name shows them as one person.
  void renameSpeaker(int id, String name) {
    db.execute('UPDATE speakers SET name = ? WHERE id = ?', [name, id]);
    _relabel();
  }

  /// Everyone heard so far, for filtering search.
  List<String> people() => [
        for (final r in db.select(
            "SELECT DISTINCT speaker FROM transcript_segments WHERE speaker IS NOT NULL ORDER BY speaker = 'You' DESC, speaker"))
          r['speaker'] as String,
      ];

  /// Lines matching [query], said by [speaker] when given. With only a speaker, their lines newest first.
  List<SearchHit> search(String query, {String? speaker}) {
    // Quote every word so user input is matched literally instead of parsed as FTS5 syntax.
    final match = query
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => '"${w.replaceAll('"', '""')}"')
        .join(' ');
    if (match.isEmpty) {
      if (speaker == null) return [];
      return db
          .select('SELECT chunk_id, start_ms, speaker, text AS snippet FROM transcript_segments WHERE speaker = ? '
              'ORDER BY chunk_id DESC, start_ms DESC LIMIT 200', [speaker])
          .map(SearchHit.new)
          .toList();
    }
    return db
        .select(
            "SELECT s.chunk_id, s.start_ms, s.speaker, snippet(transcript_fts, 0, '[', ']', '…', 12) AS snippet "
            'FROM transcript_fts JOIN transcript_segments s ON s.id = transcript_fts.rowid '
            'WHERE transcript_fts MATCH ? ${speaker == null ? '' : 'AND s.speaker = ?'} ORDER BY rank LIMIT 200',
            [match, ?speaker])
        .map(SearchHit.new)
        .toList();
  }
}
