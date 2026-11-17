/// Seam for the on-device transcription stage. It is called once per chunk after the chunk is
/// committed to app storage, and is expected to fill `transcript_segments` for [chunkId].
abstract class TranscriptionService {
  Future<void> transcribe(int chunkId, String chunkPath);
}
