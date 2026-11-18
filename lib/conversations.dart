import 'db.dart';

/// Chunks further apart than this start a new conversation.
const maxGapMs = 120000;

/// Orders chunks newest first. A chunk with unknown time borrows the time of the nearest
/// known chunk of the same store (protocol 1.4), so it sits in the right place by seq.
List<(Chunk, int?)> placeChunks(List<Chunk> byStoreSeq) {
  final approx = [for (final c in byStoreSeq) c.startMs];
  for (var i = 1; i < approx.length; i++) {
    if (approx[i] == null && byStoreSeq[i].storeId == byStoreSeq[i - 1].storeId) approx[i] = approx[i - 1];
  }
  for (var i = approx.length - 2; i >= 0; i--) {
    if (approx[i] == null && byStoreSeq[i].storeId == byStoreSeq[i + 1].storeId) approx[i] = approx[i + 1];
  }
  final placed = [for (var i = 0; i < byStoreSeq.length; i++) (byStoreSeq[i], approx[i])];
  // List.sort is not stable, so break ties on the original order.
  final order = {for (var i = 0; i < placed.length; i++) placed[i].$1: i};
  placed.sort((a, b) {
    final c = (b.$2 ?? -1).compareTo(a.$2 ?? -1);
    return c != 0 ? c : order[b.$1]!.compareTo(order[a.$1]!);
  });
  return placed;
}

/// Back-to-back chunks of one recording run, oldest first.
class Conversation {
  Conversation(this.chunks, this.startMs);

  final List<Chunk> chunks;
  final int? startMs; // placed time of the first chunk; null = unknown

  int get durationMs => chunks.fold(0, (t, c) => t + c.durationMs);
  bool get hasSpeech => chunks.first.hasSpeech;
  bool get bookmarked => chunks.any((c) => c.bookmarked);
  int get bookmarks => chunks.fold(0, (n, c) => n + c.bookmarksMs.length);
}

/// Groups chunks (store, seq order) into conversations, newest first: same store, consecutive seq,
/// same speech state, and at most [maxGapMs] of silence between them when both times are known.
/// A gap in seq means audio was not kept in between (pre-roll nobody said "Perthro" for, "Perthro forget",
/// or a deleted chunk), so it always starts a new conversation.
List<Conversation> groupConversations(List<Chunk> byStoreSeq) {
  final runs = <(List<Chunk>, int?)>[];
  int? prevAt;
  for (final (c, at) in placeChunks(byStoreSeq).reversed) {
    final run = runs.lastOrNull?.$1;
    final prev = run?.last;
    final joins = prev != null &&
        prev.storeId == c.storeId &&
        prev.seq + 1 == c.seq &&
        prev.hasSpeech == c.hasSpeech &&
        (at == null || prevAt == null || at - (prevAt + prev.durationMs) <= maxGapMs);
    if (joins) {
      run!.add(c);
    } else {
      runs.add(([c], at));
    }
    prevAt = at;
  }
  return [for (final (chunks, at) in runs.reversed) Conversation(chunks, at)];
}
