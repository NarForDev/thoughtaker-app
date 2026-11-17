import 'package:sqlite3/sqlite3.dart';

// sqlite3 (not sqflite) because it bundles its own SQLite with FTS5; Android's system SQLite may lack it.
typedef Segment = ({int startMs, int endMs, String text});

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

class AppDb {
  AppDb(this.db) {
    db.execute('''
      PRAGMA foreign_keys = ON;
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

  /// The stored crc if this chunk is already committed (its ACK may have been lost).
  int? chunkCrc(int storeId, int seq) =>
      db.select('SELECT crc FROM chunks WHERE store_id = ? AND seq = ?', [storeId, seq]).firstOrNull?['crc'];

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
    db.execute('BEGIN');
    try {
      db.execute('DELETE FROM transcript_segments WHERE chunk_id = ?', [chunkId]);
      final insert =
          db.prepare('INSERT INTO transcript_segments(chunk_id, start_ms, end_ms, text) VALUES (?, ?, ?, ?)');
      for (final s in segments) {
        insert.execute([chunkId, s.startMs, s.endMs, s.text]);
      }
      insert.close();
      db.execute('INSERT OR IGNORE INTO transcribed(chunk_id) VALUES (?)', [chunkId]);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  List<SearchHit> search(String query) {
    // Quote every word so user input is matched literally instead of parsed as FTS5 syntax.
    final match = query
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => '"${w.replaceAll('"', '""')}"')
        .join(' ');
    if (match.isEmpty) return [];
    return db
        .select(
            "SELECT s.chunk_id, s.start_ms, s.speaker, snippet(transcript_fts, 0, '[', ']', '…', 12) AS snippet "
            'FROM transcript_fts JOIN transcript_segments s ON s.id = transcript_fts.rowid '
            'WHERE transcript_fts MATCH ? ORDER BY rank LIMIT 200',
            [match])
        .map(SearchHit.new)
        .toList();
  }
}
