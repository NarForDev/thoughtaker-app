import 'dart:math';
import 'dart:typed_data';

// shortcut: not calibrated on the user's own voice; set it from the measured same/different score gap.
const voiceThreshold = 0.5;

double cosine(Float32List a, Float32List b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return na == 0 || nb == 0 ? 0 : dot / sqrt(na * nb);
}

// Scores this close to the threshold are guesses; those lines are worth asking about.
const voiceUnsureMargin = 0.12;

/// How close [voice] is to the user's own: the best match among their samples, 0 without any.
double myVoiceScore(Float32List voice, List<Float32List> samples) =>
    samples.fold(0.0, (best, s) => max(best, cosine(voice, s)));

/// True when [voice] is close enough to a sample the user marked as theirs, and closer to it than to any line
/// they said was not them.
bool isMyVoice(Float32List voice, List<Float32List> mine, [List<Float32List> notMine = const []]) {
  final score = myVoiceScore(voice, mine);
  return score >= voiceThreshold && score > myVoiceScore(voice, notMine);
}

bool isUnsure(double score) => (score - voiceThreshold).abs() < voiceUnsureMargin;

/// The id of the nearest centroid at or above the threshold, or null when [voice] is someone new.
int? nearestSpeaker(Map<int, Float32List> centroids, Float32List voice) {
  int? best;
  var bestScore = voiceThreshold;
  for (final MapEntry(key: id, value: c) in centroids.entries) {
    final s = cosine(voice, c);
    if (s >= bestScore) (best, bestScore) = (id, s);
  }
  return best;
}

/// The centroid of [n] voices after adding [voice].
Float32List addToMean(Float32List centroid, int n, Float32List voice) =>
    Float32List.fromList([for (var i = 0; i < voice.length; i++) (centroid[i] * n + voice[i]) / (n + 1)]);

Uint8List voiceBytes(Float32List v) => Uint8List.sublistView(v);

// Copies, because a BLOB's bytes may not be 4-byte aligned for a Float32List view.
Float32List voiceFromBytes(Uint8List b) => Uint8List.fromList(b).buffer.asFloat32List();
