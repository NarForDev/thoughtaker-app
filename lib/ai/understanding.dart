// Local LLM pass over transcripts: pulls out tasks, promises, decisions, events and facts, each tied to the
// line it came from. Qwen3-1.7B through llama.cpp (llamadart), under the same charging rule as transcription.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';
import 'package:sqlite3/sqlite3.dart' show Row;

import '../conversations.dart';
import '../db.dart';
import 'download.dart';

const ModelFile llmModel = (
  name: 'Qwen3-1.7B-Q4_K_M.gguf',
  url: 'https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/d7f544eead698dbd1f15126ef60b45a1e1933222/Qwen3-1.7B-Q4_K_M.gguf',
  size: 1107409472,
  sha256: 'b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897',
);

/// Item kinds and how the app titles them.
const itemKinds = {
  'task': 'Tasks',
  'my_promise': 'I promised',
  'their_promise': 'Promised to me',
  'event': 'Events',
  'decision': 'Decisions',
  'fact': 'Worth remembering',
};

typedef Generate = Future<String> Function(String system, String user, Map<String, Object> schema);

const _system = '''You read a transcript recorded by a pendant the user wears, and list what is worth acting on.
Kinds:
- task: something the user should do
- my_promise: the user committed to do something for someone
- their_promise: someone committed to do something for the user
- event: a meeting, appointment or dated plan
- decision: something that was decided
- fact: a name, number or fact worth remembering
Each line starts with who said it. The user's own lines are labelled "You"; anyone else is a name, "Person N" or "Speaker".
"line" is the number of the transcript line it comes from. "text" is a short plain summary, at most 15 words.
"due" is the date or date-time it is due or happens, as YYYY-MM-DD or YYYY-MM-DDTHH:MM, or "" if none was said.
Only list what is actually in the transcript. Small talk gives an empty list.''';

const _schema = {
  'type': 'json_schema',
  'json_schema': {
    'schema': {
      'type': 'object',
      'properties': {
        'items': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'kind': {
                'type': 'string',
                'enum': ['task', 'my_promise', 'their_promise', 'event', 'decision', 'fact'],
              },
              'line': {'type': 'integer'},
              'text': {'type': 'string'},
              'due': {'type': 'string'},
            },
            'required': ['kind', 'line', 'text', 'due'],
          },
        },
      },
      'required': ['items'],
    },
  },
};

const _summarySystem = '''You summarise a day of conversations recorded by a pendant the user wears.
The user's lines are labelled "You". Write "summary": 2 or 3 plain sentences about what happened and what was agreed,
addressed to the user as "you". Write "topics": 3 to 8 short lowercase topic words or phrases.''';

const _summarySchema = {
  'type': 'json_schema',
  'json_schema': {
    'schema': {
      'type': 'object',
      'properties': {
        'summary': {'type': 'string'},
        'topics': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'required': ['summary', 'topics'],
    },
  },
};

/// Local day key, YYYY-MM-DD.
String dayKey(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Days whose spoken chunks changed since their summary, with those chunks. Today waits for 5 new chunks
/// between summaries, so the model is not rerun on every minute of a busy day.
List<(String, List<Chunk>)> staleDays(
    List<Chunk> byStoreSeq, Set<int> spoken, Map<String, int> summarizedCounts, DateTime now) {
  final days = <String, List<Chunk>>{};
  for (final (c, at) in placeChunks(byStoreSeq).reversed) {
    if (at != null && spoken.contains(c.id)) days.putIfAbsent(dayKey(at), () => []).add(c);
  }
  final today = dayKey(now.millisecondsSinceEpoch);
  return [
    for (final MapEntry(key: day, value: chunks) in days.entries)
      if (summarizedCounts[day] case final done
          when done == null || (day == today ? chunks.length - done >= 5 : chunks.length != done))
        (day, chunks),
  ];
}

/// Model output is untrusted: a non-empty summary of bounded length and a few short topic words.
({String text, List<String> topics})? parseSummary(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final text = decoded['summary'], topics = decoded['topics'];
  if (text is! String || text.trim().isEmpty) return null;
  final t = text.trim();
  return (
    text: t.length > 600 ? t.substring(0, 600) : t,
    topics: [
      if (topics is List)
        for (final w in topics.whereType<String>().map((w) => w.trim().toLowerCase().replaceAll(',', ' ')))
          if (w.isNotEmpty && w.length <= 30) w,
    ].take(8).toList(),
  );
}

/// The user message: when it was said, then the numbered transcript lines.
String buildPrompt(List<Row> segments, DateTime? saidAt, DateTime now) {
  final b = StringBuffer('Today is ${now.toIso8601String().substring(0, 16)}.\n');
  if (saidAt != null) b.writeln('This was said at ${saidAt.toIso8601String().substring(0, 16)}.');
  b.writeln('Transcript:');
  for (var i = 0; i < segments.length; i++) {
    b.writeln('${i + 1}. ${segments[i]['speaker'] ?? 'Speaker'}: ${segments[i]['text']}');
  }
  return b.toString();
}

/// Model output is untrusted: keeps only well-formed items that point at a real line.
List<NewItem> parseItems(String json, List<int> segmentIds) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return [];
  }
  final list = decoded is Map ? decoded['items'] : null;
  if (list is! List) return [];
  final out = <NewItem>[];
  for (final e in list) {
    if (e is! Map) continue;
    final kind = e['kind'], line = e['line'], text = e['text'], due = e['due'];
    if (kind is! String || !itemKinds.containsKey(kind)) continue;
    if (line is! int || line < 1 || line > segmentIds.length) continue;
    if (text is! String || text.trim().isEmpty) continue;
    final t = text.trim();
    out.add((
      segmentId: segmentIds[line - 1],
      kind: kind,
      text: t.length > 300 ? t.substring(0, 300) : t,
      dueMs: due is String ? DateTime.tryParse(due)?.millisecondsSinceEpoch : null,
    ));
  }
  return out;
}

/// Pulls items out of transcribed chunks one at a time, newest first. The DB is the queue: a chunk is
/// pending until it has an `extracted` row, and re-transcribing a chunk clears that row.
class UnderstandingService extends ChangeNotifier {
  UnderstandingService(this.db, this.modelDir, {required this.mayRunNow, Generate? generate})
      : _generateOverride = generate;

  final AppDb db;
  final Directory modelDir;
  final Future<bool> Function() mayRunNow;
  final Generate? _generateOverride;

  bool modelReady = false, downloading = false, working = false;
  double downloadProgress = 0;
  String? error;

  Future<void>? _running;
  bool _again = false;
  LlamaEngine? _engine; // ~1.4 GB while loaded, so only while the queue drains

  void start() {
    modelReady = isDownloaded(modelDir, llmModel);
    kick();
  }

  Future<void> kick() {
    _again = true;
    return _running ??= _drain().whenComplete(() {
      _running = null;
      if (_again) kick();
    });
  }

  Future<void> _drain() async {
    try {
      while (_again) {
        _again = false;
        while ((modelReady || _generateOverride != null) && await mayRunNow()) {
          final generate = _generateOverride ?? _generate;
          final next = db.nextUnextracted();
          if (next != null) {
            working = true;
            notifyListeners();
            final segments = db.segments(next.id);
            final start = next.startMs;
            final reply = await generate(_system,
                buildPrompt(segments, start == null ? null : DateTime.fromMillisecondsSinceEpoch(start), DateTime.now()),
                _schema);
            db.saveItems(next.id, parseItems(reply, [for (final s in segments) s['id'] as int]));
          } else {
            // Items first; then summaries for days that changed.
            final stale = staleDays(db.chunks(), db.spokenChunkIds(),
                {for (final e in db.summaries().entries) e.key: e.value.chunkCount}, DateTime.now());
            if (stale.isEmpty) break;
            working = true;
            notifyListeners();
            final (day, chunks) = stale.first;
            final summary = parseSummary(await generate(_summarySystem, _dayTranscript(chunks), _summarySchema));
            // An unusable reply still records the count, so a bad day is not retried in a loop.
            db.saveSummary(day, summary?.text ?? '', summary?.topics ?? const [], chunks.length);
          }
          error = null;
          notifyListeners();
        }
      }
    } catch (e) {
      _again = false; // retried on the next kick, not in a tight loop
      error = 'Understanding stopped: $e';
    } finally {
      working = false;
      final engine = _engine;
      _engine = null;
      await engine?.dispose();
      notifyListeners();
    }
  }

  /// The day's lines in order, capped so the prompt fits the context window.
  String _dayTranscript(List<Chunk> chunks) {
    final b = StringBuffer();
    for (final c in chunks) {
      for (final s in db.segments(c.id)) {
        b.writeln('${s['speaker'] ?? 'Speaker'}: ${s['text']}');
      }
    }
    // shortcut: keeps the first ~2500 tokens of a long day; a map-reduce over conversations would cover all of it.
    final t = b.toString();
    return t.length > 10000 ? t.substring(0, 10000) : t;
  }

  Future<String> _generate(String system, String user, Map<String, Object> schema) async {
    final engine = _engine ??= await LlamaEngine.load(
        LlamaModel(ModelSource.path('${modelDir.path}/${llmModel.name}')),
        params: const ModelParams(contextSize: 4096));
    return engine
        .create([
          LlamaChatMessage.fromText(role: LlamaChatRole.system, text: system),
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: user),
        ], params: const GenerationParams(maxTokens: 768, temp: 0.2), enableThinking: false, responseFormat: schema)
        .text();
  }

  Future<void> downloadModel() async {
    if (downloading) return;
    downloading = true;
    error = null;
    notifyListeners();
    final client = HttpClient();
    try {
      await checkNetwork(db);
      await downloadVerified(client, modelDir, llmModel, (got) {
        final p = got / llmModel.size;
        if ((p * 100).floor() != (downloadProgress * 100).floor()) {
          downloadProgress = p;
          notifyListeners();
        }
      });
      modelReady = true;
      kick();
    } catch (e) {
      error = 'Model download failed: $e';
    } finally {
      client.close(force: true);
      downloading = false;
      notifyListeners();
    }
  }
}
