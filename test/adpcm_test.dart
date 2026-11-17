import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thoughtaker_app/adpcm.dart';

/// Reference IMA ADPCM encoder (Microsoft block layout), as the firmware is expected to implement it.
/// Returns the encoded blocks and the decoder-side reconstruction the encoder tracked.
(Uint8List, Int16List) encodeImaAdpcm(List<int> pcm) {
  final blocks = pcm.length ~/ 505;
  final out = Uint8List(blocks * 256);
  final recon = Int16List(blocks * 505);
  final d = ByteData.sublistView(out);
  var index = 0;
  for (var b = 0; b < blocks; b++) {
    final s = pcm.sublist(b * 505, b * 505 + 505);
    final base = b * 256;
    d.setInt16(base, s[0], Endian.little);
    out[base + 2] = index;
    var pred = s[0];
    recon[b * 505] = pred;
    for (var j = 1; j < 505; j++) {
      var step = imaStepTable[index];
      var diff = s[j] - pred;
      var nib = 0;
      if (diff < 0) {
        nib = 8;
        diff = -diff;
      }
      var vpdiff = step >> 3;
      if (diff >= step) {
        nib |= 4;
        diff -= step;
        vpdiff += step;
      }
      step >>= 1;
      if (diff >= step) {
        nib |= 2;
        diff -= step;
        vpdiff += step;
      }
      step >>= 1;
      if (diff >= step) {
        nib |= 1;
        vpdiff += step;
      }
      pred = (nib & 8 != 0 ? pred - vpdiff : pred + vpdiff).clamp(-32768, 32767);
      index = (index + imaIndexTable[nib]).clamp(0, 88);
      recon[b * 505 + j] = pred;
      final at = base + 4 + ((j - 1) >> 1);
      out[at] |= (j - 1).isEven ? nib : nib << 4;
    }
  }
  return (out, recon);
}

void main() {
  test('hand-computed block: low nibble first, step/index tables', () {
    // predictor 0, index 0 (step 7); nibbles 7, F, 0, 8.
    final block = Uint8List(256)..[4] = 0xF7..[5] = 0x80;
    final pcm = decodeImaAdpcm(block);
    expect(pcm.length, 505);
    expect(pcm.sublist(0, 5), [0, 11, -19, -15, -18]);
  });

  test('predictor clamps at int16 limits and bad index byte is clamped', () {
    final block = Uint8List(256);
    ByteData.sublistView(block).setInt16(0, 32767, Endian.little);
    block[2] = 200; // corrupt: treated as 88 (step 32767)
    block[4] = 0x77;
    final pcm = decodeImaAdpcm(block);
    expect(pcm.sublist(0, 3), [32767, 32767, 32767]);
  });

  test('decoder reproduces the encoder reconstruction exactly on a sine', () {
    final pcm = [for (var i = 0; i < 505 * 40; i++) (8000 * sin(2 * pi * 440 * i / 16000)).round()];
    final (encoded, recon) = encodeImaAdpcm(pcm);
    final decoded = decodeImaAdpcm(encoded);
    expect(decoded, recon);

    var signal = 0.0, noise = 0.0;
    for (var i = 0; i < pcm.length; i++) {
      signal += pcm[i] * pcm[i];
      noise += pow(pcm[i] - decoded[i], 2);
    }
    expect(10 * log(signal / noise) / ln10, greaterThan(20)); // dB
  });

  test('each block decodes on its own', () {
    final pcm = [for (var i = 0; i < 505 * 3; i++) (12000 * sin(2 * pi * 300 * i / 16000)).round()];
    final (encoded, recon) = encodeImaAdpcm(pcm);
    final third = decodeImaAdpcm(Uint8List.sublistView(encoded, 512));
    expect(third, recon.sublist(1010));
    // A trailing partial block is ignored.
    expect(decodeImaAdpcm(Uint8List.sublistView(encoded, 0, 300)).length, 505);
  });

  test('pcmWav writes a canonical 16-bit mono header', () {
    final wav = pcmWav(Int16List.fromList([1, -2]));
    final d = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav, 0, 4), 'RIFF');
    expect(d.getUint16(20, Endian.little), 1);
    expect(d.getUint32(24, Endian.little), 16000);
    expect(d.getUint32(40, Endian.little), 4);
    expect(d.getInt16(46, Endian.little), -2);
  });
}
