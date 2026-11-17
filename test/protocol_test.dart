import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thoughtaker_app/adpcm.dart';
import 'package:thoughtaker_app/protocol.dart';

/// Builds a chunk file exactly as protocol.md 1.4/1.5 describes the device writing it.
Uint8List buildChunk({
  required int storeId,
  required int seq,
  int blocks = 3,
  int flags = flagSpeech | flagTimeSynced,
  int bootId = 7,
  int startUptimeMs = 123456,
  int epochOffsetMs = 1700000000000,
  List<int> bookmarks = const [],
}) {
  final f = Uint8List(512 + blocks * 256);
  final d = ByteData.sublistView(f);
  void tag(int o, String s) => f.setRange(o, o + 4, s.codeUnits);
  tag(0, 'RIFF');
  d.setUint32(4, 504 + blocks * 256, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  d.setUint32(16, 20, Endian.little);
  d.setUint16(20, 0x11, Endian.little);
  d.setUint16(22, 1, Endian.little);
  d.setUint32(24, 16000, Endian.little);
  d.setUint32(28, 8110, Endian.little);
  d.setUint16(32, 256, Endian.little);
  d.setUint16(34, 4, Endian.little);
  d.setUint16(36, 2, Endian.little);
  d.setUint16(38, 505, Endian.little);
  tag(40, 'fact');
  d.setUint32(44, 4, Endian.little);
  d.setUint32(48, blocks * 505, Endian.little);
  tag(52, 'tkmd');
  d.setUint32(56, 444, Endian.little);
  d.setUint16(60, 1, Endian.little);
  d.setUint16(62, flags | (bookmarks.isEmpty ? 0 : flagBookmarked), Endian.little);
  d.setUint32(64, storeId, Endian.little);
  d.setUint32(68, seq, Endian.little);
  d.setUint32(72, bootId, Endian.little);
  d.setUint64(76, startUptimeMs, Endian.little);
  d.setInt64(84, epochOffsetMs, Endian.little);
  f[96] = bookmarks.length;
  for (var i = 0; i < bookmarks.length; i++) {
    d.setUint32(100 + i * 4, bookmarks[i], Endian.little);
  }
  tag(504, 'data');
  d.setUint32(508, blocks * 256, Endian.little);
  for (var i = 512; i < f.length; i++) {
    f[i] = i * 31;
  }
  // Audio first, then the header with the crc field still zero.
  d.setUint32(92, crc32(Uint8List.sublistView(f, 0, 512), crc32(Uint8List.sublistView(f, 512))), Endian.little);
  return f;
}

void main() {
  test('crc32 matches zlib check value and continues across pieces', () {
    expect(crc32('123456789'.codeUnits), 0xCBF43926);
    expect(crc32('6789'.codeUnits, crc32('12345'.codeUnits)), 0xCBF43926);
  });

  test('verify accepts a well-formed chunk and reads its metadata', () {
    final f = buildChunk(storeId: 0xA1B2C3D4, seq: 0x1A, bookmarks: [1500, 42000]);
    final h = ChunkHeader.verify(f, seq: 0x1A);
    expect(h.storeId, 0xA1B2C3D4); // from the header, so chunks from an older store_id still sync
    expect(h.bootId, 7);
    expect(h.startUptimeMs, 123456);
    expect(h.epochOffsetMs, 1700000000000);
    expect(h.bookmarksMs, [1500, 42000]);
    expect(h.flags & flagBookmarked, isNonZero);
    expect(h.durationMs, 3 * 505 * 1000 ~/ 16000);
    expect(chunkToPcmWav(f).length, 44 + 3 * 505 * 2);
  });

  test('verify rejects corruption, wrong identity and truncation', () {
    final f = buildChunk(storeId: 1, seq: 2);
    expect(() => ChunkHeader.verify(Uint8List.fromList(f)..[700] ^= 1, seq: 2), throwsFormatException);
    expect(() => ChunkHeader.verify(Uint8List.fromList(f)..[97] = 1, seq: 2), throwsFormatException);
    expect(() => ChunkHeader.verify(Uint8List.fromList(f)..[64] ^= 1, seq: 2), throwsFormatException); // crc covers store_id
    expect(() => ChunkHeader.verify(f, seq: 3), throwsFormatException);
    expect(() => ChunkHeader.verify(Uint8List.sublistView(f, 0, f.length - 256), seq: 2), throwsFormatException);
  });

  test('status and LIST payloads parse per 3.3', () {
    final p = Uint8List(32);
    final d = ByteData.sublistView(p);
    d.setUint16(0, 1, Endian.little);
    p[2] = 0x02 | 0x08 | 0x10;
    p[3] = 0xFF;
    d.setUint32(4, 0xDEADBEEF, Endian.little);
    d.setUint64(12, 99999, Endian.little);
    d.setUint32(28, 5, Endian.little);
    final s = DeviceStatus.parse(p, 0);
    expect([s.protoVersion, s.storeId, s.uptimeMs, s.pendingChunks], [1, 0xDEADBEEF, 99999, 5]);
    expect([s.muted, s.timeSynced, s.storageFull, s.recording], [true, true, true, false]);
    expect(() => DeviceStatus.parse(Uint8List(31), 0), throwsFormatException);

    final list = Uint8List.fromList([3, 0, 0, 0, 2, ...u32(0x10), ...u32(487168), 3, ...u32(0x11), ...u32(1024), 0]);
    final (total, entries) = parseList(list);
    expect(total, 3);
    expect([for (final e in entries) (e.seq, e.size, e.flags)], [(0x10, 487168, 3), (0x11, 1024, 0)]);
    expect(() => parseList(Uint8List.sublistView(list, 0, 10)), throwsFormatException);
  });

  test('request framing and seq hex', () {
    expect(requestFrame(opPull, 9, [...u32(1), ...u32(2), ...u32(3)]),
        [4, 9, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0]);
    expect(seqHex(0x1A), '000001A');
  });
}
