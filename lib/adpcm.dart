// IMA ADPCM (Microsoft WAV variant, tag 0x0011) mono decoder, per docs/protocol.md 1.1.
import 'dart:typed_data';

import 'protocol.dart';

const imaStepTable = [
  7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, //
  107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
  876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428,
  4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350,
  22385, 24623, 27086, 29794, 32767,
];
const imaIndexTable = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8];

/// Decodes whole 256-byte blocks of [data] (the WAV `data` payload) to PCM16.
Int16List decodeImaAdpcm(Uint8List data) {
  final blocks = data.length ~/ blockSize;
  final out = Int16List(blocks * samplesPerBlock);
  final d = ByteData.sublistView(data);
  var o = 0;
  for (var b = 0; b < blocks; b++) {
    final base = b * blockSize;
    var pred = d.getInt16(base, Endian.little);
    // A corrupt index byte must not index past the table.
    var index = data[base + 2].clamp(0, 88);
    out[o++] = pred;
    for (var j = 0; j < samplesPerBlock - 1; j++) {
      // Low nibble is the earlier sample.
      final n = (data[base + 4 + (j >> 1)] >> ((j & 1) * 4)) & 0x0F;
      final step = imaStepTable[index];
      var diff = step >> 3;
      if (n & 1 != 0) diff += step >> 2;
      if (n & 2 != 0) diff += step >> 1;
      if (n & 4 != 0) diff += step;
      pred = (n & 8 != 0 ? pred - diff : pred + diff).clamp(-32768, 32767);
      index = (index + imaIndexTable[n]).clamp(0, 88);
      out[o++] = pred;
    }
  }
  return out;
}

/// Builds a plain 16-bit PCM WAV file that any player can open.
Uint8List pcmWav(Int16List samples, {int rate = sampleRate}) {
  final dataLen = samples.length * 2;
  final out = Uint8List(44 + dataLen);
  final d = ByteData.sublistView(out);
  void tag(int o, String s) => out.setRange(o, o + 4, s.codeUnits);
  tag(0, 'RIFF');
  d.setUint32(4, 36 + dataLen, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, 1, Endian.little);
  d.setUint16(22, 1, Endian.little);
  d.setUint32(24, rate, Endian.little);
  d.setUint32(28, rate * 2, Endian.little);
  d.setUint16(32, 2, Endian.little);
  d.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  d.setUint32(40, dataLen, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    d.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return out;
}

/// Converts a stored chunk file (512-byte header + ADPCM) to a PCM16 WAV.
Uint8List chunkToPcmWav(Uint8List chunk) => pcmWav(decodeImaAdpcm(Uint8List.sublistView(chunk, headerSize)));
