// Opt-in end-to-end check with the real models on the desktop VM:
//   TT_MODELS=<dir> TT_WAVS=<dir with 0.wav and 1.wav from the sherpa-onnx-whisper-base repo>
//   TT_SHERPA=<pub cache>/sherpa_onnx_windows-<ver>/windows/x64 flutter test test/transcription_models_test.dart
// Missing models are downloaded into TT_MODELS through the app's own download path.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:thoughtaker_app/ai/on_device_transcription.dart';
import 'package:thoughtaker_app/db.dart';
import 'package:thoughtaker_app/protocol.dart';

import 'adpcm_test.dart' show encodeImaAdpcm;

Int16List wavPcm(String path) {
  final b = File(path).readAsBytesSync();
  for (var i = 12; i + 8 <= b.length;) {
    final len = ByteData.sublistView(b).getUint32(i + 4, Endian.little);
    if (String.fromCharCodes(b, i, i + 4) == 'data') {
      return Int16List.fromList(Int16List.sublistView(b, i + 8, i + 8 + len));
    }
    i += 8 + len;
  }
  throw const FormatException('no data chunk');
}

void main() {
  final env = Platform.environment;
  final models = env['TT_MODELS'], wavs = env['TT_WAVS'], sherpaDir = env['TT_SHERPA'];
  test('VAD + Whisper transcribe a pendant-format chunk', () async {
    // Windows' System32 ships an older onnxruntime.dll that would win the DLL search; load sherpa's by path first.
    DynamicLibrary.open('$sherpaDir/onnxruntime.dll');
    DynamicLibrary.open('$sherpaDir/sherpa-onnx-c-api.dll');
    final dir = Directory(models!);
    final db = AppDb(sqlite3.openInMemory());
    final svc = OnDeviceTranscriptionService(db, dir, isPluggedIn: () async => true);
    await svc.downloadModels();
    expect(svc.error, isNull);
    expect(svc.modelsReady, isTrue);

    // 2 s silence, utterance, 3 s silence, utterance, 1 s silence, all on a +3000 DC offset like the INMP441's.
    final a = wavPcm('$wavs/0.wav'), b = wavPcm('$wavs/1.wav');
    final pcm = [
      ...List.filled(32000, 0), ...a, ...List.filled(48000, 0), ...b, ...List.filled(16000, 0) //
    ].map((s) => (s + 3000).clamp(-32768, 32767)).toList();
    final (adpcm, _) = encodeImaAdpcm(pcm);
    final file = File('${Directory.systemTemp.createTempSync('tt').path}/1.wav')
      ..writeAsBytesSync([...Uint8List(headerSize), ...adpcm]);
    final id = db.insertChunk(
        storeId: 1, seq: 1, bootId: 1, flags: 1, startUptimeMs: 0, startMs: 0, durationMs: pcm.length ~/ 16,
        bookmarksMs: const [], crc: 0, path: file.path);

    final t = Stopwatch()..start();
    await svc.kick();
    final segs = db.segments(id);
    // ignore: avoid_print
    print('${t.elapsedMilliseconds} ms for ${pcm.length ~/ 16} ms of audio:\n'
        '${segs.map((s) => '${s['start_ms']}-${s['end_ms']}: ${s['text']}').join('\n')}');
    expect(svc.error, isNull);
    expect(db.isTranscribed(id), isTrue);
    expect(db.search('yellow lamps').first.startMs, inInclusiveRange(1500, 2500));
    final secondStart = (32000 + a.length + 48000) * 1000 ~/ sampleRate;
    expect(db.search('lovely child').first.startMs, inInclusiveRange(secondStart - 500, secondStart + 500));
  },
      skip: models == null || wavs == null || sherpaDir == null ? 'set TT_MODELS, TT_WAVS and TT_SHERPA' : false,
      timeout: const Timeout(Duration(minutes: 10)));
}
