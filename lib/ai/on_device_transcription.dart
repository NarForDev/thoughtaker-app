// On-device transcription: Silero VAD finds speech in each chunk, multilingual Whisper base (int8)
// transcribes each region and 3D-Speaker CAM++ fingerprints the voice in it. Models are downloaded once into app storage, never bundled in the APK.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../adpcm.dart';
import '../db.dart';
import '../protocol.dart';
import 'download.dart';

const _whisper = 'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base/resolve/bb53ee204431c90d314c1cc08d28d23e5b7927cc';

// Pinned to a repo commit and checked by size and SHA-256 (download.dart).
const List<ModelFile> models = [
  (
    name: 'silero_vad.onnx',
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
    size: 643854,
    sha256: '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
  ),
  (
    name: 'base-encoder.int8.onnx',
    url: '$_whisper/base-encoder.int8.onnx',
    size: 29120534,
    sha256: '0b8fb1304b6109976038efff5ace81720e00386f3ff6b54ee8c75291ca0a1e11',
  ),
  (
    name: 'base-decoder.int8.onnx',
    url: '$_whisper/base-decoder.int8.onnx',
    size: 130672026,
    sha256: '9759d217388a01b3a4c7c15533201067b48ae819c4daafc8624e64b9409dc02d',
  ),
  (
    name: 'base-tokens.txt',
    url: '$_whisper/base-tokens.txt',
    size: 816730,
    sha256: 'b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126',
  ),
  (
    name: 'campplus.onnx',
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/'
        '3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx',
    size: 28281164,
    sha256: 'aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2',
  ),
];

final modelBytes = models.fold<int>(0, (n, m) => n + m.size);

/// Whisper's non-speech captions, e.g. "[Music]" or "(crowd cheering)".
final noiseTag = RegExp(r'^\s*[\[(].*[\])]\s*$');

// shortcut: shorter regions are left unlabelled; calibrate on the user's own recordings.
const minVoiceMs = 1500;

const _onlyChargingKey = 'transcribe_only_charging';
const _power = MethodChannel('thoughtaker/power');

/// Maps a VAD region (sample offsets from the chunk's first sample) to milliseconds from the chunk start.
(int, int) segmentMs(int startSample, int numSamples) =>
    (startSample * 1000 ~/ sampleRate, (startSample + numSamples) * 1000 ~/ sampleRate);

/// PCM16 to float with a one-pole high-pass (~13 Hz), because the mic's DC offset drifts and skews VAD.
Float32List toFloatNoDc(Int16List pcm) {
  final out = Float32List(pcm.length);
  if (pcm.isEmpty) return out;
  var prevX = pcm[0] / 32768.0, prevY = 0.0;
  for (var i = 0; i < pcm.length; i++) {
    final x = pcm[i] / 32768.0;
    prevY = x - prevX + 0.995 * prevY;
    prevX = x;
    out[i] = prevY;
  }
  return out;
}

sherpa.OfflineRecognizerConfig asrConfig(String dir) => sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        // language '' = Whisper detects it per region, so English mixed with Indian languages still works.
        whisper: sherpa.OfflineWhisperModelConfig(
            encoder: '$dir/base-encoder.int8.onnx', decoder: '$dir/base-decoder.int8.onnx', task: 'transcribe'),
        tokens: '$dir/base-tokens.txt',
        numThreads: 2,
        debug: false,
      ),
    );

/// Runs in a worker isolate. [asrAddress] is a recognizer created by [createRecognizer] in this process.
List<Segment> recognizeChunk(String modelDir, int asrAddress, String chunkPath) {
  sherpa.initBindings();
  final asr = sherpa.OfflineRecognizer.fromPtr(ptr: Pointer.fromAddress(asrAddress), config: asrConfig(modelDir));
  final bytes = File(chunkPath).readAsBytesSync();
  final samples = toFloatNoDc(decodeImaAdpcm(Uint8List.sublistView(bytes, headerSize)));
  final vad = sherpa.VoiceActivityDetector(
    config: sherpa.VadModelConfig(
      // Whisper sees at most 30 s per pass, so long monologues are split at 20 s.
      sileroVad: sherpa.SileroVadModelConfig(model: '$modelDir/silero_vad.onnx', maxSpeechDuration: 20),
      debug: false,
    ),
    bufferSizeInSeconds: 60,
  );
  // shortcut: loaded per chunk; keep it alive beside the recognizer if the load shows up in timings.
  final voices = sherpa.SpeakerEmbeddingExtractor(
      config: sherpa.SpeakerEmbeddingExtractorConfig(model: '$modelDir/campplus.onnx', numThreads: 2, debug: false));
  Float32List? voiceOf(Float32List samples) {
    if (samples.length * 1000 < minVoiceMs * sampleRate) return null;
    final stream = voices.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      stream.inputFinished();
      return voices.isReady(stream) ? voices.compute(stream) : null;
    } finally {
      stream.free();
    }
  }

  final out = <Segment>[];
  void takeRegions() {
    while (!vad.isEmpty()) {
      final region = vad.front();
      vad.pop();
      final stream = asr.createStream();
      stream.acceptWaveform(samples: region.samples, sampleRate: sampleRate);
      asr.decode(stream);
      final text = asr.getResult(stream).text.trim();
      stream.free();
      final (start, end) = segmentMs(region.start, region.samples.length);
      if (text.isNotEmpty && !noiseTag.hasMatch(text)) {
        out.add((startMs: start, endMs: end, text: text, voice: voiceOf(region.samples)));
      }
    }
  }

  try {
    const window = 512; // Silero's frame size at 16 kHz
    for (var i = 0; i < samples.length; i += window) {
      vad.acceptWaveform(Float32List.sublistView(samples, i, i + window < samples.length ? i + window : null));
      takeRegions();
    }
    vad.flush();
    takeRegions();
  } finally {
    vad.free();
    voices.free();
  }
  return out;
}

int createRecognizer(String modelDir) {
  sherpa.initBindings();
  return sherpa.OfflineRecognizer(asrConfig(modelDir)).ptr.address;
}

void freeRecognizer(String modelDir, int address) {
  sherpa.initBindings();
  sherpa.OfflineRecognizer.fromPtr(ptr: Pointer.fromAddress(address), config: asrConfig(modelDir)).free();
}

/// Transcribes committed chunks one at a time, newest first, whenever the models are present and the
/// charging rule allows. The DB is the queue: a chunk is pending until it has a `transcribed` row.
class OnDeviceTranscriptionService extends ChangeNotifier {
  OnDeviceTranscriptionService(this.db, this.modelDir,
      {Future<bool> Function()? isPluggedIn, Future<List<Segment>> Function(String chunkPath)? recognize})
      : _isPluggedIn = isPluggedIn ?? _platformPluggedIn,
        _recognizeOverride = recognize;

  final AppDb db;
  final Directory modelDir;
  final Future<bool> Function() _isPluggedIn;
  final Future<List<Segment>> Function(String chunkPath)? _recognizeOverride;

  bool modelsReady = false, downloading = false, working = false;
  double downloadProgress = 0;
  String? error;

  Future<void>? _running;
  bool _again = false;
  int? _asr; // native recognizer, alive only while the queue drains so ~200 MB is not held while idle
  Timer? _poll;

  static Future<bool> _platformPluggedIn() async => await _power.invokeMethod<bool>('isPluggedIn') ?? false;

  bool get onlyWhileCharging => db.setting(_onlyChargingKey) != '0';

  /// Heavy on-device work (transcription, understanding) runs only when this allows it.
  Future<bool> mayRunNow() async => !onlyWhileCharging || await _isPluggedIn();

  set onlyWhileCharging(bool v) {
    db.setSetting(_onlyChargingKey, v ? null : '0');
    notifyListeners();
    kick();
  }

  void start() {
    modelsReady = models.every((m) => isDownloaded(modelDir, m));
    // shortcut: polls for the phone being plugged in; a power-connected receiver would react instantly.
    _poll = Timer.periodic(const Duration(minutes: 1), (_) => kick());
    kick();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> kick() {
    _again = true;
    return _running ??= _drain().whenComplete(() {
      _running = null;
      if (_again) kick(); // a kick arrived while the last drain was shutting down
    });
  }

  Future<void> _drain() async {
    try {
      while (_again) {
        _again = false;
        while (modelsReady && await mayRunNow()) {
          final next = db.nextUntranscribed();
          if (next == null) break;
          working = true;
          notifyListeners();
          db.saveTranscript(next.id, await (_recognizeOverride ?? _recognize)(next.path));
          error = null;
        }
      }
    } catch (e) {
      _again = false; // retried on the next kick, not in a tight loop
      error = 'Transcription stopped: $e';
    } finally {
      working = false;
      final asr = _asr, dir = modelDir.path;
      _asr = null;
      if (asr != null) await Isolate.run(() => freeRecognizer(dir, asr));
      notifyListeners();
    }
  }

  Future<List<Segment>> _recognize(String chunkPath) async {
    final dir = modelDir.path;
    final asr = _asr ?? await Isolate.run<int>(() => createRecognizer(dir));
    _asr = asr;
    return Isolate.run(() => recognizeChunk(dir, asr, chunkPath));
  }

  /// Downloads missing models with progress, verifying size and SHA-256 before a file is used.
  Future<void> downloadModels() async {
    if (downloading) return;
    downloading = true;
    error = null;
    notifyListeners();
    final client = HttpClient();
    try {
      await checkNetwork(db);
      var done = 0;
      for (final m in models) {
        await downloadVerified(client, modelDir, m, (got) {
          final p = (done + got) / modelBytes;
          if ((p * 100).floor() != (downloadProgress * 100).floor()) {
            downloadProgress = p;
            notifyListeners();
          }
        });
        done += m.size;
      }
      modelsReady = true;
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
